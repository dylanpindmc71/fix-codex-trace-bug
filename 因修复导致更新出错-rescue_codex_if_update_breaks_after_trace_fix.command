#!/bin/zsh
set -euo pipefail

DB="$HOME/.codex/logs_2.sqlite"
WAL="$DB-wal"
SHM="$DB-shm"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$HOME/.codex/backups/logs_2_codex_update_rescue_$STAMP"
SCRIPT_DIR="${0:A:h}"
REPORT="$SCRIPT_DIR/codex_update_rescue_report_$STAMP.txt"

mkdir -p "$BACKUP_DIR"

backup_file() {
  local file="$1"
  if [ -f "$file" ]; then
    cp -p "$file" "$BACKUP_DIR/"
  fi
}

move_aside_file() {
  local file="$1"
  if [ -f "$file" ]; then
    mv "$file" "$file.rescued_$STAMP"
  fi
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
  echo "Codex update rescue after TRACE trigger fix"
  echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "This script only touches logs_2.sqlite files."
  echo "It does not touch state_5.sqlite, sessions, archived_sessions, auth, or config."
  echo "Backup: $BACKUP_DIR"
  echo

  echo "Step 1: asking Codex to quit..."
  osascript -e 'tell application "Codex" to quit' >/dev/null 2>&1 || true

  echo "Step 2: waiting for log database files to close..."
  if wait_db_closed; then
    echo "Database closed."
  else
    echo "ERROR: Codex still holds the log database after 90 seconds."
    echo "Force quit Codex manually, then run this file again."
    exit 2
  fi

  echo
  echo "Step 3: backing up current log database files..."
  backup_file "$DB"
  backup_file "$WAL"
  backup_file "$SHM"

  if [ ! -f "$DB" ]; then
    echo "No logs_2.sqlite found. Nothing to repair."
    echo "Reopening Codex..."
    open -a "Codex" >/dev/null 2>&1 || true
    exit 0
  fi

  echo
  echo "Step 4: trying safe repair: drop TRACE trigger..."
  if sqlite3 "$DB" <<'SQL'
PRAGMA busy_timeout=10000;
BEGIN;
DROP TRIGGER IF EXISTS codex_ignore_trace_logs;
COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
SQL
  then
    echo "Safe repair succeeded."
    echo
    echo "Current triggers:"
    sqlite3 "file:$DB?mode=ro" "select name from sqlite_master where type='trigger';" || true
  else
    echo "Safe repair failed. Log database may be incompatible with new Codex."
    echo "Step 5: moving log database aside so Codex can recreate it..."
    move_aside_file "$DB"
    move_aside_file "$WAL"
    move_aside_file "$SHM"
  fi

  echo
  echo "Step 6: reopening Codex..."
  open -a "Codex" >/dev/null 2>&1 || true

  echo
  echo "Done."
  echo "If Codex opens normally, repair worked."
  echo "If Codex still fails, the issue is probably not logs_2.sqlite."
  echo "Report: $REPORT"
  echo "Backup: $BACKUP_DIR"
} 2>&1 | tee "$REPORT"

echo
echo "Press Enter to close this window."
read -r _
