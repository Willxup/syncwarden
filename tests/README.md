# SyncWarden test suite

**English** | [简体中文](README.zh.md)

The suite targets Bash 5 on GNU/Linux. It requires no Bats, Python, network
connection, or additional downloaded test dependencies.

## Running tests

Run from the project root:

```bash
bash tests/run_tests.sh all
```

You can also run individual groups:

```bash
bash tests/run_tests.sh parser
bash tests/run_tests.sh cli
bash tests/run_tests.sh i18n
bash tests/run_tests.sh retention
bash tests/run_tests.sh archive
bash tests/run_tests.sh transport
bash tests/run_tests.sh orchestration
bash tests/run_tests.sh logs
bash tests/run_tests.sh integration
```

## Isolation boundaries

- Each run creates an isolated temporary root with `mktemp` and removes it on exit.
- Fake commands replace external boundaries including SSH, rsync, ZIP, gzip, find, df, rm, timeout, and checksums.
- Configuration parsing, path safeguards, archive indexes, retention, logs, state, locking, retries, orchestration, and the CLI use real production functions.
- Tests do not connect to remote hosts, read real `syncwarden.conf` files, modify backup data, or touch crontab.
- One symlink preservation case uses real Info-ZIP. If real `zip` is unavailable, that case is reported as skipped; release validation requires it to run.

The final `passed`, `failed`, and `skipped` counts refer to assertions, not
independent test scenarios.

## Coverage

The suite covers:

- Strict INI parsing, default inheritance, and server overrides;
- Source and destination safety validation;
- Private key and SSH preflight error classification;
- Retries for transient errors and stopping on permanent errors;
- rsync mirrors, dry runs, code 24, transfer sizes, average speeds, and locale consistency;
- ZIP creation, verification, atomic promotion, and archive indexes;
- Retention of recent archives and the last archive of each month;
- Fail-closed cleanup and monthly log maintenance;
- State persistence, schedule slots, locking, and global timeouts;
- Sequential processing of multiple sources/servers and failure isolation;
- Long/short CLI options, concise help, and read-only query boundaries.

## Bilingual regression coverage

The test entry point selects English explicitly so an inherited `SYNCWARDEN_LANG`
does not affect assertions. The `i18n` group selects languages explicitly to test
English defaults, Chinese and its aliases, fallback values, Chinese status
explanations, literal format characters and user data, and read-only help/queries.

With fixed clocks, it compares persisted logs and state byte-for-byte across
languages. It also reuses deletion-argument, retry, archive-failure protection,
success/warning/failure exit-code, schedule deduplication, and global-timeout
regressions in Chinese mode. Language selection must not change backup behavior
or persisted formats. The `all` group includes `i18n`.
