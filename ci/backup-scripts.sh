#!/usr/bin/env bash
# Tests roles/host/files/infra-backup against a fake docker, mountpoint and df:
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
    case "$*" in
      "exec postgresql pg_dumpall -U postgres")
        [ ! -f "$state/pg.rc" ] || { echo "pg_dumpall: error: connection to server failed" >&2; exit "$(cat "$state/pg.rc")"; }
        printf -- '--\n-- PostgreSQL database cluster dump\n--\nCREATE ROLE portfolio;\n'
        ;;
      "exec immich-postgres pg_dumpall --clean --if-exists -U postgres")
        [ ! -f "$state/immich-pg.rc" ] || { echo "pg_dumpall: error: connection to server failed" >&2; exit "$(cat "$state/immich-pg.rc")"; }
        printf -- '--\n-- PostgreSQL database cluster dump\n--\nCREATE TABLE public.asset ();\n'
        ;;
      *) echo "fake docker: unsupported exec: $*" >&2; exit 2 ;;
    esac
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
# df: state/df.seq lines of "<avail> <size>", one per call (the last one repeats); default plenty free.
cat >"$work/bin/df" <<'SH'
#!/usr/bin/env bash
seq="$FAKE_STATE/df.seq"
echo "Avail Size"
if [ -f "$seq" ]; then
  head -n 1 "$seq"
  [ "$(wc -l <"$seq")" -le 1 ] || sed -i 1d "$seq"
else
  echo "900 1000"
fi
SH
chmod +x "$work/bin/docker" "$work/bin/mountpoint" "$work/bin/rsync" "$work/bin/df"


count=0
state=""
new_state() {
  local volume
  count=$((count + 1))
  state="$work/state$count"
  mkdir -p "$state/backup" "$state/running" "$state/stopped" "$state/volumes"
  touch "$state/mounted" "$state/calls"
  for volume in jellyfin-config audiobookshelf-config audiobookshelf-metadata kavita-config open-webui-data portfolio-media hypernova_prizm-storage ollama-models beszel-data garage-meta sftpgo-data; do
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
  mkdir -p "$state/media/photos/library/admin/2024/2024-05-01" "$state/media/photos/thumbs/u1" "$state/media/photos/encoded-video/u1" \
    "$state/media/photos/backups"
  echo photo >"$state/media/photos/library/admin/2024/2024-05-01/IMG_0001.jpg"
  echo thumb >"$state/media/photos/thumbs/u1/a_thumbnail.webp"
  echo video >"$state/media/photos/encoded-video/u1/a.mp4"
  echo dump >"$state/media/photos/backups/immich-db-backup.sql.gz"
  touch "$state/running/jellyfin" "$state/running/audiobookshelf" "$state/running/open-webui" "$state/stopped/kavita" \
    "$state/running/beszel" "$state/running/garage" "$state/running/sftpgo" "$state/running/immich-postgres"
}

