# Autonomous agents

Three things act on the host without anyone asking. All are idempotent, all live in
`playbook.yml`, and all are opt-in per container rather than blanket.

## Watchtower

Polls GHCR every 60 seconds and, when a watched image has a new digest, pulls it and
recreates the container. This is what makes the application repositories build-only: a
push is a deploy.

- `WATCHTOWER_LABEL_ENABLE=true` — only containers labelled
  `com.centurylinklabs.watchtower.enable=true` are considered. PostgreSQL, Redis,
  Typesense and Traefik carry no such label and are never touched. **Never label a
  database**: an unattended image swap on a stateful container is a restore, not an
  update.
- `WATCHTOWER_CLEANUP=true` — removes the image it replaced. Without this every update
  leaves an untagged layer set behind.
- `WATCHTOWER_ROLLING_RESTART=true` — updates one container at a time instead of stopping
  everything and starting everything.
- `DOCKER_API_VERSION=1.40` — `containrrr/watchtower` negotiates API 1.25, which newer
  daemons reject outright (`client version is too old, minimum 1.40`). Pinning a version
  the daemon accepts is the workaround; without it the container exits at startup.

Registry authentication is the host's `/root/.docker/config.json`, mounted read-only.
That file is written by the `docker login ghcr.io` step in `roles/watchtower`, so the
same credentials serve both the stacks' image pulls and Watchtower's digest checks.

**Watchtower updates containers; it does not create them.** If a container is missing,
Watchtower will not bring it back — a deploy will. This matters when reasoning about
what a wipe-and-wait will actually do.

## Autoheal

Restarts a container that reports `unhealthy`.

This exists because Docker does nothing when a healthcheck fails — it records the status
and moves on — and Traefik does not read that status either. Without autoheal, a hung
application stays in the routing table and keeps taking traffic that it will never
answer.

- Opt in with `autoheal=true`, the same shape as Watchtower's label.
- `AUTOHEAL_START_PERIOD=300` — grace after a restart before a container is eligible
  again, so something slow to warm up is not restarted into a loop.
- **Never label a database.** Restarting a slow PostgreSQL under load is how a slow
  database becomes a broken one.

`crm-web` and `prizm-web` are deliberately not labelled: neither defines a healthcheck
nor bakes one into its image, so there is nothing for autoheal to act on. Give them one
and the label becomes worth adding.

## The prune timer

`docker-prune.timer` reclaims dangling images every Sunday at 03:00.

Every image swap leaves the replaced image behind untagged. Watchtower cleans up the
swaps it performed itself, but a deploy-driven one (`compose up --pull always`)
accumulates until something reclaims it.

**Dangling only, never `-a`.** An untagged image is referenced by nothing and is safe to
remove. `-a` deletes anything without a *running* container, which includes every image
belonging to a stack that happens to be down mid-deploy, and any tag being kept
deliberately.

Containers are not pruned at all, so a deliberately stopped one survives.

Run it early with `systemctl start docker-prune.service`.
