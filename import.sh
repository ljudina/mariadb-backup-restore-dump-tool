#!/bin/bash
set -e

###############################################
# Configuration
###############################################
DB_NAME="$1"
SQL_DIR="$2"
HOST="${3:-localhost}"
PORT="${4:-3306}"
USER="${5:-root}"

if [ -z "$DB_NAME" ] || [ -z "$SQL_DIR" ]; then
  echo "Usage: $0 <database_name> <sql_directory> [host] [port] [user]"
  echo ""
  echo "Arguments:"
  echo "  database_name   Target database name to import into"
  echo "  sql_directory    Directory containing the SQL dump files"
  echo "  host             MySQL host (default: localhost)"
  echo "  port             MySQL port (default: 3306)"
  echo "  user             MySQL user (default: root)"
  echo ""
  echo "Examples:"
  echo "  $0 myapp ./output/myapp"
  echo "  $0 myapp ./output/myapp localhost 3306 root"
  echo "  $0 erptest ./output/erplive db.example.com 3307 admin"
  echo ""
  echo "Import order: schema -> data -> views -> routines -> triggers -> events -> grants"
  exit 1
fi

read -s -p "MySQL password: " PASS
echo ""

MYSQL_CMD="mysql -h $HOST -P $PORT -u $USER -p$PASS --max-allowed-packet=512M"

# Import order matters!
IMPORT_ORDER=(
  "schema.sql"
  "data.sql"
  "views.sql"
  "routines.sql"
  "triggers.sql"
  "events.sql"
  "grants.sql"
)

###############################################
# Functions
###############################################
log() { echo "[$(date '+%H:%M:%S')] $*"; }

format_size() {
  local bytes=$1
  if [ "$bytes" -ge 1073741824 ]; then
    awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
  elif [ "$bytes" -ge 1048576 ]; then
    awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
  elif [ "$bytes" -ge 1024 ]; then
    awk "BEGIN {printf \"%.1f KB\", $bytes/1024}"
  else
    echo "${bytes} B"
  fi
}

format_elapsed() {
  local elapsed=$1
  if [ "$elapsed" -ge 3600 ]; then
    echo "$((elapsed / 3600))h $((elapsed % 3600 / 60))m $((elapsed % 60))s"
  elif [ "$elapsed" -ge 60 ]; then
    echo "$((elapsed / 60))m $((elapsed % 60))s"
  else
    echo "${elapsed}s"
  fi
}

import_file() {
  local filepath="$1"
  local filename
  filename=$(basename "$filepath")
  local bytes
  bytes=$(wc -c < "$filepath")
  local size
  size=$(format_size "$bytes")

  # Skip if file has no meaningful content
  if [ "$bytes" -le 200 ]; then
    log "Skipping $filename (empty - $size)"
    return 0
  fi

  log "Importing $filename ($size)..."
  local start_time
  start_time=$(date +%s)

  # For large files (>10MB), use optimized settings and show progress
  if [ "$bytes" -gt 10485760 ]; then
    log "  Large file detected. Using optimized import..."

    # Build a wrapper that prepends optimization flags to the SQL stream
    {
      echo "SET FOREIGN_KEY_CHECKS=0;"
      echo "SET UNIQUE_CHECKS=0;"
      echo "SET AUTOCOMMIT=0;"
      echo "SET sql_log_bin=0;"
      cat "$filepath"
      echo "COMMIT;"
      echo "SET FOREIGN_KEY_CHECKS=1;"
      echo "SET UNIQUE_CHECKS=1;"
    } | if command -v pv &>/dev/null; then
      pv -s "$((bytes + 200))" | $MYSQL_CMD "$DB_NAME"
    else
      # No pv - show periodic progress in background
      (
        while true; do
          sleep 30
          echo -ne "\r[$(date '+%H:%M:%S')]   Still importing $filename... (elapsed: $(format_elapsed $(($(date +%s) - start_time))))  "
        done
      ) &
      local progress_pid=$!
      $MYSQL_CMD "$DB_NAME"
      kill $progress_pid 2>/dev/null || true
      wait $progress_pid 2>/dev/null || true
      echo ""
    fi
  else
    # Small file, import directly
    $MYSQL_CMD "$DB_NAME" < "$filepath"
  fi

  local end_time
  end_time=$(date +%s)
  local elapsed=$((end_time - start_time))
  log "  Done. ($(format_elapsed $elapsed))"
}

