# MariaDB Backup Restore & SQL Dump Tool

A set of Bash scripts to restore MariaDB backups (created with `mariabackup`) using Docker and export them as organized SQL dump files. Includes a separate import script to restore dumps into any MariaDB instance.

## Overview

This project solves a common workflow: you have a physical backup from `mariabackup` and need to convert it into portable SQL files — separated by type (schema, data, triggers, routines, etc.) — for selective restoration, migration, or archival.

```
mariabackup files  →  restore_and_dump.sh  →  Organized SQL files  →  import.sh  →  Target database
```

## Features

- **Docker-based** — no local MariaDB installation required
- **Selective database dump** — specify databases or dump all automatically
- **Separated SQL files** — schema, data, views, routines, triggers, events, and grants in individual files
- **Optional full dump** — combined dump file for quick full restores (can be skipped with `-s`)
- **Interactive password prompt** — use `-p` without a value for secure password entry
- **Optimized large file import** — disables FK checks, unique checks, and autocommit for faster imports
- **Progress indication** — supports `pv` progress bars or periodic elapsed time updates
- **Post-import verification** — reports table and row counts after import
- **Automatic cleanup** — removes temporary containers and data on exit

## Prerequisites

- **Docker** — installed and running
- **Bash** — version 4.0+
- **pv** (optional) — for progress bars during large file imports

```bash
# Install pv (optional but recommended)
# Ubuntu/Debian
sudo apt install pv

# macOS
brew install pv
```

## Project Structure

```
.
├── restore_and_dump.sh    # Restore mariabackup and export to SQL files
├── import.sh              # Import SQL files into a MariaDB instance
├── backup/                # Place your mariabackup files here
└── output/                # Generated SQL dumps (created automatically)
    └── <database_name>/
        ├── schema.sql     # CREATE TABLE / CREATE INDEX statements
        ├── data.sql       # INSERT statements only
        ├── views.sql      # CREATE VIEW definitions
        ├── routines.sql   # Stored procedures & functions
        ├── triggers.sql   # CREATE TRIGGER definitions
        ├── events.sql     # CREATE EVENT (scheduled jobs)
        ├── grants.sql     # GRANT statements for database users
        └── full.sql       # Complete combined dump (optional)
```

## Usage

### restore_and_dump.sh

Restores a `mariabackup` backup inside a temporary Docker container and exports SQL dumps.

```bash
chmod +x restore_and_dump.sh

# Dump all databases
./restore_and_dump.sh -b ./backups/full_backup

# Dump specific databases
./restore_and_dump.sh -d myapp,orders -b ./backups/full_backup

# Skip full combined dump
./restore_and_dump.sh -d myapp -s -b ./backups/full_backup

# Prompt for password interactively
./restore_and_dump.sh -d myapp -s -p -b ./backups/full_backup

# Provide password inline
./restore_and_dump.sh -d myapp -s -p mysecret -b ./backups/full_backup

# Custom output directory and Docker image
./restore_and_dump.sh -d myapp -b ./backups/full_backup -o ./sql_output -i mariadb:10.5
```

**Options:**

| Flag | Description | Default |
|------|-------------|---------|
| `-d` | Comma-separated list of databases to dump | All databases |
| `-s` | Skip full combined dump | `false` |
| `-p` | MySQL root password (prompts if no value given) | `rootpass` |
| `-b` | Backup directory path | `./backup` |
| `-o` | Output directory path | `./output` |
| `-i` | MariaDB Docker image | `mariadb:10.5` |
| `-h` | Show help | — |

### import.sh

Imports SQL dump files into a target MariaDB instance in the correct dependency order.

```bash
chmod +x import.sh

# Basic usage
./import.sh <database_name> <sql_directory> [host] [port] [user]

# Import into local MariaDB
./import.sh erptest ./output/erplive

# Import into remote server
./import.sh erptest ./output/erplive db.example.com 3306 root

# Import with custom port
./import.sh erptest ./output/erplive localhost 3307 admin
```

**Arguments:**

| Argument | Description | Default |
|----------|-------------|---------|
| `database_name` | Target database name (created if not exists) | Required |
| `sql_directory` | Directory containing the SQL dump files | Required |
| `host` | MySQL host | `localhost` |
| `port` | MySQL port | `3306` |
| `user` | MySQL user | `root` |

## Import Order

The import script applies SQL files in a specific order to respect object dependencies:

