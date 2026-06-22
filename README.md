# Codex TRACE 日志高频写盘修复脚本

> **重要限制：本仓库脚本仅限 macOS + Codex 桌面版。**
>
> 不支持 Windows。  
> 不支持 Linux。  
> 不支持只安装 Codex CLI 的环境。  
> 不支持非 Codex 桌面版日志库。  
>
> 如果你的电脑不是 macOS，或者你用的不是 Codex 桌面版，请不要运行这些 `.command` 脚本。

用于处理 Codex 桌面版把大量 `TRACE` 日志写入 `~/.codex/logs_2.sqlite`，导致 SQLite WAL 高频写盘、日志库膨胀的问题。

## 适用范围

只适合同时满足这些条件的电脑：

- macOS
- Codex 桌面版
- 存在 `~/.codex/logs_2.sqlite`
- `logs` 表包含 `level` 字段
- 系统有 `zsh`、`sqlite3`、`lsof`、`osascript`、`open`

明确不适合：

- Windows
- Linux
- Codex CLI-only 环境
- Codex 未来版本改了日志库结构

原因：

- `.command` 是 macOS 脚本格式
- 脚本使用 macOS 专有命令 `osascript` 和 `open -a "Codex"`
- 日志路径按 Codex 桌面版的 `~/.codex/logs_2.sqlite` 设计
- 修复逻辑依赖 `logs` 表和 `level` 字段

## 脚本

- `普通修复-fix_codex_trace_logs.command`
  - 退出 Codex
  - 备份 `logs_2.sqlite`
  - 创建 `BEFORE INSERT` trigger
  - 用 `RAISE(IGNORE)` 拦截 `TRACE`
  - `wal_checkpoint(TRUNCATE)`
  - 重开 Codex

- `更新后补修-repair_codex_trace_guard_after_update.command`
  - Codex 更新后使用
  - 检查 schema
  - 重新安装 TRACE 拦截 trigger
  - 截断 WAL
  - 自动采样确认

- `因修复导致更新出错-rescue_codex_if_update_breaks_after_trace_fix.command`
  - 如果 Codex 更新后异常，用这个救援
  - 删除 trigger
  - 如果日志库打不开，就把 `logs_2.sqlite` 移走，让 Codex 重建
  - 不动 session、auth、config、`state_5.sqlite`

- `回滚修复-rollback_codex_trace_log_trigger.command`
  - 删除 TRACE 拦截 trigger
  - 恢复 Codex 原始日志行为

## 使用方式

双击需要的 `.command` 文件。

macOS 如果提示无法打开：

1. 右键脚本
2. 选择“打开”
3. 再确认打开

## 数据安全

脚本只处理：

- `~/.codex/logs_2.sqlite`
- `~/.codex/logs_2.sqlite-wal`
- `~/.codex/logs_2.sqlite-shm`

脚本不处理：

- `~/.codex/state_5.sqlite`
- `~/.codex/sessions`
- `~/.codex/archived_sessions`
- `~/.codex/auth.json`
- `~/.codex/config.toml`

所以正常不会丢 Codex session。

## 副作用

- `TRACE` 诊断日志不会再进入 `logs` 表
- `INFO`、`DEBUG`、`WARN`、`ERROR` 仍会写入
- 如果以后要向官方提交底层网络 TRACE，需要先运行回滚脚本

## 修复后的可能风险

这个修复是“拦截 TRACE 写入日志库”，不是 Codex 官方修复。它主要是止血，降低磁盘写入和 WAL 膨胀。

可能风险：

- **缺少 TRACE 诊断日志**
  - 修复后，Codex 的底层网络、websocket、轮询细节不会再以 `TRACE` 级别进入 `logs` 表。
  - 如果之后要给官方排查深层 bug，日志细节会少。
  - 需要完整 TRACE 时，先运行 `回滚修复-rollback_codex_trace_log_trigger.command`。

- **Codex 更新后可能需要重新处理**
  - Codex 更新可能删除 trigger。
  - Codex 更新也可能改变 `logs_2.sqlite` 的表结构。
  - 更新后如果高频 TRACE 又出现，运行 `更新后补修-repair_codex_trace_guard_after_update.command`。

- **如果 Codex 更新后打不开**
  - 可能是日志库结构变化，或者 trigger 和新版本不兼容。
  - 运行 `因修复导致更新出错-rescue_codex_if_update_breaks_after_trace_fix.command`。
  - 这个救援脚本会先尝试删除 trigger；如果日志库打不开，会把 `logs_2.sqlite` 移走，让 Codex 重建日志库。

- **运行脚本时会关闭并重开 Codex**
  - 正在执行的 Codex 任务可能中断。
  - 建议在没有重要任务运行时执行。

- **已有日志库体积不会自动变小**
  - trigger 只阻止新的 TRACE 写入。
  - 已经膨胀的 `logs_2.sqlite` 不会自动瘦身。
  - 如需回收空间，需要在 Codex 关闭后另行执行 SQLite `VACUUM`。

- **脚本只保护当前已知结构**
  - 当前逻辑依赖 `logs` 表和 `level` 字段。
  - 如果未来 Codex 改表名、字段名、日志库路径，脚本会停止或失效。

不会影响的内容：

- 不会删除 Codex session
- 不会修改 `state_5.sqlite`
- 不会修改 `sessions`
- 不会修改 `archived_sessions`
- 不会修改 `auth.json`
- 不会修改 `config.toml`

## 判断是否修好

修复后检查：

```sh
sqlite3 "file:$HOME/.codex/logs_2.sqlite?mode=ro" \
  "select count(*) from logs where ts >= cast(strftime('%s','now') as integer)-60 and level='TRACE';"
```

输出 `0`，表示最近 60 秒没有 TRACE 写入。
