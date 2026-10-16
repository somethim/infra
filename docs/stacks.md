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

Ollama, Open WebUI, SearXNG and ComfyUI, for the owner alone. Nothing in this stack is public:
it is not on `edge`, has no Traefik label, and is never behind the tunnel. Everything Open
WebUI's admin panel would otherwise hold is code in `stack/ai/docker-compose.yml` and applied
on every release: the owner configures nothing in the GUI.

- **`ollama`** serves models on `11434` inside Docker only: it publishes no port. It joins
  `ai` (a plain bridge, which it needs to download models) and `llm`, an **internal** network
  (no route out) whose only other member is hypernova's `prizm-provider`. Its models and key
  live in the external `ollama-models` volume (`HOME=/ollama`), on the SSD.
- **`ollama-pull`** is a one-shot on every release, once Ollama is healthy: `ollama pull` for
  each model in `ollama_models` (`production.yml`, passed as `OLLAMA_MODELS`), in order. A model
  Ollama already has costs a manifest check. Only when every pull finished does it remove the
  models the list no longer names (`ollama rm`), so the volume does not keep models nobody uses;
  a failed pull removes nothing. A model pulled by hand (from the admin panel) is removed by
  the next release unless it is added to the list. It exits; verify does not wait for it
  (restart `"no"`). `sudo docker logs ollama-pull` shows each pull and removal.
