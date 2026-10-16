# Deploying

Two paths touch the server, and they never share credentials:

- **Provisioning** (`provision.yml`) runs from the owner's machine as `admin` with a sudo
  password, over the tailnet. It sets up the host, the edge proxy and the agents, and holds no
  app secrets. Run it when a role changes.
- **Releases** run from GitHub Actions (**Actions → Deploy → Run workflow**). The runner
  renders a bundle and hands it to the `deploy` account, which can only run `release` or
  `status`. Run one when a secret, a file under `stack/` or `production.yml` changes. Not for
  routine image updates: Watchtower deploys those within about a minute of a push.

First-time setup of the home server is in [RUNBOOK.md](../RUNBOOK.md) (sections 2–10).

## Releases

The workflow ([`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)) runs only from
`master`, in the `production` Environment, one run at a time. Its inputs:

| Input | Values |
| --- | --- |
| `action` | `release` (default), `resume`, `rollback`, `status` |
| `portfolio` | rollback only: `previous` (default), `current`, `latest`, a 40-character commit sha, `sha256:<digest>` |
| `hypernova_provider`, `hypernova_web` | rollback only: `previous` (default), `current`, `latest`, `sha256:<digest>` |
| `dry_run` | rollback only: print the resolved pins and stop |

What each action does, and how to read `status`, is in
[RUNBOOK.md](../RUNBOOK.md#releases-status-rollback-resume). The steps of a `release`:

1. Refuse any branch but `master`, a malformed input, and a `SERVER_USER` of `root` or `admin`.
2. Join the tailnet as an ephemeral `tag:infra-ci` node (`TS_OAUTH_CLIENT_ID`,
   `TS_OAUTH_SECRET`), and pin the server's host key from `SSH_KNOWN_HOSTS` under
   `SERVER_SSH_HOST` (`StrictHostKeyChecking=yes`).
3. Write the Environment's values to a JSON extra-vars file, and run
   [`build-bundle.sh`](../build-bundle.sh): it refuses an unpinned third-party image, runs
   [`release.yml`](../release.yml) on the runner to render the bundle, writes `release.env`
   (`RELEASE_MODE=latest|pinned`, `RELEASE_COMMIT=<sha>`) and `manifest.sha256`, and packs a
   deterministic tgz. The extra-vars file is deleted right after.
4. `ssh deploy@infra-host release < bundle.tgz`. The forced command
   (`infra-deploy-gate`) runs `sudo -n /usr/local/sbin/infra-apply release` and nothing else.
5. Last, after the host has verified and marked the release, `infra-apply` asks the public
   hosts by name through Cloudflare, from the host itself, for up to 5 minutes: `2xx` for the
   portfolio's and hypernova's health and hypernova's `/`, `301` from `www.` to the apex, and
   `301` from `http://` to `https://` (Cloudflare's Always Use HTTPS); it prints "Cloudflare
   serves …". It runs on the host, not on the runner, because Cloudflare's bot protection
   answers GitHub's data-centre addresses with `403`. A failure here leaves the release current
   and verified and names the Cloudflare-side cause; there is nothing to roll back.

A rollback first reads `status`, logs in to GHCR, and turns the inputs into digest pins with
[`release-images.sh`](../release-images.sh) `resolve`; `build-bundle.sh --pin` applies them.
`resume` is a `release`.

## Secrets and variables

All live in the GitHub **`production` Environment** on `somethim/infra`, not in repository
secrets. Secrets are set with `gh secret set <NAME> --env production`, variables with
`gh variable set <NAME> --env production --body <value>`. This list matches the workflow's
`env` blocks; keep the two in step.

`release.yml` asserts the formats on the runner, before anything reaches the host. Every value
that lands in an env file must also be free of `$`, `"`, `'`, `` ` ``, `\`, `#`, line breaks and
leading or trailing spaces, which Compose would rewrite.

### Secrets

| Secret | Meaning |
| --- | --- |
| `GHCR_TOKEN` | GHCR token for `GHCR_USERNAME`, `[A-Za-z0-9_]+`. Needs `read:packages` for the portfolio (`somethim`) and hypernova (`hypernova3643725`) images. The host logs in with it on every release, and Watchtower reuses that login |
| `POSTGRES_SUPERUSER_PASSWORD` | The cluster's own administrator, `postgres`, owned by no application |
| `PRIZM_DB_PASSWORD` | hypernova's role in the shared cluster |
| `PORTFOLIO_DB_PASSWORD` | the portfolio's role in the shared cluster |
| `PORTFOLIO_ADMIN_PASSWORD` | The password the portfolio's bootstrap gives its only operator account when that account does not exist yet. Changing it later does **not** change an existing account — do that in `/admin` |
| `PORTFOLIO_RESEND_API_KEY` | *(optional)* Outgoing mail. Without it, messages are still recorded and only the notification is skipped |
| `PORTFOLIO_GOOGLE_CLIENT_ID` / `PORTFOLIO_GOOGLE_CLIENT_SECRET` | *(optional)* Google Cloud Console OAuth client backing the Calendar integration that mints a Meet link per booking. Without them, "Connect Google Calendar" just fails with a clear error instead of the server refusing to start. Create a "Web application" OAuth client, enable the Calendar API, and register `https://arbikullakshi.com/api/google/callback` as an authorized redirect URI exactly |
| `PORTFOLIO_TOTP_ENCRYPTION_KEY` | Encrypts enrolled TOTP secrets at rest. **Rotating or losing it makes every already-enrolled TOTP secret permanently unreadable** — re-enrollment is the only recovery. Generate with `openssl rand -base64 32`, not the `-hex 24` used below — the app expects exactly 32 raw bytes, base64-encoded |
| `HYPERNOVA_SESSION_SECRET` / `HYPERNOVA_ADMIN_PASSWORD` | hypernova provider secrets |
| `SSH_PRIVATE_KEY` | Private half of the CI deploy key ([RUNBOOK.md](../RUNBOOK.md#5-first-provision-over-the-lan)). The public half is committed at `roles/common/files/deploy_key.pub` and installed for `deploy` only |
| `SSH_KNOWN_HOSTS` | The server's verified host key line under its tailnet name, `infra-host ssh-ed25519 AAAA…` ([RUNBOOK.md](../RUNBOOK.md#5-first-provision-over-the-lan)) |
| `TS_OAUTH_SECRET` | Secret of the Tailscale OAuth client (scope Auth Keys: write, tag `tag:infra-ci`) |
| `CF_TUNNEL_TOKEN` | The token of the remotely managed Cloudflare Tunnel `infra-host` (base64, starts with `eyJ`; Zero Trust → Networks → Tunnels → the tunnel's connector install command). Rendered only into `tunnel/tunnel.env`, read only by `cloudflared` ([edge.md](edge.md#why-the-tunnel-is-a-release-stack)) |
| `HOME_TLS_CF_DNS_TOKEN` | Cloudflare API token with Zone Read and DNS Edit on arbikullakshi.com only, for `home-tls`'s Let's Encrypt DNS-01 challenge ([RUNBOOK.md](../RUNBOOK.md#the-links-page)). Rendered only into `media/home-tls.env`, read only by `home-tls`. Rotating it changes nothing but the next renewal's credentials |
| `WEBUI_SECRET_KEY` | Signs Open WebUI's login sessions (`openssl rand -hex 32`, at least 32 letters and digits). Rendered only into `ai/open-webui.env`, read only by `open-webui`. Rotating it signs everyone out; nothing else is lost ([stacks.md](stacks.md#ai)) |
| `BESZEL_PASSWORD` | The owner's Beszel dashboard password (`openssl rand -hex 16`, at least 16 letters and digits). Creates the login on the hub's first start only (`media/beszel.env`, `beszel`); `beszel-pair` signs in with it (`media/beszel-pair.env`). Change it in the dashboard first, then here |
| `BESZEL_AGENT_TOKEN` | The token Beszel's agent presents (`openssl rand -hex 24`, at least 32 letters, digits and `-`). Rendered into `media/beszel-agent.env` and `media/beszel-pair.env` (which registers it as the owner's universal token) |
| `GARAGE_RPC_SECRET` | Garage's RPC secret (`openssl rand -hex 32`, exactly 64 hex digits). Only in `media/garage.env`, read by `garage` |
| `GARAGE_ADMIN_TOKEN` | Garage's admin API token (`openssl rand -hex 32`, at least 32 letters and digits). In `media/garage.env` and `media/garage-setup.env` |
| `GARAGE_OWNER_ACCESS_KEY_ID` / `GARAGE_OWNER_SECRET_KEY` | The owner's S3 key (`GK` + `openssl rand -hex 12`; `openssl rand -hex 32`), imported by `garage-setup` (`media/garage-setup.env`). Rotate both together: Garage never reuses a deleted key ID |
| `SEARXNG_SECRET` | SearXNG's secret key (`openssl rand -hex 32`, at least 32 letters and digits). Rendered only into `ai/searxng.env`, read only by `searxng`. Rotating it changes nothing visible ([stacks.md](stacks.md#ai)) |

The three database passwords must be at least 32 letters and digits (`[A-Za-z0-9]{32,}`)
and all different: they are written into `provision.sql` and the DSNs as literals. Generate
them, and the hypernova session secret, with `openssl rand -hex 24`.
`PORTFOLIO_TOTP_ENCRYPTION_KEY` must be base64 of 32 bytes (`[A-Za-z0-9+/]{43}=`).
`CF_TUNNEL_TOKEN` must look like a token Cloudflare issues (`eyJ` and at least 40 more
base64 characters). `WEBUI_SECRET_KEY` and `SEARXNG_SECRET` must be at least 32 letters and digits. `HOME_TLS_CF_DNS_TOKEN` must be 40 or
more letters, digits, `_` and `-`. The Beszel and Garage secrets' formats are in their rows above. [RUNBOOK.md](../RUNBOOK.md#7-the-production-environment) generates every
value.

### Variables

| Variable | Meaning |
| --- | --- |
| `GHCR_USERNAME` | The GHCR account `GHCR_TOKEN` belongs to, `[A-Za-z0-9-]+` |
| `TS_OAUTH_CLIENT_ID` | ID of the Tailscale OAuth client |
| `SERVER_SSH_HOST` | The server's tailnet name, `infra-host`. The only address the workflow SSHes to |
| `SERVER_USER` | *(optional)* The forced-command account; defaults to `deploy`. The workflow refuses `root` and `admin` |
| `PORTFOLIO_GOOGLE_CLIENT_ID` | *(optional)* The client ID half of the Google OAuth pair in the secrets table; a variable, not a secret |

The domains, the app image repositories, the `ai` and `media` accounts' uids and gids, the
Ollama model and the disks' UUIDs are in [`production.yml`](../production.yml), not in the
Environment. The tunnel's Public Hostnames are in Cloudflare
([edge.md](edge.md#why-the-tunnel-is-a-release-stack)).

## Where each secret lands

`release.yml` renders one env file per container, so each secret reaches only the container
that reads it. The bundle holds 20 files; on the host the compose files and `release.env` are
mode 0644, the rest 0600:

| Bundle file | Holds | Read by |
| --- | --- | --- |
| `database/postgres.env` | superuser password | `postgresql` |
| `database/provision.sql` | role passwords | `psql`, run by `infra-apply` |
| `portfolio/portfolio.env` | DSN, TOTP key, admin password, mail, Google | `portfolio` |
| `hypernova/provider.env` | DSN, session secret, admin password | `prizm-provider` |
| `tunnel/tunnel.env` | `TUNNEL_TOKEN`, the Cloudflare Tunnel token | `cloudflared` |
| `ai/open-webui.env` | `WEBUI_SECRET_KEY`, Open WebUI's session key | `open-webui` |
| `ai/searxng.env` | `SEARXNG_SECRET`, SearXNG's secret key | `searxng` |
| `media/home-tls.env` | `CF_DNS_API_TOKEN`, the Cloudflare DNS token for the links page's certificate | `home-tls` |
| `media/beszel.env` | `BESZEL_HUB_USER_PASSWORD`, the dashboard login's password | `beszel` |
| `media/beszel-pair.env` | `OWNER_PASSWORD`, `AGENT_TOKEN` | `beszel-pair` |
| `media/beszel-agent.env` | `TOKEN`, the agent's token | `beszel-agent` |
| `media/garage.env` | `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN` | `garage` |
| `media/garage-setup.env` | `GARAGE_ADMIN_TOKEN`, `OWNER_ACCESS_KEY_ID`, `OWNER_SECRET_ACCESS_KEY` | `garage-setup` |
| `ghcr.env` | GHCR login | `infra-apply`'s `docker login` |
| `<stack>/.env` | image references, domains, the `ai` and `media` uids and gids, the Ollama models, the ACME contact and the dashboard's login name only | Compose interpolation |
| `release.env`, `manifest.sha256`, `<stack>/docker-compose.yml` | no secrets | `infra-apply` |

See [architecture.md](architecture.md#env-files) for why the `.env` files carry no secrets.

## What `infra-apply` checks, in order

[`roles/common/files/infra-apply`](../roles/common/files/infra-apply) refuses a bundle before
anything changes ("…; the running release is untouched") unless all of this holds:

1. It runs as root, `/etc/infra/host.env` names the three app image repositories, the host's
   Tailscale IPv4 (`TAILSCALE_IP`, in `100.64.0.0/10`) and the `ai` and `media` accounts
   (`AI_USER`, `MEDIA_USER`, never root), no other release or status holds the lock, and `/opt/edge/docker-compose.yml` (Traefik, written by
   provisioning) exists.
2. The bundle is at most 1 MiB, a gzip tar of exactly the 26 expected names, regular files
   only, each at most 256 KiB.
3. `manifest.sha256` lists exactly those files, and every checksum matches.
4. Every env file is `KEY=value` lines only; `ghcr.env` sets exactly `GHCR_USERNAME` and
   `GHCR_TOKEN`; `tunnel/tunnel.env` sets exactly `TUNNEL_TOKEN`; `ai/open-webui.env` sets
   exactly `WEBUI_SECRET_KEY`; `ai/searxng.env` sets exactly `SEARXNG_SECRET`; `media/home-tls.env` sets exactly `CF_DNS_API_TOKEN`; each Beszel and Garage env file sets
   exactly its keys in the formats of the secrets above; `release.env` sets exactly
   `RELEASE_MODE` and `RELEASE_COMMIT`.
5. Each app image is `<repo>:latest` in a `latest` release, or `<repo>:<tag>@sha256:<digest>`
   in a `pinned` one, for the repository `/etc/infra/host.env` names.
6. `docker compose config` of each stack passes
   [`infra-compose-guard`](../roles/common/files/infra-compose-guard): the stack's own project
   name, container names, volumes and existing networks only (and, where it says so, per
   container: only hypernova's provider joins `llm`); no privileged settings, added
   capabilities, devices, host namespaces or Docker socket; no host port but the tailnet-only
   ones (`open-webui` 8080, `jellyfin` 8096, `audiobookshelf` 13378, `kavita` 5000, `home` 80,
   `home-tls` 443, `beszel` 8090, `garage` 3900), each
   written exactly `"${TAILSCALE_IP}:<port>:<port>"` and resolved to the address `host.env`
   names; no bind mount but the media library folders, Garage's `/srv/media/s3` and the two
   folders Beszel's agent sizes disks through, each in its own container at its fixed path,
   read-only except Audiobookshelf's audiobooks and podcasts and Garage's objects,
   `create_host_path: false`; a GPU reservation only for `ollama`, `comfyui`, `jellyfin` and
   `beszel-agent`, and only the whole NVIDIA GPU; only the stack's own env files, each read by
   its one container; in `ai` and
   `media`, every service is named after its container and runs as `AI_USER` or `MEDIA_USER`
   with a `mem_limit`, `cap_drop: [ALL]` and `no-new-privileges`; third-party images pinned by
   digest; no routing or agent labels on the database, and only `autoheal` on the tunnel, `ai`
   and `media`.
7. `docker login ghcr.io` with `ghcr.env`, and a pull of every image.

Then it installs the bundle as `/opt/infra/releases/<UTC time>-<sha12>`, starts `database`
with `--wait`, runs `provision.sql` over the local socket, points `current` at the new release
(and `previous` at the last verified one), starts `portfolio`, `hypernova`, `tunnel`, `ai` and
`media` (Compose gets `TAILSCALE_IP` from `host.env` for every call), and verifies:
every container running and healthy within 10 minutes, each up for at least 30 s without
a restart (so a container without a healthcheck, such as `prizm-web`, that crash-loops is not
taken for running), judged only on a poll that listed every stack and inspected every listed
container (one that Watchtower recreated in between counts as not ready yet); Traefik, asked
on its `edge` address the way the tunnel asks it (`Host:` the domain, `X-Forwarded-Proto:
https`), answering `2xx` for `arbikullakshi.com/api/health`, `hypernova.arbikullakshi.com/` and
its `/api/health`, and `301`/`308` for `www.arbikullakshi.com/`; `cloudflared`'s `/ready`
answering `200` (the tunnel holds a connection to Cloudflare); each tailnet-only port bound by
Docker to the Tailscale address and nothing else (`docker inspect` of its `PortBindings`); and
no refused call in any socket proxy's log ([edge.md](edge.md#verifying-it)). Only then does it record the running digests
(`running-images.env`), mark the release `.verified`, and print `RELEASE OK`. It keeps only
`current` and `previous`.

## Provisioning

```bash
cp inventory/hosts.example inventory/hosts       # [server] infra-host ansible_host=infra-host
ansible-playbook -u admin --ask-become-pass provision.yml
```

`ansible.cfg` points at `inventory/hosts` and checks host keys. The very first run is
different (the installer's account, over the LAN):
[RUNBOOK.md](../RUNBOOK.md#5-first-provision-over-the-lan), [host.md](host.md#the-bootstrap).

The checks in `tasks/provision-checks.yml` and the SSH policy at the end
(`roles/common/tasks/ssh_access.yml`) run on every invocation, whatever the tags. Each role has
a tag of its own:

| Tag | Runs |
| --- | --- |
| `common` | packages, ufw, the `admin` and `deploy` accounts and the release scripts, fail2ban, patching, NTP, journald |
| `tailscale` | the tailnet join and its checks |
| `docker` | the pinned Engine, `daemon.json` (with the `nvidia` runtime when `gpu_enabled`), the prune timer |
| `gpu` | the NVIDIA server driver of `nvidia_driver_major`, the Container Toolkit, the read-back (`nvidia-smi`, `docker info`) |
| `host` | `/etc/infra/host.env` (with the Tailscale IPv4), non-local binds, the `INFRA-PUBLIC` firewall and its tailnet hook, swap, no sleep, the `edge`, `data`, `ai`, `llm` and `media` networks, the `pgdata-v18` volume, the `ai` and `media` accounts and their volumes, the disks at `/srv/media` and `/srv/backup`, the nightly backup timer, the published-port read-back |
| `edge` / `watchtower` / `autoheal` | that compose project and its verify tasks (Traefik: no published port) |

No tags runs everything, in that order.

## Adding a project

The release path is deliberately explicit about which stacks, files, containers and images
exist, so a new project touches several places:

1. `stack/<name>/docker-compose.yml`, `env.j2` (images and domains only) and one env template
   per container that needs secrets. Give the public container the Traefik labels (unique
   router names, entrypoint `web`, no TLS labels — see [edge.md](edge.md)),
   `com.centurylinklabs.watchtower.enable=true` and, with a healthcheck, `autoheal=true`.
2. `production.yml`: its domain and image repository; `roles/host/tasks/main.yml`: the
   repository's key in `/etc/infra/host.env`.
3. `release.yml`: the bundle directory, the copy and template loops, the secret asserts and
   `env_file_values`.
4. `roles/common/files/infra-apply`: `stacks`, `bundle_files`, `env_files`, `secret_files`,
   `image_specs` and `route_targets`; `roles/common/files/infra-compose-guard`: its `STACKS`
   entry (networks, volumes, container names, env files). A port for the tailnet only goes in
   `TAILNET_PORTS` (the guard and `ci/check_templates.py`), `tailnet_ports` (infra-apply and
   `roles/host/defaults/main.yml`) and `ufw_allowed`, and in the Tailscale policy's grant;
   `ci/check_access.py` (rule 5) fails until all of them agree. Never a public port: the public
   arrives through the tunnel.
5. `build-bundle.sh` (`image_keys`, `env_file_for`) and `release-images.sh` (`resolve`), and
   the workflow's rollback inputs, if it should roll back.
6. If it needs a database: a consumer in `stack/database/provision.sql.j2`, its password
   secret, and the `data` network on the container.
7. The new secrets in the workflow's `env` block and `jq` call, in this file, and in the
   `production` Environment; then the fixtures in `ci/release-scripts.sh`.
8. A Public Hostname on the tunnel (`<domain>` → `http://edge-traefik:80`) with its proxied
   `CNAME`, at Cloudflare ([RUNBOOK.md](../RUNBOOK.md#6-cloudflare-tunnel)). Then provision (for
   `host.env`) and release.
