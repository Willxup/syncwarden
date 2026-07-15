# SyncWarden 测试套件

测试套件面向 Bash 5 和 GNU/Linux，不需要 Bats、Python、网络连接或下载额外测试依赖。

## 运行测试

在项目根目录执行：

```bash
bash tests/run_tests.sh all
```

也可以单独运行测试分组：

```bash
bash tests/run_tests.sh parser
bash tests/run_tests.sh cli
bash tests/run_tests.sh retention
bash tests/run_tests.sh archive
bash tests/run_tests.sh transport
bash tests/run_tests.sh orchestration
bash tests/run_tests.sh logs
bash tests/run_tests.sh integration
```

## 隔离边界

- 每次运行使用 `mktemp` 创建独立临时根目录，并在退出时清理。
- fake 命令替代 SSH、rsync、ZIP、gzip、find、df、rm、timeout 和校验和等外部边界。
- 配置解析、路径保护、归档索引、保留策略、日志、状态、锁、重试、编排和 CLI
  使用真实生产函数。
- 测试不会连接远程主机、读取真实 `syncwarden.conf`、修改备份数据或触碰 crontab。
- 一个符号链接保留用例使用真实 Info-ZIP。如果系统中没有真实 `zip`，该用例会显示
  skipped；正式发布验证要求它实际执行。

最终结果中的 `passed`、`failed` 和 `skipped` 统计断言数量，不是独立测试场景数量。

## 覆盖范围

测试覆盖：

- 严格 INI 解析、默认值继承和服务器覆盖；
- source 与 destination 安全校验；
- 私钥和 SSH 预检错误分类；
- 瞬时错误重试和永久错误停止策略；
- rsync 镜像、dry-run 和 code 24 行为；
- ZIP 创建、验证、原子提升和归档索引；
- 最近归档与月末归档保留集合；
- fail-closed 清理和月度日志维护；
- 状态持久化、定时槽位、锁和全局超时；
- 多 source、多服务器顺序执行和失败隔离；
- CLI 长短参数、简短帮助和只读查询边界。
