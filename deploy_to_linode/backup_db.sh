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
# Off-site: set RCLONE_REMOTE (e.g. gcrypt:db) to copy each verified dump
# there, gzipped (a -Ft dump is uncompressed: 741 MB -> 140 MB in Oct 2026,
# which is what makes 30 days fit Google Drive's free 15 GB). Remote copies
# older than OFFSITE_DAYS are pruned (on Google Drive a delete goes to its
# trash for 30 more days). Leave it empty to skip.
#
# Uploads: set RCLONE_UPLOADS_REMOTE (e.g. gcrypt:uploads) to copy note
# attachments from UPLOADS_DIR after the dump. `copy`, never `sync`: files are
# only added, so a wiped or damaged server folder never empties the backup.
# `--ignore-existing`: an upload is never rewritten (UUID names), so a file
# already backed up is never sent again — a damaged server copy (bad disk,
# ransomware) cannot replace the good one. Not `--immutable`: through crypt
# rclone has no hashes and compares mtimes, so a `chown -R` or a server move
# that resets mtimes would fail every night's run.
# Skipped: scans/ (half-finished phone scans, pruned after 24 h) and PDF
# *.thumb.* previews (rebuilt on demand). tray/ folders must stay: a saved
# note's files keep their upload path. Nothing is pruned remotely.
#
# Google Drive setup (once, as root — cron reads /root/.config/rclone):
#   1. On the server:  sudo rclone config
#      n) new remote "gdrive", type drive, client id blank (default is fine at
#         this volume), scope "drive.file" (the server sees only files rclone
#         made, not the rest of the Drive), "Use auto config?" n. It prints
#         `rclone authorize "drive" "<blob>"`: run that on a PC with a
#         browser, sign in, paste the token it prints back into the server.
#   2. Still in rclone config:
#      n) new remote "gcrypt", type crypt, remote "gdrive:fullcircle_backup",
#         filename encryption standard, generate a password AND a salt.
#      Put both crypt passwords in a password manager: without them the
#      backup cannot be read, by anyone, including you.
#   3. Set RCLONE_REMOTE=gcrypt:db and RCLONE_UPLOADS_REMOTE=gcrypt:uploads in
#      the crontab line (or edit the defaults below), run the script once by
#      hand and read backup.log.
#
# Failure email: set ALERT_TO (e.g. you@gmail.com) on the crontab line. Any
# failed run — a checked step (FAILED: …) or an unexpected exit — mails the
# last 30 log lines there, through the app's own SMTP account: MAIL_HOST,
# MAIL_PORT, MAIL_USERNAME, MAIL_PASSWORD and MAIL_FROM are read from
# MAIL_COMPOSE (the app's compose file), so a rotated password needs no edit
# here. Port 465 is implicit TLS, anything else STARTTLS; TLS is required.
# A run that never starts (cron gone, server down) sends nothing — read
# backup.log now and then.
#
# Restore (any machine with the same rclone.conf):
#   rclone copy gcrypt:db/backup_at_<stamp>.tar.gz . && gunzip backup_at_<stamp>.tar.gz
#   scripts/restore_backup.sh backup_at_<stamp>.tar
#   rclone copy gcrypt:uploads /home/fullcircle/uploads   # or one file's path
set -euo pipefail

DB_NAME="${DB_NAME:-fullcircle}"
DB_USER="${DB_USER:-deployer}"
DB_HOST="${DB_HOST:-localhost}"
BACKUP_DIR="${BACKUP_DIR:-/home/fullcircle/db_backup}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
UPLOADS_DIR="${UPLOADS_DIR:-/home/fullcircle/uploads}"
RCLONE_UPLOADS_REMOTE="${RCLONE_UPLOADS_REMOTE:-}"
ALERT_TO="${ALERT_TO:-}"
MAIL_COMPOSE="${MAIL_COMPOSE:-/home/fullcircle/docker-compose-fullcircle.yml}"
OFFSITE_DAYS="${OFFSITE_DAYS:-30}"
LOG_FILE="${LOG_FILE:-$BACKUP_DIR/backup.log}"

mkdir -p "$BACKUP_DIR/monthly"
exec >>"$LOG_FILE" 2>&1

