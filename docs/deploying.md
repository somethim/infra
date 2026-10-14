# Deploying

Two paths touch the server, and they never share credentials:

- **Provisioning** (`provision.yml`) runs from the owner's machine as `admin` with a sudo
  password, over the tailnet. It sets up the host, the edge proxy and the agents, and holds no
  app secrets. Run it when a role changes.
- **Releases** run from GitHub Actions (**Actions → Deploy → Run workflow**). The runner
  renders a bundle and hands it to the `deploy` account, which can only run `release` or
  `status`. Run one when a secret, a file under `stack/` or `production.yml` changes. Not for
  routine image updates: Watchtower deploys those within about a minute of a push.

First-time setup and the move from the old model are in [RUNBOOK.md](../RUNBOOK.md#6-cut-over).

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
[RUNBOOK.md](../RUNBOOK.md#8-releases-status-rollback-resume). The steps of a `release`:

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
5. Smoke-test the public hosts through Cloudflare, and, when `SERVER_HOST` is set, check that
   the origin refuses a direct request.

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
| `SSH_PRIVATE_KEY` | Private half of the CI deploy key ([RUNBOOK.md](../RUNBOOK.md#3-new-ci-deploy-key)). The public half is committed at `roles/common/files/deploy_key.pub` and installed for `deploy` only |
| `SSH_KNOWN_HOSTS` | The server's verified host key line under its tailnet name, `infra-host ssh-ed25519 AAAA…` ([RUNBOOK.md](../RUNBOOK.md#63-record-the-host-key)) |
| `TS_OAUTH_SECRET` | Secret of the Tailscale OAuth client (scope Auth Keys: write, tag `tag:infra-ci`) |
| `SERVER_HOST` | *(optional)* The server's public IPv4, used only by the smoke step to check that the origin refuses a direct request. Nothing connects to it over SSH |

The three database passwords must be at least 32 letters and digits (`[A-Za-z0-9]{32,}`)
and all different: they are written into `provision.sql` and the DSNs as literals. Generate
them, and the hypernova session secret, with `openssl rand -hex 24`.
`PORTFOLIO_TOTP_ENCRYPTION_KEY` must be base64 of 32 bytes (`[A-Za-z0-9+/]{43}=`).

### Variables

| Variable | Meaning |
| --- | --- |
| `GHCR_USERNAME` | The GHCR account `GHCR_TOKEN` belongs to, `[A-Za-z0-9-]+` |
| `TS_OAUTH_CLIENT_ID` | ID of the Tailscale OAuth client |
| `SERVER_SSH_HOST` | The server's tailnet name, `infra-host`. The only address the workflow SSHes to |
| `SERVER_USER` | *(optional)* The forced-command account; defaults to `deploy`. The workflow refuses `root` and `admin` |
| `PORTFOLIO_GOOGLE_CLIENT_ID` | *(optional)* The client ID half of the Google OAuth pair in the secrets table; a variable, not a secret |

The Let's Encrypt email, the domains and the app image repositories are in
[`production.yml`](../production.yml), not in the Environment.

## Where each secret lands

`release.yml` renders one env file per container, so each secret reaches only the container
that reads it. The bundle holds 12 files; on the host the compose files and `release.env` are
mode 0644, the rest 0600:

| Bundle file | Holds | Read by |
| --- | --- | --- |
| `database/postgres.env` | superuser password | `postgresql` |
| `database/provision.sql` | role passwords | `psql`, run by `infra-apply` |
| `portfolio/portfolio.env` | DSN, TOTP key, admin password, mail, Google | `portfolio` |
| `hypernova/provider.env` | DSN, session secret, admin password | `prizm-provider` |
| `ghcr.env` | GHCR login | `infra-apply`'s `docker login` |
| `<stack>/.env` | image references and domains only | Compose interpolation |
| `release.env`, `manifest.sha256`, `<stack>/docker-compose.yml` | no secrets | `infra-apply` |

See [architecture.md](architecture.md#env-files) for why the `.env` files carry no secrets.

## What `infra-apply` checks, in order

[`roles/common/files/infra-apply`](../roles/common/files/infra-apply) refuses a bundle before
anything changes ("…; the running release is untouched") unless all of this holds:

1. It runs as root, `/etc/infra/host.env` names the three app image repositories, no other
   release or status holds the lock, and `/opt/edge/dynamic/dynamic.yml` (the
   `cloudflare-only` allowlist, written by provisioning) exists.
2. The bundle is at most 1 MiB, a gzip tar of exactly the 12 expected names, regular files
   only, each at most 256 KiB.
3. `manifest.sha256` lists exactly those files, and every checksum matches.
4. Every env file is `KEY=value` lines only; `ghcr.env` sets exactly `GHCR_USERNAME` and
   `GHCR_TOKEN`; `release.env` sets exactly `RELEASE_MODE` and `RELEASE_COMMIT`.
5. Each app image is `<repo>:latest` in a `latest` release, or `<repo>:<tag>@sha256:<digest>`
   in a `pinned` one, for the repository `/etc/infra/host.env` names.
6. `docker compose config` of each stack passes
   [`infra-compose-guard`](../roles/common/files/infra-compose-guard): the stack's own project
   name, container names, volumes and existing networks only; no privileged settings, added
   capabilities, devices, host namespaces, host ports, bind mounts or Docker socket; only the
   stack's own env file; third-party images pinned by digest; no routing or agent labels on the
   database.
7. `docker login ghcr.io` with `ghcr.env`, and a pull of every image.

Then it installs the bundle as `/opt/infra/releases/<UTC time>-<sha12>`, starts `database`
with `--wait`, runs `provision.sql` over the local socket, points `current` at the new release
(and `previous` at the last verified one), starts `portfolio` and `hypernova`, and verifies:
every container running and healthy within 10 minutes, each up for at least 30 s without
a restart (so a container without a healthcheck, such as `prizm-web`, that crash-loops is not
taken for running), judged only on a poll that listed every stack and inspected every listed
container (one that Watchtower recreated in between counts as not ready yet), Traefik on the host answering 403 (the
`cloudflare-only` allowlist) for every public host and hypernova's `/api/`, and no refused call
in any socket proxy's log. Only then does it record the running digests
(`running-images.env`), mark the release `.verified`, and print `RELEASE OK`. It keeps only
`current` and `previous`.

## Provisioning

```bash
cp inventory/hosts.example inventory/hosts       # [server] infra-host ansible_host=infra-host
ansible-playbook -u admin --ask-become-pass provision.yml
```

`ansible.cfg` points at `inventory/hosts` and checks host keys. The very first run is
different (root, over the public address): [RUNBOOK.md](../RUNBOOK.md#61-first-provision-as-root-over-the-public-address).

The checks in `tasks/provision-checks.yml` and the SSH policy at the end
(`roles/common/tasks/ssh_access.yml`) run on every invocation, whatever the tags. Each role has
a tag of its own:

| Tag | Runs |
| --- | --- |
| `common` | packages, ufw, the `admin` and `deploy` accounts and the release scripts, fail2ban, patching, journald |
| `tailscale` | the tailnet join and its checks |
| `docker` | the pinned Engine, `daemon.json`, the prune timer |
| `host` | `/etc/infra/host.env`, the `INFRA-PUBLIC` firewall, swap, the `edge` and `data` networks, the `pgdata-v18` volume |
| `edge` / `watchtower` / `autoheal` | that compose project and its verify tasks |

No tags runs everything, in that order.

## Adding a project

The release path is deliberately explicit about which stacks, files, containers and images
exist, so a new project touches several places:

1. `stack/<name>/docker-compose.yml`, `env.j2` (images and domains only) and one env template
   per container that needs secrets. Give the public container the Traefik labels (unique
   router names, `cloudflare-only@file` first — see [edge.md](edge.md)),
   `com.centurylinklabs.watchtower.enable=true` and, with a healthcheck, `autoheal=true`.
2. `production.yml`: its domain and image repository; `roles/host/tasks/main.yml`: the
   repository's key in `/etc/infra/host.env`.
3. `release.yml`: the bundle directory, the copy and template loops, the secret asserts and
   `env_file_values`.
4. `roles/common/files/infra-apply`: `stacks`, `bundle_files`, `env_files`, `secret_files`,
   `image_specs` and `route_targets`; `roles/common/files/infra-compose-guard`: its `STACKS`
   entry (networks, volumes, container names, env files).
5. `build-bundle.sh` (`image_keys`, `env_file_for`) and `release-images.sh` (`resolve`), and
   the workflow's rollback inputs, if it should roll back.
6. If it needs a database: a consumer in `stack/database/provision.sql.j2`, its password
   secret, and the `data` network on the container.
7. The new secrets in the workflow's `env` block and `jq` call, in this file, and in the
   `production` Environment; then the fixtures in `ci/release-scripts.sh`.
8. A DNS record at Cloudflare, proxied. Then provision (for `host.env`) and release.
