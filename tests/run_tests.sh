#!/usr/bin/env bash

if (( BASH_VERSINFO[0] < 5 )); then
    printf 'SyncWarden tests require Bash 5 or newer; found %s.\n' "$BASH_VERSION" >&2
    exit 69
fi

set -uo pipefail

# Keep date formatting deterministic and avoid inheriting the host timezone.
export TZ=UTC

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_DIR=$(cd -- "$TEST_DIR/.." && pwd -P)
SCRIPT_PATH="$PROJECT_DIR/syncwarden.sh"
FIXTURE_DIR="$TEST_DIR/fixtures"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
CURRENT_SUITE=${1:-all}
TEST_RUN_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/syncwarden-test-run.XXXXXX") || exit 1

cleanup_test_run() {
    rm -rf -- "$TEST_RUN_ROOT"
}

trap cleanup_test_run EXIT

TEST_PRIVATE_KEY="$TEST_RUN_ROOT/id_test"
CLI_FIXTURE_CONFIG="$TEST_RUN_ROOT/base-cli.conf"
printf '%s\n' 'test private key placeholder' >"$TEST_PRIVATE_KEY"
chmod 0600 "$TEST_PRIVATE_KEY"
sed "s#^key_file=.*#key_file=$TEST_PRIVATE_KEY#" "$FIXTURE_DIR/base.conf" >"$CLI_FIXTURE_CONFIG"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    printf 'PASS: %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

