# Architecture

## One deployer, three ways in

This repository is the only thing that configures the server. The application
repositories — `hypernova`, `portfolio` — are **build-only**: their CI builds an image,
pushes it to GHCR, and stops there. None of them can deploy, and none of them knows the
server's address.

```
hypernova ─┐  build :latest → GHCR ┐   Watchtower (on the server) sees the new
portfolio ─┘  build :latest → GHCR ┘   digest → docker pull + recreate container
          ▲
          │ provision.yml (owner's machine, admin + sudo, over Tailscale)
          │ Deploy workflow → release bundle (deploy, forced command, over Tailscale)
        infra (this repo)
```

There are exactly three ways anything acts on the host:

| Who | How | Can do |
| --- | --- | --- |
| The owner | `admin` over the tailnet, sudo with a password | anything; runs `provision.yml` |
| The Deploy workflow | `deploy` over the tailnet, one key forced to `infra-deploy-gate` | `release` (a bundle on stdin) or `status`, nothing else |
| Watchtower | on the host, through a socket proxy, no login at all | pull a newer `:latest` of a labelled app container and recreate it |

`deploy` is in no group (not `docker`), its `authorized_keys` is owned by root, and sudo
lets it run only `/usr/local/sbin/infra-apply release` and `… status`. So the release key
can replace app containers from a checked bundle, but cannot open a shell, copy files, or
run Docker directly. Provisioning holds no app secrets; releases hold no host access beyond
`infra-apply`.

The consequence to remember: **while an app follows `:latest`, pushing an image deploys
it.** There is no approval step between a merge in an app repo and that code serving
traffic, so the GHCR token's scope and who can push to those repositories are the real
boundary. A rollback pins an app to a digest, which pauses that for the pinned app until
`resume`.

## Provision and release

- **`provision.yml`** runs the roles `common`, `tailscale`, `docker`, `host`, `edge`,
  `watchtower`, `autoheal`, then the SSH login policy. Facts about the host (tailnet name,
  Ubuntu release, Docker major, reboot time, swap, public ports, domains, app image
  repositories) are in `production.yml`. See [host.md](host.md), [edge.md](edge.md),
  [agents.md](agents.md).
- **A release** is rendered on the GitHub runner by `release.yml` and `build-bundle.sh`, and
  applied on the host by `infra-apply`. See [deploying.md](deploying.md#releases).

## Stacks and their order

A stack is a directory under `stack/` — `database`, `portfolio`, `hypernova` — holding a
`docker-compose.yml` and the env templates `release.yml` renders. Each is its own Compose
project, with the project names, container names and volumes the host had before this
layout, so a release recreates containers in place and moves no data.

`infra-apply` brings them up **in this order**:

```
database (--wait) → provision.sql → portfolio → hypernova
```

The order is load-bearing, and the reason is a limitation of Compose: `depends_on` is scoped
to a single project, so nothing outside the `database` stack can declare a dependency on
PostgreSQL. By the time `portfolio` starts, PostgreSQL is healthy and `provision.sql` has
created every role and database, so each application's credentials work the first time it
tries them, on a brand-new host. After that, `restart: always` handles a database that goes
away and comes back. See [database.md](database.md#roles-and-databases).

## Releases on the host

```
/opt/infra/
  releases/<UTC time>-<sha12>/   one directory per release: the unpacked bundle
    database/ portfolio/ hypernova/   compose file and env files per stack
    release.env                  RELEASE_MODE=latest|pinned, RELEASE_COMMIT=<sha>
    running-images.env           the digest each app container ran when verified
    .verified                    present once the release passed every check
  current  → releases/<id>       the release the stacks run from
  previous → releases/<id>       the last verified release before it
```

`previous` only ever points at a verified release, and only `current` and `previous` are
kept. A release that fails after the app stacks changed stays `current` without `.verified`,
and the failure message names the last verified one. See
[RUNBOOK.md](../RUNBOOK.md#8-releases-status-rollback-resume).

## Env files

Each container reads its secrets from its own env file (`postgres.env`, `portfolio.env`,
`provider.env`), declared with `env_file:`, where the value passes through untouched. Each
stack's `.env` is read by Compose only for `${VAR}` interpolation in the compose file, and
holds image references and domains — never a secret.

The split matters because a value Compose interpolates is subject to its syntax (a `$` is
eaten), and because a single `.env` injected wholesale would hand every container every
secret of its stack. `release.yml` refuses any value with a `$`, quote, backtick, backslash,
`#`, line break or edge space, which the env file format would rewrite, and `infra-apply`
refuses any env line that is not `KEY=value`.

## Networks

| Network | Created by | Members |
| --- | --- | --- |
| `edge` | `roles/host` | Traefik, plus every container that serves a public domain |
| `data` | `roles/host` | PostgreSQL, plus every container that talks to it |
| `edge-socket`, `watchtower-socket`, `autoheal-socket` | their compose projects, `internal: true` | one agent and its socket proxy each |

The stacks declare `edge` and `data` `external: true`, and the compose guard refuses a
release that adds or creates any other network. They are created by provisioning so they
exist before any stack or the edge proxy starts.

## Public ports

Only **80 and 443** are reachable from the internet, and only Traefik publishes them. Two
layers make that true:

- ufw denies everything inbound except 80, 443, and 22 on `tailscale0`.
- Docker's published ports bypass ufw (they are NAT rules), so `infra-firewall` hooks a chain
  `INFRA-PUBLIC` first in `DOCKER-USER`: new connections on the public interface reach only
  the ports in `public_ports` (`production.yml`). A container that published another port by
  mistake would still be unreachable; the compose guard refuses host ports in a release
  anyway.

PostgreSQL publishes nothing and is reachable only from containers on `data`. See
[host.md](host.md#firewall).

## Host keys and inventory

Host keys are checked everywhere. `ansible.cfg` sets `host_key_checking = True`, so the
owner's machine must already know the server's key (verified in the Hetzner console), and
the Deploy workflow connects with `StrictHostKeyChecking=yes` against the `SSH_KNOWN_HOSTS`
secret. A rebuilt server gets a new key, and both must be updated on purpose
([RUNBOOK.md](../RUNBOOK.md#63-record-the-host-key)).

The inventory names one host, `infra-host`, by its tailnet name; `inventory/hosts` is
gitignored and `inventory/hosts.example` is the committed template. No public address is
committed, and the workflow never uses one for SSH.
