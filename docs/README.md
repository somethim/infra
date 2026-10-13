# infra docs

Why this server is built the way it is. The code says *what* happens; these files say
*why*, and what will break if you change it. What to *do*, in order, is in
[RUNBOOK.md](../RUNBOOK.md).

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | The deployment model: one deployer, three access paths, provision vs release, the stacks and their order, the releases directory, env files, networks, why only 80/443 are public, host keys |
| [deploying.md](deploying.md) | The Deploy workflow and its inputs, every secret and variable, where each secret lands, what `infra-apply` checks, provisioning tags, adding a project |
| [stacks.md](stacks.md) | What is peculiar about hypernova and portfolio individually |
| [database.md](database.md) | The shared PostgreSQL — the volume, the superuser, how roles and databases are provisioned at release time, upgrades |
| [edge.md](edge.md) | Traefik: its socket proxy, routing by label, the conventions an app stack has to follow, TLS, optional Authenticated Origin Pulls |
| [host.md](host.md) | Tailscale-only SSH, the accounts, sshd policy, firewall, fail2ban, patching, journald, swap, the Docker daemon, memory limits |
| [agents.md](agents.md) | The three things that act on their own: Watchtower, autoheal, the prune timer; re-pinning third-party images |
| [operations.md](operations.md) | Short recipes: PostgreSQL access, disk, backups, a major upgrade, Watchtower, a hung site |

## Reading order

New to the repo: [architecture.md](architecture.md), then [deploying.md](deploying.md).

About to change something stateful: [database.md](database.md) first.

Locked out, or something is down: [RUNBOOK.md](../RUNBOOK.md), then
[operations.md](operations.md).
