# infra — the single deployer

The **one** repo that touches the server. It provisions the shared Hetzner host, runs the
edge Traefik proxy, runs **Watchtower**, and deploys every app stack (`crm`, `hypernova`).

The app repos (`crm`, `hypernova`) are **build-only**: their CI builds images and pushes
them to GHCR. They never deploy. When a new image lands, **Watchtower** on the server
pulls it and recreates the container automatically.

```
crm repo ─┐  build :latest → GHCR ┐
          │                        │   Watchtower (on the server) sees the new
hypernova ┘  build :latest → GHCR ┘   digest → docker pull + recreate container
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
```

## Deploy

GitHub → **Actions → "Deploy" → Run workflow**. Runs the whole playbook (idempotent). You
run this on a fresh server, or when a stack's **compose or secrets** change — **not** for
routine image updates (Watchtower handles those within ~60s of a push).

Required repo **secrets**:

| Secret | Meaning |
| --- | --- |
| `SERVER_HOST` | Public IP of the shared host — **the one place the IP lives** |
| `SERVER_PASSWORD` | Root SSH password |
| `GHCR_USERNAME` / `GHCR_TOKEN` | GHCR login; token needs `read:packages` for **both** the crm (`somethim`) and hypernova (`hypernova3643725`) images |
| `CRM_APP_KEY` | Laravel `APP_KEY` (`php artisan key:generate --show`) |
| `CRM_DB_PASSWORD` | CRM Postgres password |
| `PRIZM_DB_PASSWORD` | hypernova's DB role password — **one secret, used by both stacks** (CRM creates the role with it; hypernova connects with it) |
| `CRM_REDIS_PASSWORD` / `CRM_TYPESENSE_API_KEY` / `CRM_ADMIN_PASSWORD` | CRM service secrets |
| `HYPERNOVA_SESSION_SECRET` / `HYPERNOVA_ADMIN_PASSWORD` | hypernova provider secrets |
| `SERVER_USER` | *(optional)* SSH user, defaults to `root` |

The Let's Encrypt email is baked (`contact@arbikullakshi.com`, in
`roles/edge/defaults/main.yml`) — not a secret.

Local equivalent:

```bash
cp inventory/hosts.example inventory/hosts   # edit the IP
ansible-playbook playbook.yml --ask-pass -e @vars.json   # vars.json = the secrets above
```

## First-time / server-swap order

1. Update `SERVER_HOST` (and the other secrets if new).
2. Point DNS (`crm.` + `hypernova.arbikullakshi.com`) **directly** at the host IP
   (plain A records — HTTP-01 needs the origin reachable on :80).
3. Run **Deploy**. It provisions everything and brings up all stacks. The crm Postgres
   auto-creates hypernova's `prizm` role + database on first init.

After that, just push image tags from the app repos — Watchtower deploys them.

## Adding another project

1. Drop a `stacks/<name>/docker-compose.yml` (+ `env.j2`) — give its public container the
   edge Traefik labels (unique router names) and the Watchtower enable label.
2. Add `{ name: <name> }` to the `stacks` list in `playbook.yml`, plus any secrets.
3. Point a DNS A record at the host.

No change to the edge or the app repos.
