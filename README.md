# infra — the single deployer

The **one** repo that touches the server. It provisions the shared Hetzner host, runs the
edge Traefik proxy, runs **Watchtower**, and deploys every app stack (`crm`, `hypernova`, `portfolio`).

The app repos (`crm`, `hypernova`, `portfolio`) are **build-only**: their CI builds images and pushes
them to GHCR. They never deploy. When a new image lands, **Watchtower** on the server
pulls it and recreates the container automatically.

```
crm repo ─┐  build :latest → GHCR ┐
          │                        │   Watchtower (on the server) sees the new
hypernova ─┤  build :latest → GHCR ┤   digest → docker pull + recreate container
portfolio ┘                         ┘
          ▲
          │ stack defs (compose + env) + provisioning + edge + watchtower
        infra (this repo, Ansible) — the only thing that SSHes to the box
```

## What the playbook does

1. **common** — base packages + strict default-deny `ufw` (only **22 / 80 / 443**).
2. **docker** — Docker Engine + compose plugin.
3. **edge** — shared `edge`/`data` networks + Traefik on 80/443 (Let's Encrypt **HTTP-01**,
   so the app domains must resolve directly to the host — no proxy in front).
4. **watchtower** — `docker login ghcr.io` + the Watchtower agent that auto-updates the
   containers labelled `com.centurylinklabs.watchtower.enable=true` (the app images only —
   never Postgres/Redis/Typesense/Traefik).
5. **stack (×N)** — ships each `stacks/<name>/docker-compose.yml` + a rendered `.env`
   (+ `initdb/` for crm), then `docker compose up -d --pull always`.

`stacks/` holds the deploy definitions moved out of the app repos:

```
stacks/
  crm/        docker-compose.yml · env.j2 · initdb/10-prizm.sh
  hypernova/  docker-compose.yml · env.j2
  portfolio/  docker-compose.yml · env.j2
```

## Deploy

GitHub → **Actions → "Deploy" → Run workflow**. Runs the whole playbook (idempotent). You
run this on a fresh server, or when a stack's **compose or secrets** change — **not** for
routine image updates (Watchtower handles those within ~60s of a push).

Required repo **secrets**:

| Secret | Meaning |
| --- | --- |
| `SERVER_HOST` | Public IP of the shared host — **the one place the IP lives** |
| `SSH_PRIVATE_KEY` | Private half of the deploy key. The public half is committed at `roles/common/files/deploy_key.pub` and installed by the `common` role, so a rebuilt host trusts CI with nothing to remember |
| `GHCR_USERNAME` / `GHCR_TOKEN` | GHCR login; token needs `read:packages` for the crm (`somethim`) and hypernova (`hypernova3643725`) images |
| `CRM_APP_KEY` | Laravel `APP_KEY` (`php artisan key:generate --show`) |
| `CRM_DB_PASSWORD` | CRM Postgres password |
| `PRIZM_DB_PASSWORD` | hypernova's DB role password — **one secret, used by both stacks** (CRM creates the role with it; hypernova connects with it) |
| `CRM_REDIS_PASSWORD` / `CRM_TYPESENSE_API_KEY` / `CRM_ADMIN_PASSWORD` | CRM service secrets |
| `HYPERNOVA_SESSION_SECRET` / `HYPERNOVA_ADMIN_PASSWORD` | hypernova provider secrets |
| `PORTFOLIO_DB_PASSWORD` | The portfolio's own role in the shared Postgres. `roles/portfolio-db` creates the role with it and re-sets it on every deploy, so rotating the secret rotates the password |
| `PORTFOLIO_ADMIN_PASSWORD` | Seeds the portfolio's only operator account (`contact@arbikullakshi.com`) on the first boot against an empty database. Changing it later does **not** change an existing account — do that in `/admin` |
| `PORTFOLIO_RESEND_API_KEY` | *(optional)* Enables the portfolio's outgoing mail — contact notifications, comment alerts, sign-in alerts, and the codes that verify a commenter's address. Without it those are recorded and only the mail about them is skipped |
| `SERVER_USER` | *(optional)* SSH user, defaults to `root` |

Give the two portfolio secrets values with no `$` in them (`openssl rand -hex 24`). They
are rendered into a compose `.env`, and `$` there is interpolation syntax.

The Let's Encrypt email is baked (`contact@arbikullakshi.com`, in
`roles/edge/defaults/main.yml`) — not a secret.

The portfolio stack runs two tags from the same GHCR package: `latest` serves
`arbikullakshi.com`, while `legacy` serves the preserved portfolio at
`legacy.arbikullakshi.com`. They are built from two branches of the one repository
and neither build touches the other's tag.

`latest` is a Rust/Leptos server rather than a static site, so it carries two things
the other stacks do not:

- **A database on the shared Postgres.** `roles/portfolio-db` creates the `portfolio`
  role and database inside the running `postgresql` container before the stack comes
  up — an initdb script could not, since those run only on a fresh data directory.
- **The `portfolio-media` volume.** Uploads and the previews generated beside them,
  which is the only application state outside Postgres. The `media` table is a ledger
  of what is on that volume, so the two must be backed up and restored **together**:
  a mismatch shows up as broken images, not as an error.

The container applies its own migrations and seeds an empty database on start, so a
first deploy needs no manual step. Both are idempotent and re-run on every boot.

Local equivalent:

```bash
cp inventory/hosts.example inventory/hosts   # edit the IP
ansible-playbook playbook.yml --ask-pass -e @vars.json   # vars.json = the secrets above
```

## First-time / server-swap order

