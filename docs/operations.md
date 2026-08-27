# Runbook

## Rotating a secret

Change it in the repository secrets, run **Deploy**. That is the whole procedure for
every database password: `roles/postgres-provision` re-sets the role's password on every
run from the same value that renders the application's DSN, so the two cannot drift.

`PORTFOLIO_ADMIN_PASSWORD` is the exception. It seeds the operator account on first boot
against an empty database and is ignored afterwards — change that password in `/admin`.

## Getting into PostgreSQL

The image trusts connections over the local Unix socket, so a lost superuser password is
not a lockout:

```bash
docker exec -it postgresql psql -U postgres
# on a host that has not been migrated yet:
docker exec -it postgresql psql -U crm
```

Re-running the deploy re-sets every password from the repository secrets.

## After the database split deploy

Once the sites are confirmed healthy on the new volume:

```bash
docker volume rm crm-pgdata-v18   # the rollback copy of the cluster
rm -rf /opt/crm/initdb            # no longer mounted by anything
```

Do **not** remove the volume before that. Until the deploy has run, it is the live
cluster; afterwards it is the only copy of the pre-migration state.

## Reclaiming disk

```bash
docker image prune -f              # dangling only — same as the Sunday timer
systemctl start docker-prune.service
```

Never `docker image prune -a`. See [agents.md](agents.md#the-prune-timer).

## Backups

Two things must be captured together:

- the `portfolio` database
- the `portfolio-media` volume

The `media` table is a ledger of what is on that volume. Restoring one without the other
gives a working site with broken images rather than an error, which is the failure mode
that goes unnoticed longest.

## A major PostgreSQL upgrade

Never by editing the image tag — the on-disk formats are incompatible and the server
will refuse to start.

1. Stop every writer (the application stacks, not the database).
2. `pg_dumpall` from the running container.
3. Create a fresh volume named for the new major.
4. Start the new image against it and restore.
5. Update `postgres_image` and `postgres_volume` in `playbook.yml`.
6. Deploy, verify, then delete the old volume.

## Locked out of SSH

The realistic path is a dead key and a fumbled password, and the answer is the **Hetzner
Cloud console** — it does not go through sshd. From there:

```bash
fail2ban-client set sshd unbanip <your-ip>
```

That console is the reason a long ban is safe to run at all.

If sshd itself will not start, the drop-in at `/etc/ssh/sshd_config.d/10-hardening.conf`
is the first thing to check — though the deploy validates it with `sshd -t` before
installing, so this should not happen from a deploy.

## Watchtower is not updating anything

Check it is running at all:

```bash
docker ps -a --filter name=watchtower
docker logs watchtower --tail 50
```

It exits at startup on a bad `/root/.docker/config.json`. Two ways that happens: the
GHCR token expired, or the file is missing on the host — Docker then creates a
*directory* at that bind-mount path, which Watchtower cannot parse. A full deploy
re-runs `docker login ghcr.io` and recreates the container, which fixes both.

Remember that Watchtower only updates containers that already exist. A missing container
comes back from a deploy, not from Watchtower.

## A site is up but hung

Autoheal restarts containers that report `unhealthy`, but only those labelled
`autoheal=true` and only those that define a healthcheck. `crm-web` and `prizm-web` have
neither, so a hang there needs:

```bash
docker restart crm-web
```
