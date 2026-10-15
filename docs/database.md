# The shared PostgreSQL

One `postgres:18.6-alpine` container (pinned by digest), named `postgresql`, serving two
applications. It is the **`database` stack** (`stack/database/`) and is owned by no
application.

## Why it is its own stack

If it were a service inside one application's stack, that application's compose project
would own both the container and the data volume, with two consequences:

- `docker compose down -v` in that application's directory would destroy every other
  application's database along with its own.
- Retiring that application would mean either keeping a dead application's stack alive
  forever, or performing surgery on the thing every other application depends on.

Keeping it separate is isolation **by function** rather than by whichever project happened
to need a database first. `stack/database/` contains PostgreSQL and nothing else; the
application stacks contain applications and nothing stateful they share.

## The data volume

The cluster lives on **`pgdata-v18`**, declared `external: true`.

External means Compose will use the volume but never create or delete it, so a
`docker compose down -v` in the database stack is harmless. Provisioning (`roles/host`)
creates the volume, empty, only when it is missing and never deletes it; the first release
on a fresh host initialises it. The compose guard refuses a release whose database stack
names any other volume, so a release cannot swap an empty volume in for the existing one.

The name carries the major version because a major upgrade cannot be done in place; see
[Upgrades](#upgrades).

The mount point is `/var/lib/postgresql` rather than the data directory itself, because the
postgres 18 image puts `PGDATA` at `/var/lib/postgresql/18/docker`.

The database is never labelled for Watchtower or autoheal (the guard refuses those labels on
this stack): an unattended image swap or restart of a stateful container is how a slow
database becomes a broken one.

## The superuser

The cluster's administrator is **`postgres`**, and it belongs to no application. Keeping the
administrator out of every application means retiring an application never means dropping
the account that administers everyone else's databases.

On a fresh volume (the home server started with one), `POSTGRES_USER=postgres` in the compose
file makes initdb create it as the bootstrap superuser. Once initdb has run, those variables
are ignored; `provision.sql` re-asserts `postgres` as `SUPERUSER LOGIN` with the password
from `POSTGRES_SUPERUSER_PASSWORD` on every release instead.

`infra-apply` runs `provision.sql` as `postgres` over the container's local Unix socket
(`docker exec -i postgresql psql -v ON_ERROR_STOP=1 -U postgres -d postgres`). The postgres
image's `pg_hba.conf` trusts that socket, which is what makes a lost or rotated superuser
password recoverable rather than fatal; reaching the socket already means being root on the
host.

### `migration_admin`

`migration_admin` was the bootstrap superuser (OID 10) of the previous server's volume,
initialised under it during a 17 → 18 upgrade. The home server started from an empty volume,
so initdb made `postgres` the bootstrap superuser and `migration_admin` does not exist.
`provision.sql` never demotes whichever role has OID 10. Whatever its name, never drop the
bootstrap superuser of a cluster: it owns the system catalogs.

## Roles and databases

`stack/database/provision.sql.j2` is rendered into each release with the passwords as
literals (`release.yml` accepts only `[A-Za-z0-9]{32,}`, so no quoting is needed). `infra-apply`
runs it once the database is healthy and before any application stack starts:

| Database | Role | Privileges |
| --- | --- | --- |
| `prizm` | `prizm` | owner; `NOSUPERUSER NOCREATEDB NOCREATEROLE` |
| `portfolio` | `portfolio` | owner; same |

Each gets a role, a database it owns, and nothing else. If the SQL fails, the release stops
before the app stacks change, and psql's error is shown with every quoted literal masked.

### Why it runs on every release

An initdb script in `/docker-entrypoint-initdb.d` runs **only when initdb initialises a fresh
data directory**, so on a settled cluster it silently stops applying. Guarded SQL on every
release applies to a settled host and a brand-new one identically.

The guard idiom is psql's `\gexec`: a `SELECT` produces a command string only when the
object is missing, and `\gexec` executes whatever the query returned. Nothing produced,
nothing runs.

### What is reconciled on every release

- **Passwords**, unguarded and deliberately so. Rotating a secret re-renders that
  application's DSN in the same release, and a role left on the old password would simply
  stop answering it. This is what makes rotation "change the secret, run `release`".
- **Privileges** — `NOSUPERUSER NOCREATEDB NOCREATEROLE` re-asserted every time, not only at
  creation, so an account granted more at some point loses it again on the next release.
- **Ownership** — `ALTER DATABASE … OWNER TO …`, so ownership is deterministic.
- **Connect privilege** — `REVOKE CONNECT … FROM PUBLIC`, then `CONNECT, TEMPORARY` granted
  back to the owner alone.

That last one is what makes these roles neighbours rather than housemates. By default
PostgreSQL lets any role in the cluster open any database; without the revoke, least
privilege stops at the door. Existing sessions are unaffected, so it is safe to apply under
load.

### The OID 10 guard

The privilege strip is skipped for the role with OID 10 — the cluster's bootstrap superuser.
PostgreSQL refuses to demote it:

```
ERROR:  permission denied to alter role
DETAIL:  The bootstrap superuser must have the SUPERUSER attribute.
```

Unguarded, that error would abort the release on any cluster whose volume an application
initialised. Here the bootstrap role is `postgres` (initdb on an empty volume), so both
application roles are demotable.

## Connecting to it

Applications reach the container as `postgresql` on the `data` network. Passwords are
URL-encoded in the DSNs — including `/`, which the default encoder leaves alone.

For a shell, as `admin` on the host:

```bash
sudo docker exec -it postgresql psql -U postgres
```

## Upgrades

The cluster runs 18.6. A **minor** version is a re-pin of the image in
`stack/database/docker-compose.yml` ([agents.md](agents.md#re-pinning-third-party-images))
and a `release`.

**Never move to a new major by editing the image tag.** The on-disk formats are incompatible
and the server will refuse to start. A major requires a dump and a restore into a fresh
volume with every writer stopped, named for the new major. The volume name `pgdata-v18` is
written in `stack/database/docker-compose.yml`, in `roles/host/tasks/main.yml` (created when
missing), and in the compose guard's allowlist (`roles/common/files/infra-compose-guard`), so
a new major changes all three, plus the test fixtures in `ci/release-scripts.sh`. See
[operations.md](operations.md#a-major-postgresql-upgrade).

## Backups

The nightly backup (`infra-backup`) dumps the whole cluster with `pg_dumpall` to the external
disk and copies `portfolio-media` the same night. The portfolio's `media` table is a ledger of
what is on the `portfolio-media` volume, so the database and that volume must be restored
**together**, from the same night; a mismatch surfaces as broken images on a working site rather than
as an error. See [operations.md](operations.md#backups).
