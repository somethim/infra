# infra — the single deployer

The **one** repo that touches the server. It provisions the shared Hetzner host, runs
the edge Traefik proxy and the autonomous agents, and deploys every stack: the shared
`database` plus three applications.

The app repos (`crm`, `hypernova`, `portfolio`) are **build-only** — their CI builds
images and pushes them to GHCR. They never deploy. Watchtower on the server pulls a new
image and recreates the container.

```
crm repo ─┐  build :latest → GHCR ┐
          │                        │   Watchtower (on the server) sees the new
hypernova ─┤  build :latest → GHCR ┤   digest → docker pull + recreate container
portfolio ┘                         ┘
          ▲
          │ stack defs (compose + env) + provisioning + edge + agents
        infra (this repo, Ansible) — the only thing that SSHes to the box
```

## Deploy

GitHub → **Actions → "Deploy" → Run workflow**. Idempotent. Run it on a fresh server or
when a stack's compose file or secrets change — not for routine image updates.

```bash
# local equivalent
cp inventory/hosts.example inventory/hosts   # edit the IP
ansible-playbook playbook.yml -e @vars.json
```

## Layout

```
playbook.yml           the deployer: host roles, then stacks in order
ansible.cfg            auto-loaded; points at inventory/hosts
inventory/             hosts.example only — the real IP is never committed
roles/                 common · docker · edge · watchtower · autoheal
                       stack · postgres-data · postgres-provision
stacks/                database · crm · hypernova · portfolio
docs/                  why any of it is the way it is
```

## Documentation

The code says what happens. [`docs/`](docs/README.md) says why, and what breaks if you
change it.

- [architecture.md](docs/architecture.md) — the deployment model, stacks, networks, ordering
- [deploying.md](docs/deploying.md) — secrets, tags, first-time order, adding a project
- [database.md](docs/database.md) — the shared PostgreSQL
- [stacks.md](docs/stacks.md) — what is peculiar about each application
- [edge.md](docs/edge.md) — Traefik, TLS, routing conventions
- [host.md](docs/host.md) — firewall, SSH, fail2ban, patching, memory limits
- [agents.md](docs/agents.md) — Watchtower, autoheal, the prune timer
- [operations.md](docs/operations.md) — runbook
