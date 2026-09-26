# SyncWarden

**English** | [简体中文](README.zh.md)

> Maintain remote directory mirrors with rsync, with a verified ZIP snapshot before each real synchronization.

[![Bash 5+](https://img.shields.io/badge/Bash-5%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-GNU%2FLinux-blue)](#platform-and-dependencies)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

SyncWarden is a remote backup orchestration script for GNU/Linux. It uses SSH and
rsync to mirror remote files or directories locally. Before a synchronization can
delete or overwrite local files, it creates, verifies, and indexes a ZIP snapshot
of the existing mirror.

It is designed for server backups that need a simple, auditable recovery safeguard.
Manual and cron runs share the same configuration validation, SSH preflight,
archiving, synchronization, retry, timeout, logging, and state logic.

## Features

- **Protection before synchronization**: an existing mirror must be archived successfully and pass `zip -T` before real synchronization is allowed.
- **Mirror semantics**: `rsync --delete --delete-delay` makes the local mirror reflect the remote source's current state.
- **Verifiable archives**: after ZIP verification, the script computes SHA-256, promotes the archive atomically, and adds it to the managed index.
- **Path validation**: rejects root paths, paths directly below root, symbolic links, overlapping destinations, and sensitive system directories.
- **Fail-closed safeguards**: archive, index, discovery, or sorting failures prevent unsafe archive deletion or synchronization with deletion semantics.
- **Failure isolation**: a failed source or server does not prevent later servers from being processed.
- **One entry point**: manual runs, dry runs, archives, scheduled runs, checks, and status queries use the same script.
- **Strict configuration**: INI configuration is never executed with `source` or `eval`.
- **No additional runtime libraries**: no Python, jq, yq, Bats, or downloaded runtime libraries are required.

## How it works

A real synchronization follows this sequence:

```text
Validate configuration and paths
              ↓
Acquire the global lock and run SSH preflight
              ↓
Check free disk space and inodes
              ↓
Create and verify a ZIP of the existing mirror
              ↓
Synchronize the mirror with rsync (including deletions)
              ↓
Write state atomically and append monthly logs
```

On the first synchronization, no local mirror exists, so ZIP creation is skipped.
Only the final destination directory component is created before rsync runs.
On later runs, a ZIP creation, verification, or promotion failure blocks that
source's synchronization.

## Quick start

### 1. Check dependencies

Use Bash 5+ on GNU/Linux. Confirm that the following commands are installed:

```bash
bash --version
ssh -V
rsync --version
timeout --version
flock --version
zip -v
```

### 2. Install the script

SyncWarden has no fixed installation directory. This is a generic example:

```bash
sudo install -d -m 0750 /opt/syncwarden
sudo install -m 0750 syncwarden.sh /opt/syncwarden/syncwarden.sh
sudo install -m 0640 example.conf /opt/syncwarden/syncwarden.conf
```

### 3. Edit the configuration

```bash
sudo editor /opt/syncwarden/syncwarden.conf
sudo chmod 0600 /opt/syncwarden/syncwarden.conf
```

Real configuration usually contains server addresses, accounts, paths, and private
key locations. Never commit `syncwarden.conf` or share it with unrelated parties.

### 4. Check the configuration

```bash
sudo /opt/syncwarden/syncwarden.sh --check
sudo /opt/syncwarden/syncwarden.sh --check --show-resolved
```

The second command shows the effective configuration after inheritance and
overrides, so you can review it before the first synchronization.

### 5. Run a dry run first

```bash
sudo /opt/syncwarden/syncwarden.sh sample-server --dry-run
```

Review the planned additions, updates, and deletions before running a real
synchronization:

```bash
sudo /opt/syncwarden/syncwarden.sh sample-server
```

## Configuration

See [`example.conf`](example.conf) for the complete template. It uses only reserved
domains and fictitious values.

Minimal configuration:

```ini
[global]
sync_hours=2,14
log_retention_months=6

[defaults]
scheduled_sync_enabled=yes
port=22
user=backup
key_file=/home/backup/.ssh/id_syncwarden
rsync_timeout_seconds=300
retry_count=1
retry_delays_seconds=60
owner=backup:backup
archive_recent_keep=7
archive_monthly_keep=6
min_free_space_mb=1024
min_free_inodes=5000

[server:sample-server]
host=source.example.net
name=Sample server
destination=/var/backups/syncwarden/sample-server
source=/srv/example-data
```

Configuration supports one level of inheritance:

```text
[defaults] → [server:ID]
```

### `[global]`

| Key | Description |
| --- | --- |
| `sync_hours` | Local hours when `--scheduled` may synchronize, separated by commas |
| `log_retention_months` | Number of calendar months of managed monthly logs to retain |

### `[defaults]` and server overrides

| Key | Description |
| --- | --- |
| `scheduled_sync_enabled` | Whether to include the server in scheduled runs; manual runs by ID are unaffected |
| `port` | SSH port |
| `user` | SSH user |
| `key_file` | Absolute path to the SSH private key |
| `rsync_timeout_seconds` | rsync timeout in seconds without protocol I/O |
| `retry_count` | Number of retries for transient errors |
| `retry_delays_seconds` | Delays in seconds before retries, separated by commas |
| `owner` | `USER:GROUP` for mirrors and new ZIP archives |
| `archive_recent_keep` | Number of recent successful archives to retain |
| `archive_monthly_keep` | Number of calendar months whose last archives are retained |
| `min_free_space_mb` | Minimum free space on the destination filesystem |
| `min_free_inodes` | Minimum free inodes on the destination filesystem |

### `[server:ID]`

Each server must explicitly specify:

- `host`
- `destination`
- At least one `source`

`name` is optional and defaults to the server ID. Use multiple `source=` lines for
multiple remote paths. The last component of each source becomes its local mirror
directory name, so sources on the same server must have distinct basenames.

The script uses its own directory as the control directory by default. You can
also set:

- `SYNCWARDEN_HOME`: overrides the control directory for configuration, logs, state, locks, and temporary files.
- `SYNCWARDEN_CONFIG`: specifies an absolute configuration file path.

Mirrors and ZIP archives live in each server's `destination`, outside the control
directory.

## Commands

| Command | Purpose |
| --- | --- |
| `syncwarden.sh SERVER_ID` | Synchronize the specified server |
| `syncwarden.sh SERVER_ID --dry-run` | Preview changes without modifying mirrors or managed state |
| `syncwarden.sh --archive SERVER_ID` | Archive existing mirrors without connecting to the remote server |
| `syncwarden.sh --scheduled` | Run due scheduled synchronizations, for use with cron |
| `syncwarden.sh --check` | Check configuration, dependencies, and private keys |
| `syncwarden.sh --check --show-resolved` | Check and display the effective configuration |
| `syncwarden.sh --list` | List server IDs, names, and scheduled status |
| `syncwarden.sh --status SERVER_ID` | Show the latest non-dry-run status |
| `syncwarden.sh --help` | Show brief help |

Short options are also supported: `-n`, `-a`, `-s`, `-c`, `-r`, `-l`, `-t`, `-h`.

Running without arguments returns a usage error; it does not synchronize all
servers. For a dry run, the server ID must come first:

```bash
syncwarden.sh sample-server --dry-run
```

## Language

English is the default for help, diagnostics, queries, and terminal summaries.
Select Simplified Chinese explicitly with `SYNCWARDEN_LANG=zh`:

```bash
SYNCWARDEN_LANG=zh ./syncwarden.sh --help
SYNCWARDEN_LANG=zh ./syncwarden.sh --list
SYNCWARDEN_LANG=zh ./syncwarden.sh --status sample-server
SYNCWARDEN_LANG=en ./syncwarden.sh sample-server --dry-run
```

The same setting applies to manual synchronization, archive-only runs, and
scheduled runs. To keep Chinese for the current shell, use
`export SYNCWARDEN_LANG=zh`. With sudo, pass the setting explicitly:

```bash
sudo env SYNCWARDEN_LANG=zh /opt/syncwarden/syncwarden.sh --check
```

`en` and `zh` are the recommended values. Chinese aliases `zh-CN`, `zh_CN`,
`zh_CN.UTF-8`, and `zh_CN.utf8` are also accepted. An unset, empty, or unsupported
value falls back to English. Host `LANG`/`LC_*` settings do not select the display
language. Do not add a language key to the INI configuration.

| Surface | Language behavior |
| --- | --- |
| Help, usage errors, configuration checks, and runtime diagnostics | English by default; Chinese when selected |
| Server list, status query, dry-run headings, and run summaries | Localized labels and explanations; canonical status/reason codes remain visible |
| Resolved configuration (`--show-resolved`) | Configuration keys and values remain unchanged; only the introductory message is localized |
| Persisted logs, state, schedule slots, archive indexes, and filenames | Keep their existing canonical formats, independent of the display language |
| Server names, paths, and external SSH/rsync/ZIP output | Preserved verbatim; not translated or reinterpreted |

Language selection changes presentation only. It does not change validation,
synchronization/deletion behavior, archive protection, retention, retries,
timeouts, scheduling, or exit codes. Log records remain in English so existing
log readers continue to work. Chinese status views explain known codes, for
example `失败 (FAILED)` and `SSH 主机密钥已变化 (HOST_KEY_CHANGED)`, without rewriting
stored records. Unknown fields and codes remain readable as-is.

Both [English](README.md) and [Chinese](README.zh.md) documentation cover the
same behavior. [`example.conf`](example.conf) keeps English-first bilingual
comments in a single template. The script remains a single file and needs no
translation framework or extra language files.

## Scheduled runs

Cron can invoke the script every hour; `sync_hours` determines whether a
synchronization is due:

```cron
0 * * * * /opt/syncwarden/syncwarden.sh --scheduled >/dev/null 2>&1
```

The script records completed hourly slots to prevent duplicate runs in the same
hour. SyncWarden does not create, modify, or delete cron entries.

## Safety model

`--delete` is part of the fixed mirror semantics: objects deleted remotely are
also deleted from the current local mirror. The pre-sync ZIP preserves the old
state for recovery, so archiving must not be bypassed or made best-effort.

### Destination safeguards

- Must be an absolute path, neither `/` nor directly below `/`.
- Its immediate parent directory must already exist; only the final component may be created.
- Existing path components and the destination itself must not be symbolic links.
- Different servers' destinations must not be equal, nested, or overlap after canonicalization.
- Destinations must not overlap the SyncWarden control directory or reside in sensitive system directory trees.
- Sources must be remote absolute paths using safe characters and must not be the remote root.

### SSH host identity

The script uses `StrictHostKeyChecking=accept-new`. When first connecting to an
unknown host, OpenSSH may update the current user's `known_hosts`. If a recorded
host key changes, the connection is rejected. The script does not automatically
remove old entries or disable host key checking.

### Dry-run boundaries

A dry run checks configuration, private keys, capacity, SSH, and remote sources,
then executes `rsync --dry-run --itemize-changes`. It does not:

- Create ZIP archives;
- Modify mirrors;
- Write managed logs, state, archive indexes, or schedule slots;
- Clean up archives or logs.

## ZIP retention

The default retention set is:

```text
The 7 most recent successful archives
∪
The last successful archive in each of the current and 5 preceding calendar months
```

Automatic cleanup only handles ZIPs registered in the managed index, located in
the expected directory, with strictly matching names, and stored as regular,
non-symlink files. Manual files, unindexed files, other naming formats, and
symbolic links are not deleted.

Old archives are cleaned up only after a new archive is successfully verified.
Index, sorting, or discovery errors fail closed and preserve existing files.

## Logs and state

Managed files in the control directory:

```text
logs/success-YYYY-MM.log    Successful runs
logs/failure-YYYY-MM.log    Warnings and failures
logs/rotated/*.log.gz       Compressed logs from closed months
state/last-status/          Latest non-dry-run status
state/schedule/             Completed schedule slots
state/archive-index/        Verified archive indexes
state/syncwarden.lock       Global process lock
tmp/                        Managed temporary files
```

Successful manual and scheduled runs log created, updated, deleted, attempts,
`transferred`, and `avg_speed`. Transfer size and speed use readable units such as
KiB, MiB, and GiB. When retries occur, transfer size and average speed describe
only the final rsync attempt. Each attempt resets its counters and timer; ZIP
archiving, preflight checks, and retry delays are excluded. `attempts` still
records the actual number of attempts in the run. Logs do not retain rsync's
per-file names. Monthly logs are cleaned up by calendar month; manually named
logs are left untouched.

### rsync code 24

Code 24 means files or directories disappeared from an active source before
scanning, opening, or transfer, for example when a running application deletes or
renames temporary files. SyncWarden treats this as normal eventual consistency
for a live mirror:

- The source, server, and batch remain `SUCCESS`;
- No retry is performed;
- No WARNING or failure log is generated;
- Observed change counts are retained with `complete=yes`, meaning the run completed under the continuous mirroring policy.

### Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | Success or safe no-op |
| `1` | At least one failure, or required logs/state could not be persisted |
| `2` | WARNING only |
| `64` | Command-line usage error |
| `69` | Bash major version is below 5 |
| `75` | Another process holds the global lock |
| `124` | The fixed five-hour global runtime limit was exceeded |

Servers are processed sequentially; a failed server does not block later servers.

## Platform and dependencies

SyncWarden supports **Bash 5+ on GNU/Linux**. The BSD versions of `date`, `readlink`,
`stat`, and other commands shipped with macOS differ from GNU tools, so macOS is
not currently supported.

Runtime dependencies:

- Bash 5+
- OpenSSH client
- rsync
- GNU coreutils, including `timeout`, `sha256sum`, `stat`, `df`, and `date`
- util-linux `flock`
- Info-ZIP `zip`
- `gzip`, `find`, `sort`, `awk`, `sed`, and `grep`

The script does not install software automatically.

## Tests

The full suite uses temporary directories and fake SSH, rsync, ZIP, and other
command boundaries. It does not connect to real servers, read real configuration,
modify backups, or touch crontab.

Run on GNU/Linux:

```bash
bash tests/run_tests.sh all
```

See [`tests/README.md`](tests/README.md) for test groups, isolation boundaries, and
coverage.

## FAQ

### Why must a ZIP be created before synchronization?

An rsync mirror deletes objects that no longer exist remotely. The pre-sync ZIP
preserves the local mirror's state before those changes. If ZIP creation or
verification fails, the script blocks that synchronization with deletion semantics.

### Why is there no ZIP on the first synchronization?

There is no old mirror to archive on the first run. The script creates the final
destination directory component and starts synchronization. From the second real
synchronization onward, it archives the existing mirror first.

### Why must the destination's parent directory already exist?

This protects against path typos and `--delete` affecting an unintended location.
The script creates only the final directory component, not the entire path.

### Does code 24 mean the backup failed?

No. It means a file or directory disappeared from an active source before
scanning, opening, or transfer. SyncWarden treats this as success and records
`complete=yes`. This means the run completed under the continuous mirroring
policy; it does not mean an atomic point-in-time snapshot of the source was taken.

### Is a dry run guaranteed to write no files at all?

It does not write SyncWarden mirrors, ZIPs, logs, or state. However, when first
connecting to an unknown SSH host, OpenSSH's `accept-new` may update the current
user's `known_hosts`.

### Can I run it on macOS?

macOS is not currently supported. Run and validate it on Linux with Bash 5 and the
full GNU toolchain.

## License

SyncWarden is licensed under the [MIT License](LICENSE).
