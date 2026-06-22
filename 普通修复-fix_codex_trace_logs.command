#!/bin/zsh
set -euo pipefail

DB="$HOME/.codex/logs_2.sqlite"
WAL="$DB-wal"
SHM="$DB-shm"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$HOME/.codex/backups/logs_2_trace_fix_$STAMP"
SCRIPT_DIR="${0:A:h}"
REPORT="$SCRIPT_DIR/codex_trace_log_fix_report_$STAMP.txt"

mkdir -p "$BACKUP_DIR"

{
  echo "Codex TRACE log fix"
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "DB: $DB"
  echo "Backup: $BACKUP_DIR"
  echo

  if [ ! -f "$DB" ]; then
    echo "ERROR: database not found."
    exit 1
  fi

  echo "Step 1: asking Codex to quit..."
  osascript -e 'tell application "Codex" to quit' >/dev/null 2>&1 || true

  echo "Step 2: waiting for database files to close..."
  for i in {1..90}; do
    if ! lsof -nP "$DB" "$WAL" "$SHM" >/dev/null 2>&1; then
      echo "Database closed."
      break
    fi
    sleep 1
    if [ "$i" -eq 90 ]; then
      echo "ERROR: Codex still holds the database after 90 seconds."
      echo "Close Codex manually, then run this file again."
      exit 2
    fi
  done

  echo
  echo "Before:"
  ls -lh "$DB" "$WAL" "$SHM" 2>/dev/null || true
  sqlite3 "file:$DB?mode=ro" "select count(*) as rows, max(id) as max_id, datetime(max(ts),'unixepoch','localtime') as latest from logs;" || true

  echo
  echo "Step 3: backing up database files..."
  cp -p "$DB" "$BACKUP_DIR/"
  [ -f "$WAL" ] && cp -p "$WAL" "$BACKUP_DIR/" || true
  [ -f "$SHM" ] && cp -p "$SHM" "$BACKUP_DIR/" || true

  echo "Step 4: installing TRACE-drop trigger and truncating WAL..."
  sqlite3 "$DB" <<'SQL'
PRAGMA busy_timeout=10000;
BEGIN;
CREATE TRIGGER IF NOT EXISTS codex_ignore_trace_logs
BEFORE INSERT ON logs
WHEN NEW.level = 'TRACE'
BEGIN
  SELECT RAISE(IGNORE);
END;
COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
SQL

  echo
  echo "After:"
  ls -lh "$DB" "$WAL" "$SHM" 2>/dev/null || true
  sqlite3 "file:$DB?mode=ro" "select name from sqlite_master where type='trigger' and name='codex_ignore_trace_logs';"
  sqlite3 "file:$DB?mode=ro" "select count(*) as rows, max(id) as max_id, datetime(max(ts),'unixepoch','localtime') as latest from logs;"

  echo
  echo "Step 5: reopening Codex..."
  open -a "Codex" >/dev/null 2>&1 || true

  echo
  echo "Done."
  echo "Report: $REPORT"
  echo "Backup: $BACKUP_DIR"
} 2>&1 | tee "$REPORT"

echo
echo "Press Enter to close this window."
read -r _
