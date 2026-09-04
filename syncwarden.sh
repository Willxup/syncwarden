#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 5 )); then
    printf 'SyncWarden requires Bash 5 or newer; found %s.\n' "$BASH_VERSION" >&2
    return 69 2>/dev/null || exit 69
fi

set -uo pipefail
shopt -s extglob

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SYNCWARDEN_HOME=${SYNCWARDEN_HOME:-$SCRIPT_DIR}
CONFIG_FILE=${SYNCWARDEN_CONFIG:-$SYNCWARDEN_HOME/syncwarden.conf}

log_reference_epoch() {
    if [[ -n "${SYNCWARDEN_NOW_EPOCH:-}" ]]; then
        printf '%s\n' "$SYNCWARDEN_NOW_EPOCH"
    else
        date +%s
    fi
}

refresh_log_paths() {
    local epoch=${1-} month
    [[ -n "$epoch" ]] || epoch=$(log_reference_epoch) || return 1
    month=$(date -d "@$epoch" +%Y-%m) || return 1
    SUCCESS_LOG="$LOG_DIR/success-$month.log"
    FAILURE_LOG="$LOG_DIR/failure-$month.log"
}

configure_home_paths() {
    SYNCWARDEN_HOME=$1
    LOG_DIR="$SYNCWARDEN_HOME/logs"
    ROTATED_LOG_DIR="$LOG_DIR/rotated"
    STATE_DIR="$SYNCWARDEN_HOME/state"
    ARCHIVE_INDEX_DIR="$STATE_DIR/archive-index"
    LAST_STATUS_DIR="$STATE_DIR/last-status"
    SCHEDULE_STATE_DIR="$STATE_DIR/schedule"
    LOCK_FILE="$STATE_DIR/syncwarden.lock"
    TMP_DIR="$SYNCWARDEN_HOME/tmp"
    refresh_log_paths
}

configure_home_paths "$SYNCWARDEN_HOME"

ZIP_BIN=${SYNCWARDEN_ZIP_BIN:-$(command -v zip 2>/dev/null || printf 'zip')}
TIMEOUT_BIN=${SYNCWARDEN_TIMEOUT_BIN:-$(command -v timeout 2>/dev/null || printf 'timeout')}
SHA256_BIN=${SYNCWARDEN_SHA256_BIN:-$(command -v sha256sum 2>/dev/null || printf 'sha256sum')}
CHOWN_BIN=${SYNCWARDEN_CHOWN_BIN:-$(command -v chown 2>/dev/null || printf 'chown')}
SSH_BIN=${SYNCWARDEN_SSH_BIN:-$(command -v ssh 2>/dev/null || printf 'ssh')}
RSYNC_BIN=${SYNCWARDEN_RSYNC_BIN:-$(command -v rsync 2>/dev/null || printf 'rsync')}
SLEEP_BIN=${SYNCWARDEN_SLEEP_BIN:-$(command -v sleep 2>/dev/null || printf 'sleep')}
DF_BIN=${SYNCWARDEN_DF_BIN:-$(command -v df 2>/dev/null || printf 'df')}
RM_BIN=${SYNCWARDEN_RM_BIN:-$(command -v rm 2>/dev/null || printf 'rm')}
GZIP_BIN=${SYNCWARDEN_GZIP_BIN:-$(command -v gzip 2>/dev/null || printf 'gzip')}
FIND_BIN=${SYNCWARDEN_FIND_BIN:-$(command -v find 2>/dev/null || printf 'find')}
SORT_BIN=${SYNCWARDEN_SORT_BIN:-$(command -v sort 2>/dev/null || printf 'sort')}
LOG_MAINTENANCE_MESSAGES=''
FAILURE_BODY_RESULT=''

# Fixed safety limits for individual external commands. Only rsync's
# continuous no-I/O timeout belongs to the user configuration contract.
SSH_CONNECT_TIMEOUT_SECONDS=60
SSH_PREFLIGHT_TIMEOUT_SECONDS=120
CAPACITY_CHECK_TIMEOUT_SECONDS=30
ARCHIVE_CREATE_TIMEOUT_SECONDS=3600
ARCHIVE_VERIFY_TIMEOUT_SECONDS=1800
ARCHIVE_CHECKSUM_TIMEOUT_SECONDS=1800
LOCAL_COMMAND_TIMEOUT_SECONDS=60
LOG_COMMAND_TIMEOUT_SECONDS=300
GLOBAL_RUNTIME_TIMEOUT_SECONDS=18000
GLOBAL_TIMEOUT_KILL_GRACE_SECONDS=60

LAST_CONFIG_ERROR=''

RSYNC_CHANGE_PREFIX='__SYNCWARDEN_CHANGE__:'
LAST_CHANGE_COUNT=0
LAST_CHANGE_CREATED=0
LAST_CHANGE_UPDATED=0
LAST_CHANGE_DELETED=0
LAST_CHANGE_ATTEMPTS=0
LAST_CHANGE_PARSE_FAILED=0
LAST_CHANGE_COMPLETE='no'
LAST_TRANSFER_BYTES=0
LAST_TRANSFER_DURATION_US=0
LAST_SOURCE_NAME=''

declare -A GLOBAL=()
declare -A DEFAULTS=()
declare -A SERVER_VALUES=()
declare -A SERVER_SOURCE_COUNT=()
declare -A SERVER_SOURCES=()
declare -A SEEN_KEYS=()
declare -A SEEN_SERVER_SECTIONS=()
declare -a SERVER_IDS=()
declare -a ACTIVE_TEMP_FILES=()

trim() {
    local value=${1-}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

config_error() {
    [[ -n "$LAST_CONFIG_ERROR" ]] || LAST_CONFIG_ERROR=$1
    printf 'configuration error: %s\n' "$1" >&2
    return 1
}

reset_config() {
    LAST_CONFIG_ERROR=''
    GLOBAL=()
    DEFAULTS=()
    SERVER_VALUES=()
    SERVER_SOURCE_COUNT=()
    SERVER_SOURCES=()
    SEEN_KEYS=()
    SEEN_SERVER_SECTIONS=()
    SERVER_IDS=()
}

is_allowed_key() {
    local section=$1
    local key=$2

    case "$section:$key" in
        global:sync_hours|global:log_retention_months)
            return 0
            ;;
    esac

    case "$section" in
        defaults)
            case "$key" in
                scheduled_sync_enabled|port|user|key_file|rsync_timeout_seconds|retry_count|retry_delays_seconds|owner|archive_recent_keep|archive_monthly_keep|min_free_space_mb|min_free_inodes)
                    return 0
                    ;;
            esac
            ;;
        server)
            case "$key" in
                host|name|scheduled_sync_enabled|port|user|key_file|rsync_timeout_seconds|retry_count|retry_delays_seconds|source|destination|owner|archive_recent_keep|archive_monthly_keep|min_free_space_mb|min_free_inodes)
                    return 0
                    ;;
            esac
            ;;
    esac

    return 1
}

load_config() {
    local file=$1
    local raw line section='' server_id='' key value seen_key index line_number=0

    reset_config

    [[ -r "$file" ]] || config_error "config file is not readable: $file" || return 1

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line_number=$((line_number + 1))
        raw=${raw%$'\r'}
        line=$(trim "$raw")

        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^\[([^][]+)\]$ ]]; then
            case "${BASH_REMATCH[1]}" in
                global)
                    section='global'
                    server_id=''
                    ;;
                defaults)
                    section='defaults'
                    server_id=''
                    ;;
                server:*)
                    server_id=${BASH_REMATCH[1]#server:}
                    [[ "$server_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
                        config_error "line $line_number: invalid server ID '$server_id'"
                        return 1
                    }
                    [[ -z "${SEEN_SERVER_SECTIONS[$server_id]+x}" ]] || {
                        config_error "line $line_number: duplicate server section '$server_id'"
                        return 1
                    }
                    SEEN_SERVER_SECTIONS[$server_id]=1
                    SERVER_IDS+=("$server_id")
                    SERVER_SOURCE_COUNT[$server_id]=0
                    section='server'
                    ;;
                *)
                    config_error "line $line_number: unknown section '${BASH_REMATCH[1]}'"
                    return 1
                    ;;
            esac
            continue
        fi

        [[ -n "$section" ]] || {
            config_error "line $line_number: key/value appears before a section"
            return 1
        }
        [[ "$line" == *=* ]] || {
            config_error "line $line_number: expected key=value"
            return 1
        }

        key=$(trim "${line%%=*}")
        value=$(trim "${line#*=}")
        [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || {
            config_error "line $line_number: invalid key '$key'"
            return 1
        }
        is_allowed_key "$section" "$key" || {
            config_error "line $line_number: unknown key '$key' in [$section]"
            return 1
        }

        if [[ "$section" == 'server' ]]; then
            seen_key="server:$server_id:$key"
        else
            seen_key="$section:$key"
        fi

        if [[ "$key" != 'source' && -n "${SEEN_KEYS[$seen_key]+x}" ]]; then
            config_error "line $line_number: duplicate key '$key'"
            return 1
        fi
        SEEN_KEYS[$seen_key]=1

        case "$section:$key" in
            server:source)
                index=${SERVER_SOURCE_COUNT[$server_id]:-0}
                SERVER_SOURCES["$server_id:$index"]=$value
                SERVER_SOURCE_COUNT[$server_id]=$((index + 1))
                ;;
            global:*)
                GLOBAL[$key]=$value
                ;;
            defaults:*)
                DEFAULTS[$key]=$value
                ;;
            server:*)
                SERVER_VALUES["$server_id:$key"]=$value
                ;;
        esac
    done <"$file"

    return 0
}

resolve_value() {
    local server_id=$1
    local key=$2
    local composite="$server_id:$key"
    local value

    if [[ -n "${SERVER_VALUES[$composite]+x}" ]]; then
        value=${SERVER_VALUES[$composite]}
    else
        value=${DEFAULTS[$key]-}
    fi

    if [[ "$key" == 'name' && ( -z "$value" || "$value" == 'null' ) ]]; then
        value=$server_id
    fi
    printf '%s\n' "$value"
}

resolved_destination() {
    local server_id=$1
    printf '%s\n' "${SERVER_VALUES["$server_id:destination"]-}"
}

get_server_sources() {
    local server_id=$1
    local output_name=$2
    local -n output=$output_name
    local count index

    output=()
    count=${SERVER_SOURCE_COUNT[$server_id]:-0}
    for ((index = 0; index < count; index++)); do
        output+=("${SERVER_SOURCES["$server_id:$index"]}")
    done
}

source_local_name() {
    local remote=$1
    printf '%s\n' "${remote##*/}"
}

is_yes_no() {
    [[ "$1" == 'yes' || "$1" == 'no' ]]
}

