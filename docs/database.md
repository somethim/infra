# The shared PostgreSQL

One `postgres:18-alpine` container, named `postgresql`, serving two applications. It
is deployed as the **`database` stack** and owned by no application.

## Why it is its own stack

If it were a service inside one application's stack, that application's compose project
would own both the container and the data volume, with two consequences:

- `docker compose down -v` in that application's directory would destroy every other
  application's database along with its own.
- Retiring that application would mean either keeping a dead application's stack alive
  forever, or performing surgery on the thing every other application depends on.

Keeping it separate is isolation **by function** rather than by whichever project happened
to need a database first. `stacks/database/` contains PostgreSQL and nothing else; the
application stacks contain applications and nothing stateful they share.

## The data volume

The cluster lives on **`pgdata-v18`**, declared `external: true`.

External means compose will use the volume but never create or delete it. That is the
point: `docker compose down -v` in `/opt/database` is now as harmless as it is anywhere
else. `roles/postgres-data` creates the volume, which also keeps the "who owns this"
answer in one place.

The name carries the major version because a major upgrade cannot be done in place; see
[Upgrades](#upgrades).

The mount point is `/var/lib/postgresql` rather than the data directory itself, because
the postgres 18 image puts `PGDATA` at `/var/lib/postgresql/18/docker`.

## The superuser

The cluster's administrator is **`postgres`**, and it belongs to no application.

Keeping the administrator out of every application means retiring an application never
means dropping the account that administers everyone else's databases.

On a rebuilt host, `stacks/database/env.j2` sets `POSTGRES_USER=postgres`, so initdb
creates it as the bootstrap superuser and nothing else is needed. On the existing
volume initdb has long since run and those variables are ignored, so
`roles/postgres-provision` creates the role over the container's local socket instead.
One code path covers both.

### Finding a way in

The provisioning role cannot assume `postgres` exists yet, so it probes a candidate list
(today only `postgres`) and uses the first that opens a **superuser** session. It checks
`rolsuper`, not merely that the connection succeeded: a role that can log in but has been
demoted cannot create anything, and failing there with a clear message beats a permission
error thirty lines later.

This works without a password because the postgres image's `pg_hba.conf` trusts
connections over the local Unix socket. That is what makes a lost or rotated superuser
password recoverable rather than fatal, and it is not an exposure — reaching that socket
means already being root on the host.

### `migration_admin`

`migration_admin` is this cluster's **bootstrap superuser** — the PostgreSQL 18 volume
was initialised under it during the 17 → 18 upgrade, so it owns the system catalogs in
every database and owns the `postgres` maintenance database.

It looks like an upgrade leftover and is not one: **do not drop it.** It cannot log in,
so it is not an access path. A host rebuilt from scratch will not have it — initdb
creates `postgres` as the bootstrap superuser instead.

## Roles and databases

`roles/postgres-provision` runs as the `database` stack's `post_role`, so it completes
before any application stack is deployed. It reads `postgres_consumers` from
`playbook.yml`:

| Database | Role | Privileges |
| --- | --- | --- |
| `prizm` | `prizm` | owner; `NOSUPERUSER NOCREATEDB NOCREATEROLE` |
| `portfolio` | `portfolio` | owner; same |

Each gets a role, a database it owns, and nothing else.

### Why it is SQL and not an initdb script

The `prizm` role and database used to be created by an initdb script (`10-prizm.sh`),
which PostgreSQL runs from `/docker-entrypoint-initdb.d`. Those scripts execute **only
when initdb initialises a fresh data directory** — so on a cluster that has been serving
traffic for months, that bootstrap had silently stopped applying long ago. Editing it
would have had no effect on the running host, and nobody would have noticed until a
rebuild.

The provisioning role runs guarded SQL over the local socket on every deploy instead. It
is idempotent, it applies to a settled host and a brand-new one identically, and its
output names what it actually changed.

The guard idiom is psql's `\gexec`: a `SELECT` produces a command string only when the
object is missing, and `\gexec` executes whatever the query returned. Nothing produced,
nothing runs.

### What is reconciled on every deploy

- **Passwords**, unguarded and deliberately so. Rotating a secret re-renders that
  application's DSN, and a role left on the old password would simply stop answering it.
  This is what makes rotation "change the secret, run a deploy".
- **Privileges** — `NOSUPERUSER NOCREATEDB NOCREATEROLE` re-asserted every time, not only
  at creation, so an account granted more at some point loses it again on the next run.
- **Ownership** — `ALTER DATABASE … OWNER TO …`, so ownership is deterministic rather
  than a function of who happened to create it.
- **Connect privilege** — `REVOKE CONNECT … FROM PUBLIC`, then granted back to the owner
  alone.

That last one is what makes these roles neighbours rather than housemates. By default
PostgreSQL lets any role in the cluster open any database; without the revoke,
least privilege stops at the door. Existing sessions are unaffected, so it is safe to
apply under load.

### The OID 10 guard

The privilege strip is skipped for the role with OID 10 — the cluster's bootstrap
superuser. PostgreSQL refuses to demote it:

```
ERROR:  permission denied to alter role
DETAIL:  The bootstrap superuser must have the SUPERUSER attribute.
```

Unguarded, that error aborts the deploy on any cluster whose volume an application
initialised. Here the bootstrap role is `migration_admin`, so both application roles are
demotable.

## Connecting to it

Applications reach the container as `postgresql` on the `data` network. Passwords are
URL-encoded in the DSNs — including `/`, which the default encoder leaves alone — so no
generated character can corrupt the connection string.

## Upgrades

The 17 → 18 upgrade is done; the cluster runs 18.6.

**Never move to a new major by editing the image tag.** The on-disk formats are
incompatible and the server will refuse to start. A major requires a dump and a restore
into a fresh volume with every writer stopped — which is also the natural moment to
rename `pgdata-v18`, since it is being replaced anyway.

## Backups

The portfolio's `media` table is a ledger of what is on the `portfolio-media` volume.
The database and that volume must be backed up and restored **together**; a mismatch
surfaces as broken images on a working site rather than as an error. See
[operations.md](operations.md).
