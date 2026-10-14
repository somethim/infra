# Runbook

The owner's steps for the one Hetzner host: moving the live server to the provision/release
model, cleaning up crm, and operating releases afterwards. [`README.md`](README.md) and
[`docs/`](docs/README.md) explain how the pieces work; this file only says what to do, in
order. Every step that needs your accounts or your hands is marked **Owner action**.

Plan for one quiet hour for sections 6 and 7. The sites are down for about a minute twice:
once if the first provision upgrades Docker (6.1), and once when the first release recreates
the app containers (6.6).

The values below are the ones in [`production.yml`](production.yml): the tailnet name
`infra-host`, the tags `tag:infra-server` and `tag:infra-ci`, the accounts `admin` and
`deploy` ([`roles/common/defaults/main.yml`](roles/common/defaults/main.yml)). If you change
one, change that file first (through `master`) and use your value throughout.

## 1. What you need

**Owner action.**

- Admin access to the Tailscale tailnet, and your own machine on it with MagicDNS on, so
  `infra-host` resolves.
- The Hetzner Cloud console for the server, with the **root password tested in its web
  console**. That console does not go through sshd or the tailnet; it is the backstop for
  every lockout below.
- On your machine: `gh` (logged in to `somethim/infra`), `ansible-core`, `ssh-keygen`,
  `ssh-keyscan`, `nc`, and a checkout of `master`.
- Your own SSH public key in `/root/.ssh/authorized_keys` on the server **as a plain line**
  (`ssh-ed25519 AAAA… you@machine`, no `command=` or other options, installed with
  `ssh-copy-id`). The first provision copies root's keys to `admin` once, and refuses to run
  while any line there has options or is the CI deploy key.
- The Deploy workflow logs in as `deploy`. Leave the `SERVER_USER` variable unset (or set it to
  `deploy`); the workflow refuses `root` and `admin`. `SERVER_SSH_HOST` is set in 6.3.

## 2. Confirm the host's facts

**Owner action**, in the Hetzner web console (not over SSH, so the host key you write down is
the one the server really has):

| Command | Expect |
| --- | --- |
| `lsb_release -cs` | the same as `ubuntu_release` in `production.yml` (`noble` today) |
| `docker version --format '{{.Server.Version}}'` | the major (the number before the first dot) equal to `docker_engine_major` (`29` today) |
| `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` | `256 SHA256:… root@… (ED25519)`: **write the `SHA256:` fingerprint down** |
| `docker volume ls` | lists `pgdata-v18`, `portfolio-media`, `hypernova_prizm-storage` and `edge_edge-acme` |
| `docker inspect postgresql --format '{{range .Mounts}}{{.Name}} {{end}}'` | `pgdata-v18` |

If the release or the major differ, edit `production.yml` (through `master`) before anything
else: provisioning stops with "Confirm the host's facts" when they do not match, and the
Docker apt pin (written before the first `apt upgrade`) would otherwise move the Engine to
another major. If a volume is missing, stop
here and find out why before any release: the release uses these exact names and would
otherwise start an app on an empty volume.

## 3. New CI deploy key

**Owner action.** The release path has its own key, used only by the Deploy workflow and only
for the `deploy` user. Make it on your machine:

```bash
ssh-keygen -t ed25519 -N '' -C infra-deploy -f ~/.ssh/infra-deploy
```

Replace the contents of [`roles/common/files/deploy_key.pub`](roles/common/files/deploy_key.pub)
(today the placeholder `REPLACE_ME_BEFORE_DEPLOYING`) with the one line of
`~/.ssh/infra-deploy.pub`, commit it and merge it to `master`. Provisioning and the release
render both refuse to run while the placeholder is there. Then store the private half:

```bash
gh secret set SSH_PRIVATE_KEY --env production < ~/.ssh/infra-deploy
```

(Create the Environment first if `gh` says it does not exist, step 5.) Provisioning installs
the public half for `deploy` only, as one root-owned line
`restrict,command="/usr/local/sbin/infra-deploy-gate" ssh-ed25519 AAAA… infra-deploy`, and
checks that neither root nor `admin` trusts it. The old CI key, which root trusts today, is
`legacy_ci_deploy_key` in `production.yml`; the first provision removes it from root.

## 4. Tailscale

**Owner action**, in the Tailscale admin console.

