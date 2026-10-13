# Operations

The procedures — first setup, the cut-over, releases, rollback, rotating a secret, a lockout,
re-pinning an image — are in [RUNBOOK.md](../RUNBOOK.md). This page keeps the short recipes
that are not part of a procedure. Every command runs as `admin` over the tailnet
(`ssh admin@infra-host`).

| Situation | Where |
| --- | --- |
| A release failed, or an app must go back a version | [RUNBOOK.md, Releases, status, rollback, resume](../RUNBOOK.md#8-releases-status-rollback-resume) |
| A secret must change | [RUNBOOK.md, Rotating a secret](../RUNBOOK.md#9-rotating-a-secret) |
| SSH does not let you in | [RUNBOOK.md, Locked out](../RUNBOOK.md#10-locked-out) |
| A third-party image must move | [RUNBOOK.md, Re-pinning third-party images](../RUNBOOK.md#11-re-pinning-third-party-images) |

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

Nothing is backed up automatically. Two things must be captured together:

- the `portfolio` database (`sudo docker exec postgresql pg_dump -U postgres -Fc portfolio`)
- the `portfolio-media` volume

The `media` table is a ledger of what is on that volume. Restoring one without the other gives
a working site with broken images rather than an error, which is the failure mode that goes
unnoticed longest.

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
([RUNBOOK.md](../RUNBOOK.md#11-re-pinning-third-party-images)).

Remember that Watchtower only updates containers that already exist, and never one pinned by
a rollback. A missing app container comes back from a `release`.

## A site is up but hung

Autoheal restarts containers that report `unhealthy`, but only those labelled `autoheal=true`
that define a healthcheck. `prizm-web` has neither, so a hang there needs:

```bash
sudo docker restart prizm-web
```