- **`open-webui`** is the chat UI, `OLLAMA_BASE_URL=http://ollama:11434`, with its data
  (accounts, chats, presets, its RAG embedding model, downloaded on first use) in the external
  `open-webui-data` volume. It publishes **8080 on the host's Tailscale address only**
  ([architecture.md](architecture.md#public-and-tailnet-only)). `WEBUI_AUTH=true`: every page
  needs a login. `ENABLE_PERSISTENT_CONFIG=false`: the environment is the whole configuration,
  read on every start; what the admin panel saves lasts until the next restart, so a setting
  is changed in the compose file and released. Sign-up is off (`ENABLE_SIGNUP=false`; the
  owner's account exists), `DEFAULT_USER_ROLE=pending` would hold any account that got in
  anyway, new chats start on the **Quick** preset (`DEFAULT_MODELS=quick`), web search goes to
  `searxng` and image generation to `comfyui`. Its only secret, `WEBUI_SECRET_KEY`, signs
  sessions and comes from `open-webui.env`, which no other container may read. OpenAI
  connections, community sharing, update checks and telemetry are off.
- **`webui-presets`** is a one-shot on every release, once `open-webui` is healthy. It runs
  Open WebUI's own code (same image, same volume, `python3 -c`) and writes the presets in
  `PRESETS` into its database as workspace models, owned by the admin account and readable by
  every user; it hides the raw `ollama_models` from the model picker, and deletes the presets
  it wrote that `PRESETS` no longer lists (it marks its own with `managed_by: infra` and leaves
  everything else alone). A preset whose base model `ollama_models` does not pull stops it with
  an error; on a fresh volume, before anyone has signed up, it does nothing and says so.
  `sudo docker logs webui-presets` lists what it added, updated or removed. It needs no key:
  it reads and writes the database directly and serves nothing.
- **`searxng`** is the web search Open WebUI queries (`http://searxng:8080/search`, JSON):
  a metasearch engine on the `ai` network only, with no rate limiter (nothing outside the
  stack can reach it), no image proxy and no metrics. Its settings are written to `/tmp` from
  the compose file at start; its secret key comes from `searxng.env` (`SEARXNG_SECRET`), which
  no other container may read. Engines that block it for a while (CAPTCHAs, rate limits) are
  skipped for that query; the others still answer.
- **`comfyui`** generates images for Open WebUI on the GPU (`http://comfyui:8188`), with
  **Stable Diffusion XL base 1.0**. ComfyUI publishes no official image; this is YanWenKun's
  `comfyui-boot` (`cu126-slim`, CUDA 12.6, which the 580 driver runs): the most used maintained
  build, which bakes a tagged stable ComfyUI release into the image rather than cloning one at
  start. The stack runs that copy directly as the `ai` account (not the image's root
  entrypoint), with a read-only root, `--disable-all-custom-nodes` (ComfyUI-Manager, which can
  install code, never loads), `--disable-api-nodes`, and its data (`models/`, outputs, its
  settings) in the external `comfyui-data` volume (`--base-directory=/data`). The workflow
  Open WebUI sends (`COMFYUI_WORKFLOW`, ComfyUI's API format) is in the compose file, 1024×1024
  and 25 steps by default; `COMFYUI_WORKFLOW_NODES` tells Open WebUI which inputs take the
  prompt, size, steps, seed and checkpoint.
- **`comfyui-fetch`** is a one-shot on every release: it downloads `sd_xl_base_1.0.safetensors`
  (6.9 GB, from a pinned revision of `stabilityai/stable-diffusion-xl-base-1.0`, ungated,
  CreativeML Open RAIL++-M) into `comfyui-data` and keeps it only if its sha256 matches the
  pinned one. A checkpoint already there is skipped. Verify does not wait for it; until it
  finishes, image generation fails with a missing checkpoint. `sudo docker logs comfyui-fetch`
  shows the progress (every GiB). FLUX.1-schnell was the other candidate: its smallest
  all-in-one file (fp8) is 17 GB, more than the host's 16 GB of RAM can stage while loading.

**The presets.** `PRESETS` in the compose file is the one list:

| Preset | Base model | For | Context | Defaults |
|---|---|---|---|---|
| Quick | `qwen3:4b` | short answers checked against the web | 8k | web search on, thinking off |
| MCU Coder | `qwen2.5-coder:14b` | embedded Rust, C and C++ | 16k | temperature 0.2 |
| Robotics | `qwen3:14b` | kinematics, control, ROS 2, with the maths | 16k | |
| Research | `qwen3:14b` | searches until it can cite an answer | 16k | web search on, native function calling (the model calls the search tool again and again) |
| Image | `qwen3:4b` | image generation | 8k | image generation on, thinking off |

Research would like 32k of context, but `qwen3:14b` (Q4, about 9 GB) plus a 32k cache does not
fit 12 GB even at q8_0, and a model that spills to the CPU slows to a few words a second; 16k
with the q8_0 cache stays on the GPU. To add a model: append it to `ollama_models`
(`<model>:<tag>`, sized for 12 GB) and release. To add or change a preset: edit `PRESETS`
(id, name, base, description, num_ctx, temperature, system, optional `function_calling` and
`features`), and release. Avoid `$` in prompts (Compose would read it as a variable).

**Hardening.** Every container runs as the `ai` account (`ai_uid:ai_gid` in `production.yml`,
`2001:2001`, created by `roles/host` with no login), never root, with `cap_drop: [ALL]`,
`no-new-privileges` and a `mem_limit`; the compose guard refuses the stack otherwise, and
allows the GPU only to `ollama` and `comfyui` (and Jellyfin in `media`). The three volumes are
created by provisioning with their root owned by that account (0700) and mounted with
`nocopy`, so Docker never copies an image's root-owned directory over them. `ollama`,
`ollama-pull`, `searxng`, `comfyui` and `comfyui-fetch` also run with a read-only root
filesystem (a tmpfs `/tmp`). `open-webui` and `webui-presets` do not: the Python app writes a
few files into its own tree at start, which as a non-root user already fails harmlessly for
anything root owns, and a read-only root would add little. Only `open-webui` publishes a port;
`searxng` and `comfyui` (which has no login) are reachable from the `ai` network alone.

**hypernova.** The provider reaches Ollama on `llm` (`OLLAMA_HOST=http://ollama:11434`,
`OLLAMA_MODEL` = `hypernova_ollama_model`, which must be in `ollama_models`;
`AI_DISABLED=false` in `provider.env`). `prizm-web` is not on `llm`; the guard refuses it there.

**Sharing the GPU.** The RTX 2060 has 12 GB of VRAM, shared by Ollama, ComfyUI and Jellyfin's
transcodes (a few hundred MB each). Ollama keeps **one** model loaded
(`OLLAMA_MAX_LOADED_MODELS=1`, one request at a time) and unloads it after **2 minutes** idle
(`OLLAMA_KEEP_ALIVE=2m`), with flash attention and a q8_0 KV cache, so a 14B model and its 16k
context take about 11 GB. ComfyUI loads Stable Diffusion XL (about 7 GB) for each image and
frees RAM and VRAM right after (`--cache-none --disable-smart-memory`). The trade-offs: the
first message after 2 idle minutes waits a few seconds while the model loads again, and each
image takes 10–20 s longer to load the checkpoint. The **Image** preset runs on the 4B model
(about 4 GB), so the checkpoint fits next to it; turning image generation on in a chat with a
14B model squeezes ComfyUI into what is left, which is slow or fails. Switching between
presets on different base models (Quick and MCU Coder, say) swaps the model in VRAM, a few
seconds each time.

**Memory.** `mem_limit`: `ollama` 8 GiB (the model sits in VRAM; RAM covers the runner and
what does not fit), `comfyui` 8 GiB (it stages the 7 GB checkpoint in RAM while loading it,
then frees it), `open-webui` 2 GiB (its embedding model runs on the CPU), `webui-presets`
512 MiB, `searxng` 384 MiB, `comfyui-fetch` 256 MiB, `ollama-pull` 128 MiB. The limits add up
to more than the host's 16 GB on purpose: they cap each container, and the large two peak only
while loading a model.

**Updates.** The images are pinned `<tag>@sha256:<digest>` and carry no Watchtower label, on
purpose: Open WebUI migrates its database on start, Ollama changes its model format now and
then, ComfyUI and SearXNG change often, and none should change unattended. Move them with a
re-pin and a release ([agents.md](agents.md#re-pinning-third-party-images)); `autoheal`
restarts any of them that turns unhealthy. A new Open WebUI version can rename what
`webui-presets` imports: `docker logs webui-presets` after the release shows it.

**GPU.** `ollama` and `comfyui` reserve the GPU (`deploy.resources.reservations.devices`,
driver `nvidia`, `count: all`, `capabilities: [gpu]`). `gpu_enabled: false` makes the release
refuse to render, since the stack could not start.

## media

Jellyfin (films and series), Audiobookshelf (audiobooks and podcasts) and Kavita (books), the
Beszel status dashboard, Garage (S3 storage) with SFTPGo as its file manager, for the owner
alone, and `home`, a links page
(`http://infra-host/`) with a tile for each of them and Open WebUI (six tiles, two by three),
with `home-tls` in front of it for `https://home.arbikullakshi.com/` (and the file manager's
WebDAV at `/dav`). Like `ai`, nothing here is
public: no `edge`, no label for the edge Traefik, never behind the tunnel. Serving video through Cloudflare's tunnel is against Cloudflare's terms anyway, and
the tailnet is faster: a phone or TV on Tailscale talks to the server directly (or through a
relay when it must), WireGuard-encrypted.

| Container | Port, on the Tailscale address only | Library (bind mount) | Its data (volume, SSD) |
| --- | --- | --- | --- |
| `jellyfin` | 8096 | `/srv/media/shows` → `/media/shows`, `/srv/media/movies` → `/media/movies`, read-only | `jellyfin-config` (`/config`), `jellyfin-cache` (`/cache`, with the transcodes) |
| `audiobookshelf` | 13378 (`PORT=13378`) | `/srv/media/audiobooks` → `/audiobooks`, `/srv/media/podcasts` → `/podcasts`, read-write | `audiobookshelf-config`, `audiobookshelf-metadata` |
| `kavita` | 5000 | `/srv/media/books` → `/books`, read-only | `kavita-config` (`/kavita/config`) |
| `home` | 80 | none | none (the links page is `HOME_HTML` in the compose file, written to tmpfs and served by busybox `httpd`) |
| `home-tls` | 443 | none | `home-tls-acme` (`/acme`: the Let's Encrypt account and certificate) |
| `beszel` | 8090 | none | `beszel-data` (`/beszel_data`: the hub's database, history, alerts) |
| `beszel-pair` | none (one-shot) | none | writes the hub's public key into `beszel-agent-data` |
| `beszel-agent` | none | `/srv/media/.beszel` → `/extra-filesystems/media` and `/srv/backup` → `/extra-filesystems/backup`, read-only, for the disks' sizes only | `beszel-agent-data` (`/var/lib/beszel-agent`: its fingerprint, the hub's key) |
| `garage-config` | none (one-shot) | none | writes `garage.toml` into `garage-meta` |
| `garage` | 3900 (S3; admin 3903 and RPC 3901 on the `media` network only) | `/srv/media/s3` → `/data`, read-write (the objects) | `garage-meta` (`/meta`: the config and the SQLite metadata) |
| `garage-setup` | none (one-shot) | none | none (Garage's admin API) |
| `sftpgo` | 8091 (web client; WebDAV on 8092, `media` network only, through `home-tls` at `/dav`) | none (its files are the `files` bucket, over S3) | `sftpgo-data` (`/var/lib/sftpgo`: its SQLite database, share links) |

**`beszel`, `beszel-pair`, `beszel-agent`** (Beszel 0.21). The hub creates the owner's login on
its first start from `BESZEL_HUB_USER_EMAIL` (`status_owner_email`, `media/.env`) and
`BESZEL_HUB_USER_PASSWORD` (`beszel.env`, the `BESZEL_PASSWORD` secret), so there is no sign-up
page. After it is healthy, `beszel-pair` (curl) signs in as the owner, makes
`BESZEL_AGENT_TOKEN` the owner's permanent *universal token* and writes the hub's ed25519 public
key into the agent's volume; the agent starts only after that (`service_completed_successfully`),
dials `http://beszel:8090` with the token, checks the hub with the key (`KEY_FILE`) and is added
as the system `infra-host` on its first connection, then recognised by its fingerprint. The agent
uses the `beszel-agent-nvidia` image and the GPU reservation for NVML (the GPU's use, memory and
power), reads CPU, memory and temperatures from the host's `/proc` and `/sys`, the SSD from its
own root, and the media and backup disks through two bind mounts that show it nothing (an empty
root-owned folder, and the backup disk's root-only mountpoint). Container stats come through
`beszel-socket-proxy` (`roles/beszel`, on the internal `beszel-socket` network, the only other
network the agent joins): `GET` version, info, the container list and one container's stats,
nothing else, so the dashboard's container details and logs stay empty (inspect would show
every container's environment, secrets included). No host network, so no host network totals;
no SSH listener (`DISABLE_SSH`); no image update checks; no update checks in the hub.

**`garage-config`, `garage`, `garage-setup`** (Garage 2.4). Garage's image has no shell, so
`garage-config` (busybox) writes its configuration (`GARAGE_TOML` in the compose file: one
node, `replication_factor = 1`, SQLite metadata in `/meta/db`, S3 on 3900 with region
`garage`) into `garage-meta` before it starts; the RPC secret and admin token come from
`garage.env` as environment variables, never into a file. After Garage is healthy (`garage
status`), `garage-setup` (curl) uses the admin API: it assigns the node its layout role once,
imports the owner's key (`GARAGE_OWNER_ACCESS_KEY_ID` and `_SECRET_KEY`, `garage-setup.env`;
Garage never reuses a deleted key ID, so a new secret needs a new ID, and keys named `owner`
under another ID are deleted), creates the buckets in `GARAGE_BUCKETS` (`files`) and grants the
key read, write and owner on them. It prints no secret and fails the release
(`check_one_shots`) when anything is refused. The objects are on the media disk, the metadata on
the SSD (Garage recommends fast storage for it). Garage's own community web UI is not used (no
release in a year, and it would need the full admin token); `sftpgo` is the interface.

**`sftpgo`** (SFTPGo 2.7, the `-alpine` image) is the file manager on the `files` bucket: its
web client (`http://infra-host:8091/web/client`, the Files tile) uploads by drag and drop, makes
folders, renames, moves, deletes, previews, downloads and makes share links, and its WebDAV
server (8092, on the `media` network only) is published at `https://home.arbikullakshi.com/dav`
by `home-tls`, with the real certificate, so a laptop or phone mounts the bucket as a drive. Its
one user, `owner`, is code: at every start `OWNER_JSON_SH` (compose file) writes it to tmpfs and
SFTPGo loads it with `LOADDATA_MODE=0` (added, or updated to match), with the password from
`FILES_PASSWORD` and an S3 filesystem (`http://garage:3900`, region `garage`, bucket `files`,
path-style) with the owner's key (`sftpgo.env`). SFTPGo sends every sign-in to its admin setup
page until an admin exists, so the same file adds one with a fresh random password at each
start; the admin web UI and the REST API are off, so nobody can use it. SFTP and FTP are off. It
starts after `garage-setup` has created the bucket and imported the key.

**`home-tls`** is a second Traefik (the edge image and digest) that terminates TLS for
`home.arbikullakshi.com` and proxies to `home:80` over the `media` network. The apex sends HSTS
with `includeSubDomains`, so browsers only open `home.` over https. It has no Docker socket: its
static and dynamic configuration are `HOME_TLS_STATIC` and `HOME_TLS_DYNAMIC` in the compose file,
written to tmpfs at start. The certificate comes from Let's Encrypt by DNS-01 through
Cloudflare's API with `CF_DNS_API_TOKEN` from `home-tls.env` (the `HOME_TLS_CF_DNS_TOKEN`
secret, Zone Read and DNS Edit on the zone only), the stack's one secret, which no other
container reads; nothing on the internet has to reach the host. Port 443 needs no capability
(Docker lets any user bind low ports inside the container's network namespace), so it runs as
the media account like the rest. `infra-apply` verify asks `https://home.arbikullakshi.com/`
pinned to the Tailscale address and requires a trusted certificate.

**The library** is on the internal 1 TB HDD at `/srv/media` ([host.md](host.md#disks)); the
apps' own databases, artwork and caches are in volumes on the SSD. Each container mounts only
its own folders, at fixed paths, `bind.create_host_path: false`, and the compose guard allows
no other bind mount in any stack: not `/srv/media` as a whole, not a folder at another path,
not read-write where it says read-only. Audiobookshelf writes because it downloads podcast
episodes and may store covers next to the books. With the media disk missing the folders do
not exist (the mountpoint stays empty and immutable), so the containers fail to start instead
of serving, or scanning away, an empty library; Docker also starts only after the disk's mount
unit at boot.

**Hardening.** Every container runs as the `media` account (`media_uid:media_gid`,
`2000:2000`), which owns the library folders; `cap_drop: [ALL]`, `no-new-privileges`, a
`mem_limit`; the guard refuses the stack otherwise. Jellyfin and Audiobookshelf run with a
read-only root filesystem and a tmpfs `/tmp`. Kavita does not: its entrypoint copies a default
`appsettings.json` from the image's `/tmp/config` on first start, which a tmpfs `/tmp` would
hide; as a non-root user it cannot write anything root owns in the image anyway. Each secret is in
its own env file, read by its one container (`home-tls.env`, `beszel.env`, `beszel-pair.env`,
`beszel-agent.env`, `garage.env`, `garage-setup.env`, `sftpgo.env`); `media/.env` holds only the uid and gid,
the links page's name and ACME contact and the dashboard's login name.

**GPU.** Jellyfin reserves the GPU like Ollama for NVENC/NVDEC transcodes, and `beszel-agent`
for reading the GPU's state through NVML (the guard allows exactly `ollama`, `comfyui`,
`jellyfin` and `beszel-agent`); turn it on in Jellyfin's **Dashboard → Playback → Transcoding**
([RUNBOOK.md](../RUNBOOK.md#first-logins)). The 12 GB are shared with Ollama
([ai](#ai)): a transcode takes a few hundred MB, so a 7B model and two or three streams fit
together. Consumer drivers allow a handful of concurrent NVENC sessions, plenty for one home.

**Memory.** `jellyfin` 3 GiB (ffmpeg runs inside it), `audiobookshelf` 1 GiB, `kavita` 1 GiB, `garage` 512 MiB,
`sftpgo` 256 MiB, `beszel` 192 MiB, `beszel-agent` 128 MiB, `home-tls` 128 MiB, `home` 32 MiB, the one-shots 16–32 MiB.
With `ollama` at 8 GiB and the rest, the stacks fit a 16 GB machine with the swap file as a
buffer; give Ollama less if the server has less RAM.

**Updates and backups.** Pinned images, no Watchtower label, as in `ai`: Jellyfin migrates its
database irreversibly on a major upgrade. Re-pin, read the release notes, make sure last
night's backup ran, then release. The nightly backup copies each app's volumes (not
Jellyfin's cache; Beszel's history and Garage's metadata included, with both stopped) and
mirrors `audiobooks`, `books`, `podcasts` and Garage's `s3` (while Garage is stopped, so the
objects match that night's metadata); films and series are not
copied (they would not fit, and can be re-ripped) ([operations.md](operations.md#backups)).