1. **Access controls**: merge into the policy, and give nothing else access to
   `tag:infra-server`:

   ```json
   {
     "tagOwners": {
       "tag:infra-server": ["autogroup:admin"],
       "tag:infra-ci": ["autogroup:admin"]
     },
     "grants": [
       {"src": ["autogroup:admin"], "dst": ["tag:infra-server"], "ip": ["tcp:22"]},
       {"src": ["tag:infra-ci"], "dst": ["tag:infra-server"], "ip": ["tcp:22"]}
     ]
   }
   ```

2. **Settings → Keys → Generate auth key**: one-off (not reusable), **pre-approved**, not
   ephemeral, tag `tag:infra-server`, expiry 1 day. Keep it for 6.1; the first provision asks
   for it without showing or storing it.
3. **Settings → OAuth clients → Generate OAuth client**: scope **Auth Keys: write**, tag
   `tag:infra-ci` only. The client ID is a variable, the secret a secret:

   ```bash
   gh variable set TS_OAUTH_CLIENT_ID --env production --body '<client id>'
   gh secret set TS_OAUTH_SECRET --env production
   ```

   The Deploy workflow joins the tailnet with them for each run as an ephemeral
   `tag:infra-ci` node.

Provisioning joins the server as `infra-host` with `--ssh=false --accept-dns=false
--accept-routes=false` (OpenSSH stays the login), and on every run checks that it is on the
tailnet as `infra-host` with exactly `tag:infra-server`. A stop there with "Check the auth
key's tag and the policy's tagOwners" means the key was made without the tag, or the policy
does not let you own it.

## 5. The production Environment

**Owner action**, on GitHub (`somethim/infra` → Settings → Environments).

1. Create the Environment `production`. Optionally restrict it to the `master` branch and add
   yourself as a required reviewer; the workflow refuses any other branch either way.
