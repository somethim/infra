#!/usr/bin/env bash
# Tests roles/host/files/infra-backup against a fake docker and mountpoint:
# every path is a temp dir (INFRA_BACKUP_ROOT, INFRA_BACKUP_MEDIA_ROOT), the
# volumes are temp dirs the fake `docker volume inspect` names, and tar, gzip
# and rsync are real. Nothing here touches the local Docker daemon or a disk.
#
#   bash ci/backup-scripts.sh
#
# Prints "ok   ..." per case and stops with "FAIL ..." on the first failure.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
backup="$root/roles/host/files/infra-backup"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat >"$work/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="$FAKE_STATE"
printf '%s\n' "$*" >>"$state/calls"
case "$1" in
  exec)
    [ "$*" = "exec postgresql pg_dumpall -U postgres" ] || { echo "fake docker: unsupported exec: $*" >&2; exit 2; }
    [ ! -f "$state/pg.rc" ] || { echo "pg_dumpall: error: connection to server failed" >&2; exit "$(cat "$state/pg.rc")"; }
    printf -- '--\n-- PostgreSQL database cluster dump\n--\nCREATE ROLE portfolio;\n'
    ;;
  container)
    [ "$2 $3 $4" = "inspect --format {{.State.Running}}" ] || { echo "fake docker: unsupported: $*" >&2; exit 2; }
    if [ -f "$state/running/$5" ]; then echo true; elif [ -f "$state/stopped/$5" ]; then echo false; else echo "Error: No such container: $5" >&2; exit 1; fi
    ;;
  stop)
    name="${!#}"
    [ ! -f "$state/stop.rc" ] || exit "$(cat "$state/stop.rc")"
    rm -f "$state/running/$name"
    touch "$state/stopped/$name"
    ;;
  start)
    [ ! -f "$state/start.rc" ] || exit "$(cat "$state/start.rc")"
    rm -f "$state/stopped/$2"
    touch "$state/running/$2"
    ;;
  volume)
    [ "$2 $3 $4" = "inspect --format {{.Mountpoint}}" ] || { echo "fake docker: unsupported: $*" >&2; exit 2; }
    [ -d "$state/volumes/$5" ] || { echo "Error: No such volume: $5" >&2; exit 1; }
    printf '%s\n' "$state/volumes/$5"
    ;;
  *) echo "fake docker: unsupported: $*" >&2; exit 2 ;;
esac
SH
cat >"$work/bin/mountpoint" <<'SH'
#!/usr/bin/env bash
[ "$1" = -q ] || { echo "fake mountpoint: unsupported: $*" >&2; exit 2; }
[ -f "$FAKE_STATE/mounted" ] && [ "$2" = "$FAKE_STATE/backup" ]
SH
# rsync is real; the wrapper records which folder each run mirrored, in order with the docker calls.
real_rsync="$(command -v rsync)"
cat >"$work/bin/rsync" <<SH
#!/usr/bin/env bash
printf 'rsync %s\n' "\${@: -2:1}" >>"\$FAKE_STATE/calls"
exec "$real_rsync" "\$@"
SH
chmod +x "$work/bin/docker" "$work/bin/mountpoint" "$work/bin/rsync"

count=0
state=""
new_state() {
  local volume
  count=$((count + 1))
  state="$work/state$count"
  mkdir -p "$state/backup" "$state/running" "$state/stopped" "$state/volumes"
  touch "$state/mounted" "$state/calls"
  for volume in jellyfin-config audiobookshelf-config audiobookshelf-metadata kavita-config open-webui-data portfolio-media hypernova_prizm-storage ollama-models beszel-data garage-meta; do
    mkdir -p "$state/volumes/$volume"
    echo "$volume data" >"$state/volumes/$volume/data.db"
  done
  mkdir -p "$state/volumes/jellyfin-config/log" "$state/volumes/jellyfin-config/metadata" "$state/volumes/open-webui-data/cache/embedding" \
    "$state/volumes/kavita-config/cache" "$state/volumes/audiobookshelf-metadata/cache"
  echo log >"$state/volumes/jellyfin-config/log/log_1.log"
  echo poster >"$state/volumes/jellyfin-config/metadata/poster.jpg"
  echo model >"$state/volumes/open-webui-data/cache/embedding/model.bin"
  echo page >"$state/volumes/kavita-config/cache/page.png"
  echo cover >"$state/volumes/audiobookshelf-metadata/cache/cover.jpg"
  echo weights >"$state/volumes/ollama-models/blob"
  mkdir -p "$state/media/audiobooks/Author/Book" "$state/media/books" "$state/media/podcasts/Show" "$state/media/movies"
  echo chapter >"$state/media/audiobooks/Author/Book/01.mp3"
  echo epub >"$state/media/books/novel.epub"
  echo episode >"$state/media/podcasts/Show/ep1.mp3"
  echo film >"$state/media/movies/film.mkv"
  mkdir -p "$state/media/s3/ab/cd"
  echo object >"$state/media/s3/ab/cd/abcdef"
  touch "$state/running/jellyfin" "$state/running/audiobookshelf" "$state/running/open-webui" "$state/stopped/kavita" \
    "$state/running/beszel" "$state/running/garage"
}

