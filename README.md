# Codex TRACE 日志高频写盘修复脚本

用于处理 Codex 桌面版把大量 `TRACE` 日志写入 `~/.codex/logs_2.sqlite`，导致 SQLite WAL 高频写盘、日志库膨胀的问题。

## 适用范围

适合：

- macOS
- Codex 桌面版
- 存在 `~/.codex/logs_2.sqlite`
- `logs` 表包含 `level` 字段
- 系统有 `zsh`、`sqlite3`、`lsof`、`osascript`、`open`

不适合：

- Windows
- Linux
- Codex CLI-only 环境
- Codex 未来版本改了日志库结构

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

## 判断是否修好

修复后检查：

```sh
sqlite3 "file:$HOME/.codex/logs_2.sqlite?mode=ro" \
  "select count(*) from logs where ts >= cast(strftime('%s','now') as integer)-60 and level='TRACE';"
```

输出 `0`，表示最近 60 秒没有 TRACE 写入。