2. Set every secret and variable in [docs/deploying.md](docs/deploying.md#secrets-and-variables).
   Secrets go in with `gh secret set <NAME> --env production` (it reads the value from the
   prompt or stdin); variables with `gh variable set <NAME> --env production --body <value>`.
   `SSH_KNOWN_HOSTS` and `SERVER_SSH_HOST` come from 6.3.
3. Check the values you carry over from the old repository secrets (GitHub never shows a
   stored value: take them from your password manager, or make new ones) against the formats
   the release render asserts, on the runner, before anything reaches the host:
   - `POSTGRES_SUPERUSER_PASSWORD`, `PRIZM_DB_PASSWORD`, `PORTFOLIO_DB_PASSWORD`: at least 32
     letters and digits only (`[A-Za-z0-9]{32,}`), and all three different. Rotate any that is
     not (`openssl rand -hex 24`): the first release re-sets each role's password and renders
     the matching DSN in the same run, so the new value takes effect everywhere at once.
   - `PORTFOLIO_TOTP_ENCRYPTION_KEY`: base64 of exactly 32 bytes (44 characters ending in `=`).
     Carry the existing value over unchanged; a new one makes every enrolled TOTP secret
     unreadable.
   - No value may hold `$`, `"`, `'`, `` ` ``, `\`, `#`, a line break, or a leading or trailing
     space, which the Compose env file would rewrite. Pick a new value for any that does.
     `PORTFOLIO_ADMIN_PASSWORD` is only used when the operator account does not exist yet;
     storing a new value never changes an existing account, so change the password in the
     portfolio's `/admin` as well.

A missing or malformed value stops the release with "Missing or invalid deploy secrets" or
"`<name>` holds a $, quote, …" (both cite "Rotating a secret").

## 6. Cut-over

The order is lockout-safe: public SSH stays open until a provisioning run has come in over the
tailnet, root login stays open (keys only) until `admin` is proven, and the Hetzner Cloud
Firewall rule goes last. **Do not run Deploy before 6.6**: the old workflow that ran the
playbook as root is gone from `master`, and the new one cannot reach the host until 6.3.

### 6.1 First provision, as root over the public address

**Owner action.** Host keys are checked (`ansible.cfg`), so first trust the server's key under
its public IPv4, compared against the fingerprint from step 2:

```bash
ssh-keyscan -t ed25519 <IPv4> | ssh-keygen -lf -     # must print step 2's SHA256: fingerprint
ssh-keygen -F <IPv4> || ssh-keyscan -t ed25519 <IPv4> >> ~/.ssh/known_hosts
```

The play targets the inventory group `server`, and provisioning requires exactly one host in
it, so an inline `-i '<IPv4>,'` inventory does not work. Point the inventory at the public
address for this run only:

```bash
cp inventory/hosts.example inventory/hosts
# edit inventory/hosts: under [server], set   infra-host ansible_host=<IPv4>
ansible-playbook -u root provision.yml
```

Enter the Tailscale auth key from step 4 at the prompt (`Tailscale auth key for infra-host`).
Expect, in this order (the order of `provision.yml`): the checks pass; ufw admits 22 on
`tailscale0`, 80 and 443, **and still 22 on the public address**; the retired CI key is removed
from root's `authorized_keys`; `admin` is created with your keys (copied once from root) and
sudo that asks for a password; `deploy` is created with the forced command and the release
scripts; fail2ban, patching and the journald cap are set; the server joins the tailnet; Docker
comes from the pinned apt repository (the pin is written before the first `apt upgrade`, so the
Engine stays on `docker_engine_major`; an update within that major restarts every container once);
`/etc/infra/host.env`, the `INFRA-PUBLIC` firewall chain and swap are in place; Traefik,
Watchtower and autoheal are replaced by the pinned, socket-proxied ones (same project names,
same `edge_edge-acme` certificates); last, password and keyboard-interactive login are off and
root login is `prohibit-password` (keys only). The run ends with:

```
Root can still log in with a key until provisioning runs as admin.
Set the admin sudo password over the tailnet first: ssh -t root@infra-host passwd admin
Then set ansible_host=infra-host in inventory/hosts and run: ansible-playbook -u admin --ask-become-pass provision.yml (RUNBOOK.md, "Cut-over").
This run reached infra-host on its public address, so ufw keeps 22/tcp open there. ...
```

The app stacks and crm keep running untouched. A stop at "Root's authorized_keys … must hold
only your own public keys" means a line there has options or is the new CI key: fix the file
as root and run again.

### 6.2 Set the admin sudo password, over the tailnet

**Owner action.** This proves the tailnet path and your key before anything closes. The first
connection to `infra-host` shows its key fingerprint: answer `yes` only if it equals step 2's.

```bash
ssh -t root@infra-host passwd admin
```

Keep the password in your password manager; every later provision asks for it
(`--ask-become-pass`). The admin run in 6.4 refuses to start closing root login until this
password is set.

### 6.3 Record the host key

**Owner action.** The Deploy workflow checks the host key strictly, from the `SSH_KNOWN_HOSTS`
secret, under the tailnet name in `SERVER_SSH_HOST`:

```bash
ssh-keyscan -t ed25519 infra-host | ssh-keygen -lf -    # must print step 2's SHA256: fingerprint
ssh-keyscan -t ed25519 infra-host > /tmp/kh && gh secret set SSH_KNOWN_HOSTS --env production < /tmp/kh && cat /tmp/kh >> ~/.ssh/known_hosts && rm /tmp/kh
gh variable set SERVER_SSH_HOST --env production --body infra-host
ssh admin@infra-host true                               # exits 0, no prompt
```

The secret's line must start with `infra-host`, the name `SERVER_SSH_HOST` holds; otherwise
the workflow stops with "SSH_KNOWN_HOSTS has no key for infra-host". If the server is ever
rebuilt, it gets a new host key: repeat step 2's fingerprint and this section.

### 6.4 Second provision, as admin over the tailnet

**Owner action.** Point the inventory back at the tailnet name and run as `admin`:

```bash
cp inventory/hosts.example inventory/hosts      # [server] infra-host ansible_host=infra-host
ansible-playbook -u admin --ask-become-pass provision.yml
```

Expect: "Close SSH on the public address once runs come in over the tailnet" reports
`changed` (ufw's public 22 rule is deleted), sshd applies `PermitRootLogin no`, a cloud
image's `ubuntu` account and `/etc/sudoers.d/90-cloud-init-users` are removed if present, and
no "public address" message at the end. Every later provision runs exactly like this.

### 6.5 Close SSH on the public address

**Owner action.** From your machine:

```bash
nc -z -w 5 <IPv4> 22                 # times out (exit 1)
ssh admin@infra-host sudo ufw status  # Status: active; 22/tcp on tailscale0, 80/tcp, 443/tcp
```

If a Hetzner Cloud Firewall is attached to the server, delete its tcp 22 rule now, last. The
web console still takes root's password if the tailnet is ever unreachable (section 10).

### 6.6 First release

**Owner action.** GitHub → **Actions → Deploy → Run workflow**, "Use workflow from" `master`,
action `release`, every other input at its default. Expect in the "Release on the server" step:

```
infra-apply: compose model accepted: 1 service(s) in the database stack, ...
infra-apply: compose model accepted: 1 service(s) in the portfolio stack, ...
infra-apply: compose model accepted: 2 service(s) in the hypernova stack, ...
infra-apply: bundle accepted: 12 files, manifest checksums match
infra-apply: pulling images
infra-apply: starting the database
infra-apply: database roles, passwords and grants are in place
infra-apply: starting portfolio
infra-apply: starting hypernova
infra-apply: every container is running and healthy
infra-apply: Traefik routes arbikullakshi.com/ www.arbikullakshi.com/ hypernova.arbikullakshi.com/ hypernova.arbikullakshi.com/api/ and keeps them behind the cloudflare-only allowlist
infra-apply: Traefik, Watchtower and autoheal reach Docker through their socket proxies with no refused calls
infra-apply: RELEASE OK: <id> is current, following :latest, auto-updates on
```

and a green smoke step through Cloudflare (`OK 200 …` for `https://arbikullakshi.com/api/health`,
`https://hypernova.arbikullakshi.com/` and its `/api/health`, `OK 301 …` for `www.`, and, when
`SERVER_HOST` is set, `OK the origin refuses direct requests (403)`).
`postgresql`, `portfolio`, `prizm-provider` and `prizm-web` are recreated in place (same names,
same volumes) from the release in `/opt/infra/releases/<id>`, which `/opt/infra/current`
points at. The portfolio can take up to 180 s to report healthy.

### 6.7 Remove the old stack directories

**Owner action.** Check that the apps now run from the release directory:

```bash
ssh admin@infra-host
sudo docker inspect portfolio --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'
```

It must start with `/opt/infra/` (portfolio and hypernova are started from
`/opt/infra/current/<stack>`, the database from `/opt/infra/releases/<id>/database`), not
`/opt/portfolio`. Then delete the old directories, whose `.env` files still hold every secret
in plain text:

```bash
sudo rm -rf /opt/database /opt/portfolio /opt/hypernova
```

Keep `/opt/edge`, `/opt/watchtower` and `/opt/autoheal` (provisioning owns them) and `/opt/crm`
(section 7).

### 6.8 Delete the old secrets

**Owner action.** On `somethim/infra` → Settings → Secrets and variables → Actions, delete the
old **repository** secrets: every `CRM_*`, `SSH_PRIVATE_KEY` (the retired key), `SERVER_USER`,
`SERVER_HOST`, `GHCR_USERNAME`, `GHCR_TOKEN`, and the database and app secrets now in the
`production` Environment. `SERVER_HOST` is still read, as an optional Environment secret for
the smoke step's direct-origin check: set it there (`gh secret set SERVER_HOST --env
production`) if you want that check. In the Tailscale console, revoke the auth key from step 4
if it is still listed.

## 7. crm cleanup

One-shot, destructive, and only after 6.6 is green. It is a runbook step rather than a
playbook on purpose: it runs once, and you read each output before the next command. All
commands run as `admin` over the tailnet (`ssh admin@infra-host`), with `sudo`.

1. **Optional final dump.** The new desktop crm starts fresh, so this is insurance only:

   ```bash
   sudo docker exec postgresql pg_dump -U postgres -Fc crm > ~/crm-final.dump
   ```

   Copy it off the host (`scp admin@infra-host:crm-final.dump .`), then delete it there.
2. **Stop the stack**, keeping its volumes for now:

   ```bash
   cd /opt/crm && sudo docker compose down
   sudo docker ps -a --filter label=com.docker.compose.project=crm     # header line only
   ```

3. **Drop the database and the role:**

   ```bash
   sudo docker exec -i postgresql psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c 'DROP DATABASE IF EXISTS crm WITH (FORCE)'
   for db in postgres prizm portfolio; do
     sudo docker exec -i postgresql psql -v ON_ERROR_STOP=1 -U postgres -d "$db" -c 'REASSIGN OWNED BY crm TO postgres; DROP OWNED BY crm'
   done
   sudo docker exec -i postgresql psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c 'DROP ROLE IF EXISTS crm'
   sudo docker exec postgresql psql -U postgres -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='crm'"   # prints nothing
   ```

   Then open `https://arbikullakshi.com` and `https://hypernova.arbikullakshi.com`: both still
   answer.
4. **Volumes and network:**

   ```bash
   sudo docker volume ls --filter label=com.docker.compose.project=crm   # crm_crm-storage, crm_crm-typesense, crm_crm-redis
   sudo docker volume rm crm_crm-storage crm_crm-typesense crm_crm-redis
   sudo docker network rm crm            # "not found" is fine: compose down removed it
   sudo docker inspect postgresql --format '{{range .Mounts}}{{.Name}} {{end}}'   # must print pgdata-v18
   sudo docker volume rm crm-pgdata-v18  # only after the line above printed pgdata-v18; "no such volume" is fine
   ```

5. **Images and files:**

   ```bash
   sudo docker image ls --filter 'reference=ghcr.io/somethim/crm-*'
   sudo docker image rm ghcr.io/somethim/crm-provider:latest ghcr.io/somethim/crm-web:latest
   sudo docker image rm redis:7-alpine typesense/typesense:28.0   # refused if something still uses them; then keep them
   sudo rm -rf /opt/crm
   ```

6. **Done when** no crm container, volume, network, image, role or database remains:
   `sudo docker ps -a`, `sudo docker volume ls`, `sudo docker network ls` and
   `sudo docker image ls` show nothing crm, step 3's query prints nothing, and Traefik serves no
   crm router (the DNS records are already deleted). **Owner action.**

## 8. Releases, status, rollback, resume

All four are **Actions → Deploy → Run workflow** from `master`, with the `action` input. The
`portfolio`, `hypernova_provider`, `hypernova_web` and `dry_run` inputs apply only to
`rollback`; the workflow refuses them with any other action.

**`release`** renders the bundle on the runner from `master` and the Environment, streams it to
`deploy`, and brings every stack up on `:latest`. Run it when a secret, a stack file under
`stack/`, or `production.yml` changes, and after a provision that changed `/etc/infra/host.env`.
It is not needed for app updates: while an app follows `:latest`, Watchtower deploys a new
image within about a minute of it being pushed. The release path is described in
[docs/deploying.md](docs/deploying.md#what-infra-apply-checks-in-order).

**`status`** prints, with no change to the host (each line starts with `infra-apply: `):

```
current release: <id> (verified|not verified), <summary>
previous release: <id> (verified), <summary>        or  previous release: none
image <container> ref=<image> digest=<sha256:…|unknown> created=<time|unknown>
known <repository> digest=<sha256:…> created=<time>
recorded <id> <container>=<repository>@<sha256:…>
```

then one `docker compose ps` table per stack. `<summary>` is `following :latest, auto-updates
on` or `pinned (<keys>), auto-updates paused for them`. `image` is what each app container
runs now, `known` every version of that repository still on the host, and `recorded` the
digest each container ran when that release was verified (`/opt/infra/releases/<id>/running-images.env`).

**`rollback`** pins app images to digests. Per app, the input is:

| Input | Means |
| --- | --- |
| `previous` (default) | the first digest that differs from the running one: from the current release's `recorded` lines, then the previous release's, then the `known` images |
| `current` | the digest running now (freezes it) |
| `latest` | keep following `:latest` for this app |
| a 40-character commit sha | portfolio only: its `:<sha>` tag, by digest |
| `sha256:<64 hex>` | that digest, after checking GHCR has it |

Run it with `dry_run: true` first: it prints the status and the resolved pins (`RELEASE_MODE=pinned`
and one `PORTFOLIO_IMAGE=`, `PROVIDER_IMAGE=`, `WEB_IMAGE=` line each) and stops. All three
`latest` is refused (that is `resume`). A pinned image is `<repository>:latest@sha256:<digest>`,
which Watchtower cannot move, so auto-updates stay paused for the pinned apps until `resume`.
hypernova only publishes `:latest`, so its rollback needs a digest the host or a release has
seen; if none is known, pass one explicitly.

**`resume`** is a `release` again: every app back on `:latest`, auto-updates on. Run it once
the fix is published.

**When a release fails**, the output says where:

- "…; the running release is untouched": refused before any change (a bad bundle or
  compose model, a refused GHCR login, a failed pull).
- "FAILED: before the app stacks changed, …": the database did not come up healthy or
  `provision.sql` failed. The database runs the new definition, portfolio and hypernova the
  previous one, and `current` still names the previous release.
- "release `<id>` is installed but did not come up cleanly; run the Deploy workflow with action
  rollback … (the last verified release was `<id>`: `<summary>`)": the new release is `current`
  but not verified, and `previous` still names the last verified one. Read the failure line
  above it (which container was not healthy, which route answered what), fix forward with a
  new `release`, or `rollback`.

## 9. Rotating a secret

Change it in the `production` Environment, then run `release`. That is the whole procedure for
most values:

- **Database passwords**: `provision.sql` re-sets each role's password in the same release
  that renders the new DSN, so the two cannot drift. `POSTGRES_SUPERUSER_PASSWORD` is re-set
  the same way. Generate with `openssl rand -hex 24`.
- **`PORTFOLIO_ADMIN_PASSWORD`** is used only when the portfolio's operator account does not
  exist yet; changing it does not change an existing account. Change that password in
  `/admin`, then store the same value here.
- **`PORTFOLIO_TOTP_ENCRYPTION_KEY`**: never rotate it casually. A new key makes every enrolled
  TOTP secret permanently unreadable; re-enrolment is the only recovery.
- **`GHCR_TOKEN`**: a release logs in again, which also refreshes the credentials Watchtower
  reads from `/root/.docker`.
- **`SSH_PRIVATE_KEY`** (the CI deploy key): make a new pair as in step 3, commit the public
  half, provision (it replaces `deploy`'s one line), then set the secret.
- **`TS_OAUTH_SECRET`**: generate a new OAuth client as in step 4 and replace both values.

Every value must pass the formats in [docs/deploying.md](docs/deploying.md#secrets-and-variables);
the render on the runner refuses one that does not, before the host is touched.

## 10. Locked out

The way in that does not depend on sshd, keys or the tailnet is the **Hetzner Cloud web
console**, logging in as root with the root password. From there:

- **The tailnet is down or the server left it**: `tailscale status`. If it is logged out,
  `tailscale up --auth-key=<new one-off key, tag:infra-server> --hostname=infra-host
  --advertise-tags=tag:infra-server --ssh=false --accept-dns=false --accept-routes=false`
  (make the key as in step 4).
- **fail2ban banned you** (only possible from outside the tailnet; the tailnet range is
  ignored): `fail2ban-client set sshd unbanip <your IP>`.
- **sshd refuses logins or will not start**: check
  `/etc/ssh/sshd_config.d/10-hardening.conf` and `sshd -t`. Provisioning validates the file with
  `sshd -t` before installing it and reloads (never restarts) sshd, so a provision should not
  cause this; another drop-in in `/etc/ssh/sshd_config.d/` that overrides it would (provisioning
  stops with "Locked out" when `sshd -T` does not apply its policy).
- **You need public SSH for one run**: `ufw allow 22/tcp` in the console, run provisioning over
  the public address as in 6.1 but as `admin`, then once more over the tailnet, which deletes
  the rule again.

## 11. Re-pinning third-party images

Every non-app image is pinned `<image>:<tag>@sha256:<digest>`, one version per repository
across `stack/` and `roles/*/files/`, and the bundle build refuses anything else. To move one
(a Watchtower that the Engine calls "too old", a Traefik or PostgreSQL patch release), follow
[docs/agents.md](docs/agents.md#re-pinning-third-party-images), then provision with that
role's tag, or run `release` for `postgres` (a minor version only; a major is a dump and
restore, [docs/database.md](docs/database.md#upgrades)).

### Optional Authenticated Origin Pulls

Off by default. With it on, Traefik refuses any TLS client without Cloudflare's origin-pull
certificate, so the origin answers nothing but Cloudflare.

1. **Owner action**: enable Authenticated Origin Pulls in the Cloudflare dashboard (SSL/TLS →
   Origin Server) first, and download Cloudflare's origin-pull CA as `origin-pull-ca.pem`.
   Turning it on at the origin first would cut off Cloudflare.
2. Provision the host role (it writes `ORIGIN_PULL=1` to `/etc/infra/host.env`, which the
   release's route check reads) and the edge role together:

   ```bash
   ansible-playbook -u admin --ask-become-pass provision.yml --tags host,edge \
     -e edge_origin_pull_enabled=true -e "edge_origin_pull_ca=$(cat origin-pull-ca.pem)"
   ```

3. Run `release`. Its route check on the host now accepts the TLS refusal (curl gets no
   client certificate) and says "origin pull on: route presence not proven locally for …";
   the smoke step proves the routes through Cloudflare, and its direct-origin check accepts
   "does not answer direct requests".

The setting lives only in those `-e` flags. A later provision without them turns it off again
(the sites keep working); pass the same flags on every provision while it should stay on.