skip() {
    printf 'SKIP: %s\n' "$1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

assert_eq() {
    local expected=$1
    local actual=$2
    local message=$3
    if [[ "$expected" == "$actual" ]]; then
        pass "$message"
    else
        fail "$message (expected='$expected' actual='$actual')"
    fi
}

assert_contains() {
    local needle=$1
    local haystack=$2
    local message=$3
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (missing '$needle')"
    fi
}

assert_not_contains() {
    local needle=$1
    local haystack=$2
    local message=$3
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (unexpected '$needle')"
    fi
}

assert_matches() {
    local pattern=$1
    local actual=$2
    local message=$3
    if [[ "$actual" =~ $pattern ]]; then
        pass "$message"
    else
        fail "$message (pattern='$pattern')"
    fi
}

assert_file_exists() {
    local path=$1
    local message=$2
    if [[ -f "$path" ]]; then
        pass "$message"
    else
        fail "$message (missing file '$path')"
    fi
}

assert_file_not_exists() {
    local path=$1
    local message=$2
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        pass "$message"
    else
        fail "$message (unexpected path '$path')"
    fi
}

assert_symlink_exists() {
    local path=$1
    local message=$2
    if [[ -L "$path" ]]; then
        pass "$message"
    else
        fail "$message (missing symlink '$path')"
    fi
}

assert_dir_exists() {
    local path=$1
    local message=$2
    if [[ -d "$path" ]]; then
        pass "$message"
    else
        fail "$message (missing directory '$path')"
    fi
}

assert_fails_with() {
    local expected_text=$1
    local message=$2
    shift 2
    local output rc
    output=$("$@" 2>&1)
    rc=$?
    if (( rc != 0 )) && [[ "$output" == *"$expected_text"* ]]; then
        pass "$message"
    else
        fail "$message (rc=$rc output='$output')"
    fi
}

make_temp_dir() {
    mktemp -d "$TEST_RUN_ROOT/case.XXXXXX"
}

write_file() {
    local path=$1
    local content=$2
    printf '%s\n' "$content" >"$path"
}

load_and_validate() {
    local config=$1
    load_config "$config" && validate_config
}

write_external_contract_config() {
    local path=$1
    local destination_root="$TEST_RUN_ROOT/config-destinations"
    local servers=${2:-$'[server:x]\nhost=example.com\ndestination=/backup/x\nsource=/srv/data'}
    local line destination_parent
    mkdir -p "$destination_root"
    servers=${servers//\/backup\//$destination_root/}
    while IFS= read -r line; do
        [[ "$line" == destination="$destination_root"/* ]] || continue
        destination_parent=$(dirname -- "${line#destination=}")
        mkdir -p -- "$destination_parent"
    done <<<"$servers"
    write_file "$path" "[global]
sync_hours=3,15
log_retention_months=6

[defaults]
scheduled_sync_enabled=yes
port=22
user=backup
key_file=/home/backup/.ssh/id_syncwarden
rsync_timeout_seconds=300
retry_count=2
retry_delays_seconds=30,120
owner=nobody:nogroup
archive_recent_keep=7
archive_monthly_keep=6
min_free_space_mb=2048
min_free_inodes=10000

$servers"
}

replace_config_value() {
    local path=$1 key=$2 value=$3 temp
    temp="${path}.replace"
    awk -v key="$key" -v value="$value" '{
        if (!replaced && $0 ~ ("^" key "=")) {
            print key "=" value
            replaced=1
        }
        else print
    }' "$path" >"$temp"
    mv -f -- "$temp" "$path"
}

test_parser_accepts_external_only_contract() {
    local tmp config
    local -a sources=()
    tmp=$(make_temp_dir)
    config="$tmp/external-contract.conf"
    write_external_contract_config "$config" $'[server:x]\nhost=example.com\ndestination=/backup/x\nsource=/srv/data\nsource=/opt/application'

    load_and_validate "$config" || {
        fail 'complete external-only configuration is accepted'
        return
    }

    assert_eq 'yes' "$(resolve_value x scheduled_sync_enabled)" 'scheduled sync setting is inherited explicitly'
    assert_eq "$TEST_RUN_ROOT/config-destinations/x" "$(resolved_destination x)" 'destination comes directly from the server section'
    get_server_sources x sources
    assert_eq '2' "${#sources[@]}" 'multiple server source paths are retained'
    assert_eq '/srv/data' "${sources[0]}" 'first source is a remote absolute path only'
    assert_eq '/opt/application' "${sources[1]}" 'second source is a remote absolute path only'
}

test_parser_requires_all_external_values() {
    local tmp config filtered key
    local -a global_keys=(sync_hours log_retention_months)
    local -a default_keys=(
        scheduled_sync_enabled port user key_file rsync_timeout_seconds
        retry_count retry_delays_seconds
        owner archive_recent_keep archive_monthly_keep min_free_space_mb min_free_inodes
    )
    tmp=$(make_temp_dir)

    for key in "${global_keys[@]}" "${default_keys[@]}"; do
        config="$tmp/missing-$key.conf"
        filtered="$tmp/missing-$key.filtered"
        write_external_contract_config "$config"
        awk -v key="$key" '$0 !~ ("^" key "=") { print }' "$config" >"$filtered"
        mv -f -- "$filtered" "$config"
        load_config "$config" || {
            fail "missing '$key' fixture parses before validation"
            continue
        }
        assert_fails_with "missing required key '$key'" "missing external value '$key' is rejected explicitly" validate_config
    done
}

test_parser_rejects_removed_pseudo_configuration() {
    local tmp config key value
    local -a entries=(
        'enabled=yes'
        'destination_root=/backup'
        'destination_prefix=v-'
        'delete=yes'
        'delete_delay=yes'
        'archive_before_each_sync=yes'
        'archive_required_before_sync=yes'
        'archive_verify=yes'
        'archive_monthly_pick=last'
    )
    tmp=$(make_temp_dir)

    for value in "${entries[@]}"; do
        key=${value%%=*}
        config="$tmp/removed-$key.conf"
        write_file "$config" "[defaults]
$value"
        assert_fails_with "unknown key '$key'" "removed pseudo setting '$key' is rejected" load_config "$config"
    done
}

test_parser_requires_server_destination_and_source() {
    local tmp config filtered
    tmp=$(make_temp_dir)

    config="$tmp/missing-destination.conf"
    write_external_contract_config "$config"
    filtered="$tmp/missing-destination.filtered"
    awk '$0 !~ /^destination=/' "$config" >"$filtered"
    mv -f -- "$filtered" "$config"
    load_config "$config" || {
        fail 'missing-destination fixture parses before validation'
        return
    }
    assert_fails_with 'missing required destination' 'every server requires an explicit destination' validate_config

    config="$tmp/missing-source.conf"
    write_external_contract_config "$config"
    filtered="$tmp/missing-source.filtered"
    awk '$0 !~ /^source=/' "$config" >"$filtered"
    mv -f -- "$filtered" "$config"
    load_config "$config" || {
        fail 'missing-source fixture parses before validation'
        return
    }
    assert_fails_with 'missing required source' 'every server requires at least one source' validate_config
}

test_parser_derives_source_names_and_rejects_duplicates() {
    local tmp config
    tmp=$(make_temp_dir)

    assert_eq 'application' "$(source_local_name /opt/application 2>/dev/null)" 'source local name is derived from the final path component'

    config="$tmp/duplicate-source-basename.conf"
    write_external_contract_config "$config" $'[server:x]\nhost=example.com\ndestination=/backup/x\nsource=/srv/example-app/data\nsource=/opt/data'
    load_config "$config" || {
        fail 'duplicate-source-basename fixture parses before validation'
        return
    }
    assert_fails_with "duplicate local source name 'data'" 'duplicate derived source names are rejected' validate_config
}

test_parser_rejects_ambiguous_source_forms() {
    local tmp config source expected label
    local -a cases=(
        '/^must not be root^remote root'
        '/srv/data/^must not end with^trailing slash'
        '/srv/data|data^unsupported character^legacy source delimiter'
        '/srv/customer data/export^unsupported character^source containing a space'
        '/srv/customer;data/export^unsupported character^source containing a semicolon'
        '/srv/客户/export^unsupported character^source containing non-ASCII text'
        '/srv//export^unsafe path component^empty path component'
        '/srv/../export^unsafe path component^parent path component'
        '/srv/./export^unsafe path component^current path component'
        '^source must not be empty^empty source'
    )
    tmp=$(make_temp_dir)

    for label in "${cases[@]}"; do
        source=${label%%^*}
        label=${label#*^}
        expected=${label%%^*}
        label=${label#*^}
        config="$tmp/source-${label// /-}.conf"
        write_external_contract_config "$config" "[server:x]
host=example.com
destination=/backup/x
source=$source"
        load_config "$config" || {
            fail "$label fixture parses before validation"
            continue
        }
        assert_fails_with "$expected" "$label is rejected" validate_config
    done
}

test_parser_requires_existing_non_root_destination_parent() {
    local tmp config destination
    tmp=$(make_temp_dir)

    config="$tmp/direct-root.conf"
    write_external_contract_config "$config" $'[server:x]\nhost=example.com\ndestination=/backup\nsource=/srv/data'
    load_config "$config" || {
        fail 'direct-root destination fixture parses before validation'
        return
    }
    assert_fails_with 'must not be directly below root' 'destination directly below root is rejected' validate_config

    destination="$tmp/missing-parent/server"
    config="$tmp/missing-parent.conf"
    write_external_contract_config "$config" "[server:x]
host=example.com
destination=$destination
source=/srv/data"
    load_config "$config" || {
        fail 'missing-parent destination fixture parses before validation'
        return
    }
    assert_fails_with 'destination parent must already exist' 'missing destination parent is rejected' validate_config

    mkdir -p "$tmp/existing-parent"
    destination="$tmp/existing-parent/server"
    config="$tmp/final-component-missing.conf"
    write_external_contract_config "$config" "[server:x]
host=example.com
destination=$destination
source=/srv/data"
    if load_and_validate "$config"; then
        pass 'missing final destination is accepted below an existing parent'
    else
        fail 'missing final destination should be creatable one level below an existing parent'
    fi
    assert_file_not_exists "$destination" 'configuration validation does not create the final destination'
}

test_script_contains_no_concrete_environment_configuration() {
    local content
    content=$(<"$SCRIPT_PATH")
    assert_not_contains '/opt/syncwarden' "$content" 'script contains no fixed deployment control directory'
    assert_not_contains '/var/backups/syncwarden' "$content" 'script contains no fixed destination root'
    assert_not_contains '/home/backup/.ssh/id_syncwarden' "$content" 'script contains no fixed private-key path'
    assert_not_contains '22' "$content" 'script contains no fixed SSH port'
    assert_not_contains 'source.example.net' "$content" 'script contains no configured server address'
    assert_not_contains "GLOBAL[sync_hours]='" "$content" 'script does not assign a hidden schedule'
    assert_not_contains "DEFAULTS[port]='" "$content" 'script does not assign hidden server defaults'
    assert_not_contains 'ServerAliveInterval=30' "$content" 'script contains no hidden SSH keepalive interval'
}

test_scheduled_sync_enabled_only_filters_scheduled_mode() {
    local tmp config
    local -a scheduled_ids=()
    tmp=$(make_temp_dir)
    config="$tmp/scheduled-selection.conf"
    write_external_contract_config "$config" $'[server:one]\nhost=one.example\ndestination=/backup/one\nsource=/srv/data\n\n[server:two]\nhost=two.example\nscheduled_sync_enabled=no\ndestination=/backup/two\nsource=/srv/data'

    load_and_validate "$config" || {
        fail 'scheduled selection fixture is valid'
        return
    }
    scheduled_server_ids scheduled_ids
    assert_eq '1' "${#scheduled_ids[@]}" 'scheduled selection includes only enabled servers'
    assert_eq 'one' "${scheduled_ids[0]}" 'scheduled selection retains configured order'
    if server_exists two; then
        pass 'scheduled-disabled server remains available to manual commands'
    else
        fail 'scheduled-disabled server must remain available to manual commands'
    fi
}

test_parser_inherits_and_overrides() {
    load_and_validate "$FIXTURE_DIR/base.conf" || {
        fail 'valid fixture loads'
        return
    }

    assert_eq '22' "$(resolve_value sample-server port)" 'server inherits default port'
    assert_eq '2222' "$(resolve_value backup-node port)" 'server overrides port'
    assert_eq '/tmp/syncwarden-test-sample-server' "$(resolved_destination sample-server)" 'first explicit destination is preserved'
    assert_eq '/tmp/syncwarden-test-backup-node' "$(resolved_destination backup-node)" 'second explicit destination is preserved'
    assert_eq 'yes' "$(resolve_value backup-node scheduled_sync_enabled)" 'scheduled setting is inherited'

    local -a sources=()
    get_server_sources sample-server sources
    assert_eq '1' "${#sources[@]}" 'first server source count is preserved'
    assert_eq '/srv/example-data' "${sources[0]}" 'first server source is preserved'

    sources=()
    get_server_sources backup-node sources
    assert_eq '2' "${#sources[@]}" 'multiple server sources are preserved'
    assert_eq '/srv/example-app' "${sources[0]}" 'first explicit source is preserved'
    assert_eq '/var/lib/example-config' "${sources[1]}" 'second explicit source is preserved'
}

test_parser_rejects_unknown_key() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/unknown.conf"
    write_file "$config" $'[global]\nsync_hours=5\nunknown_option=yes\n[server:x]\nhost=example.com'
    assert_fails_with 'unknown key' 'unknown config key is rejected' load_config "$config"
}

test_parser_rejects_duplicate_server_section() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/duplicate.conf"
    write_file "$config" $'[server:x]\nhost=one.example\n[server:x]\nhost=two.example'
    assert_fails_with 'duplicate server section' 'duplicate server ID is rejected' load_config "$config"
}

test_parser_rejects_missing_host() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/missing-host.conf"
    write_external_contract_config "$config" $'[server:x]\nname=NoHost\ndestination=/backup/x\nsource=/srv/data'
    load_config "$config" || {
        fail 'missing-host fixture parses before validation'
        return
    }
    assert_fails_with 'missing required host' 'missing host is rejected' validate_config
}

test_parser_rejects_invalid_port() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/port.conf"
    write_external_contract_config "$config" $'[server:x]\nhost=example.com\nport=70000\ndestination=/backup/x\nsource=/srv/data'
    load_config "$config" || {
        fail 'invalid-port fixture parses before validation'
        return
    }
    assert_fails_with 'invalid port' 'out-of-range port is rejected' validate_config
}

test_parser_rejects_non_absolute_source() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/source.conf"
    write_external_contract_config "$config" $'[server:x]\nhost=example.com\ndestination=/backup/x\nsource=data'
    load_config "$config" || {
        fail 'invalid-source fixture parses before validation'
        return
    }
    assert_fails_with 'remote source must be absolute' 'relative source is rejected' validate_config
}

test_parser_rejects_duplicate_local_target() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/source-duplicate.conf"
    write_external_contract_config "$config" $'[server:x]\nhost=example.com\ndestination=/backup/x\nsource=/one/srv/data\nsource=/two/srv/data'
    load_config "$config" || {
        fail 'duplicate-source fixture parses before validation'
        return
    }
    assert_fails_with 'duplicate local source name' 'duplicate local source names are rejected' validate_config
}

test_parser_rejects_duplicate_destination_source_pair() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/destination-duplicate.conf"
    write_external_contract_config "$config" $'[server:one]\nhost=one.example\ndestination=/backup/shared\nsource=/srv/data\n\n[server:two]\nhost=two.example\ndestination=/backup/shared\nsource=/srv/data'
    load_config "$config" || {
        fail 'duplicate-destination fixture parses before validation'
        return
    }
    assert_fails_with 'duplicate resolved target' 'duplicate resolved targets are rejected' validate_config
}

test_parser_rejects_canonical_duplicate_destination_source_pair() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/destination-canonical-duplicate.conf"
    write_external_contract_config "$config" $'[server:one]\nhost=one.example\ndestination=/backup/area/../shared\nsource=/srv/data\n\n[server:two]\nhost=two.example\ndestination=/backup/shared\nsource=/srv/data'
    load_config "$config" || {
        fail 'canonical duplicate fixture parses before validation'
        return
    }
    assert_fails_with 'duplicate resolved target' 'canonical-equivalent targets are rejected' validate_config
}

test_parser_rejects_root_after_canonicalization() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/destination-canonical-root.conf"
    write_external_contract_config "$config" $'[server:x]\nhost=example.com\ndestination=/srv/..\nsource=/srv/data'
    load_config "$config" || {
        fail 'canonical root fixture parses before validation'
        return
    }
    assert_fails_with 'canonical destination must not be root' 'destination resolving to root is rejected' validate_config
}

test_parser_rejects_symlinked_destination_component() {
    local tmp config
    tmp=$(make_temp_dir)
    mkdir -p "$tmp/real"
    ln -s "$tmp/real" "$tmp/link"
    config="$tmp/destination-symlink.conf"
    write_external_contract_config "$config" "[server:x]
host=example.com
destination=$tmp/link
source=/srv/data"
    load_config "$config" || {
        fail 'symlink destination fixture parses before validation'
        return
    }
    assert_fails_with 'symbolic-link component' 'destination symlink components are rejected' validate_config
}

test_parser_rejects_short_retry_delay_list() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/retry.conf"
    write_external_contract_config "$config" $'[server:x]\nhost=example.com\nretry_count=2\nretry_delays_seconds=30\ndestination=/backup/x\nsource=/srv/data'
    load_config "$config" || {
        fail 'retry fixture parses before validation'
        return
    }
    assert_fails_with 'retry delays' 'retry delay count is validated' validate_config
}

test_parser_requires_positive_rsync_timeout_and_rejects_removed_timeout_keys() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/timeout-limit.conf"
    write_external_contract_config "$config" $'[server:x]\nhost=example.com\nrsync_timeout_seconds=0\ndestination=/backup/x\nsource=/srv/data'
    load_config "$config" || {
        fail 'timeout-limit fixture parses before validation'
        return
    }
    assert_fails_with "rsync_timeout_seconds' must be a positive decimal integer" 'rsync I/O timeout must be positive' validate_config

    for config in connect_timeout_seconds io_timeout_seconds server_timeout_seconds; do
        write_file "$tmp/removed-$config.conf" "[defaults]
$config=60"
        assert_fails_with "unknown key '$config'" "removed timeout key '$config' is rejected" load_config "$tmp/removed-$config.conf"
    done
}

test_parser_accepts_log_retention_months() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/log-retention.conf"
    write_external_contract_config "$config"
    load_and_validate "$config" || {
        fail 'log_retention_months=6 is accepted'
        return
    }
    assert_eq '6' "${GLOBAL[log_retention_months]}" 'configured log retention is loaded'
}

test_parser_rejects_invalid_log_retention_months() {
    local tmp config filtered value
    tmp=$(make_temp_dir)
    for value in 0 -1 six; do
        config="$tmp/log-retention-$value.conf"
        filtered="$tmp/log-retention-$value.filtered"
        write_external_contract_config "$config"
        awk -v value="$value" '{ if ($0 ~ /^log_retention_months=/) print "log_retention_months=" value; else print }' "$config" >"$filtered"
        mv -f -- "$filtered" "$config"
        load_config "$config" || {
            fail "log retention fixture '$value' parses before validation"
            continue
        }
        assert_fails_with 'log_retention_months' "invalid log retention '$value' is rejected" validate_config
    done
}

test_parser_rejects_leading_zero_integer() {
    local tmp config filtered
    tmp=$(make_temp_dir)
    config="$tmp/leading-zero.conf"
    filtered="$tmp/leading-zero.filtered"
    write_external_contract_config "$config"
    awk '{ if ($0 ~ /^log_retention_months=/) print "log_retention_months=08"; else print }' "$config" >"$filtered"
    mv -f -- "$filtered" "$config"
    load_config "$config" || {
        fail 'leading-zero fixture parses before validation'
        return
    }
    assert_fails_with 'decimal integer' 'leading-zero integers are rejected before Bash arithmetic' validate_config
}

test_parser_rejects_cross_server_nested_managed_paths() {
    local tmp config
    tmp=$(make_temp_dir)
    config="$tmp/nested.conf"
    write_external_contract_config "$config" $'[server:a]\nhost=a.example\ndestination=/backup/a\nsource=/x\n\n[server:b]\nhost=b.example\ndestination=/backup/a/x\nsource=/y'
    load_config "$config" || {
        fail 'nested managed-path fixture parses before validation'
        return
    }
    assert_fails_with 'managed path overlap' 'cross-server ancestor targets are rejected' validate_config
}

test_parser_rejects_control_and_system_destinations() {
    local tmp config destination label
    tmp=$(make_temp_dir)
    for destination in /etc/backup "$SYNCWARDEN_HOME/payload"; do
        label=$(basename -- "$destination")
        config="$tmp/$label.conf"
        write_external_contract_config "$config" "[server:x]
host=example.com
destination=$destination
source=/srv/data"
        load_config "$config" || {
            fail "unsafe destination fixture '$destination' parses before validation"
            continue
        }
        assert_fails_with 'unsafe managed path' "unsafe destination '$destination' is rejected" validate_config
    done
}

test_public_example_uses_approved_retention_policy() {
    local content
    content=$(<"$PROJECT_DIR/example.conf")
    assert_contains 'log_retention_months=6' "$content" 'public example keeps six calendar months of managed logs'
    assert_contains 'archive_recent_keep=7' "$content" 'public example keeps seven recent archives'
    assert_contains 'archive_monthly_keep=6' "$content" 'public example keeps six monthly archives'
    assert_contains 'rsync_timeout_seconds=300' "$content" 'public example exposes only the rsync no-I/O timeout'
    assert_not_contains 'connect_timeout_seconds=' "$content" 'public example has no configurable SSH connect timeout'
    assert_not_contains 'io_timeout_seconds=' "$content" 'public example has no legacy rsync timeout name'
    assert_not_contains 'server_timeout_seconds=' "$content" 'public example has no shared server deadline'
}

test_public_docs_are_chinese_and_project_shaped() {
    local readme example test_readme heading
    local -a headings=(
        '## 核心特性'
        '## 工作原理'
        '## 快速开始'
        '## 配置说明'
        '## 命令'
        '## 安全模型'
        '## 常见问题'
        '## 许可证'
    )

    readme=$(<"$PROJECT_DIR/README.md")
    example=$(<"$PROJECT_DIR/example.conf")
    test_readme=$(<"$PROJECT_DIR/tests/README.md")

    for heading in "${headings[@]}"; do
        assert_contains "$heading" "$readme" "README contains project section '$heading'"
    done
    assert_not_contains 'README.zh.md' "$readme" 'single-language README has no alternate-language link'
    assert_not_contains 'Reliable backups' "$readme" 'project introduction is written in Chinese'
    assert_contains 'SyncWarden 公开示例配置' "$example" 'public example has a Chinese title'
    assert_not_contains 'SyncWarden Public Example Configuration' "$example" 'public example removes the English title'
    assert_contains '## 运行测试' "$test_readme" 'test documentation has a Chinese run section'
    assert_not_contains '# SyncWarden test suite' "$test_readme" 'test documentation removes the English title'
}

run_parser_suite() {
    test_parser_accepts_external_only_contract
    test_parser_requires_all_external_values
    test_parser_rejects_removed_pseudo_configuration
    test_parser_requires_server_destination_and_source
    test_parser_derives_source_names_and_rejects_duplicates
    test_parser_rejects_ambiguous_source_forms
    test_parser_requires_existing_non_root_destination_parent
    test_script_contains_no_concrete_environment_configuration
    test_scheduled_sync_enabled_only_filters_scheduled_mode
    test_parser_inherits_and_overrides
    test_parser_rejects_unknown_key
    test_parser_rejects_duplicate_server_section
    test_parser_rejects_missing_host
    test_parser_rejects_invalid_port
    test_parser_rejects_non_absolute_source
    test_parser_rejects_duplicate_local_target
    test_parser_rejects_duplicate_destination_source_pair
    test_parser_rejects_canonical_duplicate_destination_source_pair
    test_parser_rejects_root_after_canonicalization
    test_parser_rejects_symlinked_destination_component
    test_parser_rejects_short_retry_delay_list
    test_parser_requires_positive_rsync_timeout_and_rejects_removed_timeout_keys
    test_parser_accepts_log_retention_months
    test_parser_rejects_invalid_log_retention_months
    test_parser_rejects_leading_zero_integer
    test_parser_rejects_cross_server_nested_managed_paths
    test_parser_rejects_control_and_system_destinations
    test_public_example_uses_approved_retention_policy
    test_public_docs_are_chinese_and_project_shaped
}

run_cli_command() {
    local home=$1
    shift
    SYNCWARDEN_LIB_MODE=0 SYNCWARDEN_HOME="$home" SYNCWARDEN_CONFIG="$CLI_FIXTURE_CONFIG" \
        "$SCRIPT_PATH" "$@"
}

test_help_is_concise_and_has_no_side_effects() {
    local tmp short long short_rc long_rc line_count
    tmp=$(make_temp_dir)
    short=$(SYNCWARDEN_LIB_MODE=0 SYNCWARDEN_HOME="$tmp/home" SYNCWARDEN_CONFIG="$tmp/missing.conf" "$SCRIPT_PATH" -h 2>&1)
    short_rc=$?
    long=$(SYNCWARDEN_LIB_MODE=0 SYNCWARDEN_HOME="$tmp/home" SYNCWARDEN_CONFIG="$tmp/missing.conf" "$SCRIPT_PATH" --help 2>&1)
    long_rc=$?
    assert_eq '0' "$short_rc" '-h returns zero without a config'
    assert_eq '0' "$long_rc" '--help returns zero without a config'
    assert_eq "$short" "$long" 'short and long help are identical'
    assert_contains '用法' "$long" 'help presents command usage'
    assert_contains 'syncwarden.sh sample-server' "$long" 'help shows a manual synchronization example'
    assert_contains 'syncwarden.sh sample-server --dry-run' "$long" 'help shows a dry-run example'
    assert_contains 'syncwarden.sh --archive SERVER_ID' "$long" 'help lists archive-only mode'
    assert_contains 'syncwarden.sh --scheduled' "$long" 'help lists scheduled mode'
    assert_contains 'syncwarden.sh --check --show-resolved' "$long" 'help lists resolved configuration checks'
    assert_contains 'syncwarden.sh --list' "$long" 'help lists server discovery'
    assert_contains 'syncwarden.sh --status SERVER_ID' "$long" 'help lists status inspection'
    assert_contains 'README.md' "$long" 'help points users to project documentation'
    assert_contains "$tmp/missing.conf" "$long" 'help displays the active configuration path'
    assert_not_contains 'known_hosts' "$long" 'help leaves SSH host-key details in the README'
    assert_not_contains '05h00m00s' "$long" 'help leaves timeout details in the README'
    assert_not_contains '退出码' "$long" 'help leaves exit-code details in the README'
    assert_not_contains 'success-YYYY-MM.log' "$long" 'help leaves log-layout details in the README'
    assert_not_contains '服务器配置要点' "$long" 'help leaves configuration rules in the README'
    assert_not_contains 'dry-run 边界' "$long" 'help leaves dry-run boundaries in the README'
    assert_not_contains '/opt/syncwarden' "$long" 'help contains no fixed deployment control path'
    line_count=$(printf '%s\n' "$long" | wc -l)
    if (( line_count <= 40 )); then
        pass 'help stays within forty lines'
    else
        fail "help should stay within forty lines (actual='$line_count')"
    fi
    assert_file_not_exists "$tmp/home" 'help does not initialize the control root'
}

test_no_args_is_brief_and_has_no_side_effects() {
    local tmp output rc
    tmp=$(make_temp_dir)
    output=$(SYNCWARDEN_LIB_MODE=0 SYNCWARDEN_HOME="$tmp/home" SYNCWARDEN_CONFIG="$tmp/missing.conf" "$SCRIPT_PATH" 2>&1)
    rc=$?
    assert_eq '64' "$rc" 'no arguments returns usage error 64'
    assert_contains '--help' "$output" 'brief usage points to full help'
    assert_file_not_exists "$tmp/home" 'no-argument usage does not initialize the control root'
}

test_dry_run_requires_a_preceding_configured_id() {
    local tmp output rc
    tmp=$(make_temp_dir)
    output=$(run_cli_command "$tmp/home-one" --dry-run sample-server 2>&1)
    rc=$?
    assert_eq '64' "$rc" 'reversed dry-run syntax is rejected'
    assert_contains 'SERVER_ID before' "$output" 'reversed dry-run error explains required order'

    output=$(run_cli_command "$tmp/home-two" -n 2>&1)
    rc=$?
    assert_eq '64' "$rc" 'standalone -n is rejected'

    output=$(run_cli_command "$tmp/home-three" does-not-exist -n 2>&1)
    rc=$?
    assert_eq '64' "$rc" 'unknown preceding ID is rejected'
    assert_contains 'unknown server ID' "$output" 'unknown dry-run target is explicit'

    output=$(run_cli_command "$tmp/home-four" -r 2>&1)
    rc=$?
    assert_eq '64' "$rc" 'standalone -r is rejected'
    assert_contains 'only valid after' "$output" 'standalone resolved modifier explains its required check command'
}

test_short_query_aliases_match_long_forms() {
    local tmp short long mixed_one mixed_two rc
    tmp=$(make_temp_dir)
    short=$(run_cli_command "$tmp/home" -l 2>&1)
    rc=$?
    assert_eq '0' "$rc" '-l succeeds'
    long=$(run_cli_command "$tmp/home" --list 2>&1)
    assert_eq "$short" "$long" '-l and --list produce the same output'

    short=$(run_cli_command "$tmp/home" -c -r 2>&1)
    rc=$?
    assert_eq '0' "$rc" '-c -r succeeds'
    long=$(run_cli_command "$tmp/home" --check --show-resolved 2>&1)
    assert_eq "$short" "$long" 'short and long resolved checks match'
    mixed_one=$(run_cli_command "$tmp/home" -c --show-resolved 2>&1)
    mixed_two=$(run_cli_command "$tmp/home" --check -r 2>&1)
    assert_eq "$long" "$mixed_one" '-c accepts the long resolved modifier'
    assert_eq "$long" "$mixed_two" '--check accepts the short resolved modifier'

    short=$(run_cli_command "$tmp/home" -t sample-server 2>&1)
    rc=$?
    assert_eq '0' "$rc" '-t SERVER_ID succeeds'
    long=$(run_cli_command "$tmp/home" --status sample-server 2>&1)
    assert_eq "$short" "$long" '-t and --status produce the same output'
}

test_monthly_log_paths_use_reference_month() {
    local tmp
    tmp=$(make_temp_dir)
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:30:00 +0000' +%s)
    export SYNCWARDEN_NOW_EPOCH
    configure_home_paths "$tmp/home"
    assert_eq "$tmp/home/logs/success-2026-07.log" "$SUCCESS_LOG" 'success log path uses the reference month'
    assert_eq "$tmp/home/logs/failure-2026-07.log" "$FAILURE_LOG" 'failure log path uses the reference month'
    unset SYNCWARDEN_NOW_EPOCH
}

test_read_only_and_invalid_cli_paths_do_not_initialize_home() {
    local tmp output rc mode
    tmp=$(make_temp_dir)

    output=$(run_cli_command "$tmp/check-home" --check 2>&1)
    rc=$?
    assert_eq '0' "$rc" '--check succeeds for valid config'
    assert_contains 'configuration OK' "$output" '--check reports success'
    assert_file_not_exists "$tmp/check-home" '--check does not initialize the control root'

    output=$(run_cli_command "$tmp/list-home" --list 2>&1)
    rc=$?
    assert_eq '0' "$rc" '--list succeeds without runtime initialization'
    assert_file_not_exists "$tmp/list-home" '--list does not initialize the control root'

    output=$(run_cli_command "$tmp/status-home" --status sample-server 2>&1)
    rc=$?
    assert_eq '0' "$rc" '--status succeeds without runtime initialization'
    assert_file_not_exists "$tmp/status-home" '--status does not initialize the control root'

    output=$(run_cli_command "$tmp/unknown-option-home" --not-a-command 2>&1)
    rc=$?
    assert_eq '64' "$rc" 'unknown option returns usage error without runtime initialization'
    assert_file_not_exists "$tmp/unknown-option-home" 'unknown option does not initialize the control root'

    output=$(run_cli_command "$tmp/unknown-id-home" does-not-exist 2>&1)
    rc=$?
    assert_eq '64' "$rc" 'unknown ID returns usage error without runtime initialization'
    assert_file_not_exists "$tmp/unknown-id-home" 'unknown ID does not initialize the control root'

    output=$(SYNCWARDEN_LIB_MODE=0 SYNCWARDEN_HOME="$tmp/missing-config-home" SYNCWARDEN_CONFIG="$tmp/missing.conf" "$SCRIPT_PATH" --list 2>&1)
    rc=$?
    if (( rc != 0 )); then pass 'missing config fails before runtime initialization'; else fail 'missing config must fail'; fi
    assert_file_not_exists "$tmp/missing-config-home" 'missing config does not initialize the control root'

    mkdir -m 0755 "$tmp/existing-home"
    run_cli_command "$tmp/existing-home" --list >/dev/null 2>&1
    mode=$(stat -c '%a' "$tmp/existing-home")
    assert_eq '755' "$mode" 'read-only command does not chmod an existing control root'
}

test_cli_list_and_resolved_output() {
    local tmp output rc
    tmp=$(make_temp_dir)
    output=$(run_cli_command "$tmp" --list 2>&1)
    rc=$?
    assert_eq '0' "$rc" '--list succeeds'
    assert_contains 'sample-server' "$output" '--list prints first ID'
    assert_contains 'backup-node' "$output" '--list prints second ID'

    output=$(run_cli_command "$tmp" --check --show-resolved 2>&1)
    rc=$?
    assert_eq '0' "$rc" '--check --show-resolved succeeds'
    assert_contains 'destination=/tmp/syncwarden-test-sample-server' "$output" 'resolved output shows explicit destination'
    assert_contains 'port=2222' "$output" 'resolved output shows per-server override'
    assert_contains 'source=/srv/example-app' "$output" 'resolved output shows first explicit source'
    assert_contains 'source=/var/lib/example-config' "$output" 'resolved output shows second explicit source'
    assert_contains 'scheduled_sync_enabled=yes' "$output" 'resolved output names scheduled participation explicitly'
}

test_cli_no_args_and_unknown_id_are_safe() {
    local tmp output rc
    tmp=$(make_temp_dir)

    output=$(run_cli_command "$tmp" 2>&1)
    rc=$?
    if (( rc != 0 )); then
        pass 'no-argument invocation fails safely'
    else
        fail 'no-argument invocation must not run a backup'
    fi
    assert_contains '--help' "$output" 'no-argument invocation points to full help'

    output=$(run_cli_command "$tmp" does-not-exist 2>&1)
    rc=$?
    assert_eq '64' "$rc" 'unknown ID returns usage error'
    assert_contains 'unknown server ID' "$output" 'unknown ID error is explicit'
}

test_cli_status_without_state_is_readable() {
    local tmp output rc
    tmp=$(make_temp_dir)
    output=$(run_cli_command "$tmp" --status sample-server 2>&1)
    rc=$?
    assert_eq '0' "$rc" '--status succeeds without prior runs'
    assert_contains 'no recorded status' "$output" '--status explains missing state'
}

test_plain_log_block_has_separators_and_no_color() {
    local tmp log content
    tmp=$(make_temp_dir)
    log="$tmp/success.log"
    append_log_block "$log" 'RUN START' $'[OK] Sample-Server\nSUMMARY success=1'
    content=$(<"$log")
    assert_contains '================================================================================' "$content" 'log block contains major separator'
    assert_contains '--------------------------------------------------------------------------------' "$content" 'log block contains minor separator'
    assert_contains '[OK] Sample-Server' "$content" 'log block contains body'
    assert_not_contains $'\033[' "$content" 'file log contains no ANSI color'
}

test_cli_checks_private_key_file_and_permissions() {
    local tmp config key output rc
    tmp=$(make_temp_dir)
    config="$tmp/key-check.conf"
    key="$tmp/id_test"
    printf 'test private key placeholder\n' >"$key"
    chmod 0644 "$key"
    write_external_contract_config "$config" "[server:x]
host=example.com
destination=$tmp/payload
source=/srv/data"
    replace_config_value "$config" key_file "$key"

    output=$(SYNCWARDEN_LIB_MODE=0 SYNCWARDEN_HOME="$tmp/home" SYNCWARDEN_CONFIG="$config" "$SCRIPT_PATH" --check 2>&1)
    rc=$?
    if (( rc != 0 )); then pass '--check rejects a private key readable by group or others'; else fail '--check must reject unsafe private-key permissions'; fi
    assert_contains 'private key permissions' "$output" 'unsafe private-key permissions have an explicit error'

    chmod 0600 "$key"
    output=$(SYNCWARDEN_LIB_MODE=0 SYNCWARDEN_HOME="$tmp/home" SYNCWARDEN_CONFIG="$config" "$SCRIPT_PATH" --check 2>&1)
    rc=$?
    assert_eq '0' "$rc" '--check accepts an existing readable 0600 private key'
}

run_cli_suite() {
    test_help_is_concise_and_has_no_side_effects
    test_no_args_is_brief_and_has_no_side_effects
    test_dry_run_requires_a_preceding_configured_id
    test_short_query_aliases_match_long_forms
    test_read_only_and_invalid_cli_paths_do_not_initialize_home
    test_cli_list_and_resolved_output
    test_cli_no_args_and_unknown_id_are_safe
    test_cli_status_without_state_is_readable
    test_plain_log_block_has_separators_and_no_color
    test_cli_checks_private_key_file_and_permissions
    test_monthly_log_paths_use_reference_month
}

create_indexed_archive() {
    local id=$1
    local local_name=$2
    local when=$3
    local destination=$4
    local index_file="$ARCHIVE_INDEX_DIR/$id.list"
    local epoch month basename path
    epoch=$(date -d "$when" +%s)
    month=$(date -d "@$epoch" +%Y-%m)
    basename=$(archive_basename "$local_name" "$epoch")
    path="$destination/$basename"
    printf 'archive %s\n' "$when" >"$path"
    printf '%s|%s|sha-%s|%s\n' "$epoch" "$month" "$epoch" "$path" >>"$index_file"
    printf '%s\n' "$path"
}

test_archive_basename_has_second_precision() {
    local epoch actual
    epoch=$(date -d '2026-07-11 13:00:01 +0000' +%s)
    actual=$(archive_basename data "$epoch")
    assert_eq 'data-2026-07-11_13-00-01.zip' "$actual" 'archive name includes date and second'
}

test_retention_keeps_recent_and_monthly_union_only() {
    local tmp destination reference newest old_july old_june old_jan symlink_path
    local custom1 custom2 custom3 custom4 index_file
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp"
    ensure_home_layout
    load_and_validate "$FIXTURE_DIR/base.conf" || {
        fail 'retention fixture loads'
        return
    }
    destination="$tmp/payload"
    mkdir -p "$destination"
    index_file="$ARCHIVE_INDEX_DIR/sample-server.list"

    newest=$(create_indexed_archive sample-server data '2026-07-11 13:00:01 +0000' "$destination")
    create_indexed_archive sample-server data '2026-07-11 05:00:01 +0000' "$destination" >/dev/null
    create_indexed_archive sample-server data '2026-07-10 13:00:01 +0000' "$destination" >/dev/null
    create_indexed_archive sample-server data '2026-07-10 05:00:01 +0000' "$destination" >/dev/null
    create_indexed_archive sample-server data '2026-07-09 13:00:01 +0000' "$destination" >/dev/null
    create_indexed_archive sample-server data '2026-07-09 05:00:01 +0000' "$destination" >/dev/null
    create_indexed_archive sample-server data '2026-07-08 13:00:01 +0000' "$destination" >/dev/null
    old_july=$(create_indexed_archive sample-server data '2026-07-08 05:00:01 +0000' "$destination")

    create_indexed_archive sample-server data '2026-06-30 13:00:01 +0000' "$destination" >/dev/null
    old_june=$(create_indexed_archive sample-server data '2026-06-01 05:00:01 +0000' "$destination")
    create_indexed_archive sample-server data '2026-05-31 13:00:01 +0000' "$destination" >/dev/null
    create_indexed_archive sample-server data '2026-05-01 05:00:01 +0000' "$destination" >/dev/null
    create_indexed_archive sample-server data '2026-04-30 13:00:01 +0000' "$destination" >/dev/null
    create_indexed_archive sample-server data '2026-03-31 13:00:01 +0000' "$destination" >/dev/null
    create_indexed_archive sample-server data '2026-02-28 13:00:01 +0000' "$destination" >/dev/null
    old_jan=$(create_indexed_archive sample-server data '2026-01-31 13:00:01 +0000' "$destination")

    custom1="$destination/data-backup.zip"
    custom2="$destination/data-manual-2026-07-11.zip"
    custom3="$destination/data-2026-07-11-final.zip"
    custom4="$destination/data-2026-07-11_13-00-02.zip"
    printf 'manual\n' >"$custom1"
    printf 'manual\n' >"$custom2"
    printf 'manual\n' >"$custom3"
    printf 'manual exact name but not indexed\n' >"$custom4"

    symlink_path="$destination/data-2026-01-30_13-00-01.zip"
    ln -s /dev/null "$symlink_path"
    printf '%s|2026-01|sha-link|%s\n' "$(date -d '2026-01-30 13:00:01 +0000' +%s)" "$symlink_path" >>"$index_file"

    reference=$(date -d '2026-07-11 14:00:00 +0000' +%s)
    cleanup_archives sample-server data "$destination" "$newest" "$reference"

    assert_file_exists "$newest" 'newest recent archive is kept'
    assert_file_not_exists "$old_july" 'older current-month archive outside recent set is deleted'
    assert_file_not_exists "$old_june" 'non-monthly older June archive is deleted'
    assert_file_not_exists "$old_jan" 'archive outside six calendar months is deleted'
    assert_file_exists "$destination/data-2026-06-30_13-00-01.zip" 'last successful June archive is kept'
    assert_file_exists "$destination/data-2026-02-28_13-00-01.zip" 'last successful February archive is kept'
    assert_file_exists "$custom1" 'custom data-backup.zip is untouched'
    assert_file_exists "$custom2" 'custom manual backup is untouched'
    assert_file_exists "$custom3" 'custom final backup is untouched'
    assert_file_exists "$custom4" 'unindexed exact-format backup is untouched'
    assert_symlink_exists "$symlink_path" 'indexed symlink is never deleted'
}

test_cleanup_requires_new_verified_archive() {
    local tmp destination old reference
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp"
    ensure_home_layout
    load_and_validate "$FIXTURE_DIR/base.conf" || {
        fail 'cleanup guard fixture loads'
        return
    }
    destination="$tmp/payload"
    mkdir -p "$destination"
    old=$(create_indexed_archive sample-server data '2025-01-01 00:00:01 +0000' "$destination")
    reference=$(date -d '2026-07-11 14:00:00 +0000' +%s)
    cleanup_archives sample-server data "$destination" '' "$reference"
    assert_file_exists "$old" 'cleanup does not run without a newly verified archive'
}

test_cleanup_reports_delete_failure_and_preserves_index() {
    local tmp destination newest old reference rc index_content
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    load_and_validate "$FIXTURE_DIR/base.conf" || {
        fail 'cleanup failure fixture loads'
        return
    }
    destination="$tmp/payload"
    mkdir -p "$destination"
    SERVER_VALUES['sample-server:archive_recent_keep']='1'
    SERVER_VALUES['sample-server:archive_monthly_keep']='1'
    newest=$(create_indexed_archive sample-server data '2026-07-11 13:00:01 +0000' "$destination")
    old=$(create_indexed_archive sample-server data '2026-05-01 05:00:01 +0000' "$destination")
    reference=$(date -d '2026-07-11 14:00:00 +0000' +%s)
    RM_BIN="$TEST_DIR/fakes/rm"
    FAKE_RM_MODE=fail
    export FAKE_RM_MODE

    cleanup_archives sample-server data "$destination" "$newest" "$reference" >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'managed archive deletion failure is reported'; else fail 'managed archive deletion failure must not report success'; fi
    assert_file_exists "$old" 'archive that could not be deleted remains on disk'
    index_content=$(<"$ARCHIVE_INDEX_DIR/sample-server.list")
    assert_contains "$old" "$index_content" 'archive that could not be deleted remains indexed'
    unset FAKE_RM_MODE
    RM_BIN=$(command -v rm)
}

test_cleanup_sort_failure_deletes_nothing() {
    local tmp destination newest old reference rc before after
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    load_and_validate "$FIXTURE_DIR/base.conf" || {
        fail 'sort-failure retention fixture loads'
        return
    }
    destination="$tmp/payload"
    mkdir -p "$destination"
    SERVER_VALUES['sample-server:archive_recent_keep']='1'
    SERVER_VALUES['sample-server:archive_monthly_keep']='1'
    newest=$(create_indexed_archive sample-server data '2026-07-11 13:00:01 +0000' "$destination")
    old=$(create_indexed_archive sample-server data '2026-01-01 05:00:01 +0000' "$destination")
    before=$(<"$ARCHIVE_INDEX_DIR/sample-server.list")
    reference=$(date -d '2026-07-11 14:00:00 +0000' +%s)

    ( SORT_BIN=false; cleanup_archives sample-server data "$destination" "$newest" "$reference" ) >/dev/null 2>&1
    rc=$?
    after=$(<"$ARCHIVE_INDEX_DIR/sample-server.list")
    if (( rc != 0 )); then pass 'sort failure aborts archive cleanup'; else fail 'sort failure must abort archive cleanup'; fi
    assert_file_exists "$newest" 'sort failure preserves newest archive'
    assert_file_exists "$old" 'sort failure preserves old archive'
    assert_eq "$before" "$after" 'sort failure preserves the original index'
}

test_cleanup_malformed_index_deletes_nothing() {
    local tmp destination newest old reference rc before after
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    load_and_validate "$FIXTURE_DIR/base.conf" || {
        fail 'malformed-index retention fixture loads'
        return
    }
    destination="$tmp/payload"
    mkdir -p "$destination"
    SERVER_VALUES['sample-server:archive_recent_keep']='1'
    SERVER_VALUES['sample-server:archive_monthly_keep']='1'
    newest=$(create_indexed_archive sample-server data '2026-07-11 13:00:01 +0000' "$destination")
    old=$(create_indexed_archive sample-server data '2026-01-01 05:00:01 +0000' "$destination")
    printf 'bogus|2026-01|sha-bogus|%s\n' "$old" >>"$ARCHIVE_INDEX_DIR/sample-server.list"
    before=$(<"$ARCHIVE_INDEX_DIR/sample-server.list")
    reference=$(date -d '2026-07-11 14:00:00 +0000' +%s)

    cleanup_archives sample-server data "$destination" "$newest" "$reference" >/dev/null 2>&1
    rc=$?
    after=$(<"$ARCHIVE_INDEX_DIR/sample-server.list")
    if (( rc != 0 )); then pass 'malformed index aborts archive cleanup'; else fail 'malformed index must abort archive cleanup'; fi
    assert_file_exists "$newest" 'malformed index preserves newest archive'
    assert_file_exists "$old" 'malformed index preserves old archive'
    assert_eq "$before" "$after" 'malformed index preserves the original index'
}

test_duplicate_index_path_counts_once() {
    local tmp destination newest second reference newest_line
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    load_and_validate "$FIXTURE_DIR/base.conf" || {
        fail 'duplicate-index retention fixture loads'
        return
    }
    destination="$tmp/payload"
    mkdir -p "$destination"
    SERVER_VALUES['sample-server:archive_recent_keep']='2'
    SERVER_VALUES['sample-server:archive_monthly_keep']='1'
    newest=$(create_indexed_archive sample-server data '2026-07-11 13:00:01 +0000' "$destination")
    second=$(create_indexed_archive sample-server data '2026-07-11 12:00:01 +0000' "$destination")
    newest_line=$(sed -n '1p' "$ARCHIVE_INDEX_DIR/sample-server.list")
    printf '%s\n' "$newest_line" >>"$ARCHIVE_INDEX_DIR/sample-server.list"
    reference=$(date -d '2026-07-11 14:00:00 +0000' +%s)

    cleanup_archives sample-server data "$destination" "$newest" "$reference" >/dev/null 2>&1
    assert_file_exists "$second" 'duplicate newest path consumes only one recent slot'
}

run_retention_suite() {
    test_archive_basename_has_second_precision
    test_retention_keeps_recent_and_monthly_union_only
    test_cleanup_requires_new_verified_archive
    test_cleanup_reports_delete_failure_and_preserves_index
    test_cleanup_sort_failure_deletes_nothing
    test_cleanup_malformed_index_deletes_nothing
    test_duplicate_index_path_counts_once
}

prepare_archive_test() {
    local home=$1
    local destination=$2
    configure_home_paths "$home"
    ensure_home_layout
    load_and_validate "$FIXTURE_DIR/base.conf"
    SERVER_VALUES['sample-server:destination']=$destination
    SERVER_VALUES['sample-server:min_free_space_mb']='1'
    SERVER_VALUES['sample-server:min_free_inodes']='1'
    ZIP_BIN="$TEST_DIR/fakes/zip"
    SHA256_BIN=$(command -v sha256sum)
    DF_BIN=$(command -v df)
    RM_BIN=$(command -v rm)
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-11 13:00:01 +0000' +%s)
    export SYNCWARDEN_NOW_EPOCH
}

test_archive_skips_missing_local_mirror() {
    local tmp destination deadline rc
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_archive_test "$tmp/home" "$destination" || {
        fail 'archive fixture loads for missing mirror test'
        return
    }
    deadline=$(( $(date +%s) + 300 ))
    archive_source sample-server '/srv/data' "$deadline"
    rc=$?
    assert_eq '0' "$rc" 'missing first-sync mirror is a safe archive skip'
    assert_eq 'SKIPPED_NO_MIRROR' "${LAST_ARCHIVE_STATUS-}" 'archive skip reason is explicit'
    assert_file_not_exists "$ARCHIVE_INDEX_DIR/sample-server.list" 'missing mirror creates no archive index'
}

test_archive_success_is_verified_indexed_and_atomic() {
    local tmp destination deadline rc final index_content
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination/data"
    printf 'payload\n' >"$destination/data/file.txt"
    prepare_archive_test "$tmp/home" "$destination" || {
        fail 'archive success fixture loads'
        return
    }
    FAKE_ZIP_MODE=success
    export FAKE_ZIP_MODE
    deadline=$(( $(date +%s) + 300 ))
    archive_source sample-server '/srv/data' "$deadline"
    rc=$?
    final="$destination/data-2026-07-11_13-00-01.zip"
    assert_eq '0' "$rc" 'successful archive returns zero'
    assert_file_exists "$final" 'verified archive is atomically promoted to final name'
    assert_file_not_exists "$destination/.data-2026-07-11_13-00-01.part.zip" 'temporary archive is removed after success'
    index_content=$(<"$ARCHIVE_INDEX_DIR/sample-server.list")
    assert_contains "$final" "$index_content" 'successful archive is recorded in managed index'
    assert_eq 'SUCCESS' "${LAST_ARCHIVE_STATUS-}" 'archive success status is exposed'
    assert_eq "$final" "${LAST_ARCHIVE_PATH-}" 'archive final path is exposed'
}

test_archive_creation_failure_leaves_no_artifact_or_index() {
    local tmp destination deadline rc
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination/data"
    printf 'payload\n' >"$destination/data/file.txt"
    prepare_archive_test "$tmp/home" "$destination" || {
        fail 'archive creation failure fixture loads'
        return
    }
    FAKE_ZIP_MODE=create-fail
    export FAKE_ZIP_MODE
    deadline=$(( $(date +%s) + 300 ))
    archive_source sample-server '/srv/data' "$deadline" >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then
        pass 'archive creation failure returns non-zero'
    else
        fail 'archive creation failure must return non-zero'
    fi
    assert_file_not_exists "$destination/data-2026-07-11_13-00-01.zip" 'failed creation has no final archive'
    assert_file_not_exists "$destination/.data-2026-07-11_13-00-01.part.zip" 'failed creation cleans temporary archive'
    assert_file_not_exists "$ARCHIVE_INDEX_DIR/sample-server.list" 'failed creation is not indexed'
}

test_archive_verification_failure_leaves_no_artifact_or_index() {
    local tmp destination deadline rc
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination/data"
    printf 'payload\n' >"$destination/data/file.txt"
    prepare_archive_test "$tmp/home" "$destination" || {
        fail 'archive verification failure fixture loads'
        return
    }
    FAKE_ZIP_MODE=verify-fail
    export FAKE_ZIP_MODE
    deadline=$(( $(date +%s) + 300 ))
    archive_source sample-server '/srv/data' "$deadline" >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then
        pass 'archive verification failure returns non-zero'
    else
        fail 'archive verification failure must return non-zero'
    fi
    assert_file_not_exists "$destination/data-2026-07-11_13-00-01.zip" 'verification failure has no final archive'
    assert_file_not_exists "$destination/.data-2026-07-11_13-00-01.part.zip" 'verification failure cleans temporary archive'
    assert_file_not_exists "$ARCHIVE_INDEX_DIR/sample-server.list" 'verification failure is not indexed'
}

test_archive_same_second_collision_never_overwrites() {
    local tmp destination deadline existing new_path
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination/data"
    printf 'payload\n' >"$destination/data/file.txt"
    existing="$destination/data-2026-07-11_13-00-01.zip"
    printf 'manual existing archive\n' >"$existing"
    prepare_archive_test "$tmp/home" "$destination" || {
        fail 'archive collision fixture loads'
        return
    }
    FAKE_ZIP_MODE=success
    export FAKE_ZIP_MODE
    deadline=$(( $(date +%s) + 300 ))
    archive_source sample-server '/srv/data' "$deadline"
    new_path="$destination/data-2026-07-11_13-00-02.zip"
    assert_contains 'manual existing archive' "$(<"$existing")" 'existing same-second file is not overwritten'
    assert_file_exists "$new_path" 'collision advances to a unique second'
}

test_archive_promotion_collision_never_overwrites() {
    local tmp destination deadline first_path second_path index_content
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination/data"
    printf 'payload\n' >"$destination/data/file.txt"
    prepare_archive_test "$tmp/home" "$destination" || {
        fail 'archive promotion collision fixture loads'
        return
    }
    first_path="$destination/data-2026-07-11_13-00-01.zip"
    second_path="$destination/data-2026-07-11_13-00-02.zip"
    FAKE_ZIP_MODE=success
    FAKE_ZIP_COLLISION_PATH=$first_path
    FAKE_ZIP_COLLISION_CONTENT='manual collision'
    export FAKE_ZIP_MODE FAKE_ZIP_COLLISION_PATH FAKE_ZIP_COLLISION_CONTENT
    deadline=$(( $(date +%s) + 300 ))

    archive_source sample-server '/srv/data' "$deadline" >/dev/null 2>&1
    assert_eq 'manual collision' "$(<"$first_path")" 'promotion never overwrites a raced final file'
    assert_file_exists "$second_path" 'verified ZIP is promoted under the next timestamp'
    index_content=$(<"$ARCHIVE_INDEX_DIR/sample-server.list")
    assert_contains "$second_path" "$index_content" 'only the no-clobber promoted path is indexed'
    assert_not_contains "$first_path" "$index_content" 'raced manual path is not indexed'
    assert_eq "$second_path" "${LAST_ARCHIVE_PATH-}" 'reported archive path matches no-clobber promotion'
    unset FAKE_ZIP_COLLISION_PATH FAKE_ZIP_COLLISION_CONTENT
}

test_real_zip_stores_symlink_without_following_target() {
    local tmp destination deadline final listing real_zip fake_zip
    real_zip=$(command -v zip 2>/dev/null || true)
    fake_zip=$(readlink -f -- "$TEST_DIR/fakes/zip")
    if [[ -z "$real_zip" || "$(readlink -f -- "$real_zip")" == "$fake_zip" ]]; then
        skip 'real Info-ZIP zip is unavailable; symlink behavior requires release verification'
        return
    fi
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination/data" "$tmp/outside"
    printf 'must not enter archive\n' >"$tmp/outside/secret.txt"
    ln -s "$tmp/outside" "$destination/data/outside-link"
    prepare_archive_test "$tmp/home" "$destination" || {
        fail 'real zip symlink fixture loads'
        return
    }
    ZIP_BIN=$real_zip
    SERVER_VALUES['sample-server:owner']='backup:backup'
    deadline=$(( $(date +%s) + 300 ))
    archive_source sample-server '/srv/data' "$deadline" >/dev/null 2>&1
    final="$destination/data-2026-07-11_13-00-01.zip"
    listing=$("$real_zip" -sf "$final" 2>&1)
    assert_contains 'data/outside-link' "$listing" 'real ZIP stores the mirror symlink entry'
    assert_not_contains 'data/outside-link/secret.txt' "$listing" 'real ZIP does not follow a mirror symlink outside the mirror'
}

test_archive_refuses_low_free_space_before_zip() {
    local tmp destination deadline rc
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination/data"
    printf 'payload\n' >"$destination/data/file.txt"
    prepare_archive_test "$tmp/home" "$destination" || {
        fail 'archive capacity fixture loads'
        return
    }
    SERVER_VALUES['sample-server:min_free_space_mb']='2048'
    DF_BIN="$TEST_DIR/fakes/df"
    FAKE_DF_AVAILABLE_MB=100
    FAKE_DF_AVAILABLE_INODES=50000
    FAKE_ZIP_ARGS_FILE="$tmp/zip-args"
    export FAKE_DF_AVAILABLE_MB FAKE_DF_AVAILABLE_INODES FAKE_ZIP_ARGS_FILE
    deadline=$(( $(date +%s) + 300 ))
    archive_source sample-server '/srv/data' "$deadline" >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'archive refuses insufficient free space'; else fail 'archive must not run below free-space threshold'; fi
    assert_eq 'FAILED_LOW_FREE_SPACE' "${LAST_ARCHIVE_STATUS-}" 'archive capacity failure is classified explicitly'
    assert_file_not_exists "$FAKE_ZIP_ARGS_FILE" 'ZIP is not invoked when free space is below threshold'
    unset FAKE_DF_AVAILABLE_MB FAKE_DF_AVAILABLE_INODES FAKE_ZIP_ARGS_FILE
    DF_BIN=$(command -v df)
}

test_unified_temp_registry_removes_all_registered_files() {
    local tmp part diagnostic index_temp final path
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    part="$tmp/.data-2026-07-11_13-00-01.part.zip"
    diagnostic="$TMP_DIR/rsync-attempt.test"
    index_temp="$ARCHIVE_INDEX_DIR/.test.list.tmp"
    final="$tmp/data-2026-07-11_13-00-01.zip"
    printf 'partial archive\n' >"$part"
    printf 'diagnostic\n' >"$diagnostic"
    printf 'index\n' >"$index_temp"
    printf 'verified archive\n' >"$final"
    ACTIVE_TEMP_FILES=()
    if ! declare -F register_temp_file >/dev/null; then
        fail 'unified temporary-file registry exists'
        return
    fi
    for path in "$part" "$diagnostic" "$index_temp"; do
        register_temp_file "$path"
    done
    cleanup_active_temp_files
    assert_file_not_exists "$part" 'registered partial ZIP is removed by exit cleanup'
    assert_file_not_exists "$diagnostic" 'registered rsync diagnostic is removed by exit cleanup'
    assert_file_not_exists "$index_temp" 'registered index temporary file is removed by exit cleanup'
    assert_file_exists "$final" 'unregistered promoted archive is preserved by exit cleanup'
    assert_eq '0' "${#ACTIVE_TEMP_FILES[@]}" 'unified temporary-file registry is emptied after cleanup'
}

test_failure_body_consumes_registered_output_in_parent_shell() {
    local tmp diagnostic body
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    load_config "$FIXTURE_DIR/base.conf" || {
        fail 'failure-body temporary-file fixture loads'
        return
    }
    ACTIVE_TEMP_FILES=()
    make_temp_file diagnostic "$TMP_DIR/failure-output.XXXXXX" || {
        fail 'failure-body temporary output is created'
        return
    }
    printf 'diagnostic\n' >"$diagnostic"

    build_failure_body sample-server MANUAL RSYNC RSYNC_FAILED 1 1 "$diagnostic" data
    body=${FAILURE_BODY_RESULT-}

    assert_contains 'diagnostic' "$body" 'failure body retains command diagnostics'
    assert_file_not_exists "$diagnostic" 'failure body removes consumed command output'
    assert_eq '0' "${#ACTIVE_TEMP_FILES[@]}" 'failure body unregisters consumed output in the parent shell'
}

test_archive_checksum_has_an_independent_command_timeout() {
    local tmp destination started elapsed rc original_timeout
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination/data"
    printf 'payload\n' >"$destination/data/file.txt"
    prepare_archive_test "$tmp/home" "$destination" || {
        fail 'archive checksum deadline fixture loads'
        return
    }
    FAKE_ZIP_MODE=success
    SHA256_BIN="$TEST_DIR/fakes/sha256sum"
    FAKE_SHA256_MODE=ignore-term
    FAKE_SHA256_SLEEP_SECONDS=5
    export FAKE_ZIP_MODE FAKE_SHA256_MODE FAKE_SHA256_SLEEP_SECONDS
    original_timeout=$ARCHIVE_CHECKSUM_TIMEOUT_SECONDS
    ARCHIVE_CHECKSUM_TIMEOUT_SECONDS=1
    started=$(date +%s)
    archive_source sample-server '/srv/data' >/dev/null 2>&1
    rc=$?
    elapsed=$(( $(date +%s) - started ))
    ARCHIVE_CHECKSUM_TIMEOUT_SECONDS=$original_timeout
    if (( rc != 0 )); then pass 'archive checksum is stopped by its command timeout'; else fail 'checksum past its command timeout must fail the archive'; fi
    assert_eq 'FAILED_TIMEOUT' "${LAST_ARCHIVE_STATUS-}" 'checksum command timeout is classified explicitly'
    if (( elapsed < 4 )); then pass 'checksum command timeout stops a stalled checksum'; else fail "checksum command timeout was exceeded (${elapsed}s)"; fi
}

run_archive_suite() {
    test_archive_skips_missing_local_mirror
    test_archive_success_is_verified_indexed_and_atomic
    test_archive_creation_failure_leaves_no_artifact_or_index
    test_archive_verification_failure_leaves_no_artifact_or_index
    test_archive_same_second_collision_never_overwrites
    test_archive_promotion_collision_never_overwrites
    test_real_zip_stores_symlink_without_following_target
    test_archive_refuses_low_free_space_before_zip
    test_unified_temp_registry_removes_all_registered_files
    test_failure_body_consumes_registered_output_in_parent_shell
    test_archive_checksum_has_an_independent_command_timeout
}

prepare_transport_test() {
    local home=$1
    local destination=$2
    configure_home_paths "$home"
    ensure_home_layout
    load_and_validate "$FIXTURE_DIR/base.conf"
    SERVER_VALUES['sample-server:destination']=$destination
    SERVER_VALUES['sample-server:retry_delays_seconds']='0,0'
    SERVER_VALUES['sample-server:min_free_space_mb']='1'
    SERVER_VALUES['sample-server:min_free_inodes']='1'
    SSH_BIN="$TEST_DIR/fakes/ssh"
    RSYNC_BIN="$TEST_DIR/fakes/rsync"
    DF_BIN=$(command -v df)
}

test_preflight_host_key_and_auth_do_not_retry() {
    local tmp destination deadline rc state
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport fixture loads for permanent SSH errors'
        return
    }
    deadline=$(( $(date +%s) + 30 ))

    state="$tmp/host-key-attempts"
    FAKE_SSH_MODE=host-key FAKE_SSH_STATE_FILE="$state" preflight_server sample-server "$deadline" >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'host-key error fails preflight'; else fail 'host-key error must fail preflight'; fi
    assert_eq 'HOST_KEY_CHANGED' "${LAST_FAILURE_REASON-}" 'host-key error is classified explicitly'
    assert_eq '1' "$(<"$state")" 'host-key error is not retried'

    state="$tmp/auth-attempts"
    FAKE_SSH_MODE=auth FAKE_SSH_STATE_FILE="$state" preflight_server sample-server "$deadline" >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'authentication error fails preflight'; else fail 'authentication error must fail preflight'; fi
    assert_eq 'AUTH_FAILED' "${LAST_FAILURE_REASON-}" 'authentication error is classified explicitly'
    assert_eq '1' "$(<"$state")" 'authentication error is not retried'
}

test_preflight_transient_network_retries_and_missing_source_does_not() {
    local tmp destination deadline rc state
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport fixture loads for retry test'
        return
    }
    deadline=$(( $(date +%s) + 30 ))

    state="$tmp/network-attempts"
    FAKE_SSH_MODE=network-once FAKE_SSH_STATE_FILE="$state" preflight_server sample-server "$deadline"
    rc=$?
    assert_eq '0' "$rc" 'transient SSH error succeeds after retry'
    assert_eq '2' "$(<"$state")" 'transient SSH error is retried once'

    state="$tmp/missing-attempts"
    FAKE_SSH_MODE=missing FAKE_SSH_STATE_FILE="$state" preflight_server sample-server "$deadline" >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'missing remote source fails preflight'; else fail 'missing remote source must fail preflight'; fi
    assert_eq 'REMOTE_SOURCE_MISSING' "${LAST_FAILURE_REASON-}" 'missing source is classified explicitly'
    assert_eq '1' "$(<"$state")" 'missing source is not retried'
}

test_preflight_quotes_remote_path_and_diagnostic_as_data() {
    local tmp destination deadline rc marker remote
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport fixture loads for remote quoting test'
        return
    }
    marker="$tmp/injected"
    remote="/missing'; touch $marker; : '/srv/data"
    SERVER_SOURCES['sample-server:0']="$remote"
    SERVER_SOURCE_COUNT['sample-server']=1
    SERVER_VALUES['sample-server:retry_count']='0'
    deadline=$(( $(date +%s) + 30 ))

    FAKE_SSH_MODE=execute-command preflight_server sample-server "$deadline" >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'quoted missing remote path fails preflight'; else fail 'missing remote path must fail preflight'; fi
    assert_eq 'REMOTE_SOURCE_MISSING' "${LAST_FAILURE_REASON-}" 'quoted missing path retains its failure classification'
    assert_file_not_exists "$marker" 'remote path text cannot inject a shell command'
}

test_preflight_uses_posix_test_syntax_for_existing_path() {
    local tmp destination deadline rc remote
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    remote="$tmp/existing-remote"
    mkdir -p "$destination" "$remote"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport fixture loads for POSIX test syntax'
        return
    }
    SERVER_SOURCES['sample-server:0']="$remote"
    SERVER_SOURCE_COUNT['sample-server']=1
    SERVER_VALUES['sample-server:retry_count']='0'
    deadline=$(( $(date +%s) + 30 ))

    FAKE_SSH_MODE=execute-command preflight_server sample-server "$deadline" >/dev/null 2>&1
    rc=$?
    assert_eq '0' "$rc" 'preflight accepts an existing directory under a POSIX /bin/sh'
}

test_sync_command_preserves_mirror_semantics() {
    local tmp destination deadline rc args
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport fixture loads for rsync command test'
        return
    }
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/rsync-args"
    export FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE
    deadline=$(( $(date +%s) + 30 ))
    sync_source sample-server '/srv/data' "$deadline" 0
    rc=$?
    args=$(<"$FAKE_RSYNC_ARGS_FILE")
    assert_eq '0' "$rc" 'successful rsync returns zero'
    assert_contains '--delete' "$args" 'rsync command keeps delete semantics'
    assert_contains '--delete-delay' "$args" 'rsync command delays deletion'
    assert_contains '--timeout=300' "$args" 'rsync command uses configured I/O timeout'
    assert_contains '--out-format=__SYNCWARDEN_CHANGE__:%i|%b' "$args" 'rsync command emits machine-readable change and byte statistics'
    assert_contains 'backup@source.example.net:/srv/data/' "$args" 'rsync command uses remote directory contents'
    assert_contains "$destination/data/" "$args" 'rsync command uses configured local name'
    assert_not_contains '--ignore-errors' "$args" 'rsync command never ignores I/O errors'
    assert_not_contains '--log-file' "$args" 'rsync command never writes itemized rsync log'
}

test_sync_refuses_low_free_inodes_before_rsync() {
    local tmp destination deadline rc
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport capacity fixture loads'
        return
    }
    SERVER_VALUES['sample-server:min_free_inodes']='10000'
    DF_BIN="$TEST_DIR/fakes/df"
    FAKE_DF_AVAILABLE_MB=50000
    FAKE_DF_AVAILABLE_INODES=100
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/rsync-args"
    export FAKE_DF_AVAILABLE_MB FAKE_DF_AVAILABLE_INODES FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE
    deadline=$(( $(date +%s) + 30 ))

    sync_source sample-server '/srv/data' "$deadline" 0 >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'rsync refuses insufficient free inodes'; else fail 'rsync must not run below inode threshold'; fi
    assert_eq 'LOW_FREE_INODES' "${LAST_FAILURE_REASON-}" 'rsync inode failure is classified explicitly'
    assert_file_not_exists "$FAKE_RSYNC_ARGS_FILE" 'rsync is not invoked when free inodes are below threshold'
    unset FAKE_DF_AVAILABLE_MB FAKE_DF_AVAILABLE_INODES
    DF_BIN=$(command -v df)
}

test_capacity_check_has_a_finite_safety_timeout() {
    local tmp destination rc started elapsed
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'capacity timeout fixture loads'
        return
    }
    local original_timeout=$CAPACITY_CHECK_TIMEOUT_SECONDS
    CAPACITY_CHECK_TIMEOUT_SECONDS=1
    DF_BIN="$TEST_DIR/fakes/df"
    FAKE_DF_MODE=ignore-term
    FAKE_DF_SLEEP_SECONDS=5
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/rsync-args"
    export FAKE_DF_MODE FAKE_DF_SLEEP_SECONDS FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE

    started=$(date +%s)
    sync_source sample-server '/srv/data' 0 0 >/dev/null 2>&1
    rc=$?
    elapsed=$(( $(date +%s) - started ))
    CAPACITY_CHECK_TIMEOUT_SECONDS=$original_timeout
    if (( rc != 0 )); then pass 'capacity check timeout fails the sync stage'; else fail 'timed-out capacity check must fail'; fi
    assert_eq 'CAPACITY_CHECK_TIMEOUT' "${LAST_FAILURE_REASON-}" 'capacity timeout is classified explicitly'
    if (( elapsed < 4 )); then pass 'capacity check cannot block the script indefinitely'; else fail "capacity timeout took too long (${elapsed}s)"; fi
    assert_file_not_exists "$FAKE_RSYNC_ARGS_FILE" 'rsync is not invoked after capacity timeout'
    unset FAKE_DF_MODE FAKE_DF_SLEEP_SECONDS
    DF_BIN=$(command -v df)
}

test_sync_dry_run_and_code24_classification() {
    local tmp destination deadline rc args output
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport fixture loads for dry-run test'
        return
    }
    deadline=$(( $(date +%s) + 30 ))

    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_OUTPUT='>f+++++++++ proposed.txt'
    FAKE_RSYNC_ARGS_FILE="$tmp/dry-args"
    export FAKE_RSYNC_MODE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE
    output=$(sync_source sample-server '/srv/data' "$deadline" 1)
    rc=$?
    args=$(<"$FAKE_RSYNC_ARGS_FILE")
    assert_eq '0' "$rc" 'rsync dry-run returns zero'
    assert_contains '--dry-run' "$args" 'dry-run flag reaches rsync'
    assert_contains '--itemize-changes' "$args" 'dry-run exposes proposed changes'
    assert_contains '>f+++++++++ proposed.txt' "$output" 'dry-run prints itemized changes to the user'
    assert_dir_exists "$destination" 'dry-run keeps existing destination root'
    assert_file_not_exists "$ARCHIVE_INDEX_DIR/sample-server.list" 'dry-run writes no archive state'

    FAKE_RSYNC_MODE=vanished
    FAKE_RSYNC_ARGS_FILE="$tmp/vanished-args"
    export FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE
    sync_source sample-server '/srv/data' "$deadline" 0 >/dev/null 2>&1
    rc=$?
    assert_eq '0' "$rc" 'rsync code 24 is accepted as live-mirror success'
    assert_eq 'SUCCESS' "${LAST_SYNC_STATUS-}" 'accepted code 24 exposes successful sync status'
    assert_eq 'FILES_VANISHED' "${LAST_FAILURE_REASON-}" 'code 24 classification is explicit'
    assert_eq '24' "${LAST_EXIT_CODE-}" 'accepted code 24 retains the native rsync exit code internally'
    assert_eq 'yes' "${LAST_CHANGE_COMPLETE-}" 'accepted code 24 marks the accepted sync complete'
    unset FAKE_RSYNC_OUTPUT
}

test_sync_native_io_timeout_is_explicit_and_not_retried() {
    local tmp destination rc state args
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport fixture loads for native rsync timeout test'
        return
    }

    state="$tmp/io-timeout-attempts"
    FAKE_RSYNC_MODE=io-timeout
    FAKE_RSYNC_STATE_FILE="$state"
    FAKE_RSYNC_ARGS_FILE="$tmp/io-timeout-args"
    export FAKE_RSYNC_MODE FAKE_RSYNC_STATE_FILE FAKE_RSYNC_ARGS_FILE
    sync_source sample-server '/srv/data' 0 0 >/dev/null 2>&1
    rc=$?
    args=$(<"$FAKE_RSYNC_ARGS_FILE")

    assert_eq '1' "$rc" 'native rsync I/O timeout fails the current source'
    assert_eq 'RSYNC_IO_TIMEOUT' "${LAST_FAILURE_REASON-}" 'rsync exit 30 has an explicit reason'
    assert_eq '30' "${LAST_EXIT_CODE-}" 'native rsync timeout preserves exit code 30'
    assert_eq '1' "$(<"$state")" 'native rsync I/O timeout is not retried'
    assert_contains '--timeout=300' "$args" 'configured rsync no-I/O timeout reaches rsync'
}

test_sync_transient_retry_and_permanent_failure() {
    local tmp destination deadline rc state started elapsed
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport fixture loads for rsync failure test'
        return
    }

    state="$tmp/rsync-attempts"
    FAKE_RSYNC_MODE=network-once
    FAKE_RSYNC_STATE_FILE="$state"
    FAKE_RSYNC_ARGS_FILE="$tmp/network-args"
    export FAKE_RSYNC_MODE FAKE_RSYNC_STATE_FILE FAKE_RSYNC_ARGS_FILE
    deadline=$(( $(date +%s) + 30 ))
    sync_source sample-server '/srv/data' "$deadline" 0
    rc=$?
    assert_eq '0' "$rc" 'transient rsync error succeeds after retry'
    assert_eq '2' "$(<"$state")" 'transient rsync error is retried once'

    state="$tmp/fail23-attempts"
    FAKE_RSYNC_MODE=fail23
    FAKE_RSYNC_STATE_FILE="$state"
    FAKE_RSYNC_ARGS_FILE="$tmp/fail23-args"
    export FAKE_RSYNC_MODE FAKE_RSYNC_STATE_FILE FAKE_RSYNC_ARGS_FILE
    sync_source sample-server '/srv/data' "$deadline" 0 >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'rsync code 23 fails'; else fail 'rsync code 23 must fail'; fi
    assert_eq 'RSYNC_FAILED' "${LAST_FAILURE_REASON-}" 'rsync code 23 is a permanent failure'
    assert_eq '1' "$(<"$state")" 'rsync code 23 is not blindly retried'

    FAKE_RSYNC_MODE=sleep
    FAKE_RSYNC_SLEEP_SECONDS=2
    FAKE_RSYNC_STATE_FILE="$tmp/progress-attempts"
    FAKE_RSYNC_ARGS_FILE="$tmp/progress-args"
    export FAKE_RSYNC_MODE FAKE_RSYNC_SLEEP_SECONDS FAKE_RSYNC_STATE_FILE FAKE_RSYNC_ARGS_FILE
    SERVER_VALUES['sample-server:retry_count']='0'
    deadline=0
    started=$(date +%s)
    sync_source sample-server '/srv/data' "$deadline" 0 >/dev/null 2>&1
    rc=$?
    elapsed=$(( $(date +%s) - started ))
    assert_eq '0' "$rc" 'rsync may rely on its native I/O timeout without a cumulative wall deadline'
    if (( elapsed >= 2 )); then pass 'progressing rsync is not killed by the former server deadline'; else fail 'progressing rsync ended before the fake transfer completed'; fi

}

test_rsync_attempt_parser_classifies_and_filters_rows() {
    local tmp input diagnostic rc
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    input="$tmp/attempt.out"
    diagnostic="$tmp/diagnostic.out"
    write_file "$input" $'__SYNCWARDEN_CHANGE__:>f+++++++++|1024\n__SYNCWARDEN_CHANGE__:>f.st......|2048\n__SYNCWARDEN_CHANGE__:*deleting  |0\nrsync: connection unexpectedly closed'
    : >"$diagnostic"
    reset_last_change_stats
    consume_rsync_attempt_output "$input" "$diagnostic" 1
    rc=$?
    assert_eq '0' "$rc" 'well-formed itemized rows parse successfully'
    assert_eq '3' "$LAST_CHANGE_COUNT" 'all managed rows count as changes'
    assert_eq '1' "$LAST_CHANGE_CREATED" 'new item is classified as created'
    assert_eq '1' "$LAST_CHANGE_UPDATED" 'existing item is classified as updated'
    assert_eq '1' "$LAST_CHANGE_DELETED" 'deletion is classified as deleted'
    assert_eq '3072' "$LAST_TRANSFER_BYTES" 'actual transferred bytes are accumulated'
    assert_eq '1' "$LAST_CHANGE_ATTEMPTS" 'attempt number is retained'
    assert_not_contains '__SYNCWARDEN_CHANGE__' "$(<"$diagnostic")" 'managed rows are filtered from diagnostics'
    assert_contains 'connection unexpectedly closed' "$(<"$diagnostic")" 'real diagnostic text is retained'
}

test_transfer_metrics_format_readable_units() {
    assert_eq '0B' "$(format_bytes_iec 0)" 'zero-byte transfer has a compact readable unit'
    assert_eq '1.50KiB' "$(format_bytes_iec 1536)" 'transfer size uses readable IEC units'
    assert_eq '2.00KiB/s' "$(format_average_speed 4096 2000000)" 'average speed uses readable IEC units per second'
}

test_rsync_retry_keeps_change_counts_and_resets_transfer_metrics() {
    local tmp destination deadline rc state
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'transport fixture loads for retry statistics'
        return
    }
    state="$tmp/attempt-state"
    FAKE_RSYNC_MODE=network-once
    FAKE_RSYNC_STATE_FILE="$state"
    FAKE_RSYNC_OUTPUT_1=$'__SYNCWARDEN_CHANGE__:>f+++++++++|1024\n__SYNCWARDEN_CHANGE__:*deleting  |0'
    FAKE_RSYNC_OUTPUT_2='__SYNCWARDEN_CHANGE__:>f.st......|2048'
    FAKE_RSYNC_ARGS_FILE="$tmp/args"
    export FAKE_RSYNC_MODE FAKE_RSYNC_STATE_FILE FAKE_RSYNC_OUTPUT_1 FAKE_RSYNC_OUTPUT_2 FAKE_RSYNC_ARGS_FILE
    deadline=$(( $(date +%s) + 30 ))
    sync_source sample-server '/srv/data' "$deadline" 0 >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'retrying transfer succeeds'
    assert_eq '3' "$LAST_CHANGE_COUNT" 'statistics include both attempts'
    assert_eq '2048' "$LAST_TRANSFER_BYTES" 'retry resets transfer bytes to the final rsync attempt'
    if (( LAST_TRANSFER_DURATION_US > 0 )); then pass 'transfer duration covers the final rsync attempt'; else fail 'transfer duration must be positive'; fi
    assert_eq '2' "$LAST_CHANGE_ATTEMPTS" 'statistics expose two attempts'
    assert_eq 'yes' "$LAST_CHANGE_COMPLETE" 'successful final attempt marks aggregate complete'
    unset FAKE_RSYNC_OUTPUT_1 FAKE_RSYNC_OUTPUT_2 FAKE_RSYNC_STATE_FILE
}

test_malformed_managed_row_marks_statistics_unavailable() {
    local tmp input diagnostic rc
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    input="$tmp/malformed.out"
    diagnostic="$tmp/diagnostic.out"
    write_file "$input" '__SYNCWARDEN_CHANGE__:bad'
    : >"$diagnostic"
    reset_last_change_stats
    consume_rsync_attempt_output "$input" "$diagnostic" 1
    rc=$?
    if (( rc != 0 )); then pass 'malformed managed row fails parsing'; else fail 'malformed managed row must fail parsing'; fi
    assert_eq '1' "$LAST_CHANGE_PARSE_FAILED" 'parse failure is retained explicitly'
    assert_not_contains '__SYNCWARDEN_CHANGE__' "$(<"$diagnostic")" 'malformed managed row still cannot flood diagnostics'
}

test_real_rsync_out_format_matches_parser_contract() {
    local tmp source destination output diagnostic rc real_rsync
    tmp=$(make_temp_dir)
    source="$tmp/source"
    destination="$tmp/destination"
    mkdir -p "$source" "$destination"
    printf 'new\n' >"$source/created.txt"
    printf 'new-content\n' >"$source/updated.txt"
    printf 'old-content\n' >"$destination/updated.txt"
    printf 'delete\n' >"$destination/deleted.txt"
    touch -d '2026-07-12 08:00:00 +0000' "$destination/updated.txt"
    touch -d '2026-07-12 09:00:00 +0000' "$source/updated.txt"
    touch -r "$source" "$destination"
    configure_home_paths "$tmp/home"
    ensure_home_layout
    output="$tmp/real-rsync.out"
    diagnostic="$tmp/real-rsync.diagnostic"
    : >"$diagnostic"
    real_rsync=$(command -v rsync)
    "$real_rsync" -a --delete --itemize-changes '--out-format=__SYNCWARDEN_CHANGE__:%i|%b' "$source/" "$destination/" >"$output" 2>&1
    rc=$?
    assert_eq '0' "$rc" 'local real rsync fixture succeeds'
    reset_last_change_stats
    consume_rsync_attempt_output "$output" "$diagnostic" 1
    rc=$?
    assert_eq '0' "$rc" 'real rsync output satisfies the parser contract'
    assert_eq '1' "$LAST_CHANGE_CREATED" 'real rsync creation is classified'
    assert_eq '1' "$LAST_CHANGE_UPDATED" 'real rsync update is classified'
    assert_eq '1' "$LAST_CHANGE_DELETED" 'real rsync deletion is classified'
    assert_eq '3' "$LAST_CHANGE_COUNT" 'real rsync emits exactly the three fixture operations'
    if (( LAST_TRANSFER_BYTES > 0 )); then pass 'real rsync exposes transferred bytes'; else fail 'real rsync transferred bytes must be positive'; fi
}

test_preflight_output_mktemp_failure_sets_explicit_reason() {
    local tmp destination deadline rc
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'preflight mktemp fixture loads'
        return
    }
    LAST_FAILURE_REASON=SUCCESS
    LAST_EXIT_CODE=0
    LAST_ATTEMPT_COUNT=9
    mktemp() {
        if [[ "$1" == "$TMP_DIR/preflight."* ]]; then return 1; fi
        command mktemp "$@"
    }
    deadline=$(( $(date +%s) + 30 ))
    preflight_server sample-server "$deadline" >/dev/null 2>&1
    rc=$?
    unset -f mktemp
    if (( rc != 0 )); then pass 'preflight output mktemp failure is reported'; else fail 'preflight output mktemp failure must fail'; fi
    assert_eq 'TEMP_OUTPUT_FAILED' "${LAST_FAILURE_REASON-}" 'preflight mktemp failure has an explicit reason'
    assert_eq '1' "${LAST_EXIT_CODE-}" 'preflight mktemp failure has a nonzero exit code'
    assert_eq '0' "${LAST_ATTEMPT_COUNT-}" 'preflight mktemp failure occurs before an attempt'
}

test_sync_output_mktemp_failure_sets_explicit_reason() {
    local tmp destination deadline rc
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'rsync mktemp fixture loads'
        return
    }
    LAST_FAILURE_REASON=SUCCESS
    LAST_EXIT_CODE=0
    LAST_ATTEMPT_COUNT=9
    LAST_SYNC_STATUS=SUCCESS
    mktemp() {
        if [[ "$1" == "$TMP_DIR/rsync."* ]]; then return 1; fi
        command mktemp "$@"
    }
    deadline=$(( $(date +%s) + 30 ))
    sync_source sample-server '/srv/data' "$deadline" 0 >/dev/null 2>&1
    rc=$?
    unset -f mktemp
    if (( rc != 0 )); then pass 'rsync output mktemp failure is reported'; else fail 'rsync output mktemp failure must fail'; fi
    assert_eq 'TEMP_OUTPUT_FAILED' "${LAST_FAILURE_REASON-}" 'rsync mktemp failure has an explicit reason'
    assert_eq '1' "${LAST_EXIT_CODE-}" 'rsync mktemp failure has a nonzero exit code'
    assert_eq '0' "${LAST_ATTEMPT_COUNT-}" 'rsync mktemp failure occurs before an attempt'
    assert_eq 'FAILED' "${LAST_SYNC_STATUS-}" 'rsync mktemp failure cannot inherit success status'
}

test_sync_local_mkdir_failure_sets_complete_result() {
    local tmp destination deadline rc
    tmp=$(make_temp_dir)
    destination="$tmp/payload"
    mkdir -p "$destination"
    prepare_transport_test "$tmp/home" "$destination" || {
        fail 'rsync mkdir fixture loads'
        return
    }
    LAST_FAILURE_REASON=SUCCESS
    LAST_EXIT_CODE=0
    LAST_ATTEMPT_COUNT=9
    LAST_SYNC_STATUS=SUCCESS
    mkdir() { return 1; }
    deadline=$(( $(date +%s) + 30 ))
    sync_source sample-server '/srv/data' "$deadline" 0 >/dev/null 2>&1
    rc=$?
    unset -f mkdir
    if (( rc != 0 )); then pass 'local destination mkdir failure is reported'; else fail 'local destination mkdir failure must fail'; fi
    assert_eq 'LOCAL_DESTINATION_FAILED' "${LAST_FAILURE_REASON-}" 'mkdir failure has an explicit reason'
    assert_eq '1' "${LAST_EXIT_CODE-}" 'mkdir failure has a nonzero exit code'
    assert_eq '0' "${LAST_ATTEMPT_COUNT-}" 'mkdir failure occurs before an attempt'
    assert_eq 'FAILED' "${LAST_SYNC_STATUS-}" 'mkdir failure cannot inherit success status'
}

run_transport_suite() {
    test_transfer_metrics_format_readable_units
    test_rsync_attempt_parser_classifies_and_filters_rows
    test_rsync_retry_keeps_change_counts_and_resets_transfer_metrics
    test_malformed_managed_row_marks_statistics_unavailable
    test_real_rsync_out_format_matches_parser_contract
    test_preflight_host_key_and_auth_do_not_retry
    test_preflight_transient_network_retries_and_missing_source_does_not
    test_preflight_quotes_remote_path_and_diagnostic_as_data
    test_preflight_uses_posix_test_syntax_for_existing_path
    test_sync_command_preserves_mirror_semantics
    test_sync_refuses_low_free_inodes_before_rsync
    test_capacity_check_has_a_finite_safety_timeout
    test_sync_dry_run_and_code24_classification
    test_sync_native_io_timeout_is_explicit_and_not_retried
    test_sync_transient_retry_and_permanent_failure
    test_preflight_output_mktemp_failure_sets_explicit_reason
    test_sync_output_mktemp_failure_sets_explicit_reason
    test_sync_local_mkdir_failure_sets_complete_result
}

write_orchestration_config() {
    local path=$1
    local payload_root=$2
    write_external_contract_config "$path" "[server:one]
host=one.example
name=One
destination=$payload_root/one
source=/srv/data

[server:two]
host=two.example
name=Two
scheduled_sync_enabled=no
destination=$payload_root/two
source=/srv/data

[server:three]
host=three.example
name=Three
destination=$payload_root/three
source=/srv/data"
    replace_config_value "$path" key_file "$TEST_PRIVATE_KEY"
    replace_config_value "$path" retry_count 0
    replace_config_value "$path" retry_delays_seconds 0
    replace_config_value "$path" owner backup:backup
}

write_key_isolation_config() {
    local path=$1 payload_root=$2 default_key=$3 bad_key=$4
    write_external_contract_config "$path" "[server:one]
host=one.example
name=One
destination=$payload_root/one
source=/srv/data

[server:two]
host=two.example
name=Two
key_file=$bad_key
destination=$payload_root/two
source=/srv/data

[server:three]
host=three.example
name=Three
destination=$payload_root/three
source=/srv/data"
    replace_config_value "$path" key_file "$default_key"
    replace_config_value "$path" retry_count 0
    replace_config_value "$path" retry_delays_seconds 0
    replace_config_value "$path" owner backup:backup
    replace_config_value "$path" min_free_space_mb 1
    replace_config_value "$path" min_free_inodes 1
}

prepare_orchestration_test() {
    local home=$1
    local config=$2
    configure_home_paths "$home"
    ensure_home_layout
    load_and_validate "$config"
    SSH_BIN="$TEST_DIR/fakes/ssh"
    RSYNC_BIN="$TEST_DIR/fakes/rsync"
    ZIP_BIN="$TEST_DIR/fakes/zip"
    SHA256_BIN=$(command -v sha256sum)
    DF_BIN=$(command -v df)
    RM_BIN=$(command -v rm)
    unset FAKE_DF_AVAILABLE_MB FAKE_DF_AVAILABLE_INODES
}

test_batch_is_sequential_and_failure_isolated() {
    local tmp config payload rc args first_line second_line success_content failure_content
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'orchestration fixture loads'
        return
    }

    FAKE_SSH_MODE=success
    FAKE_SSH_FAIL_HOST=two.example
    FAKE_SSH_FAIL_MODE=host-key
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/rsync-order"
    export FAKE_SSH_MODE FAKE_SSH_FAIL_HOST FAKE_SSH_FAIL_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE

    run_batch SCHEDULED 0 one two three >/dev/null
    rc=$?
    assert_eq '1' "$rc" 'one failed server makes batch fail'
    args=$(<"$FAKE_RSYNC_ARGS_FILE")
    assert_contains 'one.example:/srv/data/' "$args" 'first server is synced'
    assert_not_contains 'two.example:/srv/data/' "$args" 'failed preflight server is not synced'
    assert_contains 'three.example:/srv/data/' "$args" 'third server still syncs after second fails'
    first_line=$(sed -n '1p' "$FAKE_RSYNC_ARGS_FILE")
    second_line=$(sed -n '2p' "$FAKE_RSYNC_ARGS_FILE")
    assert_contains 'one.example' "$first_line" 'first rsync call preserves config order'
    assert_contains 'three.example' "$second_line" 'later rsync call preserves config order'

    success_content=$(<"$SUCCESS_LOG")
    failure_content=$(<"$FAILURE_LOG")
    assert_contains 'One' "$success_content" 'success log includes successful first server'
    assert_contains 'Three' "$success_content" 'success log includes successful later server'
    assert_not_contains 'Two' "$success_content" 'success log excludes failed server details'
    assert_contains 'Two' "$failure_content" 'failure log includes failed server'
    assert_contains 'HOST_KEY_CHANGED' "$failure_content" 'failure log includes classified reason'
}

test_batch_continues_after_rsync_io_timeout() {
    local tmp config payload rc args failure_content
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'rsync timeout isolation fixture loads'
        return
    }

    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_FAIL_HOST=one.example
    FAKE_RSYNC_FAIL_MODE=io-timeout
    FAKE_RSYNC_ARGS_FILE="$tmp/rsync-order"
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_FAIL_HOST FAKE_RSYNC_FAIL_MODE FAKE_RSYNC_ARGS_FILE

    run_batch SCHEDULED 0 one three >/dev/null
    rc=$?
    args=$(<"$FAKE_RSYNC_ARGS_FILE")
    failure_content=$(<"$FAILURE_LOG")
    assert_eq '1' "$rc" 'one rsync I/O timeout makes the batch fail'
    assert_contains 'one.example:/srv/data/' "$args" 'timed-out server starts its rsync attempt'
    assert_contains 'three.example:/srv/data/' "$args" 'later server still runs after rsync I/O timeout'
    assert_contains 'RSYNC_IO_TIMEOUT' "$failure_content" 'failure log records the explicit rsync I/O timeout reason'
    unset FAKE_RSYNC_FAIL_HOST FAKE_RSYNC_FAIL_MODE
}

test_batch_exit_codes_success_and_warning() {
    local tmp config payload rc
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'batch exit fixture loads'
        return
    }

    unset FAKE_SSH_FAIL_HOST FAKE_SSH_FAIL_MODE FAKE_RSYNC_FAIL_HOST FAKE_RSYNC_FAIL_MODE
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/success-args"
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE
    run_batch MANUAL 0 one >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'all-success batch returns zero'

    configure_home_paths "$tmp/warning-home"
    ensure_home_layout
    load_and_validate "$config"
    SSH_BIN="$TEST_DIR/fakes/ssh"
    RSYNC_BIN="$TEST_DIR/fakes/rsync"
    ZIP_BIN="$TEST_DIR/fakes/zip"
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_OUTPUT='__SYNCWARDEN_CHANGE__:bad'
    FAKE_RSYNC_ARGS_FILE="$tmp/warning-args"
    export FAKE_RSYNC_MODE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE
    run_batch MANUAL 0 one >/dev/null
    rc=$?
    assert_eq '2' "$rc" 'warning-only batch returns two'
    assert_contains 'CHANGE_STATS_PARSE_FAILED' "$(<"$FAILURE_LOG")" 'warning details are written only to failure log'
    unset FAKE_RSYNC_OUTPUT
}

test_multisource_failure_reason_has_priority_over_later_warning() {
    local tmp config payload rc status_content
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'multi-source priority fixture loads'
        return
    }
    SERVER_SOURCES['one:0']='/first'
    SERVER_SOURCES['one:1']='/second'
    SERVER_SOURCE_COUNT['one']=2
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE_SEQUENCE='fail23,success'
    FAKE_RSYNC_OUTPUT_2='__SYNCWARDEN_CHANGE__:bad'
    FAKE_RSYNC_STATE_FILE="$tmp/rsync-sequence-state"
    FAKE_RSYNC_ARGS_FILE="$tmp/rsync-sequence-args"
    export FAKE_SSH_MODE FAKE_RSYNC_MODE_SEQUENCE FAKE_RSYNC_OUTPUT_2 FAKE_RSYNC_STATE_FILE FAKE_RSYNC_ARGS_FILE

    run_server one MANUAL 0 >/dev/null 2>&1
    rc=$?
    assert_eq '1' "$rc" 'failure followed by warning still returns failure'
    assert_eq 'FAILED' "${SERVER_STATUS-}" 'failure followed by warning keeps failed status'
    assert_eq 'RSYNC_FAILED' "${SERVER_REASON-}" 'later warning does not overwrite the failure reason'
    status_content=$(<"$LAST_STATUS_DIR/one.status")
    assert_contains 'reason=RSYNC_FAILED' "$status_content" 'last-status preserves the highest-severity reason'
    unset FAKE_RSYNC_MODE_SEQUENCE FAKE_RSYNC_OUTPUT_2 FAKE_RSYNC_STATE_FILE
}

test_archive_only_failure_has_priority_over_later_warning() {
    local tmp config payload rc status_content
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'archive-only priority fixture loads'
        return
    }
    SERVER_SOURCES['one:0']='/first'
    SERVER_SOURCES['one:1']='/second'
    SERVER_SOURCE_COUNT['one']=2

    (
        archive_call=0
        archive_source() {
            archive_call=$((archive_call + 1))
            if (( archive_call == 1 )); then
                LAST_ARCHIVE_STATUS='FAILED_CREATE'
                LAST_COMMAND_OUTPUT=''
                return 1
            fi
            LAST_ARCHIVE_STATUS='WARNING_CLEANUP'
            LAST_COMMAND_OUTPUT=''
            return 2
        }
        run_archive_only one >/dev/null 2>&1
    )
    rc=$?
    assert_eq '1' "$rc" 'archive-only failure followed by warning returns failure'
    status_content=$(<"$LAST_STATUS_DIR/one.status")
    assert_contains 'status=FAILED' "$status_content" 'archive-only status preserves failure precedence'
    assert_contains 'reason=FAILED_CREATE' "$status_content" 'archive-only reason preserves the failure cause'
}

test_successful_sync_fails_if_last_status_cannot_be_persisted() {
    local tmp config payload rc blocker
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'last-status persistence fixture loads'
        return
    }
    blocker="$tmp/not-a-directory"
    printf 'blocker\n' >"$blocker"
    LAST_STATUS_DIR=$blocker
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/rsync-args"
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE

    run_server one MANUAL 0 >/dev/null 2>&1
    rc=$?
    assert_eq '1' "$rc" 'successful transfer is not reported successful when last-status persistence fails'
    assert_eq 'STATE_WRITE_FAILED' "${SERVER_REASON-}" 'last-status persistence failure is explicit'
}

test_last_status_chmod_failure_never_promotes() {
    local tmp target rc
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    reset_server_change_stats
    target="$LAST_STATUS_DIR/sample-server.status"

    ( chmod() { return 1; }; write_last_status sample-server SUCCESS MANUAL SUCCESS 0 1 ) >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'last-status chmod failure is reported'; else fail 'last-status chmod failure must fail'; fi
    assert_file_not_exists "$target" 'last-status chmod failure never promotes a SUCCESS file'
}

test_schedule_state_chmod_failure_never_promotes() {
    local tmp target rc
    tmp=$(make_temp_dir)
    configure_home_paths "$tmp/home"
    ensure_home_layout
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 03:00:00 +0000' +%s)
    SYNCWARDEN_NOW_HOUR=3
    export SYNCWARDEN_NOW_EPOCH SYNCWARDEN_NOW_HOUR
    target=$(schedule_state_path)

    ( chmod() { return 1; }; write_schedule_state "$target" 3 SUCCESS 0 ) >/dev/null 2>&1
    rc=$?
    if (( rc != 0 )); then pass 'schedule-state chmod failure is reported'; else fail 'schedule-state chmod failure must fail'; fi
    assert_file_not_exists "$target" 'schedule-state chmod failure never promotes a state file'
    unset SYNCWARDEN_NOW_EPOCH SYNCWARDEN_NOW_HOUR
}

test_batch_fails_if_success_or_warning_log_cannot_be_persisted() {
    local tmp config payload rc status_content output
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'log persistence fixture loads'
        return
    }
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/success-args"
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE SYNCWARDEN_NOW_EPOCH
    refresh_log_paths
    mkdir -- "$SUCCESS_LOG"
    output=$(run_batch MANUAL 0 one 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'batch fails when success log cannot be persisted'
    assert_contains 'Final Status : FAILED' "$output" 'batch terminal summary reflects log persistence failure'
    assert_contains 'Reason       : LOG_WRITE_FAILED' "$output" 'batch terminal summary explains log persistence failure'
    status_content=$(<"$LAST_STATUS_DIR/one.status")
    assert_contains 'status=FAILED' "$status_content" 'success-log failure is reflected in last-status'
    assert_contains 'reason=LOG_WRITE_FAILED' "$status_content" 'success-log failure has an explicit last-status reason'

    configure_home_paths "$tmp/warning-home"
    ensure_home_layout
    load_and_validate "$config"
    SSH_BIN="$TEST_DIR/fakes/ssh"
    RSYNC_BIN="$TEST_DIR/fakes/rsync"
    ZIP_BIN="$TEST_DIR/fakes/zip"
    SERVER_VALUES['one:min_free_space_mb']='1'
    SERVER_VALUES['one:min_free_inodes']='1'
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_OUTPUT='__SYNCWARDEN_CHANGE__:bad'
    FAKE_RSYNC_ARGS_FILE="$tmp/warning-args"
    refresh_log_paths
    mkdir -- "$FAILURE_LOG"
    export FAKE_RSYNC_MODE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE
    run_batch MANUAL 0 one >/dev/null 2>&1
    rc=$?
    assert_eq '1' "$rc" 'warning batch becomes failed when failure log cannot be persisted'
    unset FAKE_RSYNC_OUTPUT SYNCWARDEN_NOW_EPOCH
}

test_archive_only_fails_if_log_cannot_be_persisted_and_formats_sources_separately() {
    local tmp config payload rc ok_lines status_content content output
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'archive-only persistence fixture loads'
        return
    }
    SERVER_SOURCES['one:0']='/first'
    SERVER_SOURCES['one:1']='/second'
    SERVER_SOURCE_COUNT['one']=2

    (
        archive_source() {
            LAST_ARCHIVE_STATUS='SUCCESS'
            LAST_COMMAND_OUTPUT=''
            return 0
        }
        run_archive_only one >/dev/null 2>&1
    )
    rc=$?
    assert_eq '0' "$rc" 'archive-only multi-source success returns zero'
    ok_lines=$(grep -c '^\[OK\]' "$SUCCESS_LOG")
    assert_eq '2' "$ok_lines" 'archive-only renders each source result on its own line'
    content=$(<"$SUCCESS_LOG")
    assert_contains 'source=first' "$content" 'archive-only identifies the first source'
    assert_contains 'source=second' "$content" 'archive-only identifies the second source'

    configure_home_paths "$tmp/broken-log-home"
    ensure_home_layout
    load_and_validate "$config"
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    export SYNCWARDEN_NOW_EPOCH
    refresh_log_paths
    mkdir -- "$SUCCESS_LOG"
    output=$(
      (
        archive_source() {
            LAST_ARCHIVE_STATUS='SUCCESS'
            LAST_COMMAND_OUTPUT=''
            return 0
        }
        run_archive_only one
      ) 2>&1
    )
    rc=$?
    assert_eq '1' "$rc" 'archive-only fails when its success log cannot be persisted'
    assert_contains 'Final Status : FAILED' "$output" 'archive-only terminal summary reflects log persistence failure'
    assert_contains 'Reason       : LOG_WRITE_FAILED' "$output" 'archive-only terminal summary explains log persistence failure'
    status_content=$(<"$LAST_STATUS_DIR/one.status")
    assert_contains 'status=FAILED' "$status_content" 'archive-only log failure is reflected in last-status'
    assert_contains 'reason=LOG_WRITE_FAILED' "$status_content" 'archive-only log failure has an explicit last-status reason'
    unset SYNCWARDEN_NOW_EPOCH
}

test_archive_failure_blocks_only_that_server_sync() {
    local tmp config payload rc
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload/one/data"
    printf 'existing mirror\n' >"$payload/one/data/file.txt"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'archive-block fixture loads'
        return
    }

    unset FAKE_SSH_FAIL_HOST FAKE_SSH_FAIL_MODE
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/blocked-rsync-args"
    FAKE_ZIP_MODE=create-fail
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE FAKE_ZIP_MODE
    run_server one MANUAL 0 >/dev/null 2>&1
    rc=$?
    assert_eq '1' "$rc" 'required archive failure fails that server'
    assert_file_not_exists "$FAKE_RSYNC_ARGS_FILE" 'required archive failure prevents rsync for that server'
    assert_contains 'FAILED_CREATE' "${SERVER_FAILURE_BODY-}" 'archive failure reason is retained'
}

test_first_sync_without_mirror_proceeds() {
    local tmp config payload rc mkdir_log mkdir_args
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'first-sync fixture loads'
        return
    }

    unset FAKE_SSH_FAIL_HOST FAKE_SSH_FAIL_MODE
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/first-sync-args"
    FAKE_ZIP_MODE=success
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE FAKE_ZIP_MODE
    mkdir_log="$tmp/mkdir-args"
    mkdir() {
        printf '%s\n' "$*" >>"$mkdir_log"
        [[ "${1-}" != '-p' ]] || return 98
        command mkdir "$@"
    }
    run_server one MANUAL 0 >/dev/null
    rc=$?
    unset -f mkdir
    mkdir_args=$(<"$mkdir_log")
    assert_eq '0' "$rc" 'first sync succeeds without an existing mirror archive'
    assert_file_exists "$FAKE_RSYNC_ARGS_FILE" 'first sync still invokes rsync'
    assert_dir_exists "$payload/one" 'first sync creates exactly the missing destination component'
    assert_dir_exists "$payload/one/data" 'first sync creates exactly the missing source target component'
    assert_not_contains '-p' "$mkdir_args" 'first sync never recreates a missing destination chain'
    assert_eq 'SKIPPED_NO_MIRROR' "${SERVER_ARCHIVE_SUMMARY-}" 'first sync records archive skip reason'
}

test_scheduled_hour_matching() {
    local tmp config payload
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'schedule fixture loads'
        return
    }

    SYNCWARDEN_NOW_HOUR=3
    export SYNCWARDEN_NOW_HOUR
    if scheduled_due_now; then pass 'configured hour is due'; else fail 'configured hour should be due'; fi
    SYNCWARDEN_NOW_HOUR=6
    if scheduled_due_now; then fail 'unconfigured hour must not be due'; else pass 'unconfigured hour is not due'; fi
    unset SYNCWARDEN_NOW_HOUR
}

test_real_sync_aggregates_changes_into_log_and_status() {
    local tmp config payload content status rc
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || {
        fail 'change aggregation fixture loads'
        return
    }
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_OUTPUT=$'__SYNCWARDEN_CHANGE__:>f+++++++++|1024\n__SYNCWARDEN_CHANGE__:>f.st......|2048\n__SYNCWARDEN_CHANGE__:*deleting  |0'
    FAKE_RSYNC_ARGS_FILE="$tmp/args"
    export SYNCWARDEN_NOW_EPOCH FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE
    refresh_log_paths
    run_batch MANUAL 0 one >/dev/null
    rc=$?
    content=$(<"$SUCCESS_LOG")
    status=$(<"$LAST_STATUS_DIR/one.status")
    assert_eq '0' "$rc" 'real sync with valid statistics succeeds'
    assert_contains 'changes=3' "$content" 'success log records total changes'
    assert_contains 'created=1' "$content" 'success log records created count'
    assert_contains 'updated=1' "$content" 'success log records updated count'
    assert_contains 'deleted=1' "$content" 'success log records deleted count'
    assert_contains 'transferred=3.00KiB' "$content" 'manual success log records readable transferred size'
    assert_matches 'avg_speed=[0-9]+([.][0-9]+)?(B|KiB|MiB|GiB|TiB|PiB)/s' "$content" 'manual success log records readable average speed'
    assert_contains 'attempts=1' "$content" 'success log records rsync attempts'
    assert_contains 'complete=yes' "$content" 'success log marks complete statistics'
    assert_contains 'changes=3' "$status" 'last-status records total changes'
    assert_contains 'transferred_bytes=3072' "$status" 'last-status records raw transferred bytes'
    assert_contains 'average_bytes_per_second=' "$status" 'last-status records machine-readable average speed'
    assert_contains 'change_complete=yes' "$status" 'last-status records completeness'
    unset FAKE_RSYNC_OUTPUT SYNCWARDEN_NOW_EPOCH
}

test_preflight_failure_marks_changes_unavailable() {
    local tmp config payload content rc
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || return
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    FAKE_SSH_MODE=host-key
    export SYNCWARDEN_NOW_EPOCH FAKE_SSH_MODE
    refresh_log_paths
    run_batch MANUAL 0 one >/dev/null 2>&1
    rc=$?
    content=$(<"$FAILURE_LOG")
    assert_eq '1' "$rc" 'preflight failure still fails the server'
    assert_contains 'Changes         : unavailable' "$content" 'preflight failure never fabricates zero changes'
    assert_contains 'Source          : data' "$content" 'failure identifies the affected source'
    assert_contains 'changes=unavailable' "$(<"$LAST_STATUS_DIR/one.status")" 'last-status records unavailable changes'
    unset SYNCWARDEN_NOW_EPOCH
}

test_code24_is_success_with_complete_status_and_no_failure_log() {
    local tmp config payload success_content status_content rc
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || return
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=vanished
    FAKE_RSYNC_OUTPUT=$'__SYNCWARDEN_CHANGE__:>f+++++++++|1024\n__SYNCWARDEN_CHANGE__:*deleting  |0'
    FAKE_RSYNC_ARGS_FILE="$tmp/args"
    export SYNCWARDEN_NOW_EPOCH FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE
    refresh_log_paths
    run_batch MANUAL 0 one >/dev/null
    rc=$?
    success_content=$(<"$SUCCESS_LOG")
    status_content=$(<"$LAST_STATUS_DIR/one.status")
    assert_eq '0' "$rc" 'code 24 is successful for a live mirror batch'
    assert_contains 'changes=2' "$success_content" 'success summary retains observed changes'
    assert_contains 'complete=yes' "$success_content" 'success summary marks the accepted sync complete'
    assert_contains 'status=SUCCESS' "$status_content" 'last-status records accepted code 24 as success'
    assert_contains 'reason=SUCCESS' "$status_content" 'last-status has no warning reason for accepted code 24'
    assert_contains 'change_complete=yes' "$status_content" 'last-status marks the accepted sync complete'
    assert_file_not_exists "$FAILURE_LOG" 'accepted code 24 writes no failure log'
    assert_not_contains '__SYNCWARDEN_CHANGE__' "$success_content" 'internal rows never enter the success log'
    unset FAKE_RSYNC_OUTPUT SYNCWARDEN_NOW_EPOCH
}

test_archive_only_status_is_not_applicable() {
    local tmp config payload status rc
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || return
    (
        archive_source() { LAST_ARCHIVE_STATUS='SUCCESS'; LAST_COMMAND_OUTPUT=''; return 0; }
        run_archive_only one >/dev/null
    )
    rc=$?
    status=$(<"$LAST_STATUS_DIR/one.status")
    assert_eq '0' "$rc" 'archive-only fixture succeeds'
    assert_contains 'changes=not_applicable' "$status" 'archive-only changes are explicitly not applicable'
    assert_contains 'attempts=0' "$status" 'archive-only has zero rsync attempts'
}

test_multisource_aggregate_and_failed_source_attribution() {
    local tmp config payload content rc
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || return
    SERVER_SOURCES['one:0']='/first'
    SERVER_SOURCES['one:1']='/second'
    SERVER_SOURCE_COUNT['one']=2
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE_SEQUENCE='success,fail23'
    FAKE_RSYNC_STATE_FILE="$tmp/rsync-state"
    FAKE_RSYNC_OUTPUT='__SYNCWARDEN_CHANGE__:>f+++++++++|1024'
    FAKE_RSYNC_ARGS_FILE="$tmp/args"
    export SYNCWARDEN_NOW_EPOCH FAKE_SSH_MODE FAKE_RSYNC_MODE_SEQUENCE FAKE_RSYNC_STATE_FILE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE
    refresh_log_paths
    run_batch MANUAL 0 one >/dev/null 2>&1
    rc=$?
    content=$(<"$FAILURE_LOG")
    assert_eq '1' "$rc" 'one failed source fails the server'
    assert_contains 'Source          : second' "$content" 'failure identifies the failed local source name'
    assert_contains 'Changes         : 2' "$content" 'server summary aggregates both source attempts'
    assert_contains 'Rsync Attempts  : 2' "$content" 'server summary totals rsync invocations across sources'
    assert_contains 'Transferred     : 2.00KiB' "$content" 'failure summary retains readable observed transfer size'
    assert_contains 'Average Speed   :' "$content" 'failure summary retains readable observed average speed'
    assert_contains 'Change Complete : no' "$content" 'one failed source makes aggregate incomplete'
    unset FAKE_RSYNC_MODE_SEQUENCE FAKE_RSYNC_STATE_FILE FAKE_RSYNC_OUTPUT SYNCWARDEN_NOW_EPOCH
}

test_change_parser_failure_warns_without_rewriting_transfer_result() {
    local tmp config payload content rc
    tmp=$(make_temp_dir)
    config="$tmp/orchestration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || return
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_OUTPUT='__SYNCWARDEN_CHANGE__:bad'
    FAKE_RSYNC_ARGS_FILE="$tmp/args"
    export SYNCWARDEN_NOW_EPOCH FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE
    refresh_log_paths
    run_batch MANUAL 0 one >/dev/null
    rc=$?
    content=$(<"$FAILURE_LOG")
    assert_eq '2' "$rc" 'successful transfer with unparseable statistics becomes warning, not failure'
    assert_contains 'CHANGE_STATS_PARSE_FAILED' "$content" 'parse warning has an explicit reason'
    assert_contains 'unavailable (parse failed)' "$content" 'parse warning never exposes partial numeric totals'
    assert_not_contains '__SYNCWARDEN_CHANGE__' "$content" 'malformed internal row is filtered from logs'
    unset FAKE_RSYNC_OUTPUT SYNCWARDEN_NOW_EPOCH
}

run_orchestration_suite() {
    test_real_sync_aggregates_changes_into_log_and_status
    test_preflight_failure_marks_changes_unavailable
    test_code24_is_success_with_complete_status_and_no_failure_log
    test_archive_only_status_is_not_applicable
    test_multisource_aggregate_and_failed_source_attribution
    test_change_parser_failure_warns_without_rewriting_transfer_result
    test_batch_is_sequential_and_failure_isolated
    test_batch_continues_after_rsync_io_timeout
    test_batch_exit_codes_success_and_warning
    test_multisource_failure_reason_has_priority_over_later_warning
    test_archive_only_failure_has_priority_over_later_warning
    test_successful_sync_fails_if_last_status_cannot_be_persisted
    test_last_status_chmod_failure_never_promotes
    test_schedule_state_chmod_failure_never_promotes
    test_batch_fails_if_success_or_warning_log_cannot_be_persisted
    test_archive_only_fails_if_log_cannot_be_persisted_and_formats_sources_separately
    test_archive_failure_blocks_only_that_server_sync
    test_first_sync_without_mirror_proceeds
    test_scheduled_hour_matching
}

run_integration_cli() {
    local home=$1
    local config=$2
    shift 2
    SYNCWARDEN_LIB_MODE=0 \
    SYNCWARDEN_HOME="$home" \
    SYNCWARDEN_CONFIG="$config" \
    SYNCWARDEN_SSH_BIN="$TEST_DIR/fakes/ssh" \
    SYNCWARDEN_RSYNC_BIN="$TEST_DIR/fakes/rsync" \
    SYNCWARDEN_ZIP_BIN="$TEST_DIR/fakes/zip" \
        "$SCRIPT_PATH" "$@"
}

make_short_global_timeout_script() {
    local output=$1
    sed 's/^GLOBAL_RUNTIME_TIMEOUT_SECONDS=18000$/GLOBAL_RUNTIME_TIMEOUT_SECONDS=1/' \
        "$SCRIPT_PATH" >"$output"
    chmod 0700 "$output"
}

test_global_timeout_constants_and_single_wrapper() {
    local tmp args_file output rc content calls
    tmp=$(make_temp_dir)
    args_file="$tmp/timeout-args"

    assert_eq '18000' "${GLOBAL_RUNTIME_TIMEOUT_SECONDS-}" 'global runtime limit is fixed at five hours'
    assert_eq '60' "${GLOBAL_TIMEOUT_KILL_GRACE_SECONDS-}" 'global timeout allows a sixty-second TERM grace period'
    assert_eq '05h00m00s' "$(format_global_runtime_limit 2>/dev/null)" 'global runtime limit is rendered as hours for readable logs'

    output=$(SYNCWARDEN_LIB_MODE=0 \
        SYNCWARDEN_TIMEOUT_BIN="$TEST_DIR/fakes/timeout" \
        FAKE_TIMEOUT_MODE=passthrough \
        FAKE_TIMEOUT_ARGS_FILE="$args_file" \
        "$SCRIPT_PATH" --help 2>&1)
    rc=$?
    content=''
    [[ -f "$args_file" ]] && content=$(<"$args_file")
    calls=$(grep -c '^CALL$' "$args_file" 2>/dev/null || true)

    assert_eq '0' "$rc" '--help succeeds through the global timeout wrapper'
    assert_eq '1' "$calls" 'direct CLI invocation enters the global wrapper exactly once'
    assert_contains 'ARG=--signal=TERM' "$content" 'global wrapper sends TERM at the absolute limit'
    assert_contains 'ARG=--kill-after=60s' "$content" 'global wrapper has a sixty-second kill grace'
    assert_contains 'ARG=18000s' "$content" 'global wrapper passes the fixed five-hour duration'
    assert_contains 'ARG=--help' "$content" 'global wrapper preserves original CLI arguments'
    assert_contains 'SyncWarden -' "$output" 'wrapped help still reaches the normal command dispatcher'
    assert_not_contains '05h00m00s' "$output" 'CLI help leaves the global runtime details in the README'
    assert_not_contains '退出码' "$output" 'CLI help leaves exit-code documentation in the README'
}

test_manual_global_timeout_logs_and_cleans_up() {
    local tmp config payload home short_script output rc failure_log content leftovers lock_rc
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    home="$tmp/home"
    short_script="$tmp/syncwarden-short-timeout.sh"
    mkdir -p "$payload/one/data"
    printf 'mirror payload\n' >"$payload/one/data/file.txt"
    write_orchestration_config "$config" "$payload"
    replace_config_value "$config" min_free_space_mb 1
    replace_config_value "$config" min_free_inodes 1
    make_short_global_timeout_script "$short_script"

    output=$(SYNCWARDEN_LIB_MODE=0 \
        SYNCWARDEN_HOME="$home" \
        SYNCWARDEN_CONFIG="$config" \
        SYNCWARDEN_SSH_BIN="$TEST_DIR/fakes/ssh" \
        SYNCWARDEN_RSYNC_BIN="$TEST_DIR/fakes/rsync" \
        SYNCWARDEN_ZIP_BIN="$TEST_DIR/fakes/zip" \
        SYNCWARDEN_TIMEOUT_BIN="$(command -v timeout)" \
        SYNCWARDEN_NOW_EPOCH="$(date -d '2026-07-14 09:00:00 +0000' +%s)" \
        FAKE_SSH_MODE=success \
        FAKE_RSYNC_MODE=sleep \
        FAKE_RSYNC_SLEEP_SECONDS=2 \
        FAKE_ZIP_MODE=success \
        "$short_script" one 2>&1)
    rc=$?
    failure_log="$home/logs/failure-2026-07.log"
    content=''
    [[ -f "$failure_log" ]] && content=$(<"$failure_log")
    leftovers=$(find "$home/tmp" -mindepth 1 -print 2>/dev/null || true)

    assert_eq '124' "$rc" 'manual invocation returns 124 at the absolute runtime limit'
    assert_contains 'GLOBAL_TIMEOUT' "$output" 'manual global timeout is explicit on stderr'
    assert_file_exists "$failure_log" 'manual global timeout writes the monthly failure log'
    assert_contains 'FAILURE - GLOBAL TIMEOUT' "$content" 'manual global timeout log has a dedicated title'
    assert_contains 'Reason     : GLOBAL_TIMEOUT' "$content" 'manual global timeout log records the reason'
    assert_contains 'Mode       : MANUAL' "$content" 'manual global timeout log records the invocation mode'
    assert_eq '' "$leftovers" 'global timeout cleans registered temporary command output'

    exec {timeout_lock_fd}>>"$home/state/syncwarden.lock"
    flock -n "$timeout_lock_fd"
    lock_rc=$?
    (( lock_rc == 0 )) && flock -u "$timeout_lock_fd"
    exec {timeout_lock_fd}>&-
    assert_eq '0' "$lock_rc" 'global timeout releases the SyncWarden lock'
}

test_dry_run_global_timeout_preserves_zero_write() {
    local tmp config payload home short_script output rc managed_files leftovers
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    home="$tmp/home"
    short_script="$tmp/syncwarden-short-timeout.sh"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    replace_config_value "$config" min_free_space_mb 1
    replace_config_value "$config" min_free_inodes 1
    make_short_global_timeout_script "$short_script"

    output=$(SYNCWARDEN_LIB_MODE=0 \
        SYNCWARDEN_HOME="$home" \
        SYNCWARDEN_CONFIG="$config" \
        SYNCWARDEN_SSH_BIN="$TEST_DIR/fakes/ssh" \
        SYNCWARDEN_RSYNC_BIN="$TEST_DIR/fakes/rsync" \
        SYNCWARDEN_ZIP_BIN="$TEST_DIR/fakes/zip" \
        SYNCWARDEN_TIMEOUT_BIN="$(command -v timeout)" \
        SYNCWARDEN_NOW_EPOCH="$(date -d '2026-07-14 09:00:00 +0000' +%s)" \
        FAKE_SSH_MODE=success \
        FAKE_RSYNC_MODE=sleep \
        FAKE_RSYNC_SLEEP_SECONDS=2 \
        "$short_script" one --dry-run 2>&1)
    rc=$?
    managed_files=$(find "$home/logs" "$home/state/last-status" "$home/state/archive-index" "$home/state/schedule" \
        -type f -print 2>/dev/null || true)
    leftovers=$(find "$home/tmp" -mindepth 1 -print 2>/dev/null || true)

    assert_eq '124' "$rc" 'dry-run is covered by the absolute runtime limit'
    assert_contains 'GLOBAL_TIMEOUT' "$output" 'dry-run global timeout is explicit on stderr'
    assert_eq '' "$managed_files" 'dry-run global timeout writes no managed logs or state'
    assert_eq '' "$leftovers" 'dry-run global timeout cleans its temporary output'
}

test_real_modes_log_global_configuration_failure_and_readonly_modes_do_not() {
    local tmp config payload rc output log
    tmp=$(make_temp_dir)
    config="$tmp/invalid.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    replace_config_value "$config" source '/unsafe source'
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-13 09:00:00 +0000' +%s)
    export SYNCWARDEN_NOW_EPOCH
    log='logs/failure-2026-07.log'

    output=$(run_integration_cli "$tmp/manual-home" "$config" one 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'manual mode stops on invalid configuration'
    assert_file_exists "$tmp/manual-home/$log" 'manual mode persists a global configuration failure'
    assert_contains 'FAILURE - CONFIGURATION' "$(<"$tmp/manual-home/$log")" 'manual configuration log has a global title'
    assert_contains 'unsupported character' "$output" 'manual mode prints the precise configuration error'

    output=$(run_integration_cli "$tmp/scheduled-home" "$config" --scheduled 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'scheduled mode stops on invalid configuration'
    assert_file_exists "$tmp/scheduled-home/$log" 'scheduled mode persists a global configuration failure'

    output=$(run_integration_cli "$tmp/archive-home" "$config" --archive one 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'archive-only mode stops on invalid configuration'
    assert_file_exists "$tmp/archive-home/$log" 'archive-only mode persists a global configuration failure'

    output=$(run_integration_cli "$tmp/dry-home" "$config" one --dry-run 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'dry-run reports invalid configuration'
    assert_file_not_exists "$tmp/dry-home/$log" 'dry-run does not persist configuration failures'

    output=$(run_integration_cli "$tmp/check-home" "$config" --check 2>&1)
    rc=$?
    assert_eq '1' "$rc" '--check reports invalid configuration'
    assert_file_not_exists "$tmp/check-home/$log" '--check does not persist configuration failures'
    unset SYNCWARDEN_NOW_EPOCH
}

test_short_action_aliases_dispatch_safely() {
    local tmp config payload output rc
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload/one/data"
    printf 'mirror\n' >"$payload/one/data/file.txt"
    write_orchestration_config "$config" "$payload"

    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/dry-args"
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE
    run_integration_cli "$tmp/dry-home" "$config" one -n >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'SERVER_ID -n dispatches dry-run'
    assert_contains '--dry-run' "$(<"$FAKE_RSYNC_ARGS_FILE")" '-n reaches rsync dry-run'

    SYNCWARDEN_NOW_HOUR=6
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 06:00:00 +0000' +%s)
    export SYNCWARDEN_NOW_HOUR SYNCWARDEN_NOW_EPOCH
    output=$(run_integration_cli "$tmp/schedule-home" "$config" -s 2>&1)
    rc=$?
    assert_eq '0' "$rc" '-s dispatches scheduled safe no-op'
    assert_contains 'No SyncWarden task is due' "$output" '-s uses scheduled-hour checks'

    FAKE_ZIP_MODE=success
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    export FAKE_ZIP_MODE SYNCWARDEN_NOW_EPOCH
    run_integration_cli "$tmp/archive-home" "$config" -a one >/dev/null
    rc=$?
    assert_eq '0' "$rc" '-a SERVER_ID dispatches archive-only'
    assert_file_exists "$tmp/archive-home/state/last-status/one.status" '-a persists archive-only state'
    unset SYNCWARDEN_NOW_HOUR SYNCWARDEN_NOW_EPOCH
}

test_cli_lock_contention_returns_75() {
    local tmp config payload output rc
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload" "$tmp/home/state"
    write_orchestration_config "$config" "$payload"

    exec 9>"$tmp/home/state/syncwarden.lock"
    flock -n 9
    output=$(run_integration_cli "$tmp/home" "$config" one --dry-run 2>&1)
    rc=$?
    flock -u 9
    exec 9>&-

    assert_eq '75' "$rc" 'lock contention returns exit 75'
    assert_contains 'already running' "$output" 'lock contention message is explicit'
}

test_scheduled_cli_noop_and_due_state() {
    local tmp config payload rc output state_file state_content args first_count second_count
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"

    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/rsync-args"
    SYNCWARDEN_NOW_HOUR=6
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-11 06:00:00 +0000' +%s)
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE SYNCWARDEN_NOW_HOUR SYNCWARDEN_NOW_EPOCH
    output=$(run_integration_cli "$tmp/home" "$config" --scheduled 2>&1)
    rc=$?
    assert_eq '0' "$rc" 'unconfigured scheduled hour exits zero'
    assert_contains 'No SyncWarden task is due' "$output" 'unconfigured hour explains no-op'
    assert_file_not_exists "$FAKE_RSYNC_ARGS_FILE" 'unconfigured hour invokes no rsync'

    SYNCWARDEN_NOW_HOUR=3
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-11 03:00:00 +0000' +%s)
    export SYNCWARDEN_NOW_HOUR SYNCWARDEN_NOW_EPOCH
    run_integration_cli "$tmp/home" "$config" --scheduled >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'configured scheduled hour runs successfully'
    args=$(<"$FAKE_RSYNC_ARGS_FILE")
    assert_contains 'one.example:/srv/data/' "$args" 'scheduled run includes first enabled server'
    assert_not_contains 'two.example:/srv/data/' "$args" 'scheduled run excludes disabled server'
    assert_contains 'three.example:/srv/data/' "$args" 'scheduled run includes later enabled server'

    state_file=$(find "$tmp/home/state/schedule" -maxdepth 1 -type f -name '*.state' -print -quit)
    assert_file_exists "$state_file" 'scheduled run writes a state record'
    state_content=$(<"$state_file")
    assert_contains 'status=SUCCESS' "$state_content" 'schedule state records batch status'
    assert_contains 'hour=3' "$state_content" 'schedule state records executed hour'
    assert_eq '' "$(find "$tmp/home/state/schedule" -maxdepth 1 -type f -name '*.tmp' -print)" 'schedule state leaves no temporary file'

    first_count=$(wc -l <"$FAKE_RSYNC_ARGS_FILE")
    output=$(run_integration_cli "$tmp/home" "$config" --scheduled 2>&1)
    rc=$?
    second_count=$(wc -l <"$FAKE_RSYNC_ARGS_FILE")
    assert_eq '0' "$rc" 'repeated invocation of the same schedule slot is a safe no-op'
    assert_contains 'already completed' "$output" 'repeated schedule slot explains why it was skipped'
    assert_eq "$first_count" "$second_count" 'repeated schedule slot does not invoke rsync again'
}

test_disabled_server_is_manually_callable_and_dry_run_is_read_only() {
    local tmp config payload rc args
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"

    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/manual-args"
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE SYNCWARDEN_NOW_EPOCH
    run_integration_cli "$tmp/home" "$config" two --dry-run >/dev/null
    rc=$?
    args=$(<"$FAKE_RSYNC_ARGS_FILE")
    assert_eq '0' "$rc" 'disabled server remains callable manually'
    assert_contains 'two.example:/srv/data/' "$args" 'manual dry-run targets disabled server by explicit ID'
    assert_file_not_exists "$tmp/home/logs/success-2026-07.log" 'dry-run writes no monthly success log'
    assert_file_not_exists "$tmp/home/logs/failure-2026-07.log" 'dry-run writes no monthly failure log'
    assert_file_not_exists "$tmp/home/state/last-status/two.status" 'dry-run writes no last-status state'
    assert_file_not_exists "$tmp/home/state/archive-index/two.list" 'dry-run writes no archive index'
    unset SYNCWARDEN_NOW_EPOCH
}

test_dry_run_prints_failure_reason_without_writing_failure_log() {
    local tmp config payload output rc
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"

    FAKE_SSH_MODE=host-key
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/dry-failure-args"
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE SYNCWARDEN_NOW_EPOCH
    output=$(run_integration_cli "$tmp/home" "$config" one --dry-run 2>&1)
    rc=$?
    assert_eq '1' "$rc" 'dry-run returns failure when SSH preflight fails'
    assert_contains 'HOST_KEY_CHANGED' "$output" 'dry-run prints its classified failure reason to the terminal'
    assert_file_not_exists "$tmp/home/logs/failure-2026-07.log" 'dry-run failure still writes no monthly failure log'
    unset SYNCWARDEN_NOW_EPOCH
}

test_archive_only_cli_writes_styled_log_and_status() {
    local tmp config payload rc success_content status_content
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload/one/data"
    printf 'mirror payload\n' >"$payload/one/data/file.txt"
    write_orchestration_config "$config" "$payload"

    FAKE_ZIP_MODE=success
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-11 18:42:16 +0000' +%s)
    export FAKE_ZIP_MODE SYNCWARDEN_NOW_EPOCH
    run_integration_cli "$tmp/home" "$config" --archive one >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'archive-only CLI succeeds'
    success_content=$(<"$tmp/home/logs/success-2026-07.log")
    assert_contains 'ARCHIVE ONLY' "$success_content" 'archive-only success is logged with its mode'
    assert_contains '================================================================================' "$success_content" 'archive-only log has visible separators'
    status_content=$(<"$tmp/home/state/last-status/one.status")
    assert_contains 'mode=ARCHIVE_ONLY' "$status_content" 'archive-only writes last-status mode'
    assert_contains 'status=SUCCESS' "$status_content" 'archive-only writes successful status'
}

test_real_modes_use_monthly_logs_and_dry_run_skips_maintenance() {
    local tmp config payload rc file_count run_count
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_OUTPUT='__SYNCWARDEN_CHANGE__:>f+++++++++|1024'
    FAKE_RSYNC_ARGS_FILE="$tmp/args"
    export SYNCWARDEN_NOW_EPOCH FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE

    mkdir -p "$tmp/dry-home/logs/rotated"
    printf 'expired\n' >"$tmp/dry-home/logs/success-2026-01.log"
    run_integration_cli "$tmp/dry-home" "$config" one --dry-run >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'dry-run succeeds'
    assert_file_exists "$tmp/dry-home/logs/success-2026-01.log" 'dry-run does not clean expired logs'
    assert_file_not_exists "$tmp/dry-home/logs/success-2026-07.log" 'dry-run creates no monthly success log'

    run_integration_cli "$tmp/real-home" "$config" one >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'real manual run succeeds'
    assert_file_exists "$tmp/real-home/logs/success-2026-07.log" 'real manual run writes current monthly success log'
    assert_file_not_exists "$tmp/real-home/logs/success.log" 'legacy undated success log is no longer created'
    run_integration_cli "$tmp/real-home" "$config" one >/dev/null
    rc=$?
    file_count=$(find "$tmp/real-home/logs" -maxdepth 1 -type f -name 'success-2026-07.log' | wc -l)
    run_count=$(grep -c '^RUN START$' "$tmp/real-home/logs/success-2026-07.log")
    assert_eq '0' "$rc" 'second same-month manual run succeeds'
    assert_eq '1' "$file_count" 'same-month runs use one success file'
    assert_eq '2' "$run_count" 'same-month runs append two separated run blocks'
    assert_file_not_exists "$tmp/real-home/logs/failure-2026-07.log" 'all-success month does not create an empty failure log'
    unset FAKE_RSYNC_OUTPUT SYNCWARDEN_NOW_EPOCH
}

test_log_maintenance_warning_changes_exit_without_hiding_server_failure() {
    local tmp config payload rc content
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    prepare_orchestration_test "$tmp/home" "$config" || return
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    export SYNCWARDEN_NOW_EPOCH
    refresh_log_paths
    printf 'old\n' >"$LOG_DIR/success-2026-06.log"
    printf 'collision\n' >"$ROTATED_LOG_DIR/success-2026-06.log.gz"
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_OUTPUT='__SYNCWARDEN_CHANGE__:>f+++++++++|1024'
    FAKE_RSYNC_ARGS_FILE="$tmp/args"
    export FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE
    run_batch MANUAL 0 one >/dev/null
    rc=$?
    content=$(<"$FAILURE_LOG")
    assert_eq '2' "$rc" 'maintenance warning raises an otherwise successful batch to warning'
    assert_contains 'LOG MAINTENANCE' "$content" 'maintenance warning is written to failure log'
    assert_file_exists "$LOG_DIR/success-2026-06.log" 'collision preserves the old source log'

    configure_home_paths "$tmp/failure-home"
    ensure_home_layout
    load_and_validate "$config"
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    refresh_log_paths
    printf 'old\n' >"$LOG_DIR/success-2026-06.log"
    printf 'collision\n' >"$ROTATED_LOG_DIR/success-2026-06.log.gz"
    SSH_BIN="$TEST_DIR/fakes/ssh"
    RSYNC_BIN="$TEST_DIR/fakes/rsync"
    FAKE_SSH_MODE=host-key
    export FAKE_SSH_MODE
    run_batch MANUAL 0 one >/dev/null 2>&1
    rc=$?
    assert_eq '1' "$rc" 'existing server failure remains failure when maintenance also warns'
    unset FAKE_RSYNC_OUTPUT SYNCWARDEN_NOW_EPOCH
}

test_archive_and_scheduled_maintenance_boundaries() {
    local tmp config payload rc scheduled_content
    tmp=$(make_temp_dir)
    config="$tmp/integration.conf"
    payload="$tmp/payload"
    mkdir -p "$payload/one/data"
    printf 'mirror\n' >"$payload/one/data/file.txt"
    write_orchestration_config "$config" "$payload"
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    FAKE_ZIP_MODE=success
    export SYNCWARDEN_NOW_EPOCH FAKE_ZIP_MODE

    mkdir -p "$tmp/archive-home/logs/rotated"
    printf 'expired\n' >"$tmp/archive-home/logs/success-2026-01.log"
    run_integration_cli "$tmp/archive-home" "$config" -a one >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'archive-only succeeds before maintenance'
    assert_file_not_exists "$tmp/archive-home/logs/success-2026-01.log" 'archive-only triggers expired managed-log cleanup'

    mkdir -p "$tmp/due-home/logs/rotated"
    printf 'expired\n' >"$tmp/due-home/logs/failure-2026-01.log"
    SYNCWARDEN_NOW_HOUR=3
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 03:00:00 +0000' +%s)
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_OUTPUT='__SYNCWARDEN_CHANGE__:>f+++++++++|1024'
    FAKE_RSYNC_ARGS_FILE="$tmp/due-args"
    export SYNCWARDEN_NOW_HOUR SYNCWARDEN_NOW_EPOCH FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_OUTPUT FAKE_RSYNC_ARGS_FILE
    run_integration_cli "$tmp/due-home" "$config" -s >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'due scheduled run succeeds'
    scheduled_content=$(<"$tmp/due-home/logs/success-2026-07.log")
    assert_contains 'Mode     : SCHEDULED' "$scheduled_content" 'scheduled log identifies its mode'
    assert_contains 'transferred=1.00KiB' "$scheduled_content" 'scheduled log records readable transferred size'
    assert_matches 'avg_speed=[0-9]+([.][0-9]+)?(B|KiB|MiB|GiB|TiB|PiB)/s' "$scheduled_content" 'scheduled log records readable average speed'
    assert_file_not_exists "$tmp/due-home/logs/failure-2026-01.log" 'real scheduled run triggers expired managed-log cleanup'

    mkdir -p "$tmp/noop-home/logs/rotated"
    printf 'expired\n' >"$tmp/noop-home/logs/failure-2026-01.log"
    SYNCWARDEN_NOW_HOUR=6
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 06:00:00 +0000' +%s)
    export SYNCWARDEN_NOW_HOUR SYNCWARDEN_NOW_EPOCH
    run_integration_cli "$tmp/noop-home" "$config" -s >/dev/null
    rc=$?
    assert_eq '0' "$rc" 'not-due scheduled invocation is a safe no-op'
    assert_file_exists "$tmp/noop-home/logs/failure-2026-01.log" 'scheduled no-op does not run maintenance'
    unset SYNCWARDEN_NOW_HOUR SYNCWARDEN_NOW_EPOCH FAKE_RSYNC_OUTPUT
}

test_scheduled_private_key_failure_is_isolated_per_server() {
    local tmp config payload bad_key rc args failure_log failure_content epoch month
    tmp=$(make_temp_dir)
    config="$tmp/key-isolation.conf"
    payload="$tmp/payload"
    bad_key="$tmp/id_bad"
    mkdir -p "$payload"
    printf 'bad private key permissions\n' >"$bad_key"
    chmod 0644 "$bad_key"
    write_key_isolation_config "$config" "$payload" "$TEST_PRIVATE_KEY" "$bad_key"

    epoch=$(date -d '2026-07-12 03:00:00 +0000' +%s)
    month=$(date -d "@$epoch" +%Y-%m)
    SYNCWARDEN_NOW_EPOCH=$epoch
    SYNCWARDEN_NOW_HOUR=3
    FAKE_SSH_MODE=success
    FAKE_RSYNC_MODE=success
    FAKE_RSYNC_ARGS_FILE="$tmp/rsync-args"
    export SYNCWARDEN_NOW_EPOCH SYNCWARDEN_NOW_HOUR FAKE_SSH_MODE FAKE_RSYNC_MODE FAKE_RSYNC_ARGS_FILE

    run_integration_cli "$tmp/home" "$config" --scheduled >/dev/null 2>&1
    rc=$?
    args=''
    [[ -f "$FAKE_RSYNC_ARGS_FILE" ]] && args=$(<"$FAKE_RSYNC_ARGS_FILE")
    failure_log="$tmp/home/logs/failure-$month.log"
    failure_content=''
    [[ -f "$failure_log" ]] && failure_content=$(<"$failure_log")
    assert_eq '1' "$rc" 'one invalid scheduled private key makes the batch fail'
    assert_contains 'one.example:/srv/data/' "$args" 'first valid-key server still runs'
    assert_not_contains 'two.example:/srv/data/' "$args" 'invalid-key server never reaches rsync'
    assert_contains 'three.example:/srv/data/' "$args" 'later valid-key server still runs'
    assert_contains 'PRIVATE_KEY_FAILED' "$failure_content" 'per-server private-key failure is logged explicitly'
    unset SYNCWARDEN_NOW_EPOCH SYNCWARDEN_NOW_HOUR
}

test_archive_only_does_not_require_ssh_private_key() {
    local tmp config payload missing_key epoch final rc
    tmp=$(make_temp_dir)
    config="$tmp/archive-no-key.conf"
    payload="$tmp/payload"
    missing_key="$tmp/id_missing"
    mkdir -p "$payload/one/data"
    printf 'mirror payload\n' >"$payload/one/data/file.txt"
    write_key_isolation_config "$config" "$payload" "$missing_key" "$missing_key"

    epoch=$(date -d '2026-07-12 05:00:00 +0000' +%s)
    final="$payload/one/$(archive_basename data "$epoch")"
    SYNCWARDEN_NOW_EPOCH=$epoch
    FAKE_ZIP_MODE=success
    export SYNCWARDEN_NOW_EPOCH FAKE_ZIP_MODE
    run_integration_cli "$tmp/home" "$config" --archive one >/dev/null 2>&1
    rc=$?
    assert_eq '0' "$rc" 'archive-only succeeds without an SSH private key'
    assert_file_exists "$final" 'archive-only still creates the local verified ZIP'
    unset SYNCWARDEN_NOW_EPOCH
}

test_scheduled_cross_hour_writes_captured_slot() {
    local tmp config payload start_epoch end_epoch start_path end_path rc content
    tmp=$(make_temp_dir)
    config="$tmp/cross-hour.conf"
    payload="$tmp/payload"
    mkdir -p "$payload"
    write_orchestration_config "$config" "$payload"
    configure_home_paths "$tmp/home"
    CONFIG_FILE=$config
    start_epoch=$(date -d '2026-07-12 03:59:00 +0000' +%s)
    end_epoch=$(date -d '2026-07-12 04:01:00 +0000' +%s)
    SYNCWARDEN_NOW_EPOCH=$start_epoch
    SYNCWARDEN_NOW_HOUR=3
    export SYNCWARDEN_NOW_EPOCH SYNCWARDEN_NOW_HOUR
    start_path="$SCHEDULE_STATE_DIR/$(date -d "@$start_epoch" +%Y-%m-%d)_03.state"
    end_path="$SCHEDULE_STATE_DIR/$(date -d "@$end_epoch" +%Y-%m-%d)_04.state"

    (
        run_batch() {
            SYNCWARDEN_NOW_EPOCH=$end_epoch
            SYNCWARDEN_NOW_HOUR=4
            RUN_ID='cross-hour-test'
            export SYNCWARDEN_NOW_EPOCH SYNCWARDEN_NOW_HOUR RUN_ID
            return 0
        }
        main --scheduled >/dev/null 2>&1
    )
    rc=$?
    assert_eq '0' "$rc" 'cross-hour scheduled batch keeps its successful exit code'
    assert_file_exists "$start_path" 'scheduled batch writes the slot captured at start'
    assert_file_not_exists "$end_path" 'scheduled batch does not occupy the completion-hour slot'
    content=''
    [[ -f "$start_path" ]] && content=$(<"$start_path")
    assert_contains 'hour=3' "$content" 'captured schedule state records the starting hour'
    if schedule_slot_already_recorded "$start_path"; then
        pass 'duplicate check accepts the captured slot path'
    else
        fail 'duplicate check must use the captured slot path'
    fi
    unset SYNCWARDEN_NOW_EPOCH SYNCWARDEN_NOW_HOUR
}

run_integration_suite() {
    test_global_timeout_constants_and_single_wrapper
    test_manual_global_timeout_logs_and_cleans_up
    test_dry_run_global_timeout_preserves_zero_write
    test_real_modes_log_global_configuration_failure_and_readonly_modes_do_not
    test_real_modes_use_monthly_logs_and_dry_run_skips_maintenance
    test_log_maintenance_warning_changes_exit_without_hiding_server_failure
    test_archive_and_scheduled_maintenance_boundaries
    test_short_action_aliases_dispatch_safely
    test_cli_lock_contention_returns_75
    test_scheduled_cli_noop_and_due_state
    test_disabled_server_is_manually_callable_and_dry_run_is_read_only
    test_dry_run_prints_failure_reason_without_writing_failure_log
    test_archive_only_cli_writes_styled_log_and_status
    test_scheduled_private_key_failure_is_isolated_per_server
    test_archive_only_does_not_require_ssh_private_key
    test_scheduled_cross_hour_writes_captured_slot
}

prepare_log_test() {
    local home=$1
    configure_home_paths "$home"
    ensure_home_layout
    load_and_validate "$FIXTURE_DIR/base.conf"
    GLOBAL[log_retention_months]=6
    SYNCWARDEN_NOW_EPOCH=$(date -d '2026-07-12 09:00:00 +0000' +%s)
    export SYNCWARDEN_NOW_EPOCH
    refresh_log_paths
    GZIP_BIN=$(command -v gzip)
    RM_BIN=$(command -v rm)
    FIND_BIN=$(command -v find)
}

test_log_discovery_failure_is_fail_closed() {
    local tmp rc
    tmp=$(make_temp_dir)
    prepare_log_test "$tmp/home"
    printf 'expired\n' >"$LOG_DIR/failure-2026-01.log"
    FIND_BIN="$TEST_DIR/fakes/find"
    FAKE_REAL_FIND_BIN=$(command -v find)
    FAKE_FIND_MODE=partial-fail
    FAKE_FIND_PARTIAL_PATH="$LOG_DIR/failure-2026-01.log"
    export FAKE_REAL_FIND_BIN FAKE_FIND_MODE FAKE_FIND_PARTIAL_PATH

    maintain_monthly_logs >/dev/null 2>&1
    rc=$?
    assert_eq '2' "$rc" 'partial managed-log discovery becomes a warning'
    assert_file_exists "$LOG_DIR/failure-2026-01.log" 'partial discovery changes no managed log'
    assert_contains 'discovery' "$LOG_MAINTENANCE_MESSAGES" 'discovery failure has an explicit warning'

    unset FAKE_REAL_FIND_BIN FAKE_FIND_MODE FAKE_FIND_PARTIAL_PATH
    FIND_BIN=$(command -v find)
}

test_log_maintenance_compresses_retained_old_months_and_deletes_only_expired() {
    local tmp
    tmp=$(make_temp_dir)
    prepare_log_test "$tmp/home"
    printf 'current\n' >"$LOG_DIR/success-2026-07.log"
    printf 'june\n' >"$LOG_DIR/success-2026-06.log"
    printf 'february\n' >"$LOG_DIR/failure-2026-02.log"
    printf 'january\n' >"$LOG_DIR/success-2026-01.log"
    printf 'old gzip\n' >"$ROTATED_LOG_DIR/failure-2026-01.log.gz"
    maintain_monthly_logs
    assert_file_exists "$LOG_DIR/success-2026-07.log" 'current month remains uncompressed'
    assert_file_not_exists "$LOG_DIR/success-2026-06.log" 'retained old plain log is removed after compression'
    assert_file_exists "$ROTATED_LOG_DIR/success-2026-06.log.gz" 'retained June log is compressed'
    assert_file_exists "$ROTATED_LOG_DIR/failure-2026-02.log.gz" 'oldest retained February log is compressed'
    assert_file_not_exists "$LOG_DIR/success-2026-01.log" 'expired January plain log is deleted'
    assert_file_not_exists "$ROTATED_LOG_DIR/failure-2026-01.log.gz" 'expired January compressed log is deleted'
    assert_eq 'june' "$(gzip -dc "$ROTATED_LOG_DIR/success-2026-06.log.gz")" 'compressed content is valid'
}

test_log_maintenance_preserves_unmanaged_future_and_symlink_entries() {
    local tmp
    tmp=$(make_temp_dir)
    prepare_log_test "$tmp/home"
    printf 'legacy\n' >"$LOG_DIR/success.log"
    printf 'manual\n' >"$LOG_DIR/my-backup-2025-01.log"
    printf 'bad month\n' >"$LOG_DIR/success-2026-13.log"
    printf 'future\n' >"$LOG_DIR/success-2026-08.log"
    printf 'future gzip\n' >"$ROTATED_LOG_DIR/failure-2026-08.log.gz"
    mkdir "$LOG_DIR/failure-2025-01.log"
    ln -s /dev/null "$LOG_DIR/success-2025-01.log"
    ln -s /dev/null "$ROTATED_LOG_DIR/failure-2025-01.log.gz"
    maintain_monthly_logs
    assert_file_exists "$LOG_DIR/success.log" 'legacy success.log is preserved'
    assert_file_exists "$LOG_DIR/my-backup-2025-01.log" 'manual filename is preserved'
    assert_file_exists "$LOG_DIR/success-2026-13.log" 'invalid managed-looking month is preserved'
    assert_file_exists "$LOG_DIR/success-2026-08.log" 'future month is preserved'
    assert_file_exists "$ROTATED_LOG_DIR/failure-2026-08.log.gz" 'future compressed month is preserved'
    assert_dir_exists "$LOG_DIR/failure-2025-01.log" 'managed-looking directory is preserved'
    assert_symlink_exists "$LOG_DIR/success-2025-01.log" 'plain-log symlink is preserved'
    assert_symlink_exists "$ROTATED_LOG_DIR/failure-2025-01.log.gz" 'gzip symlink is preserved'
}

test_log_compression_failure_and_collision_preserve_source() {
    local tmp rc messages
    tmp=$(make_temp_dir)
    prepare_log_test "$tmp/home"
    printf 'june\n' >"$LOG_DIR/success-2026-06.log"
    GZIP_BIN="$TEST_DIR/fakes/gzip"
    FAKE_REAL_GZIP_BIN=$(command -v gzip)
    FAKE_GZIP_MODE=fail
    export FAKE_REAL_GZIP_BIN FAKE_GZIP_MODE
    maintain_monthly_logs >/dev/null 2>&1
    rc=$?
    assert_eq '2' "$rc" 'gzip failure is warning-only'
    assert_file_exists "$LOG_DIR/success-2026-06.log" 'gzip failure preserves source log'
    assert_eq '' "$(find "$ROTATED_LOG_DIR" -maxdepth 1 -name '*.part.gz' -print)" 'gzip failure leaves no part file'

    FAKE_GZIP_MODE=success
    printf 'existing gzip\n' >"$ROTATED_LOG_DIR/success-2026-06.log.gz"
    maintain_monthly_logs >/dev/null 2>&1
    rc=$?
    messages=$LOG_MAINTENANCE_MESSAGES
    assert_eq '2' "$rc" 'existing target is warning-only'
    assert_file_exists "$LOG_DIR/success-2026-06.log" 'existing gzip target never causes source overwrite or deletion'
    assert_contains 'already exists' "$messages" 'collision warning is explicit'
    unset FAKE_GZIP_MODE FAKE_REAL_GZIP_BIN
    GZIP_BIN=$(command -v gzip)
}

test_log_delete_failure_preserves_expired_file() {
    local tmp rc
    tmp=$(make_temp_dir)
    prepare_log_test "$tmp/home"
    printf 'expired\n' >"$LOG_DIR/failure-2026-01.log"
    RM_BIN="$TEST_DIR/fakes/rm"
    FAKE_RM_MODE=fail
    export FAKE_RM_MODE
    maintain_monthly_logs >/dev/null 2>&1
    rc=$?
    assert_eq '2' "$rc" 'expired-log deletion failure is warning-only'
    assert_file_exists "$LOG_DIR/failure-2026-01.log" 'failed deletion preserves expired log'
    unset FAKE_RM_MODE
    RM_BIN=$(command -v rm)
}

run_log_suite() {
    test_log_discovery_failure_is_fail_closed
    test_log_maintenance_compresses_retained_old_months_and_deletes_only_expired
    test_log_maintenance_preserves_unmanaged_future_and_symlink_entries
    test_log_compression_failure_and_collision_preserve_source
    test_log_delete_failure_preserves_expired_file
    unset SYNCWARDEN_NOW_EPOCH FAKE_GZIP_MODE FAKE_REAL_GZIP_BIN FAKE_RM_MODE
    GZIP_BIN=$(command -v gzip)
    RM_BIN=$(command -v rm)
    FIND_BIN=$(command -v find)
}

if [[ ! -r "$SCRIPT_PATH" ]]; then
    printf 'FAIL: production script is missing: %s\n' "$SCRIPT_PATH" >&2
    exit 1
fi

export SYNCWARDEN_LIB_MODE=1
# shellcheck source=../syncwarden.sh
source "$SCRIPT_PATH"

case "$CURRENT_SUITE" in
    parser) run_parser_suite ;;
    cli) run_cli_suite ;;
    retention) run_retention_suite ;;
    archive) run_archive_suite ;;
    transport) run_transport_suite ;;
    orchestration) run_orchestration_suite ;;
    logs) run_log_suite ;;
    integration) run_integration_suite ;;
    all)
        run_parser_suite
        run_cli_suite
        run_retention_suite
        run_archive_suite
        run_transport_suite
        run_orchestration_suite
        run_log_suite
        run_integration_suite
        ;;
    *) printf 'Unknown suite: %s\n' "$CURRENT_SUITE" >&2; exit 64 ;;
esac

printf '\nRESULT: %d assertions passed, %d failed, %d skipped\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
(( FAIL_COUNT == 0 ))