###############################################
# Validate
###############################################
if [ ! -d "$SQL_DIR" ]; then
  log "ERROR: SQL directory '$SQL_DIR' does not exist."
  exit 1
fi

# Test connection
log "Testing MySQL connection..."
if ! $MYSQL_CMD -e "SELECT 1;" >/dev/null 2>&1; then
  log "ERROR: Cannot connect to MySQL at $HOST:$PORT as $USER"
  exit 1
fi
log "Connection OK."

# Check for pv
if command -v pv &>/dev/null; then
  log "Progress bar: enabled (pv found)"
else
  log "Progress bar: disabled (install pv for progress: apt install pv / brew install pv)"
fi

###############################################
# Main
###############################################

# Create database if not exists
log "Creating database '$DB_NAME' if not exists..."
$MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;" 2>/dev/null

# Calculate total size
TOTAL_BYTES=0
for file in "${IMPORT_ORDER[@]}"; do
  filepath="$SQL_DIR/$file"
  if [ -f "$filepath" ]; then
    bytes=$(wc -c < "$filepath")
    TOTAL_BYTES=$((TOTAL_BYTES + bytes))
  fi
done

log ""
log "============================================"
log "  Import Plan"
log "============================================"
log "  Target DB:   $DB_NAME"
log "  Source dir:   $SQL_DIR"
log "  Server:       $HOST:$PORT"
log "  Total size:   $(format_size $TOTAL_BYTES)"
log ""
log "  Files:"
for file in "${IMPORT_ORDER[@]}"; do
  filepath="$SQL_DIR/$file"
  if [ -f "$filepath" ]; then
    bytes=$(wc -c < "$filepath")
    if [ "$bytes" -le 200 ]; then
      log "    $file  $(format_size "$bytes")  (will skip - empty)"
    else
      log "    $file  $(format_size "$bytes")"
    fi
  else
    log "    $file  (not found, skipping)"
  fi
done
log "============================================"
log ""

OVERALL_START=$(date +%s)
FAILED=()
SUCCESS=()
SKIPPED=()

for file in "${IMPORT_ORDER[@]}"; do
  filepath="$SQL_DIR/$file"
  if [ -f "$filepath" ]; then
    if import_file "$filepath"; then
      SUCCESS+=("$file")
    else
      log "ERROR: Failed to import $file"
      FAILED+=("$file")
      # Ask whether to continue on error
      read -p "Continue with remaining files? (y/n): " cont
      if [ "$cont" != "y" ]; then
        log "Aborting import."
        break
      fi
    fi
  else
    log "Skipping $file (not found)"
    SKIPPED+=("$file")
  fi
done

OVERALL_END=$(date +%s)
OVERALL_ELAPSED=$((OVERALL_END - OVERALL_START))

log ""
log "========================================="
log "  Import Summary"
log "========================================="
log "  Database:     $DB_NAME"
log "  Total time:   $(format_elapsed $OVERALL_ELAPSED)"
log "  Total size:   $(format_size $TOTAL_BYTES)"
log "  Successful:   ${#SUCCESS[@]}"
if [ ${#SUCCESS[@]} -gt 0 ]; then
  for f in "${SUCCESS[@]}"; do
    log "    ✓ $f"
  done
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
  log "  Skipped:      ${#SKIPPED[@]}"
  for f in "${SKIPPED[@]}"; do
    log "    - $f"
  done
fi
if [ ${#FAILED[@]} -gt 0 ]; then
  log "  FAILED:       ${#FAILED[@]}"
  for f in "${FAILED[@]}"; do
    log "    ✗ $f"
  done
fi
log "========================================="

# Verify table count
TABLE_COUNT=$($MYSQL_CMD -BNe "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB_NAME';" 2>/dev/null)
ROW_COUNT=$($MYSQL_CMD -BNe "SELECT SUM(TABLE_ROWS) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB_NAME';" 2>/dev/null)
log ""
log "  Verification:"
log "    Tables: $TABLE_COUNT"
log "    Rows:   ${ROW_COUNT:-0} (approximate)"
log "========================================="
