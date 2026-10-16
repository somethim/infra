# Architecture

## One deployer, three ways in

This repository is the only thing that configures the server, a dedicated PC on the owner's
home LAN. The application repositories — `hypernova`, `portfolio` — are **build-only**: their
CI builds an image, pushes it to GHCR, and stops there. None of them can deploy, and none of
them knows how to reach the server.

```
                    visitors
                       │ HTTPS
                       ▼
                Cloudflare edge  (TLS, HTTP→HTTPS, DNS: proxied CNAMEs → the tunnel)
                       ▲
                       │ outbound tunnel (cloudflared dials out; no inbound port anywhere)
┌──────────────────────┼──────────────── home server (LAN, behind the router, no port forward) ──┐
│  cloudflared ──HTTP──▶ edge-traefik:80 ──▶ portfolio · prizm-web · prizm-provider ──▶ postgresql │
│  (stack/tunnel)        (roles/edge)        (stack/portfolio, stack/hypernova)     (stack/database)│
│                                                                                                   │
│  Watchtower ── sees a new :latest digest in GHCR → pull + recreate the app container              │
│  sshd :22 ◀── tailscale0 only;  Open WebUI, Jellyfin, Audiobookshelf, Kavita ◀── the Tailscale    │
│  address only (stack/ai, stack/media);  library on /srv/media (HDD), backups on /srv/backup (USB)  │
└──────────────────────────────────────▲────────────────────────────────────────────────────────────┘
                                       │ Tailscale (SSH, tcp 22)
          ┌────────────────────────────┴───────────────────────────────┐
          │ provision.yml (owner's laptop, admin + sudo)                │
          │ Deploy workflow → release bundle (deploy, forced command)   │
          └──────────────────────── infra (this repo) ──────────────────┘

hypernova ─┐  build :latest → GHCR ┐   Watchtower (on the server) sees the new
portfolio ─┘  build :latest → GHCR ┘   digest → docker pull + recreate container
```

There are exactly three ways anything acts on the host:

| Who | How | Can do |
| --- | --- | --- |
| The owner | `admin` over the tailnet (or at the server's own console), sudo with a password | anything; runs `provision.yml` |
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

- **`provision.yml`** runs the roles `common`, `tailscale`, `docker`, `gpu`, `host`, `edge`,
  `watchtower`, `autoheal`, then the SSH login policy. Facts about the host (tailnet name,
  Ubuntu release, Docker major, reboot time, swap, published ports (none), domains, app image
  repositories) are in `production.yml`. The first run bootstraps a fresh Ubuntu install over
  the LAN as the installer's account; every later one runs as `admin` over the tailnet
  ([host.md](host.md#the-bootstrap)). See [host.md](host.md), [edge.md](edge.md),
  [agents.md](agents.md).
- **A release** is rendered on the GitHub runner by `release.yml` and `build-bundle.sh`, and
  applied on the host by `infra-apply`. See [deploying.md](deploying.md#releases).

## Stacks and their order

A stack is a directory under `stack/` — `database`, `portfolio`, `hypernova`, `tunnel`, `ai`,
`media` —
holding a `docker-compose.yml` and the env templates `release.yml` renders. Each is its own
Compose project with fixed project, container and volume names, so a release recreates
containers in place and never moves data. On a fresh host the first release creates the
volumes empty (`pgdata-v18` comes from provisioning, the app volumes from Compose) and the
apps initialise them; nothing ever deletes one.

`infra-apply` brings them up **in this order**:

```
database (--wait) → provision.sql → portfolio → hypernova → tunnel → ai → media
```

The tunnel goes after the apps so that by the time Cloudflare can send requests, the apps
behind Traefik are starting; its own failure cannot hold back the apps. `ai` and `media`,
which nothing public depends on, come last: the sites are up before their large images start.

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
    database/ portfolio/ hypernova/ tunnel/   compose file and env files per stack
    release.env                  RELEASE_MODE=latest|pinned, RELEASE_COMMIT=<sha>
    running-images.env           the digest each app container ran when verified
    .verified                    present once the release passed every check
  current  → releases/<id>       the release the stacks run from
  previous → releases/<id>       the last verified release before it
```

`previous` only ever points at a verified release, and only `current` and `previous` are
kept. A release that fails after the app stacks changed stays `current` without `.verified`,
and the failure message names the last verified one. See
[RUNBOOK.md](../RUNBOOK.md#releases-status-rollback-resume).

## Env files

Each container reads its secrets from its own env file (`postgres.env`, `portfolio.env`,
`provider.env`, `tunnel.env`, `open-webui.env`), declared with `env_file:`, where the value
passes through untouched. Each stack's `.env` is read by Compose only for `${VAR}`
interpolation in the compose file, and holds image references, domains, uids and the model —
never a secret. One interpolated value comes from the host instead: `TAILSCALE_IP`, which
`infra-apply` exports from `/etc/infra/host.env` for every Compose call.

The split matters because a value Compose interpolates is subject to its syntax (a `$` is
eaten), and because a single `.env` injected wholesale would hand every container every
secret of its stack. `release.yml` refuses any value with a `$`, quote, backtick, backslash,
`#`, line break or edge space, which the env file format would rewrite, and `infra-apply`
refuses any env line that is not `KEY=value`.

## Networks

| Network | Created by | Members |
| --- | --- | --- |
| `edge` | `roles/host` | Traefik, `cloudflared`, plus every container that serves a public domain |
| `data` | `roles/host` | PostgreSQL, plus every container that talks to it |
| `ai` | `roles/host` | Ollama, `ollama-pull`, Open WebUI, `webui-presets`, SearXNG, ComfyUI, `comfyui-fetch` (a plain bridge: Ollama and `comfyui-fetch` download models, SearXNG queries search engines, Open WebUI publishes its tailnet port) |
| `llm` | `roles/host`, `--internal` | Ollama and hypernova's `prizm-provider`, nothing else; no route out |
| `media` | `roles/host` | Jellyfin, Audiobookshelf, Kavita (metadata lookups, podcast downloads, their tailnet ports) |
| `edge-socket`, `watchtower-socket`, `autoheal-socket` | their compose projects, `internal: true` | one agent and its socket proxy each |

The stacks declare these networks `external: true`, and the compose guard refuses a release
that adds or creates any other network, or puts a container on a network that is not its own
(`hypernova`, `ai`, `media`). They are created by provisioning so they exist before any stack
or the edge proxy starts.

## Public and tailnet-only

Two audiences, two ways in, and nothing else:

| Service | Who | Way in | Address |
| --- | --- | --- | --- |
| portfolio (`arbikullakshi.com`, `www.`) | anyone | Cloudflare → tunnel → Traefik | the public hostnames |
| hypernova (`hypernova.arbikullakshi.com`) | anyone | Cloudflare → tunnel → Traefik | the public hostname |
| SSH | the owner (`admin`), the Deploy workflow (`deploy`) | Tailscale, tcp 22 | `infra-host` |
| Links page (`stack/media`, `home`, `home-tls`) | the owner | Tailscale, tcp 80 and 443 | `http://infra-host/`, `https://home.arbikullakshi.com/` |
| Open WebUI (`stack/ai`) | the owner | Tailscale, tcp 8080 | `http://infra-host:8080` |
| Jellyfin (`stack/media`) | the owner | Tailscale, tcp 8096 | `http://infra-host:8096` |
| Audiobookshelf (`stack/media`) | the owner | Tailscale, tcp 13378 | `http://infra-host:13378` |
| Kavita (`stack/media`) | the owner | Tailscale, tcp 5000 | `http://infra-host:5000` |
| Ollama, PostgreSQL, Traefik | containers only | Docker networks (`llm`, `data`, `edge`) | none on the host |

A tailnet-only service publishes its port on the host's **Tailscale IPv4 alone**
(`"${TAILSCALE_IP}:<port>:<port>"`, the address provisioning reads with `tailscale ip -4` into
`/etc/infra/host.env`), never `0.0.0.0` or the LAN address, and never through the tunnel or
Traefik. The ports are an allowlist in five places that `ci/check_access.py` keeps equal: the
compose guard's and `ci/check_templates.py`'s `TAILNET_PORTS`, `infra-apply`'s and
`roles/host`'s `tailnet_ports`, and `ufw_allowed` (on `tailscale0` only). On the tailnet, the
Tailscale policy grants these ports to the owner (`autogroup:admin`) alone
([RUNBOOK.md](../RUNBOOK.md#4-tailscale)). Plain HTTP is fine there: WireGuard encrypts every
packet between the owner's devices and the server. Video in particular never goes through
the tunnel: Cloudflare's terms rule it out, and it would be slower than the tailnet anyway.

## No public ports

**Nothing on the host is reachable from the internet, and nothing is reachable from the LAN
but SSH until the tailnet takes over.** The public reaches the sites only through the
Cloudflare Tunnel, an outbound connection from `cloudflared`; Traefik listens only on the
`edge` network. Several layers make that true:

- No container publishes a port but the tailnet-only ones, and those only on the Tailscale
  address: the compose guard refuses any other `ports:` (and any other form or address for
  those) in every release stack, `ci/check_templates.py` (rule 9) in every compose file,
  `infra-apply` reads each binding back from Docker after the start, and provisioning reads
  back that Traefik has no port bindings and that every published port on the host is an
  allowlisted one on the Tailscale address.
- ufw denies everything inbound except 22 and the tailnet-only ports on `tailscale0` (and LAN
  22 only until the first run over the tailnet).
- Docker's published ports bypass ufw (they are NAT rules), so `infra-firewall` hooks a chain
  `INFRA-PUBLIC` first in `DOCKER-USER` that drops every new connection from the LAN-facing
  interface to a container (`public_ports: []` in `production.yml`), and second for every new
  connection to a published port (conntrack `DNAT`) that did not arrive on `tailscale0`. So a
  port bound wider by mistake is still unreachable from the LAN, Wi-Fi or anything but the
  tailnet.
- The home router forwards no port to the server, and the server's public IP is not in DNS.

PostgreSQL publishes nothing and is reachable only from containers on `data`. See
[edge.md](edge.md#only-the-tunnel-reaches-traefik) and [host.md](host.md#firewall).

## Host keys and inventory

Host keys are checked everywhere. `ansible.cfg` sets `host_key_checking = True`, so the
owner's laptop must already know the server's key (its fingerprint read at the server's own
console), and the Deploy workflow connects with `StrictHostKeyChecking=yes` against the
`SSH_KNOWN_HOSTS` secret. A reinstalled server gets a new key, and both must be updated on
purpose ([RUNBOOK.md](../RUNBOOK.md#5-first-provision-over-the-lan)).

The inventory names one host, `infra-host`, by its tailnet name; `inventory/hosts` is
gitignored and `inventory/hosts.example` is the committed template. Only the bootstrap run
points it at the LAN address. No address is committed, and the workflow only ever uses the
tailnet name.