run_backup() {
  PATH="$work/bin:$PATH" FAKE_STATE="$state" INFRA_BACKUP_ROOT="$state/backup" INFRA_BACKUP_MEDIA_ROOT="$state/media" \
    INFRA_BACKUP_DATE="${1:-2026-10-15}" "$backup" >"$work/out" 2>&1
}

expect_ok() {
  local name="$1"
  shift
  if ! run_backup "$@"; then cat "$work/out"; echo "FAIL expected success: $name"; exit 1; fi
  grep -q "^infra-backup: backup OK: " "$work/out" || { cat "$work/out"; echo "FAIL no backup OK line: $name"; exit 1; }
}

expect_failed() {
  local name="$1" want="$2"
  shift 2
  if run_backup "$@"; then cat "$work/out"; echo "FAIL expected failure: $name"; exit 1; fi
  grep -qE -- "$want" "$work/out" || { cat "$work/out"; echo "FAIL failed for the wrong reason (wanted '$want'): $name"; exit 1; }
}

members() {
  tar -tzf "$1" | sed 's,^\./,,; s,/$,,' | grep . | LC_ALL=C sort
}

### No backup disk: nothing is written anywhere

new_state
rm "$state/mounted"
if ! run_backup; then cat "$work/out"; echo "FAIL a missing backup disk failed the run"; exit 1; fi
grep -q "WARNING: .*/backup is not a mountpoint .*: nothing was written" "$work/out" || { cat "$work/out"; echo "FAIL no warning for a missing backup disk"; exit 1; }
[ -z "$(find "$state/backup" -mindepth 1 -print -quit)" ] || { find "$state/backup"; echo "FAIL something was written without the backup disk"; exit 1; }
[ ! -s "$state/calls" ] || { cat "$state/calls"; echo "FAIL docker was called without the backup disk"; exit 1; }
[ -f "$state/running/jellyfin" ] || { echo "FAIL a container was stopped without the backup disk"; exit 1; }
echo "ok   no backup disk: a warning, exit 0, nothing written, nothing stopped"

### A full run

new_state
expect_ok "a full run"
dump="$state/backup/postgres/2026-10-15.sql.gz"
[ -f "$dump" ] || { find "$state/backup"; echo "FAIL no PostgreSQL dump"; exit 1; }
gzip -cd "$dump" | grep -q "PostgreSQL database cluster dump" || { echo "FAIL the dump is not pg_dumpall's output"; exit 1; }
[ "$(stat -c %a "$dump")" = 600 ] || { echo "FAIL the dump is not 0600"; exit 1; }
for dir in "$state/backup" "$state/backup/postgres" "$state/backup/apps" "$state/backup/apps/2026-10-15" "$state/backup/media"; do
  [ "$(stat -c %a "$dir")" = 700 ] || { echo "FAIL $dir is not 0700"; exit 1; }