is_decimal_integer() {
    [[ "$1" == '0' || "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_integer() {
    is_decimal_integer "$1"
}

is_positive_integer() {
    is_decimal_integer "$1" && (( 10#$1 > 0 ))
}

paths_overlap() {
    local first=$1 second=$2
    [[ "$first" == "$second" || "$first" == "$second/"* || "$second" == "$first/"* ]]
}

path_in_protected_tree() {
    local path=$1 protected
    local -a protected_trees=(/boot /dev /etc /proc /run /sys /usr)
    for protected in "${protected_trees[@]}"; do
        [[ "$path" == "$protected" || "$path" == "$protected/"* ]] && return 0
    done
    return 1
}

validate_source_spec() {
    local server_id=$1
    local remote=$2 local_name component
    local -a components=()

    [[ -n "$remote" ]] || {
        config_error "server '$server_id': source must not be empty"
        return 1
    }
    [[ "$remote" == /* ]] || {
        config_error "server '$server_id': remote source must be absolute: '$remote'"
        return 1
    }
    [[ "$remote" != '/' ]] || {
        config_error "server '$server_id': remote source must not be root"
        return 1
    }
    [[ "$remote" != */ ]] || {
        config_error "server '$server_id': remote source must not end with '/': '$remote'"
        return 1
    }
    [[ "$remote" != *//* ]] || {
        config_error "server '$server_id': remote source contains an unsafe path component: '$remote'"
        return 1
    }
    [[ "$remote" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
        config_error "server '$server_id': remote source contains an unsupported character: '$remote'"
        return 1
    }
    IFS='/' read -r -a components <<<"${remote#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != '.' && "$component" != '..' ]] || {
            config_error "server '$server_id': remote source contains an unsafe path component: '$remote'"
            return 1
        }
    done
    local_name=$(source_local_name "$remote") || return 1
    [[ "$local_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$local_name" != '.' && "$local_name" != '..' ]] || {
        config_error "server '$server_id': remote source derives invalid local name '$local_name'"
        return 1
    }
}

validate_required_config() {
    local key
    local -a global_keys=(sync_hours log_retention_months)
    local -a default_keys=(
        scheduled_sync_enabled port user key_file rsync_timeout_seconds
        retry_count retry_delays_seconds
        owner archive_recent_keep archive_monthly_keep min_free_space_mb min_free_inodes
    )

    for key in "${global_keys[@]}"; do
        [[ -n "${GLOBAL[$key]+x}" && -n "${GLOBAL[$key]}" ]] || {
            config_error "missing required key '$key' in [global]"
            return 1
        }
    done
    for key in "${default_keys[@]}"; do
        [[ -n "${DEFAULTS[$key]+x}" && -n "${DEFAULTS[$key]}" ]] || {
            config_error "missing required key '$key' in [defaults]"
            return 1
        }
    done
}

validate_config() {
    local id host port destination canonical_destination canonical_target canonical_home key value retry_count delay_string hour
    local spec remote local_name target index other_index
    local -a sources=() delays=() hours=() managed_paths=() managed_ids=() managed_kinds=()
    local -A local_names=() resolved_targets=() seen_hours=()

    validate_required_config || return 1

    (( ${#SERVER_IDS[@]} > 0 )) || {
        config_error 'no server sections configured'
        return 1
    }

    canonical_home=$(canonical_path "$SYNCWARDEN_HOME") || {
        config_error "cannot canonicalize SyncWarden home '$SYNCWARDEN_HOME'"
        return 1
    }

    IFS=',' read -r -a hours <<<"${GLOBAL[sync_hours]}"
    (( ${#hours[@]} > 0 )) || {
        config_error 'sync_hours is empty'
        return 1
    }
    for hour in "${hours[@]}"; do
        hour=$(trim "$hour")
        is_nonnegative_integer "$hour" && (( 10#$hour <= 23 )) || {
            config_error "invalid decimal sync hour '$hour'"
            return 1
        }
        [[ -z "${seen_hours[$hour]+x}" ]] || {
            config_error "duplicate sync hour '$hour'"
            return 1
        }
        seen_hours[$hour]=1
    done

    is_positive_integer "${GLOBAL[log_retention_months]}" || {
        config_error "invalid positive decimal integer for 'log_retention_months': '${GLOBAL[log_retention_months]}'"
        return 1
    }

    for id in "${SERVER_IDS[@]}"; do
        host=$(resolve_value "$id" host)
        [[ -n "$host" ]] || {
            config_error "server '$id': missing required host"
            return 1
        }

        port=$(resolve_value "$id" port)
        [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || {
            config_error "server '$id': invalid port '$port'"
            return 1
        }

        value=$(resolve_value "$id" scheduled_sync_enabled)
        is_yes_no "$value" || {
            config_error "server '$id': 'scheduled_sync_enabled' must be yes or no"
            return 1
        }

        for key in rsync_timeout_seconds archive_recent_keep archive_monthly_keep min_free_space_mb min_free_inodes; do
            value=$(resolve_value "$id" "$key")
            is_positive_integer "$value" || {
                config_error "server '$id': '$key' must be a positive decimal integer"
                return 1
            }
        done
        retry_count=$(resolve_value "$id" retry_count)
        is_nonnegative_integer "$retry_count" || {
            config_error "server '$id': retry_count must be a nonnegative decimal integer"
            return 1
        }
        delay_string=$(resolve_value "$id" retry_delays_seconds)
        IFS=',' read -r -a delays <<<"$delay_string"
        if (( ${#delays[@]} < retry_count )); then
            config_error "server '$id': retry delays count is shorter than retry_count"
            return 1
        fi
        for value in "${delays[@]}"; do
            value=$(trim "$value")
            is_nonnegative_integer "$value" || {
                config_error "server '$id': retry delays must be nonnegative decimal integers"
                return 1
            }
        done

        [[ "$(resolve_value "$id" key_file)" == /* ]] || {
            config_error "server '$id': key_file must be absolute"
            return 1
        }
        [[ "$(resolve_value "$id" owner)" == *:* ]] || {
            config_error "server '$id': owner must use USER:GROUP"
            return 1
        }

        destination=$(resolved_destination "$id")
        [[ -n "$destination" ]] || {
            config_error "server '$id': missing required destination"
            return 1
        }
        [[ "$destination" == /* && "$destination" != '/' ]] || {
            config_error "server '$id': invalid destination '$destination'"
            return 1
        }
        [[ "$destination" != *[[:cntrl:]\|]* ]] || {
            config_error "server '$id': destination contains a control character or index delimiter"
            return 1
        }
        canonical_destination=$(canonical_path "$destination") || {
            config_error "server '$id': cannot canonicalize destination '$destination'"
            return 1
        }
        [[ "$canonical_destination" != '/' ]] || {
            config_error "server '$id': canonical destination must not be root"
            return 1
        }
        [[ "$(dirname -- "$canonical_destination")" != '/' ]] || {
            config_error "server '$id': destination must not be directly below root: '$destination'"
            return 1
        }
        [[ -d "$(dirname -- "$canonical_destination")" && ! -L "$(dirname -- "$canonical_destination")" ]] || {
            config_error "server '$id': destination parent must already exist as a real directory: '$(dirname -- "$canonical_destination")'"
            return 1
        }
        if path_in_protected_tree "$canonical_destination" || paths_overlap "$canonical_destination" "$canonical_home"; then
            config_error "server '$id': unsafe managed path '$canonical_destination'"
            return 1
        fi
        if path_has_symlink_component "$destination"; then
            config_error "server '$id': destination contains a symbolic-link component: '$destination'"
            return 1
        fi
        if [[ -e "$destination" && ! -d "$destination" ]]; then
            config_error "server '$id': destination exists but is not a directory: '$destination'"
            return 1
        fi
        managed_paths+=("$canonical_destination")
        managed_ids+=("$id")
        managed_kinds+=(destination)

        sources=()
        get_server_sources "$id" sources
        (( ${#sources[@]} > 0 )) || {
            config_error "server '$id': missing required source"
            return 1
        }
        local_names=()
        for spec in "${sources[@]}"; do
            validate_source_spec "$id" "$spec" || return 1
            remote=$spec
            local_name=$(source_local_name "$remote") || return 1
            [[ -z "${local_names[$local_name]+x}" ]] || {
                config_error "server '$id': duplicate local source name '$local_name'"
                return 1
            }
            local_names[$local_name]=1
            target="${destination%/}/$local_name"
            canonical_target=$(canonical_path "$target") || {
                config_error "server '$id': cannot canonicalize target '$target'"
                return 1
            }
            [[ "$(dirname -- "$canonical_target")" == "$canonical_destination" ]] || {
                config_error "server '$id': target escapes canonical destination: '$target'"
                return 1
            }
            if path_in_protected_tree "$canonical_target" || paths_overlap "$canonical_target" "$canonical_home"; then
                config_error "server '$id': unsafe managed path '$canonical_target'"
                return 1
            fi
            if path_has_symlink_component "$target"; then
                config_error "server '$id': target contains a symbolic-link component: '$target'"
                return 1
            fi
            if [[ -e "$target" && ! -d "$target" ]]; then
                config_error "server '$id': target exists but is not a directory: '$target'"
                return 1
            fi
            [[ -z "${resolved_targets[$canonical_target]+x}" ]] || {
                config_error "duplicate resolved target '$canonical_target' for servers '${resolved_targets[$canonical_target]}' and '$id'"
                return 1
            }
            resolved_targets[$canonical_target]=$id
            managed_paths+=("$canonical_target")
            managed_ids+=("$id")
            managed_kinds+=(target)
        done
    done

    for ((index = 0; index < ${#managed_paths[@]}; index++)); do
        for ((other_index = index + 1; other_index < ${#managed_paths[@]}; other_index++)); do
            [[ "${managed_ids[$index]}" != "${managed_ids[$other_index]}" ]] || continue
            if paths_overlap "${managed_paths[$index]}" "${managed_paths[$other_index]}"; then
                config_error "managed path overlap: server '${managed_ids[$index]}' ${managed_kinds[$index]} '${managed_paths[$index]}' and server '${managed_ids[$other_index]}' ${managed_kinds[$other_index]} '${managed_paths[$other_index]}'"
                return 1
            fi
        done
    done

    return 0
}

ensure_home_layout() {
    umask 077
    mkdir -p -- \
        "$ROTATED_LOG_DIR" \
        "$ARCHIVE_INDEX_DIR" \
        "$LAST_STATUS_DIR" \
        "$SCHEDULE_STATE_DIR" \
        "$TMP_DIR"
    chmod 0700 -- \
        "$LOG_DIR" \
        "$ROTATED_LOG_DIR" \
        "$STATE_DIR" \
        "$ARCHIVE_INDEX_DIR" \
        "$LAST_STATUS_DIR" \
        "$SCHEDULE_STATE_DIR" \
        "$TMP_DIR"
}

render_log_block() {
    local title=$1
    local body=$2
    local major='================================================================================'
    local minor='--------------------------------------------------------------------------------'

    printf '%s\n' "$major"
    printf '%s\n' "$title"
    printf '%s\n' "$minor"
    printf '%s\n' "$body"
    printf '%s\n\n' "$major"
}

append_log_block() {
    local file=$1
    local title=$2
    local body=$3

    mkdir -p -- "$(dirname -- "$file")" || return 1
    [[ ! -e "$file" || ( -f "$file" && ! -L "$file" ) ]] || {
        printf 'log error: target is not a regular file: %s\n' "$file" >&2
        return 1
    }
    render_log_block "$title" "$body" >>"$file" || return 1
    chmod 0600 -- "$file" || return 1
}

persist_configuration_failure() {
    local mode=$1 body reason
    reason=${LAST_CONFIG_ERROR:-UNKNOWN_CONFIGURATION_ERROR}
    RUN_ID=${SYNCWARDEN_RUN_ID:-$(new_run_id)}

    if ! ensure_home_layout; then
        printf 'configuration failure log error: cannot initialize SyncWarden control directories\n' >&2
        return 1
    fi
    refresh_log_paths || {
        printf 'configuration failure log error: cannot determine monthly failure log\n' >&2
        return 1
    }
    body=$(printf '  Time        : %s\n  Run ID      : %s\n  Mode        : %s\n  Config File : %s\n  Stage       : CONFIGURATION\n  Reason      : %s' \
        "$(timestamp_now)" "$RUN_ID" "$mode" "$CONFIG_FILE" "$reason")
    append_log_block "$FAILURE_LOG" 'FAILURE - CONFIGURATION' "$body" || {
        printf 'configuration failure log error: cannot append to %s\n' "$FAILURE_LOG" >&2
        return 1
    }
}

load_runtime_config_or_log() {
    local mode=$1 rc
    load_main_config
    rc=$?
    (( rc == 0 )) && return 0
    persist_configuration_failure "$mode" || :
    return "$rc"
}

server_exists() {
    local wanted=$1
    local id
    for id in "${SERVER_IDS[@]}"; do
        [[ "$id" == "$wanted" ]] && return 0
    done
    return 1
}

check_dependencies() {
    local command_name
    local -a required=(
        bash rsync ssh timeout flock zip find sort awk sed grep stat df date
        mktemp sha256sum gzip readlink cp mv chmod chown rm sleep dirname
        basename mkdir
    )
    local -a missing=()
    for command_name in "${required[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if (( ${#missing[@]} > 0 )); then
        printf 'missing required commands: %s\n' "${missing[*]}" >&2
        return 1
    fi
}

check_private_key() {
    local id=$1 key_file mode
    key_file=$(resolve_value "$id" key_file)
    [[ -f "$key_file" && ! -L "$key_file" && -r "$key_file" ]] || {
        printf "private key error: server '%s' key must be a readable regular non-symlink file: %s\n" "$id" "$key_file" >&2
        return 1
    }
    mode=$(stat -Lc '%a' -- "$key_file" 2>/dev/null) || {
        printf "private key error: cannot read permissions for server '%s': %s\n" "$id" "$key_file" >&2
        return 1
    }
    mode=${mode: -3}
    [[ ${#mode} -eq 3 && "${mode:1:2}" == '00' ]] || {
        printf "private key permissions are unsafe for server '%s': %s is mode %s; group/other access must be 00\n" \
            "$id" "$key_file" "$mode" >&2
        return 1
    }
}

check_private_keys() {
    local id
    for id in "$@"; do
        check_private_key "$id" || return 1
    done
}

load_main_config() {
    load_config "$CONFIG_FILE" && validate_config
}

print_brief_usage() {
    cat <<'USAGE'
用法：
  syncwarden.sh SERVER_ID
  syncwarden.sh SERVER_ID --dry-run
  syncwarden.sh --help
USAGE
}

print_usage() {
    cat <<USAGE
SyncWarden - 带同步前 ZIP 归档保护的远程镜像备份工具

配置文件：$CONFIG_FILE

用法：
  syncwarden.sh SERVER_ID
      同步指定服务器。

  syncwarden.sh SERVER_ID --dry-run
      预览同步变化，不修改镜像或创建 ZIP。

  syncwarden.sh --archive SERVER_ID
      只归档现有本地镜像，不执行同步。

  syncwarden.sh --scheduled
      执行到期的定时同步，供 cron 调用。

  syncwarden.sh --check
  syncwarden.sh --check --show-resolved
      检查配置；第二条命令同时显示最终解析结果。

  syncwarden.sh --list
      列出已配置的服务器。

  syncwarden.sh --status SERVER_ID
      查看服务器最近一次运行状态。

  syncwarden.sh --help
      显示帮助。

短参数：-n、-a、-s、-c、-r、-l、-t、-h

示例：
  syncwarden.sh sample-server
  syncwarden.sh sample-server --dry-run
  syncwarden.sh --archive sample-server
  syncwarden.sh --check --show-resolved

完整配置、安全说明和运行细节请查看项目 README.md。
USAGE
}

print_server_list() {
    local id
    printf '%-20s %-18s %s\n' 'ID' 'SCHEDULED' 'NAME'
    for id in "${SERVER_IDS[@]}"; do
        printf '%-20s %-18s %s\n' "$id" "$(resolve_value "$id" scheduled_sync_enabled)" "$(resolve_value "$id" name)"
    done
}

print_resolved_config() {
    local id key
    local -a sources=()
    for id in "${SERVER_IDS[@]}"; do
        printf '[server:%s]\n' "$id"
        printf 'host=%s\n' "$(resolve_value "$id" host)"
        printf 'name=%s\n' "$(resolve_value "$id" name)"
        for key in scheduled_sync_enabled port user key_file rsync_timeout_seconds retry_count retry_delays_seconds owner archive_recent_keep archive_monthly_keep min_free_space_mb min_free_inodes; do
            printf '%s=%s\n' "$key" "$(resolve_value "$id" "$key")"
        done
        printf 'destination=%s\n' "$(resolved_destination "$id")"
        sources=()
        get_server_sources "$id" sources
        for key in "${sources[@]}"; do
            printf 'source=%s\n' "$key"
        done
        printf '\n'
    done
}

print_status() {
    local id=$1
    local status_file="$LAST_STATUS_DIR/$id.status"
    if [[ ! -f "$status_file" ]]; then
        printf '%s: no recorded status\n' "$id"
        return 0
    fi
    printf 'Status for %s:\n' "$id"
    sed 's/^/  /' "$status_file"
}

archive_basename() {
    local local_name=$1
    local epoch=$2
    printf '%s-%s.zip\n' "$local_name" "$(date -d "@$epoch" +%Y-%m-%d_%H-%M-%S)"
}

archive_name_matches() {
    local local_name=$1
    local basename=$2
    [[ "$basename" == "$local_name"-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]-[0-9][0-9].zip ]]
}

canonical_path() {
    readlink -m -- "$1"
}

path_has_symlink_component() {
    local path=$1 current='/' component
    local -a components=()

    [[ "$path" == /* ]] || return 1
    IFS='/' read -r -a components <<<"${path#/}"
    for component in "${components[@]}"; do
        case "$component" in
            ''|.) continue ;;
            ..)
                current=$(dirname -- "$current")
                ;;
            *)
                current="${current%/}/$component"
                [[ -L "$current" ]] && return 0
                ;;
        esac
    done
    return 1
}

ensure_safe_target_path() {
    local id=$1
    local local_name=$2
    local destination target canonical_destination canonical_target canonical_parent

    destination=$(resolved_destination "$id")
    target="${destination%/}/$local_name"
    canonical_destination=$(canonical_path "$destination") || return 1
    canonical_target=$(canonical_path "$target") || return 1
    canonical_parent=$(dirname -- "$canonical_destination") || return 1

    [[ "$canonical_destination" != '/' ]] || return 1
    [[ "$canonical_parent" != '/' && -d "$canonical_parent" && ! -L "$canonical_parent" ]] || return 1
    [[ "$(dirname -- "$canonical_target")" == "$canonical_destination" ]] || return 1
    path_has_symlink_component "$destination" && return 1
    path_has_symlink_component "$target" && return 1
    [[ ! -e "$destination" || -d "$destination" ]] || return 1
    [[ ! -e "$target" || -d "$target" ]] || return 1
    return 0
}

ensure_local_target_directory() {
    local id=$1 local_name=$2
    local destination target
    destination=$(resolved_destination "$id")
    target="${destination%/}/$local_name"

    ensure_safe_target_path "$id" "$local_name" || return 1
    if [[ ! -d "$destination" ]]; then
        mkdir -- "$destination" || return 1
    fi
    ensure_safe_target_path "$id" "$local_name" || return 1
    if [[ ! -d "$target" ]]; then
        mkdir -- "$target" || return 1
    fi
    ensure_safe_target_path "$id" "$local_name"
}

managed_archive_candidate() {
    local local_name=$1
    local destination=$2
    local path=$3
    local canonical_destination canonical_parent basename

    [[ -f "$path" && ! -L "$path" ]] || return 1
    canonical_destination=$(canonical_path "$destination") || return 1
    canonical_parent=$(canonical_path "$(dirname -- "$path")") || return 1
    [[ "$canonical_parent" == "$canonical_destination" ]] || return 1
    basename=$(basename -- "$path")
    archive_name_matches "$local_name" "$basename"
}

record_archive() {
    local id=$1
    local local_name=$2
    local epoch=$3
    local sha256=$4
    local path=$5
    local month index_file temp_file

    month=$(date -d "@$epoch" +%Y-%m) || return 1
    index_file="$ARCHIVE_INDEX_DIR/$id.list"
    make_temp_file temp_file "$ARCHIVE_INDEX_DIR/.${id}.list.XXXXXX" || return 1

    if [[ -f "$index_file" ]]; then
        run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" cp -- "$index_file" "$temp_file" || {
            discard_temp_file "$temp_file"
            return 1
        }
    fi
    printf '%s|%s|%s|%s\n' "$epoch" "$month" "$sha256" "$path" >>"$temp_file" || {
        discard_temp_file "$temp_file"
        return 1
    }
    run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" chmod 0600 -- "$temp_file" || {
        discard_temp_file "$temp_file"
        return 1
    }
    run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" mv -f -- "$temp_file" "$index_file" || {
        discard_temp_file "$temp_file"
        return 1
    }
    unregister_temp_file "$temp_file"
}

validate_archive_index() {
    local index_file=$1 epoch month sha path extra expected_month
    [[ -f "$index_file" && ! -L "$index_file" ]] || return 1

    while IFS='|' read -r epoch month sha path extra || [[ -n "$epoch$month$sha$path${extra-}" ]]; do
        [[ -z "${extra-}" ]] || return 1
        is_decimal_integer "$epoch" || return 1
        [[ "$month" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] || return 1
        [[ -n "$sha" && "$path" == /* ]] || return 1
        expected_month=$(date -d "@$epoch" +%Y-%m) || return 1
        [[ "$month" == "$expected_month" ]] || return 1
    done <"$index_file"
}

index_contains_path() {
    local index_file=$1
    local wanted=$2
    local epoch month sha path
    [[ -f "$index_file" ]] || return 1
    while IFS='|' read -r epoch month sha path; do
        [[ "$path" == "$wanted" ]] && return 0
    done <"$index_file"
    return 1
}

select_retained_archives() {
    local id=$1
    local local_name=$2
    local destination=$3
    local reference_epoch=$4
    local output_name=$5
    local -n output=$output_name
    local index_file temp_sorted epoch stored_month sha path month month_start index recent_keep monthly_keep canonical
    local recent_count=0
    local -A allowed_months=() selected_months=() seen_paths=()

    output=()
    index_file="$ARCHIVE_INDEX_DIR/$id.list"
    [[ -f "$index_file" ]] || return 0
    validate_archive_index "$index_file" || return 1

    recent_keep=$(resolve_value "$id" archive_recent_keep)
    monthly_keep=$(resolve_value "$id" archive_monthly_keep)
    month_start=$(date -d "@$reference_epoch" +%Y-%m-01) || return 1
    for ((index = 0; index < monthly_keep; index++)); do
        month=$(date -d "$month_start -$index months" +%Y-%m) || return 1
        allowed_months[$month]=1
    done

    make_temp_file temp_sorted "$TMP_DIR/retention.${id}.XXXXXX" || return 1
    run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" "$SORT_BIN" -t '|' -k1,1nr "$index_file" >"$temp_sorted" || {
        discard_temp_file "$temp_sorted"
        return 1
    }

    while IFS='|' read -r epoch stored_month sha path; do
        managed_archive_candidate "$local_name" "$destination" "$path" || continue
        canonical=$(canonical_path "$path") || {
            discard_temp_file "$temp_sorted"
            return 1
        }
        [[ -z "${seen_paths[$canonical]+x}" ]] || continue
        seen_paths[$canonical]=1

        if (( recent_count < recent_keep )); then
            output[$path]=1
            recent_count=$((recent_count + 1))
        fi

        month=$(date -d "@$epoch" +%Y-%m) || {
            discard_temp_file "$temp_sorted"
            return 1
        }
        if [[ -n "${allowed_months[$month]+x}" && -z "${selected_months[$month]+x}" ]]; then
            output[$path]=1
            selected_months[$month]=1
        fi
    done <"$temp_sorted"

    discard_temp_file "$temp_sorted"
}

cleanup_archives() {
    local id=$1
    local local_name=$2
    local destination=$3
    local newly_verified_archive=$4
    local reference_epoch=${5:-$(date +%s)}
    local index_file temp_file delete_file epoch month sha path delete_failed=0
    local -A keep=()

    [[ -n "$newly_verified_archive" ]] || return 0
    [[ -f "$newly_verified_archive" && ! -L "$newly_verified_archive" ]] || return 0

    index_file="$ARCHIVE_INDEX_DIR/$id.list"
    validate_archive_index "$index_file" || return 1
    index_contains_path "$index_file" "$newly_verified_archive" || return 0
    select_retained_archives "$id" "$local_name" "$destination" "$reference_epoch" keep || return 1

    make_temp_file temp_file "$ARCHIVE_INDEX_DIR/.${id}.cleanup.XXXXXX" || return 1
    make_temp_file delete_file "$TMP_DIR/archive-delete.${id}.XXXXXX" || {
        discard_temp_file "$temp_file"
        return 1
    }
    while IFS='|' read -r epoch month sha path; do
        if managed_archive_candidate "$local_name" "$destination" "$path"; then
            if [[ -n "${keep[$path]+x}" ]]; then
                printf '%s|%s|%s|%s\n' "$epoch" "$month" "$sha" "$path" >>"$temp_file" || {
                    discard_temp_file "$temp_file"
                    discard_temp_file "$delete_file"
                    return 1
                }
            else
                printf '%s|%s|%s|%s\n' "$epoch" "$month" "$sha" "$path" >>"$delete_file" || {
                    discard_temp_file "$temp_file"
                    discard_temp_file "$delete_file"
                    return 1
                }
            fi
        else
            printf '%s|%s|%s|%s\n' "$epoch" "$month" "$sha" "$path" >>"$temp_file" || {
                discard_temp_file "$temp_file"
                discard_temp_file "$delete_file"
                return 1
            }
        fi
    done <"$index_file"

    run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" chmod 0600 -- "$temp_file" || {
        discard_temp_file "$temp_file"
        discard_temp_file "$delete_file"
        return 1
    }

    while IFS='|' read -r epoch month sha path; do
        if run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" "$RM_BIN" -f -- "$path"; then
            :
        else
            printf 'warning: failed to remove managed archive: %s\n' "$path" >&2
            delete_failed=1
            printf '%s|%s|%s|%s\n' "$epoch" "$month" "$sha" "$path" >>"$temp_file" || {
                discard_temp_file "$temp_file"
                discard_temp_file "$delete_file"
                return 1
            }
        fi
    done <"$delete_file"

    run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" chmod 0600 -- "$temp_file" || {
        discard_temp_file "$temp_file"
        discard_temp_file "$delete_file"
        return 1
    }
    run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" mv -f -- "$temp_file" "$index_file" || {
        discard_temp_file "$temp_file"
        discard_temp_file "$delete_file"
        return 1
    }
    unregister_temp_file "$temp_file"
    discard_temp_file "$delete_file"
    (( delete_failed == 0 ))
}

wall_now_epoch() {
    date +%s
}

transfer_timer_now_us() {
    local value=${EPOCHREALTIME/./}
    printf '%s\n' "$value"
}

archive_now_epoch() {
    if [[ -n "${SYNCWARDEN_NOW_EPOCH:-}" ]]; then
        printf '%s\n' "$SYNCWARDEN_NOW_EPOCH"
    else
        wall_now_epoch
    fi
}

run_with_timeout() {
    local seconds=$1
    shift
    "$TIMEOUT_BIN" --signal=TERM --kill-after=1s "${seconds}s" "$@"
}

register_temp_file() {
    ACTIVE_TEMP_FILES+=("$1")
}

make_temp_file() {
    local output_name=$1 template=$2 path
    local -n output=$output_name
    path=$(mktemp "$template") || return 1
    output=$path
    register_temp_file "$path"
}

unregister_temp_file() {
    local wanted=$1 path
    local -a remaining=()
    for path in "${ACTIVE_TEMP_FILES[@]}"; do
        [[ "$path" == "$wanted" ]] || remaining+=("$path")
    done
    ACTIVE_TEMP_FILES=("${remaining[@]}")
}

discard_temp_file() {
    local path=$1
    rm -f -- "$path"
    unregister_temp_file "$path"
}

cleanup_active_temp_files() {
    local path
    for path in "${ACTIVE_TEMP_FILES[@]}"; do
        [[ -n "$path" ]] && rm -f -- "$path"
    done
    ACTIVE_TEMP_FILES=()
}

syncwarden_exit_trap() {
    local rc=$?
    trap - EXIT
    cleanup_active_temp_files
    exit "$rc"
}

install_cleanup_traps() {
    trap syncwarden_exit_trap EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

nearest_existing_path() {
    local path=$1 parent
    while [[ ! -e "$path" ]]; do
        parent=$(dirname -- "$path")
        [[ "$parent" != "$path" ]] || break
        path=$parent
    done
    [[ -e "$path" ]] || return 1
    printf '%s\n' "$path"
}

check_destination_capacity() {
    local id=$1
    local destination probe available_mb available_inodes min_mb min_inodes output rc

    LAST_CAPACITY_REASON=''
    destination=$(resolved_destination "$id")
    probe=$(nearest_existing_path "$destination") || {
        LAST_CAPACITY_REASON='CAPACITY_CHECK_FAILED'
        printf 'capacity error: no existing filesystem ancestor for %s\n' "$destination" >&2
        return 1
    }
    output=$(run_with_timeout "$CAPACITY_CHECK_TIMEOUT_SECONDS" "$DF_BIN" -Pm -- "$probe" 2>/dev/null)
    rc=$?
    if (( rc != 0 )); then
        if (( rc == 124 || rc == 137 )); then
            LAST_CAPACITY_REASON='CAPACITY_CHECK_TIMEOUT'
            printf 'capacity error: free-space check timed out for %s\n' "$probe" >&2
        else
            LAST_CAPACITY_REASON='CAPACITY_CHECK_FAILED'
            printf 'capacity error: unable to read free space for %s\n' "$probe" >&2
        fi
        return 1
    fi
    available_mb=$(awk 'NR == 2 { print $4 }' <<<"$output") || {
        LAST_CAPACITY_REASON='CAPACITY_CHECK_FAILED'
        printf 'capacity error: unable to parse free space for %s\n' "$probe" >&2
        return 1
    }
    output=$(run_with_timeout "$CAPACITY_CHECK_TIMEOUT_SECONDS" "$DF_BIN" -Pi -- "$probe" 2>/dev/null)
    rc=$?
    if (( rc != 0 )); then
        if (( rc == 124 || rc == 137 )); then
            LAST_CAPACITY_REASON='CAPACITY_CHECK_TIMEOUT'
            printf 'capacity error: inode check timed out for %s\n' "$probe" >&2
        else
            LAST_CAPACITY_REASON='CAPACITY_CHECK_FAILED'
            printf 'capacity error: unable to read free inodes for %s\n' "$probe" >&2
        fi
        return 1
    fi
    available_inodes=$(awk 'NR == 2 { print $4 }' <<<"$output") || {
        LAST_CAPACITY_REASON='CAPACITY_CHECK_FAILED'
        printf 'capacity error: unable to parse free inodes for %s\n' "$probe" >&2
        return 1
    }
    is_nonnegative_integer "$available_mb" && is_nonnegative_integer "$available_inodes" || {
        LAST_CAPACITY_REASON='CAPACITY_CHECK_FAILED'
        printf 'capacity error: invalid df output for %s\n' "$probe" >&2
        return 1
    }

    min_mb=$(resolve_value "$id" min_free_space_mb)
    min_inodes=$(resolve_value "$id" min_free_inodes)
    if (( 10#$available_mb < 10#$min_mb )); then
        LAST_CAPACITY_REASON='LOW_FREE_SPACE'
        printf 'capacity error: %s has %s MB free; server %s requires at least %s MB\n' \
            "$probe" "$available_mb" "$id" "$min_mb" >&2
        return 1
    fi
    if (( 10#$available_inodes < 10#$min_inodes )); then
        LAST_CAPACITY_REASON='LOW_FREE_INODES'
        printf 'capacity error: %s has %s free inodes; server %s requires at least %s\n' \
            "$probe" "$available_inodes" "$id" "$min_inodes" >&2
        return 1
    fi
    return 0
}

archive_source() {
    local id=$1
    local source_spec=$2
    local remote local_name destination local_path epoch basename final_path temp_path output_file
    local owner sha256 sha256_output rc collision_count=0

    LAST_ARCHIVE_STATUS=''
    LAST_ARCHIVE_PATH=''
    LAST_COMMAND_OUTPUT=''

    remote=$source_spec
    local_name=$(source_local_name "$remote") || return 1
    LAST_SOURCE_NAME=$local_name
    destination=$(resolved_destination "$id")
    local_path="${destination%/}/$local_name"

    if ! ensure_safe_target_path "$id" "$local_name"; then
        printf 'archive error: unsafe destination path for %s/%s\n' "$id" "$local_name" >&2
        LAST_ARCHIVE_STATUS='FAILED_UNSAFE_DESTINATION'
        return 1
    fi

    if [[ ! -d "$local_path" ]]; then
        LAST_ARCHIVE_STATUS='SKIPPED_NO_MIRROR'
        return 0
    fi

    if ! check_destination_capacity "$id"; then
        LAST_ARCHIVE_STATUS="FAILED_${LAST_CAPACITY_REASON:-CAPACITY_CHECK}"
        return 1
    fi

    epoch=$(archive_now_epoch)
    while :; do
        basename=$(archive_basename "$local_name" "$epoch")
        final_path="${destination%/}/$basename"
        [[ ! -e "$final_path" && ! -L "$final_path" ]] && break
        epoch=$((epoch + 1))
        collision_count=$((collision_count + 1))
        if (( collision_count > 3600 )); then
            printf 'archive error: unable to find a unique timestamp name for %s\n' "$local_name" >&2
            LAST_ARCHIVE_STATUS='FAILED_NAME_COLLISION'
            return 1
        fi
    done

    temp_path="${destination%/}/.${basename%.zip}.part.zip"
    make_temp_file output_file "$TMP_DIR/archive.${id}.${local_name}.XXXXXX" || {
        LAST_ARCHIVE_STATUS='FAILED_TEMP_OUTPUT'
        return 1
    }
    LAST_COMMAND_OUTPUT=$output_file
    rm -f -- "$temp_path"
    register_temp_file "$temp_path"

    (
        cd -- "$destination" || exit 1
        run_with_timeout "$ARCHIVE_CREATE_TIMEOUT_SECONDS" "$ZIP_BIN" -r -y -q "$temp_path" "$local_name"
    ) >"$output_file" 2>&1
    rc=$?
    if (( rc != 0 )); then
        discard_temp_file "$temp_path"
        LAST_ARCHIVE_STATUS=$([[ $rc -eq 124 || $rc -eq 137 ]] && printf 'FAILED_TIMEOUT' || printf 'FAILED_CREATE')
        return 1
    fi

    run_with_timeout "$ARCHIVE_VERIFY_TIMEOUT_SECONDS" "$ZIP_BIN" -T "$temp_path" >>"$output_file" 2>&1
    rc=$?
    if (( rc != 0 )); then
        discard_temp_file "$temp_path"
        LAST_ARCHIVE_STATUS=$([[ $rc -eq 124 || $rc -eq 137 ]] && printf 'FAILED_TIMEOUT' || printf 'FAILED_VERIFY')
        return 1
    fi

    sha256_output=$(run_with_timeout "$ARCHIVE_CHECKSUM_TIMEOUT_SECONDS" "$SHA256_BIN" "$temp_path" 2>>"$output_file")
    rc=$?
    if (( rc != 0 )); then
        discard_temp_file "$temp_path"
        LAST_ARCHIVE_STATUS=$([[ $rc -eq 124 || $rc -eq 137 ]] && printf 'FAILED_TIMEOUT' || printf 'FAILED_CHECKSUM')
        return 1
    fi
    sha256=${sha256_output%%[[:space:]]*}
    [[ -n "$sha256" ]] || {
        discard_temp_file "$temp_path"
        LAST_ARCHIVE_STATUS='FAILED_CHECKSUM'
        return 1
    }
    owner=$(resolve_value "$id" owner)
    run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" "$CHOWN_BIN" "$owner" "$temp_path" >>"$output_file" 2>&1
    rc=$?
    if (( rc != 0 )); then
        discard_temp_file "$temp_path"
        LAST_ARCHIVE_STATUS=$([[ $rc -eq 124 || $rc -eq 137 ]] && printf 'FAILED_TIMEOUT' || printf 'FAILED_OWNER')
        return 1
    fi
    run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" chmod 0640 -- "$temp_path"
    rc=$?
    if (( rc != 0 )); then
        discard_temp_file "$temp_path"
        LAST_ARCHIVE_STATUS=$([[ $rc -eq 124 || $rc -eq 137 ]] && printf 'FAILED_TIMEOUT' || printf 'FAILED_MODE')
        return 1
    fi
    while :; do
        run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" mv -T -n -- "$temp_path" "$final_path"
        rc=$?
        if (( rc != 0 )); then
            discard_temp_file "$temp_path"
            LAST_ARCHIVE_STATUS=$([[ $rc -eq 124 || $rc -eq 137 ]] && printf 'FAILED_TIMEOUT' || printf 'FAILED_PROMOTE')
            return 1
        fi
        if [[ ! -e "$temp_path" && ! -L "$temp_path" ]]; then
            break
        fi
        if [[ ! -e "$final_path" && ! -L "$final_path" ]]; then
            discard_temp_file "$temp_path"
            LAST_ARCHIVE_STATUS='FAILED_PROMOTE'
            return 1
        fi
        epoch=$((epoch + 1))
        collision_count=$((collision_count + 1))
        if (( collision_count > 3600 )); then
            discard_temp_file "$temp_path"
            LAST_ARCHIVE_STATUS='FAILED_NAME_COLLISION'
            return 1
        fi
        final_path="${destination%/}/$(archive_basename "$local_name" "$epoch")"
    done
    [[ -f "$final_path" && ! -L "$final_path" ]] || {
        LAST_ARCHIVE_STATUS='FAILED_PROMOTE'
        return 1
    }
    unregister_temp_file "$temp_path"

    if ! record_archive "$id" "$local_name" "$epoch" "$sha256" "$final_path"; then
        LAST_ARCHIVE_STATUS='FAILED_INDEX'
        return 1
    fi

    if ! cleanup_archives "$id" "$local_name" "$destination" "$final_path" "$epoch" >>"$output_file" 2>&1; then
        LAST_ARCHIVE_STATUS='WARNING_CLEANUP'
        LAST_ARCHIVE_PATH=$final_path
        return 2
    fi

    discard_temp_file "$output_file"
    LAST_COMMAND_OUTPUT=''
    LAST_ARCHIVE_STATUS='SUCCESS'
    LAST_ARCHIVE_PATH=$final_path
    return 0
}

classify_failure() {
    local rc=$1
    local output_file=$2
    local output=''
    [[ -f "$output_file" ]] && output=$(<"$output_file")

    if (( rc == 0 )); then
        printf 'SUCCESS\n'
    elif (( rc == 24 )); then
        printf 'FILES_VANISHED\n'
    elif (( rc == 30 )); then
        printf 'RSYNC_IO_TIMEOUT\n'
    elif (( rc == 124 || rc == 137 )); then
        printf 'TIMEOUT\n'
    elif grep -Eqi 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|host key has changed' <<<"$output"; then
        printf 'HOST_KEY_CHANGED\n'
    elif grep -Eqi 'Permission denied \(publickey\)|Permission denied|Authentication failed' <<<"$output"; then
        printf 'AUTH_FAILED\n'
    elif grep -Fq 'REMOTE_SOURCE_MISSING:' <<<"$output"; then
        printf 'REMOTE_SOURCE_MISSING\n'
    elif grep -Eqi 'Connection timed out|Connection refused|Connection reset|No route to host|Network is unreachable|connection unexpectedly closed|Operation timed out|rsync error: error in socket IO' <<<"$output"; then
        printf 'NETWORK_TRANSIENT\n'
    else
        printf 'RSYNC_FAILED\n'
    fi
}

reason_is_retryable() {
    [[ "$1" == 'NETWORK_TRANSIENT' || "$1" == 'TIMEOUT' ]]
}

reset_last_change_stats() {
    LAST_CHANGE_COUNT=0
    LAST_CHANGE_CREATED=0
    LAST_CHANGE_UPDATED=0
    LAST_CHANGE_DELETED=0
    LAST_CHANGE_ATTEMPTS=0
    LAST_CHANGE_PARSE_FAILED=0
    LAST_CHANGE_COMPLETE='no'
    LAST_TRANSFER_BYTES=0
    LAST_TRANSFER_DURATION_US=0
}

consume_rsync_attempt_output() {
    local input_file=$1 diagnostic_file=$2 attempt=$3
    local line payload code bytes filtered parse_failed=0 code_length
    make_temp_file filtered "$TMP_DIR/rsync-filter.XXXXXX" || return 1
    : >"$filtered"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$RSYNC_CHANGE_PREFIX"* ]]; then
            payload=${line#"$RSYNC_CHANGE_PREFIX"}
            if [[ "$payload" != *'|'* ]]; then
                parse_failed=1
                continue
            fi
            code=${payload%%|*}
            bytes=${payload#*|}
            code_length=${#code}
            if (( code_length < 11 || code_length > 12 )) || [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
                parse_failed=1
                continue
            fi
            if [[ "$code" == \*deleting* ]]; then
                LAST_CHANGE_DELETED=$((LAST_CHANGE_DELETED + 1))
            elif [[ "$code" == *'+++++++++'* ]]; then
                LAST_CHANGE_CREATED=$((LAST_CHANGE_CREATED + 1))
            else
                LAST_CHANGE_UPDATED=$((LAST_CHANGE_UPDATED + 1))
            fi
            LAST_CHANGE_COUNT=$((LAST_CHANGE_COUNT + 1))
            LAST_TRANSFER_BYTES=$((LAST_TRANSFER_BYTES + bytes))
        else
            printf '%s\n' "$line" >>"$filtered"
        fi
    done <"$input_file"

    if [[ -s "$filtered" ]]; then
        printf '%s\n' "--- rsync attempt $attempt ---" >>"$diagnostic_file"
        sed -n 'p' "$filtered" >>"$diagnostic_file"
    fi
    discard_temp_file "$filtered"
    LAST_CHANGE_ATTEMPTS=$attempt
    if (( LAST_CHANGE_CREATED + LAST_CHANGE_UPDATED + LAST_CHANGE_DELETED != LAST_CHANGE_COUNT )); then
        parse_failed=1
    fi
    if (( parse_failed != 0 )); then
        LAST_CHANGE_PARSE_FAILED=1
        return 1
    fi
    return 0
}

run_command_with_retry() {
    local id=$1
    local stage=$2
    local attempt_timeout_seconds=$3
    local output_file=$4
    local track_changes=$5
    shift 5
    local retry_count delay_string attempt=1 max_attempts rc reason delay
    local attempt_file parse_rc attempt_started_us attempt_finished_us attempt_duration_us
    local -a delays=()

    retry_count=$(resolve_value "$id" retry_count)
    delay_string=$(resolve_value "$id" retry_delays_seconds)
    IFS=',' read -r -a delays <<<"$delay_string"
    max_attempts=$((retry_count + 1))
    LAST_ATTEMPT_COUNT=0
    LAST_EXIT_CODE=0
    LAST_FAILURE_REASON=''
    LAST_COMMAND_OUTPUT=$output_file
    if (( track_changes == 1 )); then
        reset_last_change_stats
        : >"$output_file"
    fi

    while (( attempt <= max_attempts )); do
        if (( track_changes == 1 )); then
            LAST_TRANSFER_BYTES=0
            LAST_TRANSFER_DURATION_US=0
            make_temp_file attempt_file "$TMP_DIR/rsync-attempt.${id}.XXXXXX" || {
                LAST_EXIT_CODE=1
                LAST_FAILURE_REASON='TEMP_OUTPUT_FAILED'
                printf 'unable to create rsync attempt output\n' >>"$output_file"
                return 1
            }
        else
            attempt_file=$output_file
            : >"$attempt_file"
        fi

        if (( track_changes == 1 )); then
            attempt_started_us=$(transfer_timer_now_us)
        fi
        if (( attempt_timeout_seconds > 0 )); then
            run_with_timeout "$attempt_timeout_seconds" "$@" >"$attempt_file" 2>&1
        else
            "$@" >"$attempt_file" 2>&1
        fi
        rc=$?
        if (( track_changes == 1 )); then
            attempt_finished_us=$(transfer_timer_now_us)
            attempt_duration_us=$((attempt_finished_us - attempt_started_us))
            (( attempt_duration_us > 0 )) || attempt_duration_us=1
            LAST_TRANSFER_DURATION_US=$attempt_duration_us
        fi
        reason=$(classify_failure "$rc" "$attempt_file")
        LAST_ATTEMPT_COUNT=$attempt
        LAST_EXIT_CODE=$rc
        LAST_FAILURE_REASON=$reason

        if (( track_changes == 1 )); then
            consume_rsync_attempt_output "$attempt_file" "$output_file" "$attempt"
            parse_rc=$?
            (( parse_rc == 0 )) || LAST_CHANGE_PARSE_FAILED=1
            discard_temp_file "$attempt_file"
        fi

        if (( rc == 0 )); then
            return 0
        fi
        if [[ "$reason" == 'FILES_VANISHED' ]]; then
            return 2
        fi
        if ! reason_is_retryable "$reason" || (( attempt >= max_attempts )); then
            return 1
        fi

        delay=$(trim "${delays[$((attempt - 1))]:-0}")
        if (( delay > 0 )); then
            "$SLEEP_BIN" "$delay" || {
                LAST_EXIT_CODE=1
                LAST_FAILURE_REASON='RETRY_DELAY_FAILED'
                return 1
            }
        fi
        attempt=$((attempt + 1))
    done

    printf 'internal error: retry loop exhausted for %s/%s\n' "$id" "$stage" >&2
    return 1
}

build_ssh_command() {
    local id=$1
    local output_name=$2
    local -n output=$output_name
    output=(
        "$SSH_BIN"
        -p "$(resolve_value "$id" port)"
        -i "$(resolve_value "$id" key_file)"
        -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT_SECONDS"
        -o BatchMode=yes
        -o StrictHostKeyChecking=accept-new
        -o LogLevel=ERROR
    )
}

shell_quote_posix() {
    local value=$1 prefix
    printf "'"
    while [[ "$value" == *"'"* ]]; do
        prefix=${value%%\'*}
        printf "%s'\\\\''" "$prefix"
        value=${value#*\'}
    done
    printf "%s'" "$value"
}

build_rsh_string() {
    local id=$1
    local -a ssh_command=()
    local token quoted result=''
    build_ssh_command "$id" ssh_command
    for token in "${ssh_command[@]}"; do
        printf -v quoted '%q' "$token"
        result+="${result:+ }$quoted"
    done
    printf '%s\n' "$result"
}

preflight_server() {
    local id=$1
    local user host spec remote local_name quoted_remote quoted_error remote_command output_file rc
    local -a sources=() ssh_command=()

    user=$(resolve_value "$id" user)
    host=$(resolve_value "$id" host)
    get_server_sources "$id" sources
    build_ssh_command "$id" ssh_command

    for spec in "${sources[@]}"; do
        LAST_ATTEMPT_COUNT=0
        LAST_EXIT_CODE=0
        LAST_FAILURE_REASON=''
        LAST_COMMAND_OUTPUT=''
        remote=$spec
        local_name=$(source_local_name "$remote") || {
            LAST_ATTEMPT_COUNT=0
            LAST_EXIT_CODE=1
            LAST_FAILURE_REASON='INVALID_SOURCE'
            LAST_COMMAND_OUTPUT=''
            return 1
        }
        LAST_SOURCE_NAME=$local_name
        quoted_remote=$(shell_quote_posix "$remote")
        quoted_error=$(shell_quote_posix "REMOTE_SOURCE_MISSING:$remote")
        remote_command="if test -d $quoted_remote; then exit 0; else printf '%s\\n' $quoted_error; exit 42; fi"
        make_temp_file output_file "$TMP_DIR/preflight.${id}.${local_name}.XXXXXX" || {
            LAST_ATTEMPT_COUNT=0
            LAST_EXIT_CODE=1
            LAST_FAILURE_REASON='TEMP_OUTPUT_FAILED'
            LAST_COMMAND_OUTPUT=''
            return 1
        }
        run_command_with_retry "$id" 'PREFLIGHT' "$SSH_PREFLIGHT_TIMEOUT_SECONDS" "$output_file" 0 \
            "${ssh_command[@]}" "$user@$host" "$remote_command"
        rc=$?
        if (( rc != 0 )); then
            return "$rc"
        fi
        discard_temp_file "$output_file"
        LAST_COMMAND_OUTPUT=''
    done

    LAST_FAILURE_REASON='SUCCESS'
    LAST_EXIT_CODE=0
    return 0
}

sync_source() {
    local id=$1
    local source_spec=$2
    local _legacy_deadline_ignored=$3
    local dry_run=${4:-0}
    local remote local_name destination local_path user host owner rsh output_file rc
    local -a command=()

    reset_last_change_stats
    LAST_ATTEMPT_COUNT=0
    LAST_EXIT_CODE=0
    LAST_FAILURE_REASON=''
    LAST_COMMAND_OUTPUT=''
    LAST_SYNC_STATUS=''
    remote=$source_spec
    local_name=$(source_local_name "$remote") || {
        LAST_FAILURE_REASON='INVALID_SOURCE'
        LAST_EXIT_CODE=1
        LAST_SYNC_STATUS='FAILED'
        return 1
    }
    LAST_SOURCE_NAME=$local_name
    destination=$(resolved_destination "$id")
    local_path="${destination%/}/$local_name"
    user=$(resolve_value "$id" user)
    host=$(resolve_value "$id" host)
    owner=$(resolve_value "$id" owner)
    rsh=$(build_rsh_string "$id")

    if ! ensure_safe_target_path "$id" "$local_name"; then
        LAST_FAILURE_REASON='UNSAFE_DESTINATION'
        LAST_EXIT_CODE=1
        LAST_SYNC_STATUS='FAILED'
        return 1
    fi
    if ! check_destination_capacity "$id"; then
        LAST_FAILURE_REASON=${LAST_CAPACITY_REASON:-CAPACITY_CHECK_FAILED}
        LAST_EXIT_CODE=1
        LAST_SYNC_STATUS='FAILED'
        return 1
    fi

    if (( dry_run == 0 )); then
        ensure_local_target_directory "$id" "$local_name" || {
            LAST_FAILURE_REASON='LOCAL_DESTINATION_FAILED'
            LAST_EXIT_CODE=1
            LAST_ATTEMPT_COUNT=0
            LAST_COMMAND_OUTPUT=''
            LAST_SYNC_STATUS='FAILED'
            return 1
        }
    fi

    command=(
        "$RSYNC_BIN"
        -a
        -h
        "--timeout=$(resolve_value "$id" rsync_timeout_seconds)"
        --delete
        --delete-delay
    )
    [[ -n "$owner" ]] && command+=("--chown=$owner")
    if (( dry_run == 1 )); then
        command+=(--dry-run --itemize-changes)
    else
        command+=(--itemize-changes "--out-format=${RSYNC_CHANGE_PREFIX}%i|%b")
    fi
    command+=(
        -e "$rsh"
        "$user@$host:${remote%/}/"
        "${local_path%/}/"
    )

    make_temp_file output_file "$TMP_DIR/rsync.${id}.${local_name}.XXXXXX" || {
        LAST_FAILURE_REASON='TEMP_OUTPUT_FAILED'
        LAST_EXIT_CODE=1
        LAST_ATTEMPT_COUNT=0
        LAST_COMMAND_OUTPUT=''
        LAST_SYNC_STATUS='FAILED'
        return 1
    }
    run_command_with_retry "$id" 'RSYNC' 0 "$output_file" "$((dry_run == 0))" "${command[@]}"
    rc=$?
    case "$rc" in
        0)
            if (( dry_run == 0 && LAST_CHANGE_PARSE_FAILED == 1 )); then
                LAST_CHANGE_COMPLETE='no'
                LAST_FAILURE_REASON='CHANGE_STATS_PARSE_FAILED'
                LAST_EXIT_CODE=0
                LAST_SYNC_STATUS='WARNING'
                return 2
            fi
            (( dry_run == 1 )) || LAST_CHANGE_COMPLETE='yes'
            if (( dry_run == 1 )); then
                printf '%s\n' '--------------------------------------------------------------------------------'
                printf 'DRY RUN CHANGES - %s / %s\n' "$(resolve_value "$id" name)" "$local_name"
                if [[ -s "$output_file" ]]; then
                    sed 's/^/  /' "$output_file"
                else
                    printf '%s\n' '  (no changes)'
                fi
                printf '%s\n' '--------------------------------------------------------------------------------'
            fi
            discard_temp_file "$output_file"
            LAST_COMMAND_OUTPUT=''
            LAST_SYNC_STATUS='SUCCESS'
            return 0
            ;;
        2)
            LAST_CHANGE_COMPLETE='yes'
            LAST_SYNC_STATUS='SUCCESS'
            return 0
            ;;
        *)
            LAST_CHANGE_COMPLETE='no'
            LAST_SYNC_STATUS='FAILED'
            return 1
            ;;
    esac
}

format_duration() {
    local seconds=$1
    printf '%02dm%02ds' "$((seconds / 60))" "$((seconds % 60))"
}

format_bytes_iec() {
    local bytes=$1
    awk -v bytes="$bytes" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", units, " ")
        value = bytes + 0
        unit = 1
        while (value >= 1024 && unit < 6) {
            value /= 1024
            unit++
        }
        if (unit == 1) printf "%.0f%s", value, units[unit]
        else if (value < 10) printf "%.2f%s", value, units[unit]
        else if (value < 100) printf "%.1f%s", value, units[unit]
        else printf "%.0f%s", value, units[unit]
    }'
}

average_bytes_per_second() {
    local bytes=$1 duration_us=$2
    awk -v bytes="$bytes" -v duration_us="$duration_us" 'BEGIN {
        if (duration_us <= 0) exit 1
        printf "%.0f\n", bytes * 1000000 / duration_us
    }'
}

format_average_speed() {
    local bytes=$1 duration_us=$2 bytes_per_second
    bytes_per_second=$(average_bytes_per_second "$bytes" "$duration_us") || {
        printf 'unavailable\n'
        return 1
    }
    printf '%s/s\n' "$(format_bytes_iec "$bytes_per_second")"
}

format_global_runtime_limit() {
    local seconds=${1:-$GLOBAL_RUNTIME_TIMEOUT_SECONDS}
    printf '%02dh%02dm%02ds' \
        "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
}

timestamp_now() {
    date '+%Y-%m-%d %H:%M:%S %:z'
}

new_run_id() {
    printf '%s-%s\n' "$(date '+%Y%m%dT%H%M%S')" "$$"
}

reset_server_change_stats() {
    SERVER_CHANGE_STATE='unavailable'
    SERVER_CHANGE_COUNT=0
    SERVER_CHANGE_CREATED=0
    SERVER_CHANGE_UPDATED=0
    SERVER_CHANGE_DELETED=0
    SERVER_CHANGE_ATTEMPTS=0
    SERVER_CHANGE_COMPLETE='yes'
    SERVER_TRANSFER_BYTES=0
    SERVER_TRANSFER_DURATION_US=0
    SERVER_RSYNC_STARTED=0
    SERVER_CHANGE_SUMMARY_ATTACHED=0
}

merge_last_change_stats() {
    if (( LAST_CHANGE_ATTEMPTS > 0 )); then
        SERVER_RSYNC_STARTED=1
        SERVER_CHANGE_ATTEMPTS=$((SERVER_CHANGE_ATTEMPTS + LAST_CHANGE_ATTEMPTS))
    fi
    if (( LAST_CHANGE_PARSE_FAILED == 1 )); then
        SERVER_CHANGE_STATE='parse_failed'
    elif [[ "$SERVER_CHANGE_STATE" != 'parse_failed' && "$LAST_CHANGE_ATTEMPTS" -gt 0 ]]; then
        SERVER_CHANGE_STATE='numeric'
        SERVER_CHANGE_COUNT=$((SERVER_CHANGE_COUNT + LAST_CHANGE_COUNT))
        SERVER_CHANGE_CREATED=$((SERVER_CHANGE_CREATED + LAST_CHANGE_CREATED))
        SERVER_CHANGE_UPDATED=$((SERVER_CHANGE_UPDATED + LAST_CHANGE_UPDATED))
        SERVER_CHANGE_DELETED=$((SERVER_CHANGE_DELETED + LAST_CHANGE_DELETED))
        SERVER_TRANSFER_BYTES=$((SERVER_TRANSFER_BYTES + LAST_TRANSFER_BYTES))
        SERVER_TRANSFER_DURATION_US=$((SERVER_TRANSFER_DURATION_US + LAST_TRANSFER_DURATION_US))
    fi
    [[ "$LAST_CHANGE_COMPLETE" == 'yes' ]] || SERVER_CHANGE_COMPLETE='no'
}

finalize_server_change_stats() {
    if (( SERVER_RSYNC_STARTED == 0 )); then
        SERVER_CHANGE_STATE='unavailable'
        SERVER_CHANGE_COMPLETE='no'
    elif [[ "$SERVER_CHANGE_STATE" == 'parse_failed' ]]; then
        SERVER_CHANGE_COMPLETE='no'
    fi
}

server_change_value() {
    local numeric=$1
    case "$SERVER_CHANGE_STATE" in
        numeric) printf '%s\n' "$numeric" ;;
        parse_failed|unavailable) printf 'unavailable\n' ;;
        not_applicable) printf 'not_applicable\n' ;;
        *) printf 'unavailable\n'; return 1 ;;
    esac
}

server_transfer_bytes_value() {
    server_change_value "$SERVER_TRANSFER_BYTES"
}

server_transfer_duration_value() {
    server_change_value "$SERVER_TRANSFER_DURATION_US"
}

server_average_bps_value() {
    case "$SERVER_CHANGE_STATE" in
        numeric) average_bytes_per_second "$SERVER_TRANSFER_BYTES" "$SERVER_TRANSFER_DURATION_US" ;;
        parse_failed|unavailable) printf 'unavailable\n' ;;
        not_applicable) printf 'not_applicable\n' ;;
        *) printf 'unavailable\n'; return 1 ;;
    esac
}

server_transfer_size_display() {
    case "$SERVER_CHANGE_STATE" in
        numeric) format_bytes_iec "$SERVER_TRANSFER_BYTES" ;;
        parse_failed|unavailable) printf 'unavailable\n' ;;
        not_applicable) printf 'not_applicable\n' ;;
        *) printf 'unavailable\n'; return 1 ;;
    esac
}

server_average_speed_display() {
    case "$SERVER_CHANGE_STATE" in
        numeric) format_average_speed "$SERVER_TRANSFER_BYTES" "$SERVER_TRANSFER_DURATION_US" ;;
        parse_failed|unavailable) printf 'unavailable\n' ;;
        not_applicable) printf 'not_applicable\n' ;;
        *) printf 'unavailable\n'; return 1 ;;
    esac
}

render_server_change_summary() {
    local changes created updated deleted
    changes=$(server_change_value "$SERVER_CHANGE_COUNT")
    created=$(server_change_value "$SERVER_CHANGE_CREATED")
    updated=$(server_change_value "$SERVER_CHANGE_UPDATED")
    deleted=$(server_change_value "$SERVER_CHANGE_DELETED")
    [[ "$SERVER_CHANGE_STATE" == 'parse_failed' ]] && changes='unavailable (parse failed)'
    printf '  Changes         : %s\n' "$changes"
    printf '  Created         : %s\n' "$created"
    printf '  Updated         : %s\n' "$updated"
    printf '  Deleted         : %s\n' "$deleted"
    printf '  Transferred     : %s\n' "$(server_transfer_size_display)"
    printf '  Average Speed   : %s\n' "$(server_average_speed_display)"
    printf '  Rsync Attempts  : %s\n' "$SERVER_CHANGE_ATTEMPTS"
    printf '  Change Complete : %s\n' "$SERVER_CHANGE_COMPLETE"
}

attach_server_change_summary() {
    (( SERVER_CHANGE_SUMMARY_ATTACHED == 0 )) || return 0
    SERVER_FAILURE_BODY+="${SERVER_FAILURE_BODY:+$'\n'}$(render_server_change_summary)"
    SERVER_CHANGE_SUMMARY_ATTACHED=1
}

write_last_status() {
    local id=$1
    local status=$2
    local mode=$3
    local reason=$4
    local exit_code=$5
    local duration=$6
    local target="$LAST_STATUS_DIR/$id.status"
    local temp
    make_temp_file temp "$LAST_STATUS_DIR/.${id}.status.XXXXXX" || return 1
    if ! {
        printf 'time=%s\n' "$(timestamp_now)"
        printf 'status=%s\n' "$status"
        printf 'mode=%s\n' "$mode"
        printf 'reason=%s\n' "$reason"
        printf 'exit_code=%s\n' "$exit_code"
        printf 'duration_seconds=%s\n' "$duration"
        printf 'changes=%s\n' "$(server_change_value "$SERVER_CHANGE_COUNT")"
        printf 'created=%s\n' "$(server_change_value "$SERVER_CHANGE_CREATED")"
        printf 'updated=%s\n' "$(server_change_value "$SERVER_CHANGE_UPDATED")"
        printf 'deleted=%s\n' "$(server_change_value "$SERVER_CHANGE_DELETED")"
        printf 'transferred_bytes=%s\n' "$(server_transfer_bytes_value)"
        printf 'sync_duration_microseconds=%s\n' "$(server_transfer_duration_value)"
        printf 'average_bytes_per_second=%s\n' "$(server_average_bps_value)"
        printf 'attempts=%s\n' "$SERVER_CHANGE_ATTEMPTS"
        printf 'change_complete=%s\n' "$SERVER_CHANGE_COMPLETE"
    } >"$temp"; then
        discard_temp_file "$temp"
        return 1
    fi
    chmod 0600 -- "$temp" || {
        discard_temp_file "$temp"
        return 1
    }
    mv -f -- "$temp" "$target" || {
        discard_temp_file "$temp"
        return 1
    }
    unregister_temp_file "$temp"
}

mark_last_status_failed() {
    local id=$1 reason=$2
    local target="$LAST_STATUS_DIR/$id.status" temp line
    [[ -f "$target" && ! -L "$target" ]] || return 1
    make_temp_file temp "$LAST_STATUS_DIR/.${id}.status-final.XXXXXX" || return 1
    if ! while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            status=*) line='status=FAILED' ;;
            reason=*) line="reason=$reason" ;;
            exit_code=*) line='exit_code=1' ;;
        esac
        printf '%s\n' "$line"
    done <"$target" >"$temp"; then
        discard_temp_file "$temp"
        return 1
    fi
    chmod 0600 -- "$temp" || {
        discard_temp_file "$temp"
        return 1
    }
    mv -f -- "$temp" "$target" || {
        discard_temp_file "$temp"
        return 1
    }
    unregister_temp_file "$temp"
}

persist_server_status() {
    local id=$1 status=$2 mode=$3 reason=$4 exit_code=$5 duration=$6 body
    if write_last_status "$id" "$status" "$mode" "$reason" "$exit_code" "$duration"; then
        return 0
    fi
    build_failure_body "$id" "$mode" 'STATE' 'STATE_WRITE_FAILED' 1 1 ''
    body=$FAILURE_BODY_RESULT
    SERVER_FAILURE_BODY+="${SERVER_FAILURE_BODY:+$'\n'}$body"
    attach_server_change_summary
    SERVER_STATUS='FAILED'
    SERVER_REASON='STATE_WRITE_FAILED'
    return 1
}

build_failure_body() {
    local id=$1
    local mode=$2
    local stage=$3
    local reason=$4
    local exit_code=$5
    local attempts=$6
    local output_path=${7-}
    local source_name=${8-}
    local name raw='' body
    name=$(resolve_value "$id" name)
    if [[ -n "$output_path" && -f "$output_path" ]]; then
        raw=$(sed 's/^/  /' "$output_path")
        discard_temp_file "$output_path"
    fi
    printf -v body '  Time       : %s\n  Run ID     : %s\n  Mode       : %s\n  Server     : %s\n  ID         : %s' \
        "$(timestamp_now)" "${RUN_ID:-none}" "$mode" "$name" "$id"
    if [[ -n "$source_name" ]]; then
        printf -v body '%s\n  Source          : %s' "$body" "$source_name"
    fi
    printf -v body '%s\n  Stage      : %s\n  Reason     : %s\n  Exit Code  : %s\n  Stage Attempts  : %s' \
        "$body" "$stage" "$reason" "$exit_code" "$attempts"
    if [[ -n "$raw" ]]; then
        printf -v body '%s\n--------------------------------------------------------------------------------\nRAW OUTPUT\n%s' "$body" "$raw"
    fi
    FAILURE_BODY_RESULT=$body
}

managed_plain_log_name() {
    [[ "$1" =~ ^(success|failure)-([0-9]{4})-(0[1-9]|1[0-2])\.log$ ]]
}

managed_gzip_log_name() {
    [[ "$1" =~ ^(success|failure)-([0-9]{4})-(0[1-9]|1[0-2])\.log\.gz$ ]]
}

log_month_key() {
    local month=$1 year=${1%%-*} number=${1#*-}
    printf '%d\n' "$((10#$year * 100 + 10#$number))"
}

log_maintenance_warn() {
    local message=$1
    LOG_MAINTENANCE_MESSAGES+="${LOG_MAINTENANCE_MESSAGES:+$'\n'}$message"
    printf 'warning: %s\n' "$message" >&2
}

compress_managed_log() {
    local source=$1 kind=$2 month=$3
    local destination="$ROTATED_LOG_DIR/$kind-$month.log.gz"
    local part

    if [[ -e "$destination" || -L "$destination" ]]; then
        log_maintenance_warn "rotated log already exists; source preserved: $destination"
        return 2
    fi
    make_temp_file part "$ROTATED_LOG_DIR/.$kind-$month.log.XXXXXX.part.gz" || {
        log_maintenance_warn "cannot create gzip part file for: $source"
        return 2
    }
    if ! run_with_timeout "$LOG_COMMAND_TIMEOUT_SECONDS" "$GZIP_BIN" -c -- "$source" >"$part"; then
        discard_temp_file "$part"
        log_maintenance_warn "failed to compress managed log; source preserved: $source"
        return 2
    fi
    run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" chmod 0600 -- "$part" || {
        discard_temp_file "$part"
        log_maintenance_warn "failed to set gzip mode; source preserved: $source"
        return 2
    }
    if ! run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" mv -T -n -- "$part" "$destination"; then
        discard_temp_file "$part"
        log_maintenance_warn "failed to promote compressed log; source preserved: $source"
        return 2
    fi
    if [[ -e "$part" || -L "$part" ]]; then
        discard_temp_file "$part"
        log_maintenance_warn "rotated log appeared during promotion; source preserved: $destination"
        return 2
    fi
    unregister_temp_file "$part"
    if ! run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" "$RM_BIN" -f -- "$source"; then
        log_maintenance_warn "compressed log created but source removal failed: $source"
        return 2
    fi
    return 0
}

maintain_monthly_logs() {
    local reference=${1-} month_start current_month oldest_month retention
    local current_key oldest_key path basename kind month key rc warning=0
    local plain_manifest rotated_manifest

    LOG_MAINTENANCE_MESSAGES=''
    [[ -d "$LOG_DIR" && ! -L "$LOG_DIR" && -d "$ROTATED_LOG_DIR" && ! -L "$ROTATED_LOG_DIR" ]] || {
        log_maintenance_warn 'log directories are missing or symbolic links; maintenance skipped'
        return 2
    }

    [[ -n "$reference" ]] || reference=$(log_reference_epoch) || {
        log_maintenance_warn 'cannot determine log-maintenance reference time'
        return 2
    }
    current_month=$(date -d "@$reference" +%Y-%m) || {
        log_maintenance_warn "invalid log-maintenance reference epoch: $reference"
        return 2
    }
    month_start=$(date -d "@$reference" +%Y-%m-01) || {
        log_maintenance_warn "cannot determine current month from epoch: $reference"
        return 2
    }
    retention=${GLOBAL[log_retention_months]}
    oldest_month=$(date -d "$month_start -$((retention - 1)) months" +%Y-%m) || {
        log_maintenance_warn "cannot determine oldest retained month from: $month_start"
        return 2
    }
    current_key=$(log_month_key "$current_month")
    oldest_key=$(log_month_key "$oldest_month")

    make_temp_file plain_manifest "$TMP_DIR/log-plain.XXXXXX" || {
        log_maintenance_warn 'cannot create managed-log discovery manifest'
        return 2
    }
    make_temp_file rotated_manifest "$TMP_DIR/log-rotated.XXXXXX" || {
        discard_temp_file "$plain_manifest"
        log_maintenance_warn 'cannot create rotated-log discovery manifest'
        return 2
    }
    if ! run_with_timeout "$LOG_COMMAND_TIMEOUT_SECONDS" "$FIND_BIN" \
        "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f -print0 >"$plain_manifest"; then
        discard_temp_file "$plain_manifest"
        discard_temp_file "$rotated_manifest"
        log_maintenance_warn 'managed-log discovery failed; maintenance skipped'
        return 2
    fi
    if ! run_with_timeout "$LOG_COMMAND_TIMEOUT_SECONDS" "$FIND_BIN" \
        "$ROTATED_LOG_DIR" -mindepth 1 -maxdepth 1 -type f -print0 >"$rotated_manifest"; then
        discard_temp_file "$plain_manifest"
        discard_temp_file "$rotated_manifest"
        log_maintenance_warn 'rotated-log discovery failed; maintenance skipped'
        return 2
    fi

    while IFS= read -r -d '' path; do
        [[ -f "$path" && ! -L "$path" ]] || continue
        basename=$(basename -- "$path")
        managed_plain_log_name "$basename" || continue
        kind=${BASH_REMATCH[1]}
        month="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
        key=$(log_month_key "$month")
        if (( key < oldest_key )); then
            run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" "$RM_BIN" -f -- "$path" || {
                log_maintenance_warn "failed to remove expired managed log: $path"
                warning=1
            }
        elif (( key < current_key )); then
            compress_managed_log "$path" "$kind" "$month"
            rc=$?
            (( rc == 0 )) || warning=1
        fi
    done <"$plain_manifest"

    while IFS= read -r -d '' path; do
        [[ -f "$path" && ! -L "$path" ]] || continue
        basename=$(basename -- "$path")
        managed_gzip_log_name "$basename" || continue
        month="${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
        key=$(log_month_key "$month")
        if (( key < oldest_key )); then
            run_with_timeout "$LOCAL_COMMAND_TIMEOUT_SECONDS" "$RM_BIN" -f -- "$path" || {
                log_maintenance_warn "failed to remove expired compressed log: $path"
                warning=1
            }
        fi
    done <"$rotated_manifest"

    discard_temp_file "$plain_manifest"
    discard_temp_file "$rotated_manifest"

    (( warning == 0 )) || return 2
    return 0
}

run_server() {
    local id=$1
    local mode=$2
    local dry_run=${3:-0}
    local started duration name spec rc server_rc=0 reason='SUCCESS'
    local archive_summary='NOT_REQUESTED' sync_summary='NOT_RUN' failure_parts=''
    local -a sources=()

    SERVER_STATUS=''
    SERVER_RESULT_LINE=''
    SERVER_FAILURE_BODY=''
    SERVER_ARCHIVE_SUMMARY=''
    SERVER_REASON=''
    reset_server_change_stats

    started=$(wall_now_epoch)
    name=$(resolve_value "$id" name)
    get_server_sources "$id" sources

    if ! check_private_key "$id"; then
        LAST_SOURCE_NAME=''
        LAST_ATTEMPT_COUNT=0
        LAST_EXIT_CODE=1
        LAST_FAILURE_REASON='PRIVATE_KEY_FAILED'
        LAST_COMMAND_OUTPUT=''
        reason='PRIVATE_KEY_FAILED'
        finalize_server_change_stats
        build_failure_body "$id" "$mode" 'PRIVATE_KEY' "$reason" 1 0 ''
        SERVER_FAILURE_BODY=$FAILURE_BODY_RESULT
        attach_server_change_summary
        SERVER_STATUS='FAILED'
        SERVER_ARCHIVE_SUMMARY='NOT_REQUESTED'
        SERVER_REASON=$reason
        duration=$(( $(wall_now_epoch) - started ))
        if (( dry_run == 0 )); then
            persist_server_status "$id" FAILED "$mode" "$reason" 1 "$duration" || return 1
        fi
        return 1
    fi

    preflight_server "$id"
    rc=$?
    if (( rc != 0 )); then
        reason=${LAST_FAILURE_REASON:-PREFLIGHT_FAILED}
        finalize_server_change_stats
        build_failure_body "$id" "$mode" 'PREFLIGHT' "$reason" "${LAST_EXIT_CODE:-1}" "${LAST_ATTEMPT_COUNT:-1}" "${LAST_COMMAND_OUTPUT:-}" "$LAST_SOURCE_NAME"
        SERVER_FAILURE_BODY=$FAILURE_BODY_RESULT
        attach_server_change_summary
        SERVER_STATUS='FAILED'
        SERVER_REASON=$reason
        duration=$(( $(wall_now_epoch) - started ))
        if (( dry_run == 0 )); then
            persist_server_status "$id" FAILED "$mode" "$reason" "${LAST_EXIT_CODE:-1}" "$duration" || return 1
        fi
        return 1
    fi

    if (( dry_run == 1 )); then
        archive_summary='DRY_RUN_NO_ARCHIVE'
    else
        archive_summary='SUCCESS'
        for spec in "${sources[@]}"; do
            archive_source "$id" "$spec"
            rc=$?
            case "$rc" in
                0)
                    if [[ "$LAST_ARCHIVE_STATUS" == 'SKIPPED_NO_MIRROR' ]]; then
                        archive_summary='SKIPPED_NO_MIRROR'
                    fi
                    ;;
                2)
                    server_rc=2
                    archive_summary=$LAST_ARCHIVE_STATUS
                    reason=$LAST_ARCHIVE_STATUS
                    build_failure_body "$id" "$mode" 'ARCHIVE_CLEANUP' "$reason" 2 1 "${LAST_COMMAND_OUTPUT:-}" "$LAST_SOURCE_NAME"
                    failure_parts+="$FAILURE_BODY_RESULT"$'\n'
                    ;;
                *)
                    archive_summary=${LAST_ARCHIVE_STATUS:-FAILED_ARCHIVE}
                    reason=$archive_summary
                    build_failure_body "$id" "$mode" 'ARCHIVE' "$reason" 1 1 "${LAST_COMMAND_OUTPUT:-}" "$LAST_SOURCE_NAME"
                    failure_parts+="$FAILURE_BODY_RESULT"$'\n'
                    SERVER_ARCHIVE_SUMMARY=$archive_summary
                    SERVER_FAILURE_BODY=${failure_parts%$'\n'}
                    finalize_server_change_stats
                    attach_server_change_summary
                    SERVER_STATUS='FAILED'
                    SERVER_REASON=$reason
                    duration=$(( $(wall_now_epoch) - started ))
                    persist_server_status "$id" FAILED "$mode" "$reason" 1 "$duration" || return 1
                    return 1
                    ;;
            esac
        done
    fi

    SERVER_ARCHIVE_SUMMARY=$archive_summary
    sync_summary='SUCCESS'
    for spec in "${sources[@]}"; do
        sync_source "$id" "$spec" 0 "$dry_run"
        rc=$?
        merge_last_change_stats
        case "$rc" in
            0)
                ;;
            2)
                if (( server_rc == 0 )); then
                    server_rc=2
                    sync_summary='WARNING'
                    reason=${LAST_FAILURE_REASON:-FILES_VANISHED}
                fi
                build_failure_body "$id" "$mode" 'RSYNC' "${LAST_FAILURE_REASON:-FILES_VANISHED}" "${LAST_EXIT_CODE:-24}" "${LAST_ATTEMPT_COUNT:-1}" "${LAST_COMMAND_OUTPUT:-}" "$LAST_SOURCE_NAME"
                failure_parts+="$FAILURE_BODY_RESULT"$'\n'
                ;;
            *)
                server_rc=1
                sync_summary='FAILED'
                reason=${LAST_FAILURE_REASON:-RSYNC_FAILED}
                build_failure_body "$id" "$mode" 'RSYNC' "$reason" "${LAST_EXIT_CODE:-1}" "${LAST_ATTEMPT_COUNT:-1}" "${LAST_COMMAND_OUTPUT:-}" "$LAST_SOURCE_NAME"
                failure_parts+="$FAILURE_BODY_RESULT"$'\n'
                ;;
        esac
    done

    finalize_server_change_stats
    duration=$(( $(wall_now_epoch) - started ))
    if (( dry_run == 1 )); then
        SERVER_RESULT_LINE=$(printf '[OK] %-20s archive=%-20s sync=%-8s duration=%s' \
            "$name" "$archive_summary" "$sync_summary" "$(format_duration "$duration")")
    else
        SERVER_RESULT_LINE=$(printf '[OK] %-20s archive=%-20s sync=%-8s transferred=%s avg_speed=%s changes=%s created=%s updated=%s deleted=%s attempts=%s complete=%s duration=%s' \
            "$name" "$archive_summary" "$sync_summary" \
            "$(server_transfer_size_display)" \
            "$(server_average_speed_display)" \
            "$(server_change_value "$SERVER_CHANGE_COUNT")" \
            "$(server_change_value "$SERVER_CHANGE_CREATED")" \
            "$(server_change_value "$SERVER_CHANGE_UPDATED")" \
            "$(server_change_value "$SERVER_CHANGE_DELETED")" \
            "$SERVER_CHANGE_ATTEMPTS" "$SERVER_CHANGE_COMPLETE" "$(format_duration "$duration")")
    fi
    SERVER_FAILURE_BODY=${failure_parts%$'\n'}
    [[ -z "$SERVER_FAILURE_BODY" ]] || attach_server_change_summary

    case "$server_rc" in
        0)
            SERVER_STATUS='SUCCESS'
            SERVER_REASON='SUCCESS'
            if (( dry_run == 0 )); then
                persist_server_status "$id" SUCCESS "$mode" SUCCESS 0 "$duration" || return 1
            fi
            return 0
            ;;
        2)
            SERVER_STATUS='WARNING'
            SERVER_REASON=$reason
            if (( dry_run == 0 )); then
                persist_server_status "$id" WARNING "$mode" "$reason" 2 "$duration" || return 1
            fi
            return 2
            ;;
        *)
            SERVER_STATUS='FAILED'
            SERVER_REASON=$reason
            if (( dry_run == 0 )); then
                persist_server_status "$id" FAILED "$mode" "$reason" 1 "$duration" || return 1
            fi
            return 1
            ;;
    esac
}

run_batch() {
    local mode=$1
    local dry_run=$2
    shift 2
    local started duration id rc success_count=0 warning_count=0 failed_count=0 overall=0
    local success_lines='' summary_body failure_title persistence_failed=0
    local run_log_epoch='' maintenance_rc maintenance_body
    local -a persisted_ids=()

    RUN_ID=${SYNCWARDEN_RUN_ID:-$(new_run_id)}
    started=$(wall_now_epoch)

    if (( dry_run == 0 )); then
        run_log_epoch=$(log_reference_epoch) || return 1
        refresh_log_paths "$run_log_epoch" || return 1
    fi

    for id in "$@"; do
        run_server "$id" "$mode" "$dry_run"
        rc=$?
        if (( dry_run == 0 )) && [[ "${SERVER_REASON:-}" != 'STATE_WRITE_FAILED' && -f "$LAST_STATUS_DIR/$id.status" && ! -L "$LAST_STATUS_DIR/$id.status" ]]; then
            persisted_ids+=("$id")
        fi
        case "$rc" in
            0)
                success_count=$((success_count + 1))
                success_lines+="$SERVER_RESULT_LINE"$'\n'
                ;;
            2)
                warning_count=$((warning_count + 1))
                (( overall == 0 )) && overall=2
                failure_title="WARNING - $(resolve_value "$id" name)"
                if (( dry_run == 0 )); then
                    append_log_block "$FAILURE_LOG" "$failure_title" "$SERVER_FAILURE_BODY" || persistence_failed=1
                else
                    render_log_block "$failure_title" "$SERVER_FAILURE_BODY"
                fi
                ;;
            *)
                failed_count=$((failed_count + 1))
                overall=1
                failure_title="FAILURE - $(resolve_value "$id" name)"
                if (( dry_run == 0 )); then
                    append_log_block "$FAILURE_LOG" "$failure_title" "$SERVER_FAILURE_BODY" || persistence_failed=1
                else
                    render_log_block "$failure_title" "$SERVER_FAILURE_BODY"
                fi
                ;;
        esac
    done

    duration=$(( $(wall_now_epoch) - started ))
    summary_body=$(printf '  Time     : %s\n  Run ID   : %s\n  Mode     : %s\n--------------------------------------------------------------------------------\n%s--------------------------------------------------------------------------------\nSUMMARY\n  Success  : %d\n  Warning  : %d\n  Failed   : %d\n  Duration : %s' \
        "$(timestamp_now)" "$RUN_ID" "$mode" "$success_lines" "$success_count" "$warning_count" "$failed_count" "$(format_duration "$duration")")

    if (( dry_run == 0 )); then
        append_log_block "$SUCCESS_LOG" 'RUN START' "$summary_body" || persistence_failed=1
        maintain_monthly_logs "$run_log_epoch"
        maintenance_rc=$?
        if (( maintenance_rc != 0 )); then
            maintenance_body=$(printf '  Time       : %s\n  Run ID     : %s\n  Mode       : %s\n  Stage      : LOG_MAINTENANCE\n  Reason     : LOG_MAINTENANCE_WARNING\n--------------------------------------------------------------------------------\n%s' \
                "$(timestamp_now)" "$RUN_ID" "$mode" "$LOG_MAINTENANCE_MESSAGES")
            append_log_block "$FAILURE_LOG" 'WARNING - LOG MAINTENANCE' "$maintenance_body" || persistence_failed=1
            (( overall == 0 )) && overall=2
            summary_body+=$'\n  Log Maintenance : WARNING'
        fi
    fi
    if (( persistence_failed != 0 )); then
        overall=1
        if (( dry_run == 0 )); then
            for id in "${persisted_ids[@]}"; do
                mark_last_status_failed "$id" 'LOG_WRITE_FAILED' || :
            done
        fi
        summary_body+=$'\n  Final Status : FAILED\n  Reason       : LOG_WRITE_FAILED'
    fi

    printf '%s\n' "$summary_body"

    return "$overall"
}

scheduled_due_now() {
    local current_hour=${1-}
    local item
    local -a hours=()
    [[ -n "$current_hour" ]] || current_hour=${SYNCWARDEN_NOW_HOUR:-$(date +%H)}
    current_hour=$((10#$current_hour))
    IFS=',' read -r -a hours <<<"${GLOBAL[sync_hours]}"
    for item in "${hours[@]}"; do
        item=$(trim "$item")
        (( current_hour == 10#$item )) && return 0
    done
    return 1
}

current_schedule_hour() {
    local current_hour=${SYNCWARDEN_NOW_HOUR:-$(date +%H)}
    printf '%d\n' "$((10#$current_hour))"
}

schedule_state_path() {
    local epoch=${1-} hour=${2-} date_key
    [[ -n "$epoch" ]] || epoch=${SYNCWARDEN_NOW_EPOCH:-$(wall_now_epoch)}
    [[ -n "$hour" ]] || hour=$(current_schedule_hour) || return 1
    date_key=$(date -d "@$epoch" +%Y-%m-%d) || return 1
    printf '%s/%s_%02d.state\n' "$SCHEDULE_STATE_DIR" "$date_key" "$hour"
}

schedule_slot_already_recorded() {
    local target=${1-}
    [[ -n "$target" ]] || target=$(schedule_state_path) || return 1
    [[ -f "$target" ]]
}

write_schedule_state() {
    [[ $# -eq 4 ]] || return 64
    local target=$1 hour=$2 status=$3 exit_code=$4 temp
    [[ "$(dirname -- "$target")" == "$SCHEDULE_STATE_DIR" ]] || return 1
    make_temp_file temp "$SCHEDULE_STATE_DIR/.schedule_${hour}.XXXXXX.tmp" || return 1
    if ! {
        printf 'time=%s\n' "$(timestamp_now)"
        printf 'run_id=%s\n' "${RUN_ID:-none}"
        printf 'hour=%s\n' "$hour"
        printf 'status=%s\n' "$status"
        printf 'exit_code=%s\n' "$exit_code"
    } >"$temp"; then
        discard_temp_file "$temp"
        return 1
    fi
    chmod 0600 -- "$temp" || {
        discard_temp_file "$temp"
        return 1
    }
    mv -f -- "$temp" "$target" || {
        discard_temp_file "$temp"
        return 1
    }
    unregister_temp_file "$temp"
}

acquire_lock() {
    exec {SYNCWARDEN_LOCK_FD}>"$LOCK_FILE" || return 1
    if ! flock -n "$SYNCWARDEN_LOCK_FD"; then
        printf 'SyncWarden is already running (lock: %s)\n' "$LOCK_FILE" >&2
        return 75
    fi
}

scheduled_server_ids() {
    local output_name=$1
    local -n output=$output_name
    local id
    output=()
    for id in "${SERVER_IDS[@]}"; do
        [[ "$(resolve_value "$id" scheduled_sync_enabled)" == 'yes' ]] && output+=("$id")
    done
}

run_archive_only() {
    local id=$1
    local started spec local_name rc overall=0 duration name status='SUCCESS' reason='SUCCESS'
    local success_lines='' failure_body='' title summary_body persistence_failed=0
    local maintenance_rc maintenance_body run_log_epoch
    local -a sources=()
    RUN_ID=${SYNCWARDEN_RUN_ID:-$(new_run_id)}
    run_log_epoch=$(log_reference_epoch) || return 1
    refresh_log_paths "$run_log_epoch" || return 1
    started=$(wall_now_epoch)
    name=$(resolve_value "$id" name)
    get_server_sources "$id" sources
    reset_server_change_stats
    SERVER_CHANGE_STATE='not_applicable'
    SERVER_CHANGE_COMPLETE='not_applicable'
    for spec in "${sources[@]}"; do
        local_name=$(source_local_name "$spec") || local_name='unknown'
        archive_source "$id" "$spec"
        rc=$?
        case "$rc" in
            0)
                success_lines+="$(printf '[OK] %-20s source=%-20s archive=%s changes=not_applicable created=not_applicable updated=not_applicable deleted=not_applicable attempts=0 complete=not_applicable' "$name" "$local_name" "$LAST_ARCHIVE_STATUS")"$'\n'
                ;;
            2)
                if (( overall == 0 )); then
                    overall=2
                    status='WARNING'
                    reason=$LAST_ARCHIVE_STATUS
                fi
                build_failure_body "$id" ARCHIVE_ONLY ARCHIVE_CLEANUP "$LAST_ARCHIVE_STATUS" 2 1 "${LAST_COMMAND_OUTPUT:-}" "$LAST_SOURCE_NAME"
                failure_body+="$FAILURE_BODY_RESULT"$'\n'
                ;;
            *)
                overall=1
                status='FAILED'
                reason=${LAST_ARCHIVE_STATUS:-FAILED_ARCHIVE}
                build_failure_body "$id" ARCHIVE_ONLY ARCHIVE "$reason" 1 1 "${LAST_COMMAND_OUTPUT:-}" "$LAST_SOURCE_NAME"
                failure_body+="$FAILURE_BODY_RESULT"$'\n'
                ;;
        esac
    done

    duration=$(( $(wall_now_epoch) - started ))
    summary_body=$(printf '  Time     : %s\n  Run ID   : %s\n  Mode     : ARCHIVE_ONLY\n--------------------------------------------------------------------------------\n%s--------------------------------------------------------------------------------\nSUMMARY\n  Status   : %s\n  Duration : %s' \
        "$(timestamp_now)" "$RUN_ID" "$success_lines" "$status" "$(format_duration "$duration")")
    append_log_block "$SUCCESS_LOG" 'ARCHIVE ONLY' "$summary_body" || persistence_failed=1
    if [[ -n "$failure_body" ]]; then
        failure_body=${failure_body%$'\n'}
        failure_body+=$'\n'"$(render_server_change_summary)"
        title=$([[ "$overall" -eq 2 ]] && printf 'WARNING - %s' "$name" || printf 'FAILURE - %s' "$name")
        append_log_block "$FAILURE_LOG" "$title" "$failure_body" || persistence_failed=1
    fi
    maintain_monthly_logs "$run_log_epoch"
    maintenance_rc=$?
    if (( maintenance_rc != 0 )); then
        maintenance_body=$(printf '  Time       : %s\n  Run ID     : %s\n  Mode       : ARCHIVE_ONLY\n  Stage      : LOG_MAINTENANCE\n  Reason     : LOG_MAINTENANCE_WARNING\n--------------------------------------------------------------------------------\n%s' \
            "$(timestamp_now)" "$RUN_ID" "$LOG_MAINTENANCE_MESSAGES")
        append_log_block "$FAILURE_LOG" 'WARNING - LOG MAINTENANCE' "$maintenance_body" || persistence_failed=1
        if (( overall == 0 )); then
            overall=2
            status='WARNING'
            reason='LOG_MAINTENANCE_WARNING'
        fi
        summary_body+=$(printf '\n  Log Maintenance : WARNING\n  Final Status    : %s' "$status")
    fi
    if (( persistence_failed != 0 )); then
        overall=1
        status='FAILED'
        reason='LOG_WRITE_FAILED'
    fi
    if ! write_last_status "$id" "$status" ARCHIVE_ONLY "$reason" "$overall" "$duration"; then
        persistence_failed=1
        overall=1
        status='FAILED'
        reason='STATE_WRITE_FAILED'
    fi
    if (( persistence_failed != 0 )); then
        summary_body+=$(printf '\n  Final Status : %s\n  Reason       : %s' "$status" "$reason")
    fi
    printf '%s\n' "$summary_body"
    (( persistence_failed == 0 )) || return 1
    return "$overall"
}

main() {
    local first=${1-}

    if [[ -z "$first" ]]; then
        print_brief_usage >&2
        return 64
    fi

    case "$first" in
        -h|--help)
            [[ -z "${2-}" ]] || {
                printf 'help does not accept additional arguments\n' >&2
                return 64
            }
            print_usage
            return 0
            ;;
        -n|--dry-run)
            printf 'dry-run requires a configured SERVER_ID before %s\n' "$first" >&2
            return 64
            ;;
        -r|--show-resolved)
            printf '%s is only valid after -c or --check\n' "$first" >&2
            return 64
            ;;
    esac

    case "$first" in
        -c|--check)
            if [[ "${2-}" == '-r' || "${2-}" == '--show-resolved' ]]; then
                [[ -z "${3-}" ]] || {
                    printf 'too many arguments for check\n' >&2
                    return 64
                }
            elif [[ -n "${2-}" ]]; then
                printf 'unknown check option: %s\n' "$2" >&2
                return 64
            fi
            load_main_config || return 1
            check_dependencies || return 1
            check_private_keys "${SERVER_IDS[@]}" || return 1
            printf 'SyncWarden configuration OK: %d server(s)\n' "${#SERVER_IDS[@]}"
            if [[ "${2-}" == '-r' || "${2-}" == '--show-resolved' ]]; then
                print_resolved_config
            fi
            return 0
            ;;
        -l|--list)
            [[ -z "${2-}" ]] || {
                printf '%s does not accept additional arguments\n' "$first" >&2
                return 64
            }
            load_main_config || return 1
            print_server_list
            return 0
            ;;
        -t|--status)
            [[ -n "${2-}" && -z "${3-}" ]] || {
                printf 'usage: syncwarden.sh %s SERVER_ID\n' "$first" >&2
                return 64
            }
            load_main_config || return 1
            server_exists "$2" || {
                printf 'unknown server ID: %s\n' "$2" >&2
                return 64
            }
            print_status "$2"
            return 0
            ;;
        -s|--scheduled)
            [[ -z "${2-}" ]] || {
                printf '%s does not accept additional arguments\n' "$first" >&2
                return 64
            }
            load_runtime_config_or_log SCHEDULED || return 1
            check_dependencies || return 1
            ensure_home_layout || return 1
            install_cleanup_traps
            local lock_rc scheduled_epoch scheduled_hour scheduled_path
            acquire_lock
            lock_rc=$?
            (( lock_rc == 0 )) || return "$lock_rc"
            scheduled_epoch=${SYNCWARDEN_NOW_EPOCH:-$(wall_now_epoch)}
            scheduled_hour=$(current_schedule_hour) || return 1
            if ! scheduled_due_now "$scheduled_hour"; then
                printf 'No SyncWarden task is due at this hour.\n'
                return 0
            fi
            scheduled_path=$(schedule_state_path "$scheduled_epoch" "$scheduled_hour") || return 1
            if schedule_slot_already_recorded "$scheduled_path"; then
                printf 'This SyncWarden schedule slot is already completed: %s\n' "$scheduled_path"
                return 0
            fi
            local -a scheduled_ids=()
            scheduled_server_ids scheduled_ids
            (( ${#scheduled_ids[@]} > 0 )) || {
                printf 'No servers are configured for scheduled synchronization.\n'
                return 0
            }
            local scheduled_rc scheduled_status
            run_batch SCHEDULED 0 "${scheduled_ids[@]}"
            scheduled_rc=$?
            case "$scheduled_rc" in
                0) scheduled_status='SUCCESS' ;;
                2) scheduled_status='WARNING' ;;
                *) scheduled_status='FAILED' ;;
            esac
            write_schedule_state "$scheduled_path" "$scheduled_hour" "$scheduled_status" "$scheduled_rc" || return 1
            return "$scheduled_rc"
            ;;
        -a|--archive)
            [[ -n "${2-}" && -z "${3-}" ]] || {
                printf 'usage: syncwarden.sh %s SERVER_ID\n' "$first" >&2
                return 64
            }
            load_runtime_config_or_log ARCHIVE_ONLY || return 1
            server_exists "$2" || {
                printf 'unknown server ID: %s\n' "$2" >&2
                return 64
            }
            check_dependencies || return 1
            ensure_home_layout || return 1
            install_cleanup_traps
            local archive_lock_rc
            acquire_lock
            archive_lock_rc=$?
            (( archive_lock_rc == 0 )) || return "$archive_lock_rc"
            run_archive_only "$2"
            return $?
            ;;
        -*)
            printf 'unknown option: %s\n' "$first" >&2
            print_brief_usage >&2
            return 64
            ;;
        *)
            if [[ -n "${2-}" && "${2-}" != '-n' && "${2-}" != '--dry-run' ]]; then
                printf 'unknown argument for server %s: %s\n' "$first" "$2" >&2
                return 64
            fi
            [[ -z "${3-}" ]] || {
                printf 'too many arguments\n' >&2
                return 64
            }
            local manual_lock_rc dry_run=0 manual_mode='MANUAL'
            if [[ "${2-}" == '-n' || "${2-}" == '--dry-run' ]]; then
                dry_run=1
                manual_mode='DRY_RUN'
                load_main_config || return 1
            else
                load_runtime_config_or_log MANUAL || return 1
            fi
            server_exists "$first" || {
                printf 'unknown server ID: %s\n' "$first" >&2
                return 64
            }
            check_dependencies || return 1
            ensure_home_layout || return 1
            install_cleanup_traps
            acquire_lock
            manual_lock_rc=$?
            (( manual_lock_rc == 0 )) || return "$manual_lock_rc"
            run_batch "$manual_mode" "$dry_run" "$first"
            return $?
            ;;
    esac
}

invocation_mode() {
    local first=${1-}
    local second=${2-}

    case "$first" in
        -h|--help) printf 'HELP\n' ;;
        -c|--check) printf 'CHECK\n' ;;
        -l|--list) printf 'LIST\n' ;;
        -t|--status) printf 'STATUS\n' ;;
        -s|--scheduled) printf 'SCHEDULED\n' ;;
        -a|--archive) printf 'ARCHIVE_ONLY\n' ;;
        -n|--dry-run) printf 'DRY_RUN\n' ;;
        -*|'') printf 'UNKNOWN\n' ;;
        *)
            if [[ "$second" == '-n' || "$second" == '--dry-run' ]]; then
                printf 'DRY_RUN\n'
            else
                printf 'MANUAL\n'
            fi
            ;;
    esac
}

mode_persists_global_timeout() {
    case "$1" in
        MANUAL|SCHEDULED|ARCHIVE_ONLY) return 0 ;;
        *) return 1 ;;
    esac
}

persist_global_timeout() {
    local mode=$1
    local run_id=$2
    local body

    ensure_home_layout || {
        printf 'global timeout log error: cannot initialize SyncWarden control directories\n' >&2
        return 1
    }
    refresh_log_paths || {
        printf 'global timeout log error: cannot determine monthly failure log\n' >&2
        return 1
    }
    body=$(printf '  Time       : %s\n  Run ID     : %s\n  Mode       : %s\n  Stage      : GLOBAL_RUNTIME\n  Reason     : GLOBAL_TIMEOUT\n  Exit Code  : 124\n  Limit      : %s (%s seconds)' \
        "$(timestamp_now)" "$run_id" "$mode" \
        "$(format_global_runtime_limit)" "$GLOBAL_RUNTIME_TIMEOUT_SECONDS")
    append_log_block "$FAILURE_LOG" 'FAILURE - GLOBAL TIMEOUT' "$body" || {
        printf 'global timeout log error: cannot append to %s\n' "$FAILURE_LOG" >&2
        return 1
    }
}

run_with_global_timeout() {
    local mode run_id rc

    if [[ "${SYNCWARDEN_GLOBAL_TIMEOUT_ACTIVE:-0}" == '1' ]]; then
        main "$@"
        return $?
    fi

    if ! command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
        printf 'required command not found: timeout\n' >&2
        return 1
    fi

    mode=$(invocation_mode "$@")
    run_id=${SYNCWARDEN_RUN_ID:-$(new_run_id)}
    SYNCWARDEN_GLOBAL_TIMEOUT_ACTIVE=1 \
    SYNCWARDEN_RUN_ID="$run_id" \
        "$TIMEOUT_BIN" \
        --signal=TERM \
        "--kill-after=${GLOBAL_TIMEOUT_KILL_GRACE_SECONDS}s" \
        "${GLOBAL_RUNTIME_TIMEOUT_SECONDS}s" \
        "$0" "$@"
    rc=$?

    if (( rc == 124 )); then
        printf 'SyncWarden global runtime limit exceeded: %s; mode=%s; reason=GLOBAL_TIMEOUT\n' \
            "$(format_global_runtime_limit)" "$mode" >&2
        if mode_persists_global_timeout "$mode"; then
            persist_global_timeout "$mode" "$run_id" || :
        fi
    fi

    return "$rc"
}

if [[ "${SYNCWARDEN_LIB_MODE:-0}" != '1' && "${BASH_SOURCE[0]}" == "$0" ]]; then
    run_with_global_timeout "$@"
    exit $?
fi