1. Update `SERVER_HOST` (and the other secrets if new).
2. Point DNS **directly** at the host IP — plain A records, since HTTP-01 needs the
   origin reachable on :80: `arbikullakshi.com`, `www.arbikullakshi.com`,
   `legacy.arbikullakshi.com`, `crm.arbikullakshi.com`, `hypernova.arbikullakshi.com`.
3. Run **Deploy**. It provisions everything and brings up all stacks. The crm Postgres
   auto-creates hypernova's `prizm` role + database on first init.

After that, just push image tags from the app repos — Watchtower deploys them.

## The shared PostgreSQL

One `postgres:18-alpine` container, named `postgresql`, run by the **crm** stack and
reachable from the others over the `data` network. Every app has its own database and
its own least-privilege role in it — they are neighbours, not tenants of one schema:

| Database | Role | Created by |
| --- | --- | --- |
| `crm` | `crm` (superuser) | the image's own `POSTGRES_DB` / `POSTGRES_USER` |
| `prizm` | `prizm` | `stacks/crm/initdb/10-prizm.sh`, on first init |
| `portfolio` | `portfolio` | `roles/portfolio-db`, on every deploy |

`migration_admin` is the cluster's **bootstrap superuser** — the PostgreSQL 18 volume was
initialised under it, so it owns the system catalogs in every database and owns the
`postgres` maintenance database. It looks like an upgrade leftover and is not one:
**do not drop it.** It cannot log in, so it is not an access path.

The 17 → 18 upgrade is **done** — the cluster runs 18.6 on the `crm-pgdata-v18` volume,
and the 17 volume it replaced is gone. The one-time migration playbook and the
deploy-time guard that refused to run over a 17 container are both gone with it.

A future major is the same problem again: never move it by editing the image tag, because
the on-disk formats are incompatible. It takes a dump and a restore into a fresh volume,
with the writers stopped.

## Host hardening and agents

Three things run on the host besides the stacks, all idempotent and all in `playbook.yml`:

- **Watchtower** — pulls a new image and recreates the container (`roles/watchtower`).
- **Autoheal** — restarts a container that reports `unhealthy` (`roles/autoheal`). Docker
  does nothing on a failed healthcheck and Traefik does not read it either, so without
  this a hung app stays in the routing table. Opt-in with `autoheal=true`, the same shape
  as Watchtower's label. **Never label a database**: restarting a slow PostgreSQL under
  load is how a slow database becomes a broken one. `crm-web` and `prizm-web` are
  deliberately *not* labelled — neither defines a healthcheck nor bakes one into its
  image, so there is nothing for autoheal to act on. Give them one and the label becomes
  worth adding.
- **fail2ban** — bans an SSH source for a day after ten failures, doubling to a week for
  anything that comes back (`roles/common/tasks/hardening.yml`).
- **`docker-prune.timer`** — reclaims dangling images every Sunday at 03:00
  (`roles/docker`). Dangling only, never `-a`: an untagged image is referenced by
  nothing, while `-a` would delete anything without a *running* container and would
  eat the legacy portfolio image the moment its container stopped. Containers are not
  pruned at all, so a deliberately stopped one — Watchtower during a cutover — survives.
  Run it early with `systemctl start docker-prune.service`.

  If you ever lock yourself out — the realistic path is a dead SSH key and a fumbled
  password — **the Hetzner Cloud console gets you in without SSH**. From there:
  `fail2ban-client set sshd unbanip <your-ip>`. That console is the reason a long ban is
  safe to run at all.

### Memory limits

Every app container has a `mem_limit`; the stateful ones (PostgreSQL, Redis, Typesense)
deliberately do not. That is the point: bounding the apps is what stops a runaway from
making the kernel's OOM killer pick PostgreSQL, which every stack depends on. The ceilings
are 4–6x observed usage, so they catch a runaway and nothing else. Retune them if a
container is killed in normal work — `docker inspect <name> --format '{{.State.OOMKilled}}'`.

### Patching

`unattended-upgrades` installs security updates, and
`/etc/apt/apt.conf.d/20auto-upgrades-reboot` now lets it **reboot at 04:00** when one needs
it. Without that a kernel update sits on disk while the old kernel keeps running — the box
was 14 kernel revisions behind at 63 days of uptime before this was added. The reboot takes
every site down for about a minute.

### SSH access

Authentication is by key. CI uses the deploy key above; you use whichever of your own
keys the host trusts. `roles/common` keeps `/root/.ssh/authorized_keys` in step.

Port 22 is open to the internet and takes ~5,500 failed password attempts a day, so the
last step is to stop answering them. It is deliberately **not** on by default, because
CI is the one client that cannot be repaired from a terminal afterwards:

```bash
# 1. Confirm a Deploy run has authenticated with the key. Only then:
ansible-playbook playbook.yml --tags hardening -e ssh_password_authentication=no
```

Once that has run, `SERVER_PASSWORD` is dead and can be deleted from the repo secrets.
To reverse it, run the same command with `=yes`.

The switch writes `/etc/ssh/sshd_config.d/10-hardening.conf`. The number matters:
Hetzner's cloud-init ships `50-cloud-init.conf` containing `PasswordAuthentication yes`,
and sshd keeps the **first** value it reads for a keyword. The task validates the file
with `sshd -t` before installing it and reloads rather than restarts, so a mistake
cannot lock out the session that made it. The Hetzner console is the backstop either way.

## Adding another project

1. Drop a `stacks/<name>/docker-compose.yml` (+ `env.j2`) — give its public container the
   edge Traefik labels (unique router names) and the Watchtower enable label.
2. Add `{ name: <name> }` to the `stacks` list in `playbook.yml`, plus any secrets.
3. Point a DNS A record at the host.

No change to the edge or the app repos.
