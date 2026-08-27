# infra docs

Why this server is built the way it is. The code says *what* happens; these files say
*why*, and what will break if you change it.

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | The deployment model: one deployer, build-only app repos, what a "stack" is, the networks, and why the deploy order matters |
| [deploying.md](deploying.md) | Running a deploy: the workflow, every secret, the tag system, first-time and server-swap order, adding a project |
| [stacks.md](stacks.md) | What is peculiar about crm, hypernova and portfolio individually |
| [database.md](database.md) | The shared PostgreSQL — the volume, the superuser, how roles and databases are provisioned, upgrades |
| [edge.md](edge.md) | Traefik: TLS, routing by label, and the conventions an app stack has to follow |
| [host.md](host.md) | Firewall, SSH, fail2ban, patching, the Docker daemon, memory limits |
| [agents.md](agents.md) | The three things that act on their own: Watchtower, autoheal, the prune timer |
| [operations.md](operations.md) | Runbook: rotating secrets, recovering access, backups, cleanup |

## Reading order

New to the repo: [architecture.md](architecture.md), then [deploying.md](deploying.md).

About to change something stateful: [database.md](database.md) first.

Locked out, or something is down: [operations.md](operations.md).
