#!/bin/bash
set -e

###############################################
# Configuration (defaults)
###############################################
BACKUP_DIR="./backup"
RESTORED_DATA="./restored_data"
OUTPUT_DIR="./output"
ROOT_PASS="rootpass"
IMAGE="mariadb:10.5"
CONTAINER="mariadb_restore"

# System databases to exclude when dumping all
EXCLUDE_DBS="information_schema|performance_schema|mysql|sys"

###############################################
# Parse arguments
###############################################
DATABASES=""
SKIP_FULL=false
PROMPT_PASS=false

usage() {
  echo "Usage: $0 [-d databases] [-s] [-p [password]] [-i image] [-b backup_dir] [-o output_dir]"
  echo ""
  echo "Options:"
  echo "  -d  Comma-separated list of databases (default: all)"
  echo "  -s  Skip full combined dump"
  echo "  -p  MySQL root password. If no value given, prompts interactively (default: rootpass)"
  echo "  -i  MariaDB Docker image (default: mariadb:10.5)"
  echo "  -b  Backup directory (default: ./backup)"
  echo "  -o  Output directory (default: ./output)"
  echo "  -h  Show this help"
  echo ""
  echo "Examples:"
  echo "  $0                                        # All DBs, with full dump"
  echo "  $0 -s                                     # All DBs, skip full dump"
  echo "  $0 -d myapp,orders                        # Specific DBs, with full dump"
  echo "  $0 -d myapp,orders -s                     # Specific DBs, skip full dump"
  echo "  $0 -d myapp -s -p secret                  # Custom password"
  echo "  $0 -d myapp -s -p                         # Prompt for password"
  echo "  $0 -d myapp -s -p -b /data/backup         # Prompt + custom backup dir"
  echo "  $0 -b /data/backup -o /data/sql           # Custom paths"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d)
      shift
      DATABASES="$1"
      shift
      ;;
    -s)
      SKIP_FULL=true
      shift
      ;;
    -p)
      if [ -n "${2:-}" ] && [[ ! "$2" =~ ^- ]]; then
        shift
        ROOT_PASS="$1"
        shift
      else
        PROMPT_PASS=true
        shift
      fi
      ;;
    -i)
      shift
      IMAGE="$1"
      shift
      ;;
    -b)
      shift
      BACKUP_DIR="$1"
      shift
      ;;
    -o)
      shift
      OUTPUT_DIR="$1"
      shift
      ;;
    -h)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

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

file_size_formatted() {
  local f="$1"
  local bytes
  bytes=$(wc -c < "$f")
  format_size "$bytes"
}

# Prompt for password if -p was used without a value
if [ "$PROMPT_PASS" = true ]; then
  read -s -p "Enter MySQL root password: " ROOT_PASS
  echo ""
  if [ -z "$ROOT_PASS" ]; then
    log "ERROR: Password cannot be empty."
    exit 1
  fi
fi

wait_for_db() {
  log "Waiting for MariaDB to be ready..."
  local retries=30
  while ! docker exec "$CONTAINER" mysqladmin ping -u root -p"$ROOT_PASS" --silent 2>/dev/null; do
    retries=$((retries - 1))
    if [ "$retries" -le 0 ]; then
      log "ERROR: MariaDB did not become ready in time."
      exit 1
    fi
    sleep 2
  done
  sleep 3
}

get_all_databases() {
  docker exec "$CONTAINER" mysql -u root -p"$ROOT_PASS" -BNe "SHOW DATABASES;" 2>/dev/null \
    | grep -Ev "^($EXCLUDE_DBS)$"
}

run_mysqldump() {
  docker exec "$CONTAINER" mysqldump -u root -p"$ROOT_PASS" "$@" 2>/dev/null
}

run_mysql() {
  docker exec "$CONTAINER" mysql -u root -p"$ROOT_PASS" "$@" 2>/dev/null
}

