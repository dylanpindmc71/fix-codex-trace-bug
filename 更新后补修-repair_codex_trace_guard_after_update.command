#!/bin/zsh
set -euo pipefail

DB="$HOME/.codex/logs_2.sqlite"
WAL="$DB-wal"
SHM="$DB-shm"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$HOME/.codex/backups/logs_2_trace_guard_repair_$STAMP"
SCRIPT_DIR="${0:A:h}"
REPORT="$SCRIPT_DIR/codex_trace_guard_repair_report_$STAMP.txt"

mkdir -p "$BACKUP_DIR"

log() {
  echo "$@"
}

sql_ro() {
  sqlite3 "file:$DB?mode=ro" "$@"
}

wait_db_closed() {
  for i in {1..90}; do
    if ! lsof -nP "$DB" "$WAL" "$SHM" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

{
  log "Codex TRACE guard repair after update"
  log "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  log "DB: $DB"
  log "Backup: $BACKUP_DIR"
  log

  if [ ! -f "$DB" ]; then
    log "ERROR: database not found."
    exit 1
  fi

  log "Step 1: asking Codex to quit..."
  osascript -e 'tell application "Codex" to quit' >/dev/null 2>&1 || true

  log "Step 2: waiting for database files to close..."
  if wait_db_closed; then
    log "Database closed."
  else
    log "ERROR: Codex still holds the database after 90 seconds."
    log "Close Codex manually, then run this file again."
    exit 2
  fi

  log
  log "Before:"
  ls -lh "$DB" "$WAL" "$SHM" 2>/dev/null || true
  sql_ro "select count(*) as rows, max(id) as max_id, datetime(max(ts),'unixepoch','localtime') as latest from logs;" || true
  sql_ro "select name from sqlite_master where type='trigger' and name='codex_ignore_trace_logs';" || true

  log
  log "Step 3: checking schema..."
  HAS_LOGS_TABLE="$(sql_ro "select count(*) from sqlite_master where type='table' and name='logs';")"
  HAS_LEVEL_COL="$(sql_ro "select count(*) from pragma_table_info('logs') where name='level';" 2>/dev/null || echo 0)"
  if [ "$HAS_LOGS_TABLE" != "1" ] || [ "$HAS_LEVEL_COL" != "1" ]; then
    log "ERROR: logs table or level column missing. Codex schema changed."
    log "No change made. Ask for manual inspection."
    exit 3
  fi

  log "Step 4: backing up database files..."
  cp -p "$DB" "$BACKUP_DIR/"
  [ -f "$WAL" ] && cp -p "$WAL" "$BACKUP_DIR/" || true
  [ -f "$SHM" ] && cp -p "$SHM" "$BACKUP_DIR/" || true

  log "Step 5: installing or refreshing TRACE-drop trigger..."
  sqlite3 "$DB" <<'SQL'
PRAGMA busy_timeout=10000;
BEGIN;
DROP TRIGGER IF EXISTS codex_ignore_trace_logs;
CREATE TRIGGER codex_ignore_trace_logs
BEFORE INSERT ON logs
WHEN NEW.level = 'TRACE'
BEGIN
  SELECT RAISE(IGNORE);
END;
COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
SQL

  log
  log "After repair:"
  ls -lh "$DB" "$WAL" "$SHM" 2>/dev/null || true
  sql_ro "select name from sqlite_master where type='trigger' and name='codex_ignore_trace_logs';"
  sql_ro "select count(*) as rows, max(id) as max_id, datetime(max(ts),'unixepoch','localtime') as latest from logs;"

  log
  log "Step 6: reopening Codex..."
  open -a "Codex" >/dev/null 2>&1 || true

  log "Step 7: sampling for 20 seconds..."
  sleep 8
  FIRST_ID="$(sql_ro "select coalesce(max(id),0) from logs;" || echo 0)"
  FIRST_WAL="$(stat -f '%z' "$WAL" 2>/dev/null || echo 0)"
  sleep 20
  SECOND_ID="$(sql_ro "select coalesce(max(id),0) from logs;" || echo 0)"
  SECOND_WAL="$(stat -f '%z' "$WAL" 2>/dev/null || echo 0)"
  ID_DELTA=$((SECOND_ID - FIRST_ID))
  WAL_DELTA=$((SECOND_WAL - FIRST_WAL))

  log
  log "Sample result:"
  log "max(id) delta in 20s: $ID_DELTA"
  log "WAL bytes delta in 20s: $WAL_DELTA"
  sql_ro "with m as (select max(ts) maxts from logs) select level, count(*) rows from logs,m where ts>=maxts-60 group by level order by rows desc;" || true

  if sql_ro "with m as (select max(ts) maxts from logs) select count(*) from logs,m where ts>=maxts-60 and level='TRACE';" | grep -q '^0$'; then
    log "TRACE check: OK. No TRACE rows in latest 60s."
  else
    log "TRACE check: WARNING. TRACE rows still present. Ask for manual inspection."
  fi

  log
  log "Done."
  log "Report: $REPORT"
  log "Backup: $BACKUP_DIR"
} 2>&1 | tee "$REPORT"

echo
echo "Press Enter to close this window."
read -r _
