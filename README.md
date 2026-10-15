# infra — the single deployer

The **one** repo that configures the server: a dedicated PC on the owner's home LAN, running
Ubuntu Server 26.04 LTS, with no port open to the internet. The public reaches the sites only
through a **Cloudflare Tunnel** the server dials out to; SSH works only over **Tailscale**. It
provisions the host, runs the edge Traefik proxy and the autonomous agents, and releases every
stack: the shared `database`, two applications, `portfolio` and `hypernova`, and the `tunnel`.

The app repos (`hypernova`, `portfolio`) are **build-only** — their CI builds images and
pushes them to GHCR. They never deploy. Watchtower on the server pulls a new `:latest` and
recreates the container.

```
visitors ──HTTPS──▶ Cloudflare ◀══ tunnel (outbound) ══ cloudflared ─▶ Traefik :80 ─▶ portfolio · hypernova ─▶ PostgreSQL
                                                        └──────────── home server, no open port ────────────┘
hypernova ─┐  build :latest → GHCR ┐   Watchtower (on the server) sees the new
portfolio ─┘  build :latest → GHCR ┘   digest → docker pull + recreate container
          ▲
          │ provision.yml (owner's laptop)  ·  release bundle (Deploy workflow)
        infra (this repo) — the only thing that SSHes to the box, over Tailscale only
```

## How it deploys

- **Provisioning** — `provision.yml`, from the owner's laptop, as `admin` with a sudo
  password, over the tailnet. Packages, firewall, accounts, sshd, Tailscale, Docker, the
  NVIDIA driver and Container Toolkit, power settings, the edge proxy (no published port), Watchtower and autoheal. No secrets. The very
  first run bootstraps a fresh Ubuntu install over the LAN as the installer's account
  ([RUNBOOK.md](RUNBOOK.md#5-first-provision-over-the-lan)).

  ```bash
  cp inventory/hosts.example inventory/hosts
  ansible-playbook -u admin --ask-become-pass provision.yml
  ```

- **Releases** — GitHub → **Actions → "Deploy" → Run workflow** (`release`, `resume`,
  `rollback`, `status`). The runner renders a bundle from the `production` Environment and
  streams it to the `deploy` account, whose one key is forced to `release` or `status`. The
  host checks the bundle, starts `database`, `portfolio`, `hypernova` and `tunnel` in that
  order, and marks the release verified only when everything is healthy, Traefik routes every
  domain to its app and the tunnel is connected. Run one when a secret (the Cloudflare Tunnel
  token included) or a stack file changes — not for routine image updates.
- **Watchtower** — on the host, with no login: follows `:latest` for the app containers.
  A rollback pins digests, which pauses it for those apps until `resume`.

Three access paths, and nothing else: `admin` (owner, sudo with a password), `deploy` (CI,
forced to `release|status`), and Watchtower (no login, Docker through a socket proxy).
Inbound ports (other than SSH on the tailnet), password login and root login are off; host
keys are checked everywhere.

## Layout

```
production.yml         facts about the host: tailnet name, Ubuntu release, Docker major, domains, image repos
provision.yml          the host: owner's laptop, over the LAN once, then over Tailscale
release.yml            renders the release bundle on the runner; build-bundle.sh packs it
build-bundle.sh        deterministic bundle + manifest; refuses unpinned third-party images
release-images.sh      turns rollback targets into digest pins
ansible.cfg            auto-loaded; points at inventory/hosts, checks host keys
inventory/             hosts.example only — inventory/hosts is gitignored
roles/                 common · tailscale · docker · gpu · host · edge · watchtower · autoheal
roles/common/files/    infra-deploy-gate · infra-apply · infra-compose-guard (the host side of a release)
stack/                 database · portfolio · hypernova · tunnel (compose files and env templates)
tasks/                 placeholder-guards · provision-checks · ssh-route
ci/                    the release path, verify tasks and access/template rules, tested against fakes
.github/workflows/     deploy.yml, the Deploy workflow; checks.yml, the deploy lint
RUNBOOK.md             BIOS to first release, DNS switch-over, releases, rollback, recovery
docs/                  why any of it is the way it is
```

## Documentation

[RUNBOOK.md](RUNBOOK.md) says what to do, in order. The code says what happens.
[`docs/`](docs/README.md) says why, and what breaks if you change it.

- [architecture.md](docs/architecture.md) — the home server and the tunnel, access paths, stacks and their order, releases, env files, networks, no public ports
- [deploying.md](docs/deploying.md) — the Deploy workflow, every secret and variable, what the host checks, provisioning tags, adding a project
- [database.md](docs/database.md) — the shared PostgreSQL
- [stacks.md](docs/stacks.md) — what is peculiar about each application
- [edge.md](docs/edge.md) — the Cloudflare Tunnel, Traefik, its socket proxy, client IPs, routing conventions
- [host.md](docs/host.md) — Tailscale-only SSH, accounts and the LAN bootstrap, sshd, firewall, fail2ban, patching, power, Docker, the GPU
- [agents.md](docs/agents.md) — Watchtower, autoheal, the prune timer, re-pinning images
- [operations.md](docs/operations.md) — short recipes outside the runbook