done
echo "ok   PostgreSQL: pg_dumpall to postgres/<date>.sql.gz, 0600, in 0700 directories"
apps="$state/backup/apps/2026-10-15"
want_tars="$(printf '%s.tar.gz\n' audiobookshelf-config audiobookshelf-metadata hypernova_prizm-storage jellyfin-config kavita-config open-webui-data portfolio-media beszel-data garage-meta | LC_ALL=C sort)"
[ "$(find "$apps" -mindepth 1 -printf '%f\n' | LC_ALL=C sort)" = "$want_tars" ] || { find "$apps"; echo "FAIL the app backup does not hold exactly the app volumes"; exit 1; }
grep -q 'ollama-models' "$state/calls" && { echo "FAIL the Ollama models were looked at"; exit 1; }
[ "$(members "$apps/jellyfin-config.tar.gz")" = "$(printf '%s\n' data.db metadata metadata/poster.jpg)" ] || { members "$apps/jellyfin-config.tar.gz"; echo "FAIL jellyfin-config: logs left in, or data missing"; exit 1; }
[ "$(members "$apps/open-webui-data.tar.gz")" = data.db ] || { members "$apps/open-webui-data.tar.gz"; echo "FAIL open-webui-data: the model cache was copied"; exit 1; }
[ "$(members "$apps/kavita-config.tar.gz")" = data.db ] || { members "$apps/kavita-config.tar.gz"; echo "FAIL kavita-config: its cache was copied"; exit 1; }
[ "$(members "$apps/audiobookshelf-metadata.tar.gz")" = data.db ] || { members "$apps/audiobookshelf-metadata.tar.gz"; echo "FAIL audiobookshelf-metadata: its cache was copied"; exit 1; }
echo "ok   apps: one tar per app volume, caches and logs left out, never the Ollama models"
for name in jellyfin audiobookshelf open-webui beszel garage; do
  stop_line="$(grep -n "^stop --time 60 $name$" "$state/calls" | cut -d: -f1)"
  start_line="$(grep -n "^start $name$" "$state/calls" | cut -d: -f1)"
  first_volume="$(grep -n '^volume inspect' "$state/calls" | head -n 1 | cut -d: -f1)"
  last_volume="$(grep -n '^volume inspect' "$state/calls" | tail -n 1 | cut -d: -f1)"
  [ -n "$stop_line" ] && [ -n "$start_line" ] && [ "$stop_line" -lt "$first_volume" ] && [ "$start_line" -gt "$last_volume" ] ||
    { cat "$state/calls"; echo "FAIL $name was not stopped for the whole copy"; exit 1; }
  [ -f "$state/running/$name" ] || { echo "FAIL $name does not run after the backup"; exit 1; }
done
grep -q '^start kavita$' "$state/calls" && { echo "FAIL a container that was not running was started"; exit 1; }
diff -r "$state/media/s3" "$state/backup/media/s3" >/dev/null || { echo "FAIL Garage's objects are not mirrored"; exit 1; }
s3_line="$(grep -n "^rsync $state/media/s3/$" "$state/calls" | cut -d: -f1)"
[ -n "$s3_line" ] && [ "$s3_line" -gt "$(grep -n '^stop --time 60 garage$' "$state/calls" | cut -d: -f1)" ] &&
  [ "$s3_line" -lt "$(grep -n '^start garage$' "$state/calls" | cut -d: -f1)" ] ||
  { cat "$state/calls"; echo "FAIL Garage's objects were not mirrored while Garage was stopped"; exit 1; }
echo "ok   Garage: its metadata volume tarred and its objects mirrored while it is stopped"
echo "ok   apps: the running app containers are stopped for the copy and started again; a stopped one stays stopped"
for name in audiobooks books podcasts; do
  diff -r "$state/media/$name" "$state/backup/media/$name" >/dev/null || { echo "FAIL $name is not mirrored"; exit 1; }
done
[ ! -e "$state/backup/media/movies" ] || { echo "FAIL movies were mirrored"; exit 1; }
rm "$state/media/podcasts/Show/ep1.mp3"
echo episode2 >"$state/media/podcasts/Show/ep2.mp3"
expect_ok "a second night" 2026-10-16
[ ! -e "$state/backup/media/podcasts/Show/ep1.mp3" ] && [ -f "$state/backup/media/podcasts/Show/ep2.mp3" ] || { echo "FAIL the mirror does not follow deletions"; exit 1; }
[ -f "$state/backup/postgres/2026-10-15.sql.gz" ] && [ -f "$state/backup/postgres/2026-10-16.sql.gz" ] || { echo "FAIL a second night replaced the first"; exit 1; }
echo "ok   media: audiobooks, books and podcasts mirrored with --delete, movies and shows not"

### Retention

new_state
mkdir -p "$state/backup/postgres" "$state/backup/apps"
for day in $(seq -w 1 20); do
  echo old | gzip -c >"$state/backup/postgres/2026-09-$day.sql.gz"
  mkdir -p "$state/backup/apps/2026-09-$day"
done
echo keep >"$state/backup/postgres/notes.txt"
expect_ok "a run over 20 old nights"
[ "$(find "$state/backup/postgres" -name '*.sql.gz' | wc -l)" -eq 14 ] || { ls "$state/backup/postgres"; echo "FAIL not exactly 14 dumps kept"; exit 1; }
[ -f "$state/backup/postgres/2026-10-15.sql.gz" ] && [ -f "$state/backup/postgres/2026-09-08.sql.gz" ] && [ ! -e "$state/backup/postgres/2026-09-07.sql.gz" ] ||
  { ls "$state/backup/postgres"; echo "FAIL the newest 14 dumps were not the ones kept"; exit 1; }