```
1. schema.sql      → Tables & indexes (foundation for everything)
2. data.sql        → Row data (needs tables to exist)
3. views.sql       → Views (reference tables)
4. routines.sql    → Stored procedures & functions (reference tables + views)
5. triggers.sql    → Triggers (bound to tables, may call routines)
6. events.sql      → Scheduled events (may call routines)
7. grants.sql      → User permissions (applied last)
```

## SQL File Contents

| File | Contents | Use Case |
|------|----------|----------|
| `schema.sql` | `CREATE TABLE`, `CREATE INDEX` | Recreate structure without data |
| `data.sql` | `INSERT INTO` statements | Restore data into existing schema |
| `views.sql` | `CREATE VIEW` definitions | Restore views separately |
| `routines.sql` | `CREATE PROCEDURE`, `CREATE FUNCTION` | Restore stored procedures & functions |
| `triggers.sql` | `CREATE TRIGGER` definitions | Restore triggers separately |
| `events.sql` | `CREATE EVENT` definitions | Restore scheduled jobs |
| `grants.sql` | `GRANT` statements | Restore user permissions |
| `full.sql` | Everything combined | Quick full restore (single file) |

## Performance

### Large File Import Optimizations

When importing files larger than 10 MB, the import script automatically applies these optimizations:

- `SET FOREIGN_KEY_CHECKS=0` — skips foreign key validation
- `SET UNIQUE_CHECKS=0` — skips unique index checks
- `SET AUTOCOMMIT=0` — batches inserts in a single transaction
- `SET sql_log_bin=0` — disables binary logging
- `--max-allowed-packet=512M` — handles large INSERT statements

### Estimated Import Times

| Data Size | Approximate Time |
|-----------|-----------------|
| < 100 MB | < 1 minute |
| 1 GB | 5–15 minutes |
| 10 GB | 30–90 minutes |
| 50 GB+ | Several hours |

Times vary based on hardware, disk speed, and table complexity.

## Troubleshooting

### Common Issues

**Foreign key errors during import**

Add to the top of `schema.sql` and `data.sql`:
```sql
SET FOREIGN_KEY_CHECKS=0;
```

**Packet too large errors**

The import script already uses `--max-allowed-packet=512M`. If you still hit limits, increase it in your MariaDB server config:
```ini
[mysqld]
max_allowed_packet=1G
```

**Permission denied during cleanup**

The restore script uses a Docker container to clean up files created by the MariaDB process. If manual cleanup is needed:
```bash
docker run --rm -v $(pwd)/restored_data:/data mariadb:10.5 rm -rf /data/*
rmdir restored_data
```

**Empty SQL files after dump**

Verify the database name matches exactly (case-sensitive). The script will list available databases if the specified one is not found.

**Import appears to hang**

Large `data.sql` files (10+ GB) take time. Install `pv` for a real progress bar:
```bash
sudo apt install pv   # Debian/Ubuntu
brew install pv        # macOS
```

### Verifying a Successful Import

After import, the script shows table and row counts. You can also verify manually:

```sql
-- Check table count
SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='your_database';

-- Check row counts per table
SELECT TABLE_NAME, TABLE_ROWS 
FROM information_schema.TABLES 
WHERE TABLE_SCHEMA='your_database' 
ORDER BY TABLE_ROWS DESC;

-- Check routines
SELECT ROUTINE_NAME, ROUTINE_TYPE 
FROM information_schema.ROUTINES 
WHERE ROUTINE_SCHEMA='your_database';

-- Check triggers
SELECT TRIGGER_NAME, EVENT_OBJECT_TABLE 
FROM information_schema.TRIGGERS 
WHERE TRIGGER_SCHEMA='your_database';
```

## Example Workflow

```bash
# 1. Place your mariabackup files in a directory
ls ./backups/full_backup/
# ibdata1  ib_logfile0  ib_logfile1  mysql/  erplive/  ...

# 2. Restore and dump to SQL (skip full combined dump)
./restore_and_dump.sh -d erplive -s -p -b ./backups/full_backup

# 3. Review the output
ls ./output/erplive/
# schema.sql  data.sql  views.sql  routines.sql  triggers.sql  events.sql  grants.sql

# 4. Import into a new database
./import.sh erptest ./output/erplive localhost 3306 root

# 5. Verify
mysql -u root -p -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='erptest';"
```

## Requirements

| Component | Version |
|-----------|---------|
| Docker | 20.10+ |
| Bash | 4.0+ |
| MariaDB image | 10.5 (configurable via `-i`) |
| pv | Any (optional) |

## License

MIT
