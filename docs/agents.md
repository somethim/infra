# Autonomous agents

Three things act on the host without anyone asking: Watchtower, autoheal and the prune timer.
All are installed by provisioning (`roles/watchtower`, `roles/autoheal`, `roles/docker`), all
are opt-in per container rather than blanket, and the two containers reach Docker only
through a socket proxy of their own.

## Socket proxies

Watchtower and autoheal (and Traefik, [edge.md](edge.md#the-socket-proxy)) never mount the
Docker socket. Each talks to its own `wollomatic/socket-proxy` container over an internal
network that only the two of them share (`watchtower-socket`, `autoheal-socket`; Beszel's agent,
which a release starts, uses `beszel-socket` from `roles/beszel`). The proxy
mounts the socket read-only, accepts only its one client, and allows only the API calls that
client needs:

| Proxy | Allows |
| --- | --- |
| `watchtower-socket-proxy` | `GET` ping, info, containers, image JSON; `POST` container create/stop/start/rename, image pull, network connect; `DELETE` containers and images |
| `autoheal-socket-proxy` | `GET` the container list; `POST` a container restart |
| `beszel-socket-proxy` | `GET` version, info, the container list and one container's stats (no inspect: environments hold secrets; no logs) |

Everything else is refused and logged as `blocked request`. Provisioning and every release
check that each proxy runs and refused none of its client's calls since the client started;
a new client version that needs another endpoint shows up there, and the fix is to allow
exactly what the log names in that role's `files/docker-compose.yml`.

## Watchtower

`nickfedor/watchtower` (pinned by digest), the maintained fork of `containrrr/watchtower`:
the original is unmaintained and negotiates a Docker API version current Engines refuse.

It polls GHCR every 60 seconds and, when a watched image's tag has a new digest, pulls it and
recreates the container. This is what makes the application repositories build-only: a push
to `:latest` is a deploy.

- `WATCHTOWER_LABEL_ENABLE=true` — only containers labelled
  `com.centurylinklabs.watchtower.enable=true` are considered: `portfolio`, `prizm-provider`,
  `prizm-web`. PostgreSQL and Traefik carry no such label and are never touched. **Never
  label a database**: an unattended image swap on a stateful container is a restore, not an
  update. The `ai` stack carries none either: its images are digest-pinned third-party ones
  that migrate their own data on start, so they move only with a reviewed re-pin and a
  release ([stacks.md](stacks.md#ai)); the compose guard refuses the label there.
- **Digest pins are skipped.** A rollback runs an app as `<repo>:latest@sha256:<digest>`,
  which Watchtower cannot move, so auto-updates pause for exactly the pinned apps until
  `resume` puts them back on `:latest`.
- `WATCHTOWER_CLEANUP=false` — the image it replaced stays on the host. That keeps a recent
  local copy of the previous version as an extra rollback hint (`known` lines in `status`)
  until the prune timer reclaims it. The primary record is each release's
  `running-images.env`.
- `WATCHTOWER_ROLLING_RESTART=true` — one container at a time.
- `WATCHTOWER_INCLUDE_STOPPED` and `WATCHTOWER_REVIVE_STOPPED` — a stopped labelled container
  is updated and started again.

Registry authentication is the host's `/root/.docker/config.json`, mounted read-only. That
file is written by `docker login ghcr.io` in `infra-apply` on every release, so the same
credentials serve the release's image pulls and Watchtower's digest checks; rotating
`GHCR_TOKEN` takes effect for Watchtower at the next release.

**Watchtower updates containers; it does not create them.** A missing app container comes
back from a `release`, not from Watchtower.

**A release stops Watchtower while it recreates the app containers.** `infra-apply` stops it
(`docker stop`, up to 120 s so an update in progress can finish) just before the first image
pull and starts it again once `portfolio` and `hypernova` are up, before verify checks it, so
the two never recreate the same container at once. Every failure path starts it again too;
a Watchtower that was not running when the release began is left as it was.

Provisioning waits for one completed Watchtower update session and stops if it reported
failed containers or a Docker API error.

## Autoheal

`willfarrell/autoheal` (pinned by digest). Restarts a container that reports `unhealthy`.

This exists because Docker does nothing when a healthcheck fails — it records the status and
moves on — and Traefik does not read that status either. Without autoheal, a hung application
stays in the routing table and keeps taking traffic that it will never answer.

- Opt in with the label `autoheal=true` (`AUTOHEAL_CONTAINER_LABEL=autoheal`): `portfolio`
  and `prizm-provider`.
- Checks every 30 seconds (`AUTOHEAL_INTERVAL=30`).
- `AUTOHEAL_START_PERIOD=300` — grace after autoheal itself starts, so a host that is still
  booting is not restarted into a loop.
- **Never label a database.** Restarting a slow PostgreSQL under load is how a slow database
  becomes a broken one.

`prizm-web` is deliberately not labelled: it defines no healthcheck, so there is nothing for
autoheal to act on.

## Beszel's socket proxy

`roles/beszel` provisions only `beszel-socket-proxy` and the internal `beszel-socket` network;
the hub and agent come with every release (`stack/media`, [stacks.md](stacks.md#media)). The
role's verify checks the proxy runs; a release's verify checks it refused none of
`beszel-agent`'s calls. Provision once (`--tags beszel`) before the first release with the
agent, or that release fails to start the media stack (the network does not exist yet).

## The prune timer

`docker-prune.timer` runs every Sunday at 03:00 (with up to 30 minutes of jitter, ahead of
the reboot window, and catching up after a reboot):

```
docker image prune --all --force --filter until=168h
```

That removes every image **no container uses** that was **created** more than a week ago.
Watchtower keeps replaced images (`CLEANUP=false`), so without this they would accumulate.

`until` filters by image creation time, not by when the image stopped being used, so a local
copy of a previous version survives only while it is young; that is why the rollback record
is each release's `running-images.env`, and why a digest is always pulled from GHCR, which
keeps untagged versions.

Containers are not pruned at all, so a deliberately stopped one survives. Run it early with
`sudo systemctl start docker-prune.service`.

## Re-pinning third-party images

Every image that is not an app image is pinned `<image>:<tag>@sha256:<digest>`: PostgreSQL
(`stack/database/docker-compose.yml`), cloudflared (`stack/tunnel/docker-compose.yml`), Ollama,
Open WebUI, SearXNG and ComfyUI (`stack/ai/docker-compose.yml`; Ollama's pin appears twice, for
`ollama` and `ollama-pull`, Open WebUI's for `open-webui` and `webui-presets`, ComfyUI's for
`comfyui` and `comfyui-fetch`), busybox, Traefik, Beszel (hub and the NVIDIA agent), curl,
Garage, SFTPGo and Immich (`stack/media/docker-compose.yml`: busybox for `home` and `garage-config`,
Traefik for `home-tls`, curl for `beszel-pair`, `garage-setup` and `immich-admin`; Immich's server,
CUDA machine-learning, PostgreSQL and Valkey images move together, to exactly what the new Immich
release's own `docker-compose.yml` names, after reading its release notes, since Immich migrates
its database on start; an SFTPGo re-pin also needs `FILES_HTML_SHA256` updated once `DRIVE_JS` has
been checked against the new `webclient/files.html`, which `ci/files-ui.sh` enforces), Traefik,
Watchtower, autoheal and the socket proxy
(`roles/{edge,watchtower,autoheal,beszel}/files/docker-compose.yml`). `build-bundle.sh` refuses a
release while any `image:` line there is not, and `infra-compose-guard` refuses an unpinned
one in a stack on the host. One version per repository: the socket proxy appears in four files, with the same pin.

To move one:

1. Read the multi-arch digest of the new tag:

   ```bash
   docker buildx imagetools inspect --format '{{json .Manifest.Digest}}' <image>:<tag>
   ```

2. Replace `<tag>@sha256:<digest>` in every file that runs that repository, and merge to
   `master`.
3. Apply it: provision with that role's tag (`--tags edge`, `--tags watchtower` or
   `--tags autoheal`; the socket proxy needs all three), or run `release` for PostgreSQL,
   cloudflared, Ollama and Open WebUI. Read an Open WebUI release's notes first: it migrates
   its database on start (and `webui-presets` imports its model code, so read its log after
   the release), so a copy of the `open-webui-data` volume
   ([operations.md](operations.md#backups)) is the way back. A PostgreSQL pin may move only within the major
   ([database.md](database.md#upgrades)). Pick a cloudflared release that has been out for a
   couple of weeks; it is never auto-updated (`--no-autoupdate`, no Watchtower label).