[ -f "$state/backup/postgres/notes.txt" ] || { echo "FAIL a file that is not a dump was removed"; exit 1; }
[ "$(find "$state/backup/apps" -mindepth 1 -maxdepth 1 | wc -l)" -eq 7 ] || { ls "$state/backup/apps"; echo "FAIL not exactly 7 app backups kept"; exit 1; }
[ -d "$state/backup/apps/2026-10-15" ] && [ -d "$state/backup/apps/2026-09-15" ] && [ ! -e "$state/backup/apps/2026-09-14" ] ||
  { ls "$state/backup/apps"; echo "FAIL the newest 7 app backups were not the ones kept"; exit 1; }
echo "ok   retention: the newest 14 dumps and 7 app backups, nothing else removed"

### Failures: every step still runs, the run exits 1

new_state
mkdir -p "$state/backup/postgres"
echo previous | gzip -c >"$state/backup/postgres/2026-10-14.sql.gz"
echo 1 >"$state/pg.rc"
expect_failed "pg_dumpall fails" "FAILED: pg_dumpall of the postgresql container failed"
[ -z "$(find "$state/backup/postgres" -name '.*partial')" ] && [ ! -e "$state/backup/postgres/2026-10-15.sql.gz" ] || { ls -a "$state/backup/postgres"; echo "FAIL a failed dump was left behind"; exit 1; }
[ -f "$state/backup/postgres/2026-10-14.sql.gz" ] || { echo "FAIL a failed dump removed the previous one"; exit 1; }
[ -d "$state/backup/apps/2026-10-15" ] && [ -d "$state/backup/media/books" ] || { echo "FAIL a failed dump stopped the other steps"; exit 1; }
grep -q 'FAILED: 1 step(s) failed' "$work/out" || { cat "$work/out"; echo "FAIL no summary of the failed steps"; exit 1; }
echo "ok   a failed dump leaves no partial file, keeps the earlier dumps, and the other steps still run"

new_state
rm -rf "$state/media/books"
mkdir -p "$state/backup/media/books"
echo kept >"$state/backup/media/books/novel.epub"
expect_failed "the media disk is missing" "FAILED: .*/media/books does not exist \\(is the media disk mounted\\?\\)"
[ -f "$state/backup/media/books/novel.epub" ] || { echo "FAIL a missing library emptied its mirror"; exit 1; }
new_state
rm -rf "$state/media/audiobooks"/*
mkdir -p "$state/backup/media/audiobooks"
echo kept >"$state/backup/media/audiobooks/book.mp3"
expect_failed "an empty library over a full mirror" "FAILED: .*/media/audiobooks is empty but its mirror is not"
[ -f "$state/backup/media/audiobooks/book.mp3" ] || { echo "FAIL an empty library emptied its mirror"; exit 1; }
echo "ok   media: a missing or empty library never empties its mirror"

new_state
echo 1 >"$state/start.rc"
expect_failed "a container that does not start again" "FAILED: jellyfin could not be started again; sudo docker start jellyfin"
new_state
rm -rf "$state/volumes/kavita-config" "$state/volumes/hypernova_prizm-storage"
expect_ok "a host without some volumes yet"
grep -q "the volume kavita-config does not exist yet; skipped" "$work/out" || { cat "$work/out"; echo "FAIL a missing volume was not reported"; exit 1; }
echo "ok   a container that cannot start again fails the run; a volume that does not exist yet is skipped"

if [ "$(id -u)" -ne 0 ]; then
  new_state
  chmod 000 "$state/volumes/open-webui-data"
  expect_failed "an unreadable volume" "FAILED: tar of the volume open-webui-data failed"
  chmod 755 "$state/volumes/open-webui-data"
  [ ! -e "$state/backup/apps/2026-10-15" ] && [ -z "$(find "$state/backup/apps" -name '.*partial')" ] || { ls -a "$state/backup/apps"; echo "FAIL a failed app copy was kept"; exit 1; }
  for name in jellyfin audiobookshelf open-webui; do
    [ -f "$state/running/$name" ] || { echo "FAIL $name was left stopped after a failed copy"; exit 1; }
  done
  echo "ok   a failed app copy keeps no partial backup and starts the containers again"
fi

echo "backup-scripts: all cases passed"
