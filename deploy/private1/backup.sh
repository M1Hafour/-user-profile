#!/bin/bash
# Nightly MongoDB dump (run on private server 1), keeping the last 7 days. Cron line in AWS-GUIDE.md.
# Restore with:
#   gunzip -c FILE | docker exec -i mongodb sh -c 'mongorestore -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --drop'
set -euo pipefail

DEST="${BACKUP_DIR:-$HOME/backups}"
KEEP_DAYS="${KEEP_DAYS:-7}"
mkdir -p "$DEST"

FILE="$DEST/mongo-$(date +%F-%H%M).archive.gz"
TMP="$FILE.partial"
trap 'rm -f "$TMP"' EXIT

docker exec mongodb sh -c 'mongodump -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip' > "$TMP"

# An empty file means the dump failed silently; never keep one.
[ -s "$TMP" ] || { echo "backup is empty, aborting" >&2; exit 1; }
mv "$TMP" "$FILE"

find "$DEST" -name 'mongo-*.archive.gz' -mtime +"$KEEP_DAYS" -delete
echo "Backup written: $FILE ($(du -h "$FILE" | cut -f1))"
