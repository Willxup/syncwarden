# SyncWarden

> 用 rsync 维护远程目录镜像，并在每次真实同步前创建经过验证的 ZIP 快照。

[![Bash 5+](https://img.shields.io/badge/Bash-5%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![平台](https://img.shields.io/badge/平台-GNU%2FLinux-blue)](#平台与依赖)
[![许可证](https://img.shields.io/badge/许可证-MIT-green)](LICENSE)

SyncWarden 是一个面向 GNU/Linux 的远程备份编排脚本。它通过 SSH 和 rsync
把远程文件或目录同步为本地镜像，并在可能删除或覆盖本地文件之前，为已有镜像
创建、校验并登记 ZIP 快照。

它适合需要简单、可审计且具备恢复保护的服务器备份场景。手动运行和 cron
定时运行共用同一套配置校验、SSH 预检、归档、同步、重试、超时、日志和状态逻辑。

## 核心特性

- **同步前保护**：已有镜像必须先成功创建 ZIP，并通过 `zip -T` 校验，才允许执行真实同步。
- **真实镜像语义**：使用 `rsync --delete --delete-delay`，让本地镜像反映远端当前状态。
- **归档可验证**：ZIP 校验成功后计算 SHA-256，再以原子方式提升并写入受管索引。
- **安全路径校验**：拒绝根目录、根目录直属路径、符号链接、目标嵌套和危险系统目录。
- **失败关闭**：归档、索引、扫描或排序异常时不删除旧归档，也不执行带删除语义的同步。
- **失败隔离**：单个 source 或服务器失败，不会阻止后续服务器继续处理。
- **统一入口**：手动、dry-run、归档、定时、检查和状态查询全部由一个脚本完成。
- **严格配置**：INI 配置不会通过 `source` 或 `eval` 执行。
- **无运行库依赖**：不需要 Python、jq、yq、Bats 或下载额外运行库。

## 工作原理

一次真实同步会按以下顺序执行：

```text
配置与路径校验
      ↓
全局锁与 SSH 预检
      ↓
检查磁盘空间和 inode
      ↓
为已有镜像创建并验证 ZIP
      ↓
rsync 镜像同步（包含删除语义）
      ↓
原子写入状态并追加月度日志
```

第一次同步时还没有本地镜像，因此会跳过 ZIP，只创建目标的最后一级目录并执行
rsync。后续同步如果 ZIP 创建、校验或提升失败，该 source 的同步会被阻止。

## 快速开始

### 1. 检查依赖

运行环境需要 Bash 5+ 和 GNU/Linux。确认下列命令已经安装：

```bash
bash --version
ssh -V
rsync --version
timeout --version
flock --version
zip -v
```

### 2. 安装脚本

SyncWarden 不绑定固定安装目录。下面只是一个通用示例：

```bash
sudo install -d -m 0750 /opt/syncwarden
sudo install -m 0750 syncwarden.sh /opt/syncwarden/syncwarden.sh
sudo install -m 0640 example.conf /opt/syncwarden/syncwarden.conf
```

### 3. 编辑配置

```bash
sudo editor /opt/syncwarden/syncwarden.conf
sudo chmod 0600 /opt/syncwarden/syncwarden.conf
```

真实配置通常包含服务器地址、账号、路径和私钥位置。不要把
`syncwarden.conf` 提交到版本库或发送给无关人员。

### 4. 检查配置

```bash
sudo /opt/syncwarden/syncwarden.sh --check
sudo /opt/syncwarden/syncwarden.sh --check --show-resolved
```

第二条命令会显示继承和覆盖后的最终配置，适合在首次同步前核对。

### 5. 先执行 dry-run

```bash
sudo /opt/syncwarden/syncwarden.sh sample-server --dry-run
```

确认拟新增、拟更新和拟删除的内容符合预期后，再执行真实同步：

```bash
sudo /opt/syncwarden/syncwarden.sh sample-server
```

## 配置说明

完整模板见 [`example.conf`](example.conf)。该文件只使用保留域名和虚构值。

最小配置示例：

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
name=示例服务器
destination=/var/backups/syncwarden/sample-server
source=/srv/example-data
```

配置只支持一层继承：

```text
[defaults] → [server:ID]
```

### `[global]`

| 字段 | 说明 |
| --- | --- |
| `sync_hours` | `--scheduled` 可以执行同步的本地小时，多个小时用逗号分隔 |
| `log_retention_months` | 受管月度日志保留的自然月数量 |

### `[defaults]` 和服务器覆盖项

| 字段 | 说明 |
| --- | --- |
| `scheduled_sync_enabled` | 是否参加定时同步；不影响按 ID 手动执行 |
| `port` | SSH 端口 |
| `user` | SSH 用户 |
| `key_file` | SSH 私钥绝对路径 |
| `rsync_timeout_seconds` | rsync 连续无协议 I/O 超时秒数 |
| `retry_count` | 瞬时错误重试次数 |
| `retry_delays_seconds` | 各次重试前等待秒数，用逗号分隔 |
| `owner` | 镜像和新 ZIP 使用的 `用户:组` |
| `archive_recent_keep` | 保留的最近成功归档数量 |
| `archive_monthly_keep` | 保留月末归档的自然月数量 |
| `min_free_space_mb` | 目标文件系统最小可用空间 |
| `min_free_inodes` | 目标文件系统最小可用 inode 数量 |

### `[server:ID]`

每个服务器必须显式配置：

- `host`
- `destination`
- 至少一个 `source`

`name` 可省略，默认使用服务器 ID。多个远程路径使用多行 `source=`。每个
source 的最后一级名称会成为本地镜像目录名，因此同一服务器内不能出现相同 basename。

脚本默认以自身所在目录作为控制目录，也支持：

- `SYNCWARDEN_HOME`：覆盖配置、日志、状态、锁和临时文件所在的控制目录。
- `SYNCWARDEN_CONFIG`：指定配置文件的绝对路径。

镜像和 ZIP 位于各服务器的 `destination`，不属于控制目录。

## 命令

| 命令 | 用途 |
| --- | --- |
| `syncwarden.sh SERVER_ID` | 真实同步指定服务器 |
| `syncwarden.sh SERVER_ID --dry-run` | 预览变化，不修改镜像和受管状态 |
| `syncwarden.sh --archive SERVER_ID` | 只归档已有镜像，不连接远程服务器 |
| `syncwarden.sh --scheduled` | 执行到期的定时同步，供 cron 调用 |
| `syncwarden.sh --check` | 检查配置、依赖和私钥 |
| `syncwarden.sh --check --show-resolved` | 检查并显示最终解析配置 |
| `syncwarden.sh --list` | 列出服务器 ID、名称和定时状态 |
| `syncwarden.sh --status SERVER_ID` | 查看最近一次非 dry-run 状态 |
| `syncwarden.sh --help` | 显示简短帮助 |

同时支持短参数：`-n`、`-a`、`-s`、`-c`、`-r`、`-l`、`-t`、`-h`。

无参数调用会返回用法错误，不会同步全部服务器。dry-run 的既定语法是服务器 ID
在前：

```bash
syncwarden.sh sample-server --dry-run
```

## 定时运行

可以让 cron 每小时唤醒一次脚本，再由 `sync_hours` 判断当前小时是否需要执行：

```cron
0 * * * * /opt/syncwarden/syncwarden.sh --scheduled >/dev/null 2>&1
```

脚本会记录已完成的小时槽位，防止同一小时重复执行。SyncWarden 自身不会创建、
修改或删除 cron。

## 安全模型

`--delete` 是固定的镜像语义：远端已经删除的对象也会从当前本地镜像中删除。
同步前 ZIP 是保留旧状态的恢复层，因此不能把归档步骤绕过或改成尽力而为。

### destination 保护规则

- 必须是绝对路径，不能是 `/`，也不能直接位于 `/` 下。
- 直接父目录必须提前存在；脚本只允许创建最后一级目录。
- 已有路径组件和 destination 本身不能是符号链接。
- 不同服务器的目标不能相等、嵌套或规范化后重合。
- 目标不能与 SyncWarden 控制目录相交，也不能位于敏感系统目录树。
- source 必须是安全字符组成的远程绝对路径，不能是远程根目录。

### SSH 主机身份

脚本使用 `StrictHostKeyChecking=accept-new`。首次连接未知主机时，OpenSSH 可能写入
当前用户的 `known_hosts`。已经记录的主机密钥发生变化时，连接会被拒绝；脚本
不会自动删除旧记录或关闭主机密钥校验。

### dry-run 边界

dry-run 会执行配置、私钥、容量、SSH 和远程 source 预检，并运行
`rsync --dry-run --itemize-changes`。它不会：

- 创建 ZIP；
- 修改镜像；
- 写入受管日志、状态、归档索引或调度槽位；
- 执行归档或日志清理。

## ZIP 保留策略

默认保留集合是：

```text
最近 7 份成功归档
∪
当前自然月及之前 5 个自然月中，每月最后一份成功归档
```

自动清理只处理已经登记在受管索引中、位于预期目录、名称严格匹配且为普通
非符号链接文件的 ZIP。人工文件、未索引文件、不同命名格式和符号链接不会被删除。

只有新归档成功验证后才会清理旧归档。索引、排序或扫描异常时会 fail-closed，
保留旧文件。

## 日志与状态

控制目录中的受管文件：

```text
logs/success-YYYY-MM.log    成功运行
logs/failure-YYYY-MM.log    警告和失败
logs/rotated/*.log.gz       已关闭月份的压缩日志
state/last-status/          最近一次非 dry-run 状态
state/schedule/             已完成的定时槽位
state/archive-index/        已验证归档索引
state/syncwarden.lock       全局进程锁
tmp/                        受管临时文件
```

成功日志记录 created、updated、deleted、attempts 和完整状态，不保存 rsync
逐文件名称。月度日志按自然月清理，人工命名的日志不会被处理。

### rsync code 24

code 24 表示活跃源中的文件或目录在扫描、打开或传输前消失，例如运行中的程序
删除或重命名临时文件。SyncWarden 将它视为实时镜像中的正常最终一致性行为：

- source、服务器和批次保持 `SUCCESS`；
- 不重试；
- 不产生 WARNING 或 failure 日志；
- 已观察的变化统计保留，并标记 `complete=yes`，表示本轮已按持续镜像策略完成。

### 退出码

| 代码 | 含义 |
| ---: | --- |
| `0` | 成功或安全 no-op |
| `1` | 至少一个失败，或必要日志/状态无法持久化 |
| `2` | 只有 WARNING |
| `64` | 命令行用法错误 |
| `69` | Bash 主版本低于 5 |
| `75` | 已有进程持有全局锁 |
| `124` | 超过固定的五小时全局上限 |

服务器按顺序处理；单台失败不会阻止后续服务器。

## 平台与依赖

SyncWarden 支持 **Bash 5+ 和 GNU/Linux**。macOS 自带的 BSD `date`、`readlink`、
`stat` 等命令与 GNU 版本不同，因此当前不属于受支持平台。

运行依赖：

- Bash 5+
- OpenSSH 客户端
- rsync
- GNU coreutils，包括 `timeout`、`sha256sum`、`stat`、`df`、`date`
- util-linux `flock`
- Info-ZIP `zip`
- `gzip`、`find`、`sort`、`awk`、`sed`、`grep`

脚本不会自动安装软件。

## 测试

完整测试使用临时目录和 fake SSH、rsync、ZIP 等边界，不连接真实服务器，也不会
读取真实配置、修改备份或触碰 crontab。

在 GNU/Linux 中运行：

```bash
bash tests/run_tests.sh all
```

测试分组、隔离边界和覆盖范围见 [`tests/README.md`](tests/README.md)。

## 常见问题

### 为什么同步前必须创建 ZIP？

rsync 镜像会删除远端已经不存在的对象。同步前 ZIP 保存的是本地镜像在本次变化
之前的状态。如果 ZIP 无法创建或验证，脚本会阻止本次带删除语义的同步。

### 第一次同步为什么没有 ZIP？

第一次运行时没有旧镜像可归档，因此会直接创建最后一级目标目录并开始同步。
从第二次真实同步开始，已有镜像会先归档。

### 为什么 destination 的父目录必须提前创建？

这是防止路径拼写错误和 `--delete` 作用到意外位置的保护措施。脚本只创建最终
一级目录，不会自动补齐整条路径。

### code 24 是否代表备份失败？

不是。它表示文件或目录在活跃源中恰好于扫描、打开或传输前消失。SyncWarden
将其视为成功，并标记 `complete=yes`；这表示本轮已按持续镜像策略完成，不表示
获得了源目录的原子时间点快照。

### dry-run 是否绝对不会写入任何文件？

它不会写入 SyncWarden 的镜像、ZIP、日志或状态。但首次连接未知 SSH 主机时，
OpenSSH 的 `accept-new` 可能更新当前用户的 `known_hosts`。

### 可以在 macOS 上运行吗？

当前不支持。请在 Bash 5 和 GNU 工具链完整的 Linux 环境中运行和验证。

## 许可证

SyncWarden 使用 [MIT License](LICENSE)。
