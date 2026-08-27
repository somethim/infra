# Deploying

GitHub → **Actions → "Deploy" → Run workflow**. The whole playbook, idempotent.

Run it on a fresh server, or when a stack's **compose file or secrets** change. Not for
routine image updates — Watchtower handles those within about 60 seconds of a push.

## Secrets

All are repository secrets on `somethim/infra`. The workflow assembles them into a JSON
extra-vars file, passes it to Ansible, and deletes it from the runner afterwards.
`playbook.yml` asserts every required one is non-empty before touching the host, so a
missing secret fails in seconds rather than halfway through.

| Secret | Meaning |
| --- | --- |
| `SERVER_HOST` | Public IP of the host — the one place it lives |
| `SSH_PRIVATE_KEY` | Private half of the deploy key. The public half is committed and installed by `roles/common` |
| `GHCR_USERNAME` / `GHCR_TOKEN` | GHCR login. The token needs `read:packages` for the crm (`somethim`) and hypernova (`hypernova3643725`) images |
| `POSTGRES_SUPERUSER_PASSWORD` | The cluster's own administrator, owned by no application |
| `CRM_APP_KEY` | Laravel `APP_KEY` (`php artisan key:generate --show`) |
| `CRM_DB_PASSWORD` | crm's role in the shared cluster |
| `PRIZM_DB_PASSWORD` | hypernova's role in the shared cluster |
| `CRM_REDIS_PASSWORD` / `CRM_TYPESENSE_API_KEY` / `CRM_ADMIN_PASSWORD` | crm service secrets |
| `HYPERNOVA_SESSION_SECRET` / `HYPERNOVA_ADMIN_PASSWORD` | hypernova provider secrets |
| `PORTFOLIO_DB_PASSWORD` | the portfolio's role in the shared cluster |
| `PORTFOLIO_ADMIN_PASSWORD` | Seeds the portfolio's only operator account on first boot against an empty database. Changing it later does **not** change an existing account — do that in `/admin` |
| `PORTFOLIO_RESEND_API_KEY` | *(optional)* Outgoing mail. Without it, messages are still recorded and only the notification is skipped |
| `SERVER_USER` | *(optional)* SSH user; defaults to `root` |

Generate every value with `openssl rand -hex 24`. A `$` in a secret that compose
interpolates is eaten as interpolation syntax — see
[architecture.md](architecture.md#the-env-file-does-double-duty).

The Let's Encrypt email is baked into `roles/edge/defaults/main.yml`, not a secret.

`SERVER_PASSWORD` no longer exists; CI authenticates with the deploy key alone.

## Tags

`--tags host` runs the host-level roles only — packages, firewall, Docker, the edge
proxy, autoheal — and touches no stack. It needs no secrets.

That exists for one situation: applying a host change at a moment when the stacks must
**not** be redeployed, for instance while an application's compose file expects an image
that has not been published yet.

| Tag | Runs |
| --- | --- |
| `host` | common, docker, edge, autoheal |
| `hardening` | the SSH/fail2ban/patching half of `common` |
| `docker` / `edge` / `watchtower` / `autoheal` | that role alone |
| `secrets` | the assertion, watchtower, and all stacks |
| `stacks` | the stacks only |

No tags runs everything.

## Local run

```bash
cp inventory/hosts.example inventory/hosts   # edit the IP
ansible-playbook playbook.yml -e @vars.json  # vars.json = the secrets above
```

## First-time and server-swap order

1. Update `SERVER_HOST`, and any other secrets that changed.
2. Point DNS **directly** at the host — plain A records, since HTTP-01 needs the origin
   reachable on :80: `arbikullakshi.com`, `www.arbikullakshi.com`,
   `crm.arbikullakshi.com`, `hypernova.arbikullakshi.com`.
3. Run **Deploy**.

The `database` stack comes up first and creates every application's role and database
before the application that needs it is deployed, so there is no manual step and nothing
races. The portfolio applies its own migrations and seeds an empty database on start;
both are idempotent and re-run on every boot.

After that, push image tags from the app repos and Watchtower deploys them.

## Adding a project

1. Drop `stacks/<name>/docker-compose.yml` and `env.j2`. Give the public container the
   Traefik labels (unique router names — see [edge.md](edge.md)) and
   `com.centurylinklabs.watchtower.enable=true`.
2. Add `{ name: <name> }` to `stacks` in `playbook.yml`, plus any new secrets to the
   assertion and to the workflow.
3. If it needs a database, add `{ name: <name>, password: "{{ <name>_db_password }}" }`
   to `postgres_consumers` and attach the container to the `data` network. The role and
   database will exist before the stack is deployed.
4. Point a DNS A record at the host.

No change to the edge role, and no change to the application repositories.
