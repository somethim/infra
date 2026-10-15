# The application stacks

What is peculiar about each one. The mechanics they share are in
[architecture.md](architecture.md).

## hypernova

One hostname serves both halves: the web app at `/` and the provider's API at `/api`,
split by router priority with a `stripprefix` middleware. See [edge.md](edge.md#priorities).

The provider connects to PostgreSQL with its own `prizm` role. The role name predates the
stack name — `prizm-lodge` was the original project — which is why the container names
(`prizm-provider`, `prizm-web`), the database, and the role all say `prizm` while the stack
says `hypernova`. Its secrets are in `provider.env`; `prizm-web` has none, and starts only
once the provider reports healthy.

Its only image tag is `:latest`, so a rollback names a digest (see
[RUNBOOK.md](../RUNBOOK.md#releases-status-rollback-resume)).

## portfolio

A Rust/Leptos server rather than a static site, so it carries state the other stacks do
not.

**The `portfolio-media` volume** holds uploads and the previews generated beside them. It
is the only application state outside PostgreSQL, and the `media` table is a ledger of
what is on it — the two must be backed up and restored together. See
[operations.md](operations.md#backups).

**A 180-second healthcheck grace.** The image carries the same probe, but before the
server starts, the entrypoint runs `/app/portfolio-seed migrate` (schema plus the
operator account) on every start. PostgreSQL lives in another stack, so the bootstrap
retries up to 20 times, 3 seconds apart, while the database comes up, and then applies
the migrations. The image's 15-second grace does not cover that, and without the override
autoheal could restart the container mid-bootstrap.

The entrypoint never seeds content: a seed run re-creates entries the admin has deleted,
so seeding is a manual step, run on purpose:

```bash
sudo docker exec portfolio /app/portfolio-seed
```

(The comment in the portfolio repo's `docker/entrypoint.sh` says
`docker compose exec web`; the service and container here are both named `portfolio`.)

**`WEBAUTHN_ORIGIN` is load-bearing.** Passkeys are bound to that exact origin. Change it
and every enrolled credential stops working — there is no migration path, only
re-enrolment. It is also the base for links in outgoing mail.

**`CLIENT_IP_SOURCE=Cloudflare`** reads Cloudflare's `CF-Connecting-IP` header instead of
selecting an address from `X-Forwarded-For`. Every public request reaches Traefik through the
Cloudflare Tunnel, where Cloudflare's edge sets that header to the visitor's address and
overwrites any value a client sent; nothing else can reach Traefik, so the header cannot be
forged ([edge.md](edge.md#client-addresses-and-forwarded-headers)). This keys the rate limiter
by the actual visitor instead of the proxy.

**Mail is optional.** Without `RESEND_API_KEY` the site still runs: contact messages and
comments are recorded and only the notifications are skipped and logged. The `From`
domain must be verified in Resend or every send is rejected.

**`TOTP_ENCRYPTION_KEY` is required for TOTP to work at all**, and `release.yml` refuses
a release without it (base64 of 32 bytes) before the host is even touched. It can never be
rotated casually: losing it makes every already-enrolled TOTP secret
permanently unreadable, with no fallback to plaintext — re-enrollment is the only
recovery.

The operator account is created by that bootstrap when it does not exist yet, with
`ADMIN_PASSWORD` (`PORTFOLIO_ADMIN_PASSWORD`), because the site has no signup path — without
it nobody can sign in. An existing account keeps its password whatever that secret says;
change it in `/admin`.

The portfolio publishes `:latest` and `:<full commit sha>` for every `master` build, so a
rollback can name a commit.

### The legacy site

`legacy.arbikullakshi.com` served a preserved Next.js portfolio from a second tag of the
same GHCR package. It was retired in August 2026: the DNS record, the container, the
image and the stack entry are all gone.

## ai

Ollama and Open WebUI on the GPU, for the owner alone. Nothing in this stack is public: it is
not on `edge`, has no Traefik label, and is never behind the tunnel.

- **`ollama`** serves models on `11434` inside Docker only: it publishes no port. It joins
  `ai` (a plain bridge, which it needs to download models) and `llm`, an **internal** network
  (no route out) whose only other member is hypernova's `prizm-provider`. Its models and key
  live in the external `ollama-models` volume (`HOME=/ollama`), on the SSD.
- **`ollama-pull`** is a one-shot on every release: `ollama pull <ollama_model>` against
  `http://ollama:11434` once Ollama is healthy. A model Ollama already has costs a manifest
  check. It exits; verify does not wait for it (restart `"no"`). `sudo docker logs ollama-pull`
  shows whether it worked (no internet, or a model name Ollama does not know).
- **`open-webui`** is the chat UI, `OLLAMA_BASE_URL=http://ollama:11434`, with its data
  (accounts, chats, its RAG embedding model, downloaded on first use) in the external
  `open-webui-data` volume. It publishes **8080 on the host's Tailscale address only**
  ([architecture.md](architecture.md#public-and-tailnet-only)). `WEBUI_AUTH=true`: every page
  needs a login. The first account created becomes the admin; `DEFAULT_USER_ROLE=pending`
  makes any later sign-up wait for the admin's approval, and the admin turns sign-up off right
  after creating the account ([RUNBOOK.md](../RUNBOOK.md#first-logins)). Its only secret,
  `WEBUI_SECRET_KEY`, signs sessions and comes from `open-webui.env`, which no other container
  may read. OpenAI connections, community sharing, update checks and telemetry are off.

**Hardening.** Every container runs as the `ai` account (`ai_uid:ai_gid` in `production.yml`,
`2001:2001`, created by `roles/host` with no login), never root, with `cap_drop: [ALL]`,
`no-new-privileges` and a `mem_limit`; the compose guard refuses the stack otherwise. The two
volumes are created by provisioning with their root owned by that account (0700) and mounted
with `nocopy`, so Docker never copies the image's root-owned directory over them. `ollama` and
`ollama-pull` also run with a read-only root filesystem (a tmpfs `/tmp`). `open-webui` does not:
the Python app writes a few files into its own tree at start, which as a non-root user already
fails harmlessly for anything root owns, and a read-only root would add little.

**hypernova.** The provider reaches Ollama on `llm` (`OLLAMA_HOST=http://ollama:11434`,
`OLLAMA_MODEL` = `ollama_model`, `AI_DISABLED=false` in `provider.env`). `prizm-web` is not on
`llm`; the guard refuses it there.

**Memory and VRAM.** `mem_limit`: `ollama` 8 GiB (the model sits in VRAM; RAM covers what
does not fit and the runner), `open-webui` 2 GiB (its embedding model runs on the CPU),
`ollama-pull` 128 MiB. The RTX 2060 has 12 GB of VRAM, shared with Jellyfin's transcodes in
the `media` stack: `qwen2.5:7b` (Q4) takes about 5–6 GB with its context, each NVENC/NVDEC
transcode a few hundred MB. Ollama keeps **one** model loaded (`OLLAMA_MAX_LOADED_MODELS=1`,
one request at a time) and unloads it after 10 minutes idle (`OLLAMA_KEEP_ALIVE=10m`), so a
bigger model or a second one cannot crowd the card out for long. A 14B model (~9 GB) still
fits with one or two transcodes; anything larger spills to the CPU and gets slow, which
`ollama ps` shows as a CPU/GPU split.

**Updates.** The images are pinned `<tag>@sha256:<digest>` and carry no Watchtower label, on
purpose: Open WebUI migrates its database on start, Ollama changes its model format now and
then, and neither should change unattended. Move them with a re-pin and a release
([agents.md](agents.md#re-pinning-third-party-images)); `autoheal` restarts either if it
turns unhealthy.

**GPU.** `ollama` reserves the GPU (`deploy.resources.reservations.devices`, driver `nvidia`,
`count: all`, `capabilities: [gpu]`); the guard allows that for `ollama` and Jellyfin only.
`gpu_enabled: false` makes the release refuse to render, since the stack could not start.