dump_database() {
  local db_name="$1"
  local db_dir="$OUTPUT_DIR/$db_name"
  mkdir -p "$db_dir"

  log "Dumping database: $db_name"

  # Verify database exists
  local db_exists
  db_exists=$(run_mysql -BNe "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db_name';")
  if [ -z "$db_exists" ]; then
    log "  ERROR: Database '$db_name' does not exist!"
    log "  Available databases:"
    run_mysql -BNe "SHOW DATABASES;" | grep -Ev "^($EXCLUDE_DBS)$" | while read -r db; do
      log "    - $db"
    done
    return 1
  fi

  # 1. Schema only (CREATE TABLE, no data)
  log "  -> schema (structure)..."
  run_mysqldump \
    --single-transaction \
    --no-data \
    --skip-triggers \
    --skip-routines \
    --skip-events \
    "$db_name" > "$db_dir/schema.sql"

  # 2. Data only (INSERT statements, no CREATE)
  log "  -> data..."
  run_mysqldump \
    --single-transaction \
    --no-create-info \
    --no-create-db \
    --skip-triggers \
    --skip-routines \
    --skip-events \
    "$db_name" > "$db_dir/data.sql"

  # 3. Triggers only
  log "  -> triggers..."
  run_mysqldump \
    --single-transaction \
    --no-data \
    --no-create-info \
    --no-create-db \
    --triggers \
    --skip-routines \
    --skip-events \
    "$db_name" > "$db_dir/triggers.sql"

  # 4. Routines (stored procedures + functions)
  log "  -> routines (procedures & functions)..."
  run_mysqldump \
    --single-transaction \
    --no-data \
    --no-create-info \
    --no-create-db \
    --skip-triggers \
    --routines \
    --skip-events \
    "$db_name" > "$db_dir/routines.sql"

  # 5. Events
  log "  -> events..."
  run_mysqldump \
    --single-transaction \
    --no-data \
    --no-create-info \
    --no-create-db \
    --skip-triggers \
    --skip-routines \
    --events \
    "$db_name" > "$db_dir/events.sql"

  # 6. Views (extracted separately)
  log "  -> views..."
  local views
  views=$(run_mysql -BNe \
    "SELECT TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA='$db_name';")

  if [ -n "$views" ]; then
    echo "-- Views for database: $db_name" > "$db_dir/views.sql"
    echo "USE \`$db_name\`;" >> "$db_dir/views.sql"
    echo "" >> "$db_dir/views.sql"
    for view in $views; do
      run_mysql -BNe \
        "SHOW CREATE VIEW \`$db_name\`.\`$view\`;" \
        | awk -F'\t' '{print "DROP VIEW IF EXISTS `" $1 "`;"; print $2 ";"; print ""}' \
        >> "$db_dir/views.sql"
    done
  else
    echo "-- No views found for database: $db_name" > "$db_dir/views.sql"
  fi

  # 7. Grants / User permissions related to this database
  log "  -> grants..."
  echo "-- Grants for database: $db_name" > "$db_dir/grants.sql"
  local users
  users=$(run_mysql -BNe \
    "SELECT DISTINCT CONCAT(\"'\", user, \"'@'\", host, \"'\") 
     FROM mysql.db 
     WHERE db='$db_name' OR db='%';" || true)

  if [ -n "$users" ]; then
    while IFS= read -r user_host; do
      run_mysql -BNe \
        "SHOW GRANTS FOR $user_host;" \
        | grep -i "$db_name\|ALL PRIVILEGES" \
        | sed 's/$/;/' >> "$db_dir/grants.sql" || true
    done <<< "$users"
  else
    echo "-- No specific grants found" >> "$db_dir/grants.sql"
  fi

  # 8. Full combined dump (convenience) - optional
  if [ "$SKIP_FULL" != "true" ]; then
    log "  -> full combined dump..."
    run_mysqldump \
      --single-transaction \
      --routines \
      --triggers \
      --events \
      "$db_name" > "$db_dir/full.sql"
  else
    log "  -> skipping full combined dump"
  fi

  # Print sizes
  log "  Files for $db_name:"
  for f in "$db_dir"/*.sql; do
    log "    $(basename "$f"): $(file_size_formatted "$f")"
  done
}

cleanup() {
  log "Cleaning up..."
  docker stop "$CONTAINER" 2>/dev/null && docker rm "$CONTAINER" 2>/dev/null || true
  if [ -d "$RESTORED_DATA" ]; then
    docker run --rm -v "$(cd "$RESTORED_DATA" && pwd)":/data "$IMAGE" rm -rf /data/* 2>/dev/null || true
    rmdir "$RESTORED_DATA" 2>/dev/null || true
  fi
}

trap cleanup EXIT

###############################################
# Main
###############################################
log "============================================"
log "     MariaDB Backup Restore & Dump Tool     "
log "============================================"
log "Backup dir:  $BACKUP_DIR"
log "Output dir:  $OUTPUT_DIR"
log "Image:       $IMAGE"
log "Skip full:   $SKIP_FULL"
log "Databases:   ${DATABASES:-all}"
log "============================================"
echo ""

# Validate backup directory
if [ ! -d "$BACKUP_DIR" ]; then
  log "ERROR: Backup directory '$BACKUP_DIR' does not exist."
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$RESTORED_DATA"

# Step 1: Prepare and copy-back the backup
log "Step 1/5: Preparing mariabackup..."
docker run --rm \
  -v "$(cd "$BACKUP_DIR" && pwd)":/backup \
  -v "$(cd "$RESTORED_DATA" && pwd)":/restored_data \
  "$IMAGE" bash -c "
    mariabackup --prepare --target-dir=/backup && \
    mariabackup --copy-back --target-dir=/backup --datadir=/restored_data && \
    chown -R mysql:mysql /restored_data
  "
log "Backup prepared and copied successfully."
echo ""

# Step 2: Start MariaDB with restored data
log "Step 2/5: Starting MariaDB container..."
docker run -d --name "$CONTAINER" \
  -e MYSQL_ROOT_PASSWORD="$ROOT_PASS" \
  -v "$(cd "$RESTORED_DATA" && pwd)":/var/lib/mysql \
  "$IMAGE"

wait_for_db
log "MariaDB is ready."
echo ""

# Step 3: Determine which databases to dump
log "Step 3/5: Resolving databases..."
if [ -n "$DATABASES" ]; then
  IFS=',' read -ra DB_LIST <<< "$DATABASES"
  log "Selected databases: ${DB_LIST[*]}"
else
  log "No databases specified. Discovering all user databases..."
  mapfile -t DB_LIST < <(get_all_databases)
  log "Found ${#DB_LIST[@]} databases: ${DB_LIST[*]}"
fi
echo ""

# Step 4: Validate
if [ ${#DB_LIST[@]} -eq 0 ]; then
  log "ERROR: No databases found to dump."
  exit 1
fi

# Step 5: Dump each database
log "Step 4/5: Dumping databases..."
echo ""
FAILED=()
SUCCESS=()
for db in "${DB_LIST[@]}"; do
  db=$(echo "$db" | xargs)
  if dump_database "$db"; then
    SUCCESS+=("$db")
  else
    log "WARNING: Failed to dump '$db'"
    FAILED+=("$db")
  fi
  echo ""
done

# Step 6: Summary
log "Step 5/5: Summary"
echo ""
log "============================================"
log "              DUMP SUMMARY                  "
log "============================================"
log "Output directory: $OUTPUT_DIR"
log "Skip full dump:   $SKIP_FULL"
log "Total databases:  ${#DB_LIST[@]}"
log "Successful:       ${#SUCCESS[@]}"
log "Failed:           ${#FAILED[@]}"
log ""
for db in "${SUCCESS[@]}"; do
  db=$(echo "$db" | xargs)
  db_dir="$OUTPUT_DIR/$db"
  if [ -d "$db_dir" ]; then
    log "[$db]"
    for f in "$db_dir"/*.sql; do
      log "  $(basename "$f")  $(file_size_formatted "$f")"
    done
    log ""
  fi
done
if [ ${#FAILED[@]} -gt 0 ]; then
  log "FAILED databases: ${FAILED[*]}"
fi
log "============================================"
log "Done!"
