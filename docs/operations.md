# Operations

The procedures — first setup of the home server, the DNS switch-over, releases, rollback,
rotating a secret, a lockout, re-pinning an image — are in [RUNBOOK.md](../RUNBOOK.md). This page keeps the short recipes
that are not part of a procedure. Every command runs as `admin` over the tailnet
(`ssh admin@infra-host`).

| Situation | Where |
| --- | --- |
| A release failed, or an app must go back a version | [RUNBOOK.md, Releases, status, rollback, resume](../RUNBOOK.md#releases-status-rollback-resume) |
| A secret must change (the tunnel token too) | [RUNBOOK.md, Rotating a secret](../RUNBOOK.md#rotating-a-secret) |
| SSH does not let you in | [RUNBOOK.md, Locked out](../RUNBOOK.md#locked-out) |
| The sites are down but the server is up | [RUNBOOK.md, The sites are down but the server is up](../RUNBOOK.md#the-sites-are-down-but-the-server-is-up) |
| A third-party image must move | [RUNBOOK.md, Re-pinning third-party images](../RUNBOOK.md#re-pinning-third-party-images) |
| Something must come back from the backup disk | [RUNBOOK.md, Restoring from the backup disk](../RUNBOOK.md#restoring-from-the-backup-disk) |
| GPU, AI, media, disks | [RUNBOOK.md, GPU, AI and media](../RUNBOOK.md#12-gpu-ai-and-media) |

## Getting into PostgreSQL

The image trusts connections over the local Unix socket, so a lost superuser password is not
a lockout:

```bash
sudo docker exec -it postgresql psql -U postgres
```

The next `release` re-sets every role's password from the `production` Environment.

## Reclaiming disk

```bash
sudo systemctl start docker-prune.service   # the Sunday timer, now: unused images older than a week
sudo docker system df
```

Old releases need no cleanup: `infra-apply` keeps only `current` and `previous`. See
[agents.md](agents.md#the-prune-timer).

## Backups

`infra-backup.timer` runs `/usr/local/sbin/infra-backup` (`roles/host/files/infra-backup`)
every night at `backup_time` (02:30 UTC, plus up to 15 minutes of jitter), at least an hour
before the 04:00 reboot window and clear of the Sunday 03:00 image prune; a night missed while
the server was off runs at the next boot. It writes only to the external USB disk at
`/srv/backup`, one dated snapshot per night:

| Path | What |
| --- | --- |
| `snapshots/<date>/postgres.sql.gz` | `pg_dumpall` of the shared PostgreSQL (every role and database), mode 0600 |
| `snapshots/<date>/immich.sql.gz` | `pg_dumpall --clean --if-exists` of Immich's own PostgreSQL (`immich-postgres`), mode 0600, taken before its photos are copied; skipped until a release has started Immich |
| `snapshots/<date>/volumes/<volume>/` | `jellyfin-config` (without logs, cache and transcodes), `audiobookshelf-config`, `audiobookshelf-metadata` (without its cache, logs, streams), `kavita-config` (without cache, temp, logs), `open-webui-data` (without its model cache), `portfolio-media`, `hypernova_prizm-storage`, `beszel-data` (the dashboard's history and alerts), `garage-meta` (Garage's configuration and metadata), `sftpgo-data` (the file manager's database: share links, sessions), as plain trees |
| `snapshots/<date>/media/s3/` | Garage's objects (`/srv/media/s3`), copied while Garage is stopped so they match that night's `garage-meta` |
| `snapshots/<date>/media/{audiobooks,books,podcasts}/` | those library folders |
| `snapshots/<date>/media/photos/` | Immich's `/srv/media/photos` (originals, profile pictures, Immich's own nightly database dumps in `backups/`), without `thumbs/` and `encoded-video/`, which Immich rebuilds |
| `snapshots/latest` | a symlink to the newest complete snapshot |

**Snapshots, not a mirror.** Every tree is copied with `rsync --link-dest` against the
previous complete snapshot: a file that did not change is a hard link to the earlier copy and
takes no space, so a night costs only what changed (plus the two database dumps). A file
deleted on the server stays in every older snapshot.

**Retention: about two months.** After a complete snapshot the script keeps the newest 14 and
the first snapshot of each of the 8 newest ISO weeks (Monday to Sunday), and removes the rest.
Removing a snapshot frees only the files no other snapshot links to.

**Room on the disk.** Before writing, if less than 10% of the disk is free
(`INFRA_BACKUP_MIN_FREE_PERCENT`), the oldest snapshots are removed first, but never the newest
two; if that is still not enough the run fails without writing anything (and without stopping
any app).

**Only complete snapshots count.** A night is built in `snapshots/.<date>.partial` and becomes
`snapshots/<date>` (with a `.complete` marker, then the `latest` symlink) only when every step
succeeded. A failed night's partial is kept for inspection until the next run deletes it; it is
never linked against.

**From the old layout.** The first snapshot links to the old `media/` mirror instead of copying
it again; the old `media/` and `apps/` go once a complete snapshot exists, the old `postgres/`
and `immich/` dumps once 14 snapshots exist.

Not copied: the Ollama models (`ollama-models`; they download again), Immich's ML models
(`immich-ml-cache`; they download again), Jellyfin's cache volume,
and the films and series (they would not fit; re-rip them).

- **No disk, no writes.** If `/srv/backup` is not a mountpoint (the disk is unplugged, or
  `backup_disk_uuid` is empty) the script logs a warning and exits 0 without writing
  anything; the mountpoint itself is immutable while empty, so nothing can land on the SSD.
- **Consistent copies.** Jellyfin, Audiobookshelf, Kavita, Open WebUI, Beszel, Garage and SFTPGo keep
  SQLite databases in their volumes, so the script stops those of them that run (`docker stop`, up to 60 s),
  copies, and starts exactly those again, also when a copy fails. They are down for the
  minutes of the copy, in the night. The public sites are never stopped: PostgreSQL is dumped
  live (`pg_dumpall` is consistent), and their file volumes are copied as they are.
- **No empty library over a full backup.** A library folder that is missing, or empty while
  the last snapshot of it is not (a disk that did not mount), fails the night instead of being
  backed up empty.
- **Every step runs**, and the run fails if any did: that night makes no snapshot, the earlier
  ones stay, and `infra-backup-failed.service` logs "the nightly backup FAILED" at error
  priority. Read it with:

  ```bash
  ssh admin@infra-host journalctl -u infra-backup.service --since yesterday
  ssh admin@infra-host journalctl -p err -t infra-backup
  ssh admin@infra-host sudo systemctl start infra-backup.service     # a run now
  ```

The portfolio's `media` table is a ledger of what is on `portfolio-media`: restore the
database and that volume from the same night, or the site works with broken images, the
failure that goes unnoticed longest. Restoring is in
[RUNBOOK.md](../RUNBOOK.md#restoring-from-the-backup-disk).

The backup disk sits next to the server: it covers a dead SSD or HDD and a bad upgrade, not a
fire or a burglary. For that, copy the newest snapshot's dumps and app volumes off-site now
and then (they are small), for example to the laptop over the tailnet:

```bash
ssh admin@infra-host sudo tar -C /srv/backup/snapshots/latest/ -czf - postgres.sql.gz immich.sql.gz volumes > infra-backup-$(date +%F).tgz
```

## A major PostgreSQL upgrade

Never by editing the image tag — the on-disk formats are incompatible and the server will
refuse to start.

1. Stop every writer: `sudo docker stop portfolio prizm-provider prizm-web` (not the database).
   Watchtower revives stopped labelled containers, so stop it first:
   `sudo docker stop watchtower`.
2. `pg_dumpall` from the running container.
3. Create a fresh volume named for the new major, start the new image against it, and restore.
4. Change the image pin and the volume name in `stack/database/docker-compose.yml`,
   `roles/host/tasks/main.yml`, `roles/common/files/infra-compose-guard` and the fixtures in
   `ci/release-scripts.sh` ([database.md](database.md#upgrades)); merge to `master`.
5. Provision (it creates the new volume if missing and starts Watchtower again), then run
   `release`, verify, and only then delete the old volume.

## Watchtower is not updating anything

```bash
sudo docker ps -a --filter name=watchtower
sudo docker logs watchtower --tail 50
```

An expired GHCR token, or a missing `/root/.docker/config.json`, leaves it unable to check
digests: store a new `GHCR_TOKEN` and run `release`, which logs in again. A missing or
stopped `watchtower` container comes back with `provision.yml --tags watchtower`. An "API
version too old" error means the pinned image must move
([RUNBOOK.md](../RUNBOOK.md#re-pinning-third-party-images)).

Remember that Watchtower only updates containers that already exist, and never one pinned by
a rollback. A missing app container comes back from a `release`.

## The tunnel

```bash
sudo docker logs --tail 50 cloudflared                   # "Registered tunnel connection" x4 when healthy
sudo docker inspect cloudflared --format '{{.State.Health.Status}}'
```

The Cloudflare dashboard (Zero Trust → Networks → Tunnels) shows the same: **Healthy** with
connections, or **Down**. A tunnel that is down while the server is up is almost always the
token (deleted or refreshed tunnel: store the new `CF_TUNNEL_TOKEN`, run `release`) or the home
internet line. A hostname that answers `530`/error 1033 has no Public Hostname on the tunnel;
`502` means cloudflared cannot reach `edge-traefik:80` (is `edge-traefik` running, on `edge`?).

## A site is up but hung

Autoheal restarts containers that report `unhealthy`, but only those labelled `autoheal=true`
that define a healthcheck. `prizm-web` has neither, so a hang there needs:

```bash
sudo docker restart prizm-web
```
