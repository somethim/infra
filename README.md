# infra — the single deployer

The **one** repo that configures the server. It provisions the shared Hetzner host, runs the
edge Traefik proxy and the autonomous agents, and releases every stack: the shared
`database` plus two applications, `portfolio` and `hypernova`.

The app repos (`hypernova`, `portfolio`) are **build-only** — their CI builds images and
pushes them to GHCR. They never deploy. Watchtower on the server pulls a new `:latest` and
recreates the container.

```
hypernova ─┐  build :latest → GHCR ┐   Watchtower (on the server) sees the new
portfolio ─┘  build :latest → GHCR ┘   digest → docker pull + recreate container
          ▲
          │ provision.yml (owner's machine)  ·  release bundle (Deploy workflow)
        infra (this repo) — the only thing that SSHes to the box, over Tailscale only
```

## How it deploys

- **Provisioning** — `provision.yml`, from the owner's machine, as `admin` with a sudo
  password, over the tailnet. Packages, firewall, accounts, sshd, Tailscale, Docker, the edge
  proxy, Watchtower and autoheal. No app secrets.

  ```bash
  cp inventory/hosts.example inventory/hosts
  ansible-playbook -u admin --ask-become-pass provision.yml
  ```

- **Releases** — GitHub → **Actions → "Deploy" → Run workflow** (`release`, `resume`,
  `rollback`, `status`). The runner renders a bundle from the `production` Environment and
  streams it to the `deploy` account, whose one key is forced to `release` or `status`. The
  host checks the bundle, starts `database`, `portfolio` and `hypernova` in that order, and
  marks the release verified only when everything is healthy and routed. Run one when a
  secret or a stack file changes — not for routine image updates.
- **Watchtower** — on the host, with no login: follows `:latest` for the app containers.
  A rollback pins digests, which pauses it for those apps until `resume`.

Three access paths, and nothing else: `admin` (owner, sudo with a password), `deploy` (CI,
forced to `release|status`), and Watchtower (no login, Docker through a socket proxy).
Public SSH, password login and root login are off; host keys are checked everywhere.

## Layout

```
production.yml         facts about the host: tailnet name, Ubuntu release, Docker major, domains, image repos
provision.yml          the host: owner's machine, over Tailscale
release.yml            renders the release bundle on the runner; build-bundle.sh packs it
build-bundle.sh        deterministic bundle + manifest; refuses unpinned third-party images
release-images.sh      turns rollback targets into digest pins
ansible.cfg            auto-loaded; points at inventory/hosts, checks host keys
inventory/             hosts.example only — inventory/hosts is gitignored
roles/                 common · tailscale · docker · host · edge · watchtower · autoheal
roles/common/files/    infra-deploy-gate · infra-apply · infra-compose-guard (the host side of a release)
stack/                 database · portfolio · hypernova (compose files and env templates)
tasks/                 placeholder-guards · provision-checks
ci/                    release-scripts.sh, the release path tested against fakes
.github/workflows/     deploy.yml, the Deploy workflow
RUNBOOK.md             first setup, cut-over, releases, rollback, recovery
docs/                  why any of it is the way it is
```

## Documentation

[RUNBOOK.md](RUNBOOK.md) says what to do, in order. The code says what happens.
[`docs/`](docs/README.md) says why, and what breaks if you change it.

- [architecture.md](docs/architecture.md) — access paths, stacks and their order, releases, env files, networks, ports
- [deploying.md](docs/deploying.md) — the Deploy workflow, every secret and variable, what the host checks, provisioning tags, adding a project
- [database.md](docs/database.md) — the shared PostgreSQL
- [stacks.md](docs/stacks.md) — what is peculiar about each application
- [edge.md](docs/edge.md) — Traefik, its socket proxy, TLS, routing conventions
- [host.md](docs/host.md) — Tailscale-only SSH, accounts, sshd, firewall, fail2ban, patching, Docker
- [agents.md](docs/agents.md) — Watchtower, autoheal, the prune timer, re-pinning images
- [operations.md](docs/operations.md) — short recipes outside the runbook
