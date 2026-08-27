# Architecture

## One deployer

This repository is the only thing that SSHes to the server. The application
repositories — `crm`, `hypernova`, `portfolio` — are **build-only**: their CI builds an
image, pushes it to GHCR, and stops there. None of them can deploy, and none of them
knows the server's address.

```
crm repo ─┐  build :latest → GHCR ┐
          │                        │   Watchtower (on the server) sees the new
hypernova ─┤  build :latest → GHCR ┤   digest → docker pull + recreate container
portfolio ┘                         ┘
          ▲
          │ stack defs (compose + env) + provisioning + edge + agents
        infra (this repo, Ansible)
```

The separation is what keeps the server's address, its secrets, and its deploy key in
exactly one place. It also means a compromised application repository cannot reach the
host: the worst it can do is publish an image, which Watchtower will deploy — so the
GHCR token's `read:packages` scope, and who can push to those repos, is the real
boundary.

The consequence to remember: **pushing an image deploys it.** There is no approval step
between a merge in an app repo and that code serving traffic.

## What a stack is

A stack is a directory under `stacks/<name>/` containing a `docker-compose.yml` and an
`env.j2`. `roles/stack` ships both to `/opt/<name>/` on the host, renders the template
into `/opt/<name>/.env`, and runs `docker compose up -d --remove-orphans --pull always`.

That is the entire abstraction. Adding a project is a directory plus a line in
`playbook.yml`; there is no per-project role, no per-project workflow, and no change to
the edge proxy.

Two optional hooks exist on a stack entry:

- **`pre_role`** — something that must exist before the stack's containers start, and
  that compose cannot create for itself.
- **`post_role`** — something that must be true before the *next* stack is deployed.

Only the `database` stack uses them, and it uses both. See [database.md](database.md).

### The `.env` file does double duty

`/opt/<name>/.env` is read by compose for `${VAR}` interpolation in the compose file
**and** injected wholesale into containers that declare `env_file: .env`.

This has a sharp edge: a value compose interpolates is subject to compose's own syntax,
so a `$` in it is eaten. Generate secrets with `openssl rand -hex 24` and the problem
never arises. The interpolated ones today are `POSTGRES_PASSWORD`, `REDIS_PASSWORD` and
`TYPESENSE_API_KEY`.

Compose files keep interpolation to a minimum for this reason — images, domains, and
little else. Everything an application reads arrives through `env_file` instead, where
the value passes through untouched.

## Networks

Three, all bridges, none published to the host except through Traefik.

| Network | Created by | Members |
| --- | --- | --- |
| `edge` | `roles/edge` | Traefik, plus every container that serves a public domain |
| `data` | `roles/edge` | PostgreSQL, plus every container that talks to it |
| `crm` | the crm stack | crm's internal services (`redis`, `typesense`, `app`, `worker`, `web`) |

`edge` and `data` are declared `external: true` by the stacks that use them, which is
why they are created once by `roles/edge` rather than by whichever stack happens to
come up first.

Nothing binds a host port except Traefik's 80 and 443. PostgreSQL, Redis and Typesense
are reachable only from a container on the same network — the firewall is a second line
of defence, not the first.

## Deploy order

`playbook.yml` runs the host roles, then the stacks **in list order**:

```
database → crm → hypernova → portfolio
```

The order is load-bearing, and the reason is a limitation of Compose: `depends_on` is
scoped to a single project, so nothing outside the `database` stack can declare a
dependency on PostgreSQL. Ordering the list is the only mechanism available.

By the time `crm` is deployed, the `database` stack is up and `roles/postgres-provision`
has created every role and database — so each application's credentials work the first
time it tries them, on a brand-new host, with no manual step.

After the first boot, ordering stops mattering: `restart: always` handles a database
that goes away and comes back.

## Inventory and authentication

The server's IP is never committed. CI passes it as an inline inventory
(`-i "${SERVER_HOST},"` — the trailing comma is what makes Ansible read it as a host
list rather than a filename). `inventory/hosts` is gitignored; `inventory/hosts.example`
is the committed template.

Authentication is by SSH key in both directions: CI passes `--private-key` built from
the `SSH_PRIVATE_KEY` secret, and a local run uses whichever of your own keys the host
trusts. The deploy key's *public* half is committed at `roles/common/files/deploy_key.pub`
and installed by `roles/common`, so a rebuilt host trusts CI with nothing to remember.

`ansible.cfg` is auto-loaded when Ansible runs from this directory and sets
`host_key_checking = False` — a rebuilt host gets a new host key, and CI has no known_hosts
to update.