log() { echo "$(date '+%F %T') $*"; }

# `      - MAIL_HOST=smtp.gmail.com` in the compose file -> smtp.gmail.com
mail_setting() { sed -n "s/^[[:space:]]*- $1=//p" "$MAIL_COMPOSE" | head -n 1; }

# Never fails the run: a broken alert is logged, the run's own result stands.
alert() {
  [ -n "$ALERT_TO" ] || return 0
  [ -r "$MAIL_COMPOSE" ] || { log "WARN: no alert sent: cannot read $MAIL_COMPOSE"; return 0; }
  local host port user pass from scheme=smtp
  host="$(mail_setting MAIL_HOST)"
  port="$(mail_setting MAIL_PORT)"
  user="$(mail_setting MAIL_USERNAME)"
  pass="$(mail_setting MAIL_PASSWORD)"
  from="$(mail_setting MAIL_FROM)"
  [ "$port" = 465 ] && scheme=smtps
  pass="${pass//\\/\\\\}"
  pass="${pass//\"/\\\"}"
  # The login goes to curl through -K, not argv, so `ps` never shows it.
  if {
    printf 'From: FullCircle backup <%s>\nTo: %s\nSubject: [backup] FAILED on %s: %s\nDate: %s\n\n' \
      "$from" "$ALERT_TO" "$(hostname)" "$1" "$(date -R)"
    tail -n 30 "$LOG_FILE"
  } | sed 's/$/\r/' | curl -sS --max-time 60 --ssl-reqd --url "$scheme://$host:$port" \
    --mail-from "$from" --mail-rcpt "$ALERT_TO" --upload-file - \
    -K <(printf 'user = "%s:%s"\n' "$user" "$pass"); then
    log "alert sent to $ALERT_TO"
  else
    log "WARN: alert email to $ALERT_TO failed"
  fi
}

alerted=0
fail() {
  log "FAILED: $*"
  alerted=1
  alert "$*"
  exit 1
}

# Also catches a step that fails without `|| fail` (set -e): no silent exits.
on_exit() {
  local rc=$?
  rm -f "${partial:-}" "${gz:-}"
  if [ "$rc" -ne 0 ] && [ "$alerted" -eq 0 ]; then
    log "FAILED: exited $rc"
    alert "exited $rc"
  fi
}
trap on_exit EXIT

# One run at a time (a slow dump must not overlap the next one).
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || fail "another backup is still running"

stamp="$(date +%Y%m%d%H%M%S)"
final="$BACKUP_DIR/backup_at_${stamp}.tar"
partial="$final.partial"
gz="$final.gz"

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
  # Compressed for the trip only: the local dump stays a plain .tar for
  # scripts/restore_backup.sh (gunzip an off-site copy first).
  gzip -c "$final" >"$gz" || fail "gzip for off-site copy"
  rclone copy "$gz" "$RCLONE_REMOTE" || fail "off-site copy to $RCLONE_REMOTE"
  rm -f "$gz"
  rclone delete "$RCLONE_REMOTE" --min-age "${OFFSITE_DAYS}d" --include 'backup_at_*.tar*' \
    || log "WARN: off-site prune failed (copy succeeded)"
  log "off-site: copied to $RCLONE_REMOTE"
fi

# After the dump: a file is written before its row, so a restored dump never
# names a file this copy is missing.
if [ -n "$RCLONE_UPLOADS_REMOTE" ]; then
  [ -d "$UPLOADS_DIR" ] || fail "uploads dir $UPLOADS_DIR not found"
  # -v for the closing stats line; rclone's own exit code decides success.
  if ! out="$(rclone copy "$UPLOADS_DIR" "$RCLONE_UPLOADS_REMOTE" --ignore-existing \
    --exclude '*/scans/**' --exclude '*.thumb.*' --stats-one-line -v 2>&1)"; then
    grep -E 'ERROR' <<<"$out" | tail -n 5 || true
    fail "uploads copy to $RCLONE_UPLOADS_REMOTE"
  fi
  log "uploads: copied to $RCLONE_UPLOADS_REMOTE ($(grep -c 'Copied (new)' <<<"$out" || true) new files)"
fi

log "done"