run_backup() {
  : >"$state/calls"
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

snap() {
  printf '%s\n' "$state/backup/snapshots/$1"
}

inode() {
  stat -c %i "$1"
}

latest() {
  readlink "$state/backup/snapshots/latest"
}

# fake_snapshot <date> [complete]: a snapshot as an earlier night left it.
fake_snapshot() {
  local dir
  dir="$(snap "$1")"
  mkdir -p "$dir/media/books"
  echo "old $1" >"$dir/media/books/old.epub"
  [ "${2:-complete}" != complete ] || touch "$dir/.complete"
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

### A full run: one complete snapshot

new_state
expect_ok "a full run"
s1="$(snap 2026-10-15)"
[ -f "$s1/.complete" ] && [ "$(latest)" = 2026-10-15 ] || { find "$state/backup" -maxdepth 2; echo "FAIL no complete snapshot, or latest does not point at it"; exit 1; }
[ -z "$(find "$state/backup/snapshots" -maxdepth 1 -name '.*partial')" ] || { ls -a "$state/backup/snapshots"; echo "FAIL a partial snapshot was left after a good run"; exit 1; }
gzip -cd "$s1/postgres.sql.gz" | grep -q "PostgreSQL database cluster dump" || { echo "FAIL the snapshot has no pg_dumpall output"; exit 1; }
[ "$(stat -c %a "$s1/postgres.sql.gz")" = 600 ] || { echo "FAIL the dump is not 0600"; exit 1; }
for dir in "$state/backup" "$state/backup/snapshots" "$s1" "$s1/volumes" "$s1/media"; do
  [ "$(stat -c %a "$dir")" = 700 ] || { echo "FAIL $dir is not 0700"; exit 1; }
done
echo "ok   a run writes snapshots/<date> with .complete, latest points at it, dumps 0600 in 0700 directories"
want_volumes="$(printf '%s\n' audiobookshelf-config audiobookshelf-metadata hypernova_prizm-storage jellyfin-config kavita-config open-webui-data portfolio-media beszel-data garage-meta sftpgo-data | LC_ALL=C sort)"
[ "$(find "$s1/volumes" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" = "$want_volumes" ] || { ls "$s1/volumes"; echo "FAIL the snapshot does not hold exactly the app volumes"; exit 1; }
grep -q 'ollama-models' "$state/calls" && { echo "FAIL the Ollama models were looked at"; exit 1; }
[ -f "$s1/volumes/jellyfin-config/metadata/poster.jpg" ] && [ ! -e "$s1/volumes/jellyfin-config/log" ] || { find "$s1/volumes/jellyfin-config"; echo "FAIL jellyfin-config: logs left in, or data missing"; exit 1; }
[ ! -e "$s1/volumes/open-webui-data/cache" ] && [ ! -e "$s1/volumes/kavita-config/cache" ] && [ ! -e "$s1/volumes/audiobookshelf-metadata/cache" ] ||
  { echo "FAIL an app cache was copied"; exit 1; }
echo "ok   apps: one tree per app volume, caches and logs left out, never the Ollama models"
for name in jellyfin audiobookshelf open-webui beszel garage sftpgo; do
  stop_line="$(grep -n "^stop --time 60 $name$" "$state/calls" | cut -d: -f1)"
  start_line="$(grep -n "^start $name$" "$state/calls" | cut -d: -f1)"
  first_volume="$(grep -n '^volume inspect' "$state/calls" | head -n 1 | cut -d: -f1)"
  last_volume="$(grep -n '^volume inspect' "$state/calls" | tail -n 1 | cut -d: -f1)"
  [ -n "$stop_line" ] && [ -n "$start_line" ] && [ "$stop_line" -lt "$first_volume" ] && [ "$start_line" -gt "$last_volume" ] ||
    { cat "$state/calls"; echo "FAIL $name was not stopped for the whole copy"; exit 1; }
  [ -f "$state/running/$name" ] || { echo "FAIL $name does not run after the backup"; exit 1; }
done
grep -q '^start kavita$' "$state/calls" && { echo "FAIL a container that was not running was started"; exit 1; }
diff -r "$state/media/s3" "$s1/media/s3" >/dev/null || { echo "FAIL Garage's objects are not in the snapshot"; exit 1; }
s3_line="$(grep -n "^rsync $state/media/s3/$" "$state/calls" | cut -d: -f1)"
[ -n "$s3_line" ] && [ "$s3_line" -gt "$(grep -n '^stop --time 60 garage$' "$state/calls" | cut -d: -f1)" ] &&
  [ "$s3_line" -lt "$(grep -n '^start garage$' "$state/calls" | cut -d: -f1)" ] ||
  { cat "$state/calls"; echo "FAIL Garage's objects were not copied while Garage was stopped"; exit 1; }
echo "ok   Garage: its metadata volume and its objects copied while it is stopped; the apps are started again"
for name in audiobooks books podcasts; do
  diff -r "$state/media/$name" "$s1/media/$name" >/dev/null || { echo "FAIL $name is not in the snapshot"; exit 1; }
done
[ ! -e "$s1/media/movies" ] || { echo "FAIL movies were copied"; exit 1; }
gzip -cd "$s1/immich.sql.gz" | grep -q "CREATE TABLE public.asset" && [ "$(stat -c %a "$s1/immich.sql.gz")" = 600 ] || { echo "FAIL no 0600 Immich dump in the snapshot"; exit 1; }
[ -f "$s1/media/photos/library/admin/2024/2024-05-01/IMG_0001.jpg" ] && [ -f "$s1/media/photos/backups/immich-db-backup.sql.gz" ] &&
  [ ! -e "$s1/media/photos/thumbs" ] && [ ! -e "$s1/media/photos/encoded-video" ] || { find "$s1/media/photos"; echo "FAIL Immich's photos copied wrong"; exit 1; }
dump_line="$(grep -n '^exec immich-postgres' "$state/calls" | head -n 1 | cut -d: -f1)"
photos_line="$(grep -n "^rsync $state/media/photos/$" "$state/calls" | head -n 1 | cut -d: -f1)"
[ -n "$dump_line" ] && [ -n "$photos_line" ] && [ "$dump_line" -lt "$photos_line" ] || { cat "$state/calls"; echo "FAIL Immich's database was not dumped before its photos were copied"; exit 1; }
echo "ok   media and Immich: libraries copied (not movies), Immich dumped before its photos, without thumbs and encoded video"

### A second night: hard links for what did not change, deletions stay recoverable

rm "$state/media/podcasts/Show/ep1.mp3"
echo episode2 >"$state/media/podcasts/Show/ep2.mp3"
expect_ok "a second night" 2026-10-16
s2="$(snap 2026-10-16)"
[ "$(latest)" = 2026-10-16 ] || { echo "FAIL latest does not follow the newest snapshot"; exit 1; }
[ ! -e "$s2/media/podcasts/Show/ep1.mp3" ] && [ -f "$s2/media/podcasts/Show/ep2.mp3" ] || { echo "FAIL the new snapshot does not match the library"; exit 1; }
[ -f "$s1/media/podcasts/Show/ep1.mp3" ] || { echo "FAIL a deleted file vanished from the earlier snapshot"; exit 1; }
[ "$(inode "$s1/media/books/novel.epub")" = "$(inode "$s2/media/books/novel.epub")" ] || { echo "FAIL an unchanged media file was copied instead of hard-linked"; exit 1; }
[ "$(inode "$s1/volumes/beszel-data/data.db")" = "$(inode "$s2/volumes/beszel-data/data.db")" ] || { echo "FAIL an unchanged volume file was copied instead of hard-linked"; exit 1; }
[ "$(inode "$s1/media/s3/ab/cd/abcdef")" = "$(inode "$s2/media/s3/ab/cd/abcdef")" ] || { echo "FAIL an unchanged S3 object was copied instead of hard-linked"; exit 1; }
echo "ok   a second night: unchanged files are hard links to the first snapshot; a deleted file is still in the first"
expect_ok "a second run the same night" 2026-10-16
[ -f "$(snap 2026-10-16)/.complete" ] && [ "$(inode "$s1/media/books/novel.epub")" = "$(inode "$(snap 2026-10-16)/media/books/novel.epub")" ] ||
  { echo "FAIL a rerun the same night lost the snapshot or its hard links"; exit 1; }
echo "ok   a rerun the same night replaces that night's snapshot, still linked"

### A failed night: no snapshot, the partial is never a base and goes next run

echo 1 >"$state/pg.rc"
expect_failed "a night whose dump fails" "FAILED: pg_dumpall of the postgresql container failed" 2026-10-17
[ ! -e "$(snap 2026-10-17)" ] && [ -d "$state/backup/snapshots/.2026-10-17.partial" ] && [ "$(latest)" = 2026-10-16 ] ||
  { ls -a "$state/backup/snapshots"; echo "FAIL a failed night became a snapshot, or moved latest"; exit 1; }
[ -d "$state/backup/snapshots/.2026-10-17.partial/media/books" ] || { echo "FAIL a failed dump stopped the other steps"; exit 1; }
if ! grep -q 'FAILED: 1 step(s) failed' "$work/out" || ! grep -q 'incomplete snapshot is kept in .*\.2026-10-17\.partial' "$work/out"; then
  cat "$work/out"; echo "FAIL no summary of the failed night"; exit 1
fi
rm "$state/pg.rc"
echo changed >"$state/media/books/novel.epub"
echo other >"$state/backup/snapshots/.2026-10-17.partial/media/books/marker"
expect_ok "the night after a failed one" 2026-10-18
[ ! -e "$state/backup/snapshots/.2026-10-17.partial" ] || { echo "FAIL the failed night's partial was not removed"; exit 1; }
[ ! -e "$(snap 2026-10-18)/media/books/marker" ] && [ "$(inode "$(snap 2026-10-16)/media/audiobooks/Author/Book/01.mp3")" = "$(inode "$(snap 2026-10-18)/media/audiobooks/Author/Book/01.mp3")" ] ||
  { echo "FAIL the night after a failure was based on the partial, not the last complete snapshot"; exit 1; }
[ "$(cat "$(snap 2026-10-16)/media/books/novel.epub")" = epub ] && [ "$(cat "$(snap 2026-10-18)/media/books/novel.epub")" = changed ] ||
  { echo "FAIL a changed file overwrote the earlier snapshot's copy through a hard link"; exit 1; }
echo "ok   a failed night: no snapshot, latest unchanged, the partial is deleted next run and never linked against"

### Retention: the newest 14 and the oldest of each of the 8 newest ISO weeks

new_state
d=2026-08-01
while [ "$d" != 2026-10-15 ]; do
  fake_snapshot "$d"
  d="$(date -u -d "$d + 1 day" +%F)"
done
fake_snapshot 2026-07-20 incomplete
expect_ok "a run over 75 earlier nights"
want="$(python3 - <<'PY'
import datetime as dt
days=[dt.date(2026,8,1)+dt.timedelta(n) for n in range((dt.date(2026,10,15)-dt.date(2026,8,1)).days+1)]
keep=set(days[-14:])
first={}
for d in days:
    first.setdefault(d.isocalendar()[:2], d)
for w in sorted(first)[-8:]:
    keep.add(first[w])
print("\n".join(sorted(d.isoformat() for d in keep)))
PY
)"
got="$(find "$state/backup/snapshots" -mindepth 1 -maxdepth 1 -type d -name '20*' -printf '%f\n' | grep -v 2026-07-20 | LC_ALL=C sort)"
[ "$got" = "$want" ] || { diff <(echo "$want") <(echo "$got"); echo "FAIL retention kept the wrong snapshots"; exit 1; }
[ "$(echo "$got" | wc -l)" -eq 20 ] || { echo "$got"; echo "FAIL retention did not keep 14 daily + 6 older weekly snapshots"; exit 1; }
[ -d "$(snap 2026-07-20)" ] || { echo "FAIL retention removed something that is not a complete snapshot"; exit 1; }
echo "ok   retention: 14 daily plus the oldest of each of 8 ISO weeks (20 here: two weekly picks fall inside the 14); nothing incomplete touched"

### Low space: the oldest go first, never the newest 2; otherwise fail before writing

new_state
for d in 2026-10-11 2026-10-12 2026-10-13 2026-10-14; do fake_snapshot "$d"; done
printf '%s\n' "50 1000" "80 1000" "200 1000" >"$state/df.seq"
expect_ok "low space with snapshots to spare"
[ ! -e "$(snap 2026-10-11)" ] && [ ! -e "$(snap 2026-10-12)" ] && [ -d "$(snap 2026-10-13)" ] && [ -f "$(snap 2026-10-15)/.complete" ] ||
  { ls "$state/backup/snapshots"; echo "FAIL low space did not remove exactly the oldest snapshots first"; exit 1; }
grep -q "only 5% of .* is free (need 10%): removing the oldest snapshot" "$work/out" || { cat "$work/out"; echo "FAIL no low-space note"; exit 1; }
new_state
for d in 2026-10-13 2026-10-14; do fake_snapshot "$d"; done
echo "50 1000" >"$state/df.seq"
expect_failed "low space with only 2 snapshots" "FAILED: only 5% of .* is free \\(need 10%\\) and only 2 snapshot\\(s\\) are left to keep; nothing was written"
[ -f "$(snap 2026-10-13)/.complete" ] && [ -f "$(snap 2026-10-14)/.complete" ] && [ ! -e "$(snap 2026-10-15)" ] &&
  [ -z "$(find "$state/backup/snapshots" -maxdepth 1 -name '.*partial')" ] || { ls -a "$state/backup/snapshots"; echo "FAIL low space removed the last snapshots or wrote anyway"; exit 1; }
grep -qE '^(stop|exec)' "$state/calls" && { cat "$state/calls"; echo "FAIL low space still stopped containers or dumped"; exit 1; }
echo "ok   low space: oldest snapshots removed first, the newest 2 never; still low fails before writing anything"

### Migration from the mirror layout

new_state
mkdir -p "$state/backup/media/books" "$state/backup/media/podcasts/Show" "$state/backup/apps/2026-10-14" "$state/backup/postgres"
cp "$state/media/books/novel.epub" "$state/backup/media/books/novel.epub"
touch -r "$state/media/books/novel.epub" "$state/backup/media/books/novel.epub"
echo gone >"$state/backup/media/podcasts/Show/old.mp3"
echo tar >"$state/backup/apps/2026-10-14/jellyfin-config.tar.gz"
echo old | gzip -c >"$state/backup/postgres/2026-10-14.sql.gz"
old_inode="$(inode "$state/backup/media/books/novel.epub")"
echo 1 >"$state/immich-pg.rc"
expect_failed "a failed first snapshot" "FAILED: pg_dumpall of the immich-postgres container failed"
[ -f "$state/backup/media/books/novel.epub" ] && [ -d "$state/backup/apps/2026-10-14" ] || { echo "FAIL the old layout was removed before a complete snapshot existed"; exit 1; }
rm "$state/immich-pg.rc"
expect_ok "the first snapshot over the old layout"
[ "$(inode "$(snap 2026-10-15)/media/books/novel.epub")" = "$old_inode" ] || { echo "FAIL the first snapshot copied the old mirror instead of linking to it"; exit 1; }
[ ! -e "$state/backup/media" ] && [ ! -e "$state/backup/apps" ] && [ -f "$state/backup/postgres/2026-10-14.sql.gz" ] ||
  { ls "$state/backup"; echo "FAIL the old media/ and apps/ were not retired, or the old dumps went too early"; exit 1; }
for d in $(seq -w 1 13); do fake_snapshot "2026-10-$d"; done
expect_ok "the fourteenth snapshot" 2026-10-16
[ ! -e "$state/backup/postgres" ] || { echo "FAIL the old dumps outlived 14 snapshots"; exit 1; }
echo "ok   migration: the first snapshot links to the old mirror; media/ and apps/ go after it, the old dumps after 14 snapshots, nothing before a complete one"

### Failures

new_state
rm "$state/running/immich-postgres"
expect_ok "a host without Immich yet"
grep -q "immich-postgres is not running .*its dump was skipped" "$work/out" && [ ! -e "$(snap 2026-10-15)/immich.sql.gz" ] || { cat "$work/out"; echo "FAIL a missing Immich was not skipped"; exit 1; }
echo "ok   Immich: a host without Immich yet skips its dump"

new_state
fake_snapshot 2026-10-14
mkdir -p "$(snap 2026-10-14)/media/books"
rm -rf "$state/media/books"
expect_failed "the media disk is missing" "FAILED: .*/media/books does not exist \\(is the media disk mounted\\?\\)"
[ ! -e "$(snap 2026-10-15)" ] && [ "$(cat "$(snap 2026-10-14)/media/books/old.epub")" = "old 2026-10-14" ] || { echo "FAIL a missing library made a snapshot or touched the last one"; exit 1; }
new_state
fake_snapshot 2026-10-14
rm -rf "$state/media/books"/*
expect_failed "an empty library over a full snapshot" "FAILED: .*/media/books is empty but the last backup of it is not"
echo "ok   media: a missing or empty library fails the night and leaves the last snapshot alone"

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
  expect_failed "an unreadable volume" "FAILED: rsync of the volume open-webui-data failed"
  chmod 755 "$state/volumes/open-webui-data"
  [ ! -e "$(snap 2026-10-15)" ] || { echo "FAIL a failed app copy became a snapshot"; exit 1; }
  for name in jellyfin audiobookshelf open-webui; do
    [ -f "$state/running/$name" ] || { echo "FAIL $name was left stopped after a failed copy"; exit 1; }
  done
  echo "ok   a failed app copy makes no snapshot and starts the containers again"
fi

echo "backup-scripts: all cases passed"
