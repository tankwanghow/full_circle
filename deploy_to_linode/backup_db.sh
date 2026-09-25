#!/bin/bash
# Nightly production backup: dump, verify, rotate, copy off-site.
#
# Replaces the raw pg_dump + `find /home ... -delete` crontab lines. Install:
#
#   sudo install -m 750 backup_db.sh /usr/local/bin/fullcircle_backup_db.sh
#   # password lives in ~/.pgpass of the user cron runs as (root), not in cron:
#   echo 'localhost:5432:fullcircle:deployer:<password>' | sudo tee /root/.pgpass
#   sudo chmod 600 /root/.pgpass
#   # sudo crontab -e  -> one line:
#   0 13 * * * /usr/local/bin/fullcircle_backup_db.sh
#
# Files keep the backup_at_YYYYmmddHHMMSS.tar name so
# scripts/restore_backup.sh works on them unchanged.
#
# Retention: newest KEEP_DAILY dumps in BACKUP_DIR, plus the first dump of each
# month hard-linked into BACKUP_DIR/monthly (newest KEEP_MONTHLY kept).
# Rotation is by count, never by age: if dumps start failing, nothing is deleted.
#
# Off-site: set RCLONE_REMOTE (e.g. gdrive:fullcircle_backups) to copy each
# verified dump there; remote copies older than OFFSITE_DAYS are pruned.
# Leave it empty to skip.
set -euo pipefail

DB_NAME="${DB_NAME:-fullcircle}"
DB_USER="${DB_USER:-deployer}"
DB_HOST="${DB_HOST:-localhost}"
BACKUP_DIR="${BACKUP_DIR:-/home/fullcircle/db_backup}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
OFFSITE_DAYS="${OFFSITE_DAYS:-60}"
LOG_FILE="${LOG_FILE:-$BACKUP_DIR/backup.log}"

mkdir -p "$BACKUP_DIR/monthly"
exec >>"$LOG_FILE" 2>&1

log() { echo "$(date '+%F %T') $*"; }
fail() { log "FAILED: $*"; exit 1; }

# One run at a time (a slow dump must not overlap the next one).
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || fail "another backup is still running"

stamp="$(date +%Y%m%d%H%M%S)"
final="$BACKUP_DIR/backup_at_${stamp}.tar"
partial="$final.partial"
trap 'rm -f "$partial"' EXIT

log "dump $DB_NAME -> $final"
pg_dump -w -U "$DB_USER" -h "$DB_HOST" -d "$DB_NAME" -Ft -f "$partial" \
  || fail "pg_dump exited $?"

# A readable table of contents proves the archive is complete, not truncated.
toc="$(pg_restore -l "$partial")" || fail "pg_restore -l cannot read the archive"
toc_entries="$(grep -vc '^;' <<<"$toc" || true)"
[ "$toc_entries" -gt 0 ] || fail "archive has an empty table of contents"

mv "$partial" "$final"
log "ok: $(du -h "$final" | cut -f1), $toc_entries TOC entries"

# First dump of the month also goes to monthly/ (hard link: no extra space).
month="${stamp:0:6}"
if ! compgen -G "$BACKUP_DIR/monthly/backup_at_${month}*.tar" >/dev/null; then
  ln "$final" "$BACKUP_DIR/monthly/"
  log "monthly: kept $(basename "$final")"
fi

# Keep the newest N by name (the timestamp sorts chronologically).
prune() {
  local dir=$1 keep=$2
  find "$dir" -maxdepth 1 -type f -name 'backup_at_*.tar' -printf '%f\n' \
    | sort -r | tail -n +"$((keep + 1))" \
    | while read -r f; do rm -f -- "$dir/$f"; log "pruned $dir/$f"; done
}
prune "$BACKUP_DIR" "$KEEP_DAILY"
prune "$BACKUP_DIR/monthly" "$KEEP_MONTHLY"

if [ -n "$RCLONE_REMOTE" ]; then
  rclone copy "$final" "$RCLONE_REMOTE" || fail "off-site copy to $RCLONE_REMOTE"
  rclone delete "$RCLONE_REMOTE" --min-age "${OFFSITE_DAYS}d" --include 'backup_at_*.tar' \
    || log "WARN: off-site prune failed (copy succeeded)"
  log "off-site: copied to $RCLONE_REMOTE"
fi

log "done"
