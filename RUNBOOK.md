# Runbook

The owner's steps for the one production server: a dedicated PC at home, on the home LAN
behind a consumer router, with a dynamic public IP. Nothing on it is reachable from the
internet. The public reaches the sites only through a **Cloudflare Tunnel** that the server
dials out to; SSH works only over **Tailscale**. [`README.md`](README.md) and
[`docs/`](docs/README.md) explain how the pieces work; this file only says what to do, in
order. Every step that needs your accounts or your hands is marked **Owner action**.

The server starts empty: there is no data to carry over. The first release creates the
database and the app volumes empty, and the apps initialise them.

The values below are the ones in [`production.yml`](production.yml) and
[`roles/common/defaults/main.yml`](roles/common/defaults/main.yml): the tailnet name
`infra-host`, the tags `tag:infra-server` and `tag:infra-ci`, the accounts `admin` and
`deploy`, the domains `arbikullakshi.com`, `www.arbikullakshi.com` and
`hypernova.arbikullakshi.com`. If you change one, change that file first (through `master`)
and use your value throughout. `192.168.1.50` stands for the server's LAN address and `setup`
for the account the Ubuntu installer creates; use yours.

| Section | Where you are |
| --- | --- |
| [1. What you need](#1-what-you-need) | anywhere |
| [2. BIOS](#2-bios) | at the server, keyboard and monitor |
| [3. Install Ubuntu Server](#3-install-ubuntu-server) | at the server |
| [4. Tailscale](#4-tailscale) | Tailscale admin console |
| [5. First provision over the LAN](#5-first-provision-over-the-lan) | your laptop, on the home LAN |
| [6. Cloudflare Tunnel](#6-cloudflare-tunnel) | Cloudflare (`cf` or the dashboard) |
| [7. The production Environment](#7-the-production-environment) | GitHub (`gh`) |
| [8. Second provision over the tailnet](#8-second-provision-over-the-tailnet) | your laptop |
| [9. First release](#9-first-release) | GitHub Actions |
| [10. DNS switch-over and decommissioning the old server](#10-dns-switch-over-and-decommissioning-the-old-server) | Cloudflare, then the Hetzner console |
| [11. Day-2 operations](#11-day-2-operations) | from then on |
| [12. GPU, AI and media](#12-gpu-ai-and-media) | the server, Tailscale, GitHub, your devices |

Restoring anything from the backup disk is in
[Restoring from the backup disk](#restoring-from-the-backup-disk) (section 11).

Tailscale (4) comes before the first provision (5) because that run joins the server to the
tailnet and asks for the auth key made in 4.

## 1. What you need

**Owner action.**

- The server: a dedicated PC with wired Ethernet to the router (Wi-Fi works but is not
  recommended for a server), a USB stick of at least 4 GB, and a keyboard and monitor. The
  keyboard and monitor are the backstop for every lockout below
  ([Locked out](#locked-out)): the local console goes through neither sshd nor the tailnet.
- Your laptop, on the same LAN for section 5, with: `ansible-core`, `ssh`, `ssh-copy-id`,
  `ssh-keygen`, `ssh-keyscan`, `nc`, `openssl`, `gh` (logged in to `somethim/infra`), `cf`
  (logged in to the Cloudflare account that holds `arbikullakshi.com`), and a checkout of
  `master`. The laptop must also be on the tailnet with MagicDNS on, so `infra-host`
  resolves.
- Admin access to the Tailscale tailnet, the Cloudflare account and the GitHub repository.
- The router's admin page, to give the server a fixed DHCP lease. The router forwards **no**
  port to the server; remove any forward that points at it.

## 2. BIOS

**Owner action**, at the server. Enter the firmware setup (usually `Del`, `F2` or `F10` at
power-on). Names differ per vendor:

1. **Restore on AC power loss** (also "AC Back", "After Power Failure", "Power On After
   Power Fail"): **Power On** (or **Last State**). The server then comes back by itself after
   a power cut; nothing else can switch it on remotely.
2. Boot order: the USB stick first for the install, the internal disk first afterwards.
3. Optional: turn off any "ErP"/"EuP" deep power-saving mode, which on some boards disables
   power-on after power loss; leave Secure Boot as it is (Ubuntu boots with it).

Provisioning makes sure the running system never sleeps (all sleep targets masked, lid and
sleep keys ignored, [docs/host.md](docs/host.md#power)); the firmware setting is the one part
it cannot do.

## 3. Install Ubuntu Server

**Owner action.**

1. On the laptop, download Ubuntu Server 26.04 LTS (amd64) from
   <https://ubuntu.com/download/server> together with its `SHA256SUMS`, check it, and write it
   to the USB stick (replace `/dev/sdX` with the stick, `lsblk` shows it; everything on it is
   erased):

   ```bash
   sha256sum --check --ignore-missing SHA256SUMS
   sudo dd if=ubuntu-26.04-live-server-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```

2. Boot the server from the stick and choose, in the installer:
   - **Type of install**: Ubuntu Server (not minimized).
   - **Network**: the wired interface on DHCP. Note its MAC address and the address it gets.
   - **Storage**: use the entire disk, with LVM. On the summary screen, edit `ubuntu-lv` and
     set its size to the maximum: the installer leaves most of a large disk unallocated
     otherwise.
   - **Profile**: your name; server name `infra-host`; username **`setup`** (anything but
     `admin`, `deploy` or `root`: provisioning creates `admin` and `deploy` itself and removes
     this account once `admin` works); a strong password, kept in your password manager until
     section 8.
   - **Ubuntu Pro**: skip.
   - **SSH**: **Install OpenSSH server**: yes. Allow password authentication over SSH: yes (it
     is only for `ssh-copy-id` in section 5; provisioning turns it off). Importing your key
     from GitHub here works too, and replaces the `ssh-copy-id` step.
   - **Featured server snaps**: none. In particular **not** `docker`: provisioning installs
     Docker from Docker's own apt repository, pinned.
3. Reboot, remove the stick, and log in at the console as `setup`. **Confirm the host's
   facts** `production.yml` relies on, and write the fingerprint down; you compare against it
   twice:

   | Command | Expect |
   | --- | --- |
   | `lsb_release -cs` | `resolute`, the `ubuntu_release` in `production.yml` |
   | `command -v docker` | nothing (no Docker yet); provisioning installs major `docker_engine_major` (`29`) |
   | `ip -4 -brief address` | the LAN address of the wired interface |
   | `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` | `256 SHA256:… root@infra-host (ED25519)`: **write the `SHA256:` fingerprint down** |

   If the release differs, edit `production.yml` (through `master`) before anything else:
   provisioning stops with "Confirm the host's facts" when it does not match.
4. In the router's admin page, give the server's MAC address a **fixed DHCP lease**
   (sometimes "address reservation" or "static lease") on the address it has now, so the
   address in section 5 stays valid. Reboot the server once and check `ip -4 -brief address`
   shows the same address.

## 4. Tailscale

**Owner action**, in the Tailscale admin console (<https://login.tailscale.com/admin>).

1. **Access controls**: merge these into the policy file, and give nothing else access to
   `tag:infra-server`. Admins (you) reach the server on tcp 22 and the tailnet-only ports
   (the links page 80 and 443, Open WebUI 8080, Jellyfin 8096, Audiobookshelf 13378, Kavita 5000,
   the Beszel status dashboard 8090, Garage's S3 API 3900, the SFTPGo file manager 8091, Immich 2283, [section 12](#12-gpu-ai-and-media)); the CI runners on tcp 22 only;
   OpenSSH, not Tailscale SSH, is the login:

   ```json
   {
     "tagOwners": {
       "tag:infra-server": ["autogroup:admin"],
       "tag:infra-ci": ["autogroup:admin"]
     },
     "grants": [
       {"src": ["autogroup:admin"], "dst": ["tag:infra-server"], "ip": ["tcp:22"]},
       {"src": ["autogroup:admin"], "dst": ["tag:infra-server"], "ip": ["tcp:80", "tcp:443", "tcp:2283", "tcp:3900", "tcp:8080", "tcp:8090", "tcp:8091", "tcp:8096", "tcp:13378", "tcp:5000"]},
       {"src": ["tag:infra-ci"], "dst": ["tag:infra-server"], "ip": ["tcp:22"]}
     ]
   }
   ```

   If the policy still has the default allow-all rule (`{"src": ["*"], "dst": ["*"], "ip":
   ["*"]}` in `grants`, or the older `acls` equivalent), narrow it so it does not cover
   `tag:infra-server`, or every device on the tailnet can reach the server.
2. **Settings → Keys → Generate auth key**: one-off (not reusable), **pre-approved**, not
   ephemeral, tag `tag:infra-server`, expiry 1 day. Keep it for section 5; the first
   provision asks for it without showing or storing it. A tagged node's key does not expire,
   so the server stays on the tailnet.
3. **Settings → OAuth clients → Generate OAuth client**: scope **Auth Keys: write**, tag
   `tag:infra-ci` only. Keep the client ID and secret for section 7. The Deploy workflow
   joins the tailnet with them, for each run, as an ephemeral `tag:infra-ci` node.

Provisioning joins the server as `infra-host` with `--ssh=false --accept-dns=false
--accept-routes=false`, and on every run checks that it is on the tailnet as `infra-host`
with exactly `tag:infra-server`. A stop there with "Check the auth key's tag and the
policy's tagOwners" means the key was made without the tag, or the policy does not let you
own it.

## 5. First provision over the LAN

**Owner action**, on your laptop, on the home LAN.

1. **The CI deploy key.** The release path has its own key, used only by the Deploy workflow
   and only for the `deploy` user. Its public half is already committed in
   [`roles/common/files/deploy_key.pub`](roles/common/files/deploy_key.pub) (`… infra-deploy`)
   and the private half is `~/.ssh/infra-deploy` on your laptop. If you no longer have that
   private key (or the file is still the placeholder), make a **new CI deploy key** and commit
   its public line to `master` before going on:

   ```bash
   ssh-keygen -t ed25519 -N '' -C infra-deploy -f ~/.ssh/infra-deploy
   cp ~/.ssh/infra-deploy.pub roles/common/files/deploy_key.pub   # then commit and merge to master
   ```

   Provisioning installs the public half for `deploy` only, as one root-owned line
   `restrict,command="/usr/local/sbin/infra-deploy-gate" ssh-ed25519 AAAA… infra-deploy`, and
   refuses to run if `setup` or `admin` trusts it.
2. **Trust the server's host key**, compared with the fingerprint from section 3:

   ```bash
   ssh-keyscan -t ed25519 192.168.1.50 | ssh-keygen -lf -     # must print section 3's SHA256: fingerprint
   ssh-keyscan -t ed25519 192.168.1.50 >> ~/.ssh/known_hosts
   ```

3. **Install your key** for `setup` (skip if the installer imported it from GitHub). Use your
   own key, as a plain line, never the CI deploy key:

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub setup@192.168.1.50
   ssh setup@192.168.1.50 true                                 # exits 0 without a password prompt
   ```

4. **Point the inventory at the LAN address** for this run only (the play needs exactly one
   host in `[server]`, so an inline `-i '192.168.1.50,'` does not work):

   ```bash
   cp inventory/hosts.example inventory/hosts
   sed -i 's/^infra-host ansible_host=.*/infra-host ansible_host=192.168.1.50/' inventory/hosts
   ansible-playbook -u setup --ask-become-pass provision.yml
   ```

   `BECOME password` is `setup`'s password. Enter the Tailscale auth key from section 4 at the
   prompt `Tailscale auth key for infra-host`.

Expect, in order: the checks pass (logged in as `setup`, Ubuntu `resolute`, no Docker yet);
packages are upgraded and `unattended-upgrades` and `chrony` installed; ufw admits 22 on
`tailscale0` **and still 22 on the LAN**, nothing else; `admin` is created with your keys
(copied once from `setup`) and sudo that asks for a password; `deploy` is created with the
forced command and the release scripts; fail2ban, patching, NTP and the journald cap are
set; the server joins the tailnet; Docker 29 comes from the pinned apt repository;
`/etc/infra/host.env`, the `INFRA-PUBLIC` firewall chain (no public port), swap, the sleep
masks, the `edge` and `data` networks and the empty `pgdata-v18` volume are in place;
Traefik (no published port), Watchtower and autoheal start; last, password and
keyboard-interactive login are turned off and root login stays off. The run ends with:

```
setup stays until the first run as admin removes it.
Set the admin sudo password: ssh -t setup@192.168.1.50 sudo passwd admin
Then set ansible_host=infra-host in inventory/hosts and run: ansible-playbook -u admin --ask-become-pass provision.yml (RUNBOOK.md, "Second provision over the tailnet").
This run did not reach infra-host over the tailnet, so ufw keeps 22/tcp open on the LAN. ...
```

5. **Set the admin sudo password** (it asks for `setup`'s password first, then the new one
   twice). Keep it in your password manager; every later provision asks for it:

   ```bash
   ssh -t setup@192.168.1.50 sudo passwd admin
   ```

6. **Record the host key under the tailnet name**, for your laptop and for the Deploy
   workflow (which checks it strictly from `SSH_KNOWN_HOSTS`):

   ```bash
   ssh-keyscan -t ed25519 infra-host | ssh-keygen -lf -       # must print section 3's SHA256: fingerprint
   ssh-keyscan -t ed25519 infra-host > /tmp/kh && cat /tmp/kh >> ~/.ssh/known_hosts
   ssh admin@infra-host true                                   # exits 0, no prompt: the tailnet path works
   ```

   Keep `/tmp/kh` for section 7. A stop at "setup's authorized_keys … must hold only your own
   public keys" means a line there has options or is the CI key: fix the file and run again.

## 6. Cloudflare Tunnel

**Owner action.** One remotely managed tunnel, named `infra-host`, carries all three
hostnames to Traefik. "Remotely managed" means its routes (Public Hostnames) live in
Cloudflare, and the server only needs the tunnel's token, which the release renders into
`tunnel/tunnel.env` for the `cloudflared` container. The tunnel must route:

| Public hostname | Service |
| --- | --- |
| `arbikullakshi.com` | `http://edge-traefik:80` |
| `www.arbikullakshi.com` | `http://edge-traefik:80` |
| `hypernova.arbikullakshi.com` | `http://edge-traefik:80` |

and nothing else (no catch-all other than the default `http_status:404`). Leave every origin
option at its default: Traefik routes by the original `Host` header, which cloudflared passes
through. The DNS records come in section 10, not here: the hostnames still point at the old
server until then.

With `cf`:

```bash
# 1. Create the remotely managed tunnel and store its token in 1Password; the token is never printed
#    (done 2026-10-15: tunnel "home-server", id 1dfdb06e-04a8-4a4b-942b-ede6c46015de)
OUT=$(cf tunnels create --name home-server --config-source cloudflare 2>/dev/null)
TUNNEL_ID=$(jq -r '.id' <<<"$OUT"); TUNNEL_TOKEN=$(jq -r '.token' <<<"$OUT"); unset OUT
op item create --category password --vault "Home Server" --title "Cloudflare tunnel token (home-server)" \
  "password=$TUNNEL_TOKEN" "tunnel id[text]=$TUNNEL_ID" >/dev/null; unset TUNNEL_TOKEN

# 2. Set the tunnel's ingress
cf tunnels config update "$TUNNEL_ID" --body '{"config":{"ingress":[
 {"hostname":"arbikullakshi.com","service":"http://edge-traefik:80"},
 {"hostname":"www.arbikullakshi.com","service":"http://edge-traefik:80"},
 {"hostname":"hypernova.arbikullakshi.com","service":"http://edge-traefik:80"},
 {"service":"http_status:404"}]}}' >/dev/null && echo ok

# 3. "Always Use HTTPS" (already on for arbikullakshi.com; this only checks it)
cf zones settings get always_use_https -z arbikullakshi.com | jq -r .value
```

Or in the dashboard: **Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared**,
name it `home-server`, then on the "Install and run a connector" page pick **Docker** and copy
the token: the long string after `--token` in the command shown (it starts with `eyJ`). Do
not run that command anywhere; the release runs cloudflared. Then **Next → Public
Hostnames**: add the three rows of the table above (Subdomain empty / `www` / `hypernova`,
domain `arbikullakshi.com`, Service type `HTTP`, URL `edge-traefik:80`). If the dashboard
refuses a hostname because a DNS record with that name exists, do section 10's first step
(delete the old records) at that point, at the cost of a slightly longer gap. Then **SSL/TLS
→ Edge Certificates → Always Use HTTPS: On**.

Keep the token for section 7 (the `CF_TUNNEL_TOKEN` secret). It is a credential: anyone with
it can run a connector that serves your hostnames. If it leaks, rotate it
([Rotating a secret](#rotating-a-secret)).

## 7. The production Environment

**Owner action**, on your laptop, with `gh` in the checkout. Create the Environment first
(Settings → Environments → New environment → `production`; optionally restrict it to the
`master` branch and add yourself as a required reviewer). Every value is new: generate them
here. Every value must be free of `$`, `"`, `'`, `` ` ``, `\`, `#`, line breaks and leading
or trailing spaces; the generated ones are.

```bash
# Access: the CI deploy key, the host key from section 5, the Tailscale OAuth client from section 4
gh secret set SSH_PRIVATE_KEY --env production < ~/.ssh/infra-deploy
gh secret set SSH_KNOWN_HOSTS --env production < /tmp/kh && rm /tmp/kh
gh variable set SERVER_SSH_HOST --env production --body infra-host
gh variable set TS_OAUTH_CLIENT_ID --env production --body '<client id>'
gh secret set TS_OAUTH_SECRET --env production                     # paste the OAuth client secret

# The Cloudflare Tunnel token from section 6
op item get "Cloudflare tunnel token (home-server)" --vault "Home Server" --fields label=password --reveal | gh secret set CF_TUNNEL_TOKEN --env production

# GHCR: an account and a classic token with read:packages that can read
# ghcr.io/somethim/portfolio and the ghcr.io/hypernova3643725 images
gh variable set GHCR_USERNAME --env production --body '<github user>'
# GitHub shows a token's value only once. If you don't have it saved, make a new one:
# GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) →
# Generate new token (classic), scope read:packages only, expiry 1 year; store it in 1Password
# ("Home Server" vault, "GHCR read token (infra)"), then:
op item get "GHCR read token (infra)" --vault "Home Server" --fields label=password --reveal | gh secret set GHCR_TOKEN --env production

# Database: three different passwords, 48 hex characters each; nobody needs to know them
for name in POSTGRES_SUPERUSER_PASSWORD PRIZM_DB_PASSWORD PORTFOLIO_DB_PASSWORD; do
  gh secret set "$name" --env production --body "$(openssl rand -hex 24)"
done

# Apps: generated secrets
gh secret set PORTFOLIO_TOTP_ENCRYPTION_KEY --env production --body "$(openssl rand -base64 32)"
gh secret set HYPERNOVA_SESSION_SECRET --env production --body "$(openssl rand -hex 24)"
gh secret set WEBUI_SECRET_KEY --env production --body "$(openssl rand -hex 32)"
gh secret set SEARXNG_SECRET --env production --body "$(openssl rand -hex 32)"
# The status dashboard and S3 storage: run the block in section 12, "The status dashboard and
# S3 secrets" (it keeps the values in 1Password: the dashboard password and the S3 key are yours to use)
# HOME_TLS_CF_DNS_TOKEN: a Cloudflare API token, created as in "The links page" (section 12)

# Apps: the two operator passwords you will log in with; store each in your password manager first
portfolio_admin="$(openssl rand -hex 16)"; echo "portfolio admin: $portfolio_admin"
gh secret set PORTFOLIO_ADMIN_PASSWORD --env production --body "$portfolio_admin"
hypernova_admin="$(openssl rand -hex 16)"; echo "hypernova admin: $hypernova_admin"
gh secret set HYPERNOVA_ADMIN_PASSWORD --env production --body "$hypernova_admin"
unset portfolio_admin hypernova_admin

# Optional: outgoing mail and the Google Calendar integration
gh secret set PORTFOLIO_RESEND_API_KEY --env production            # paste the Resend API key
gh variable set PORTFOLIO_GOOGLE_CLIENT_ID --env production --body '<client id>.apps.googleusercontent.com'
gh secret set PORTFOLIO_GOOGLE_CLIENT_SECRET --env production      # paste the client secret
```

Leave the `SERVER_USER` variable unset (the workflow uses `deploy` and refuses `root` and
`admin`). Delete what the old server used and nothing reads any more:

```bash
gh secret delete SERVER_HOST --env production      # "not found" is fine
gh secret list --env production; gh variable list --env production
```

The full list, with the format each value must have, is in
[docs/deploying.md](docs/deploying.md#secrets-and-variables). A missing or malformed value
stops the release on the runner, before the host is touched, with "Missing or invalid deploy
secrets" or "`<name>` holds a $, quote, …".

## 8. Second provision over the tailnet

**Owner action.** Point the inventory at the tailnet name and run as `admin`; every later
provision runs exactly like this:

```bash
cp inventory/hosts.example inventory/hosts      # [server] infra-host ansible_host=infra-host
ansible-playbook -u admin --ask-become-pass provision.yml
```

`BECOME password` is the admin password from section 5. Expect: "Close SSH on the LAN once
runs come in over the tailnet" reports `changed` (ufw's LAN 22 rule is deleted), the `setup`
account and its home directory are removed ("Remove the installer's account …"), and no "LAN"
message at the end. Then, from the laptop:

```bash
nc -z -w 5 192.168.1.50 22                      # times out or is refused (exit 1)
ssh admin@infra-host sudo ufw status            # Status: active; 22, 80, 443, 2283, 3900, 5000, 8080, 8090, 8091, 8096, 13378/tcp on tailscale0, nothing else
ssh admin@infra-host sudo docker ps --format '{{.Names}} {{.Ports}}'   # no "->": nothing is published
```

From now on the keyboard and monitor take the admin password if the tailnet is unreachable
([Locked out](#locked-out)).

## 9. First release

**Owner action.** GitHub → **Actions → Deploy → Run workflow**, "Use workflow from" `master`,
action `release`, every other input at its default. Expect in the "Release on the server"
step:

```
infra-apply: compose model accepted: 1 service(s) in the database stack, ...
infra-apply: compose model accepted: 1 service(s) in the portfolio stack, ...
infra-apply: compose model accepted: 2 service(s) in the hypernova stack, ...
infra-apply: compose model accepted: 1 service(s) in the tunnel stack, ...
infra-apply: compose model accepted: 3 service(s) in the ai stack, no privileged settings, no host port but open-webui 100.x.y.z:8080 on the tailnet, ...
infra-apply: compose model accepted: 17 service(s) in the media stack, no privileged settings, no host port but audiobookshelf 100.x.y.z:13378, beszel 100.x.y.z:8090, garage 100.x.y.z:3900, home 100.x.y.z:80, home-tls 100.x.y.z:443, immich-server 100.x.y.z:2283, ...
infra-apply: bundle accepted: 30 files, manifest checksums match
infra-apply: Watchtower is stopped until the app stacks are up
infra-apply: pulling images
infra-apply: starting the database
infra-apply: database roles, passwords and grants are in place
infra-apply: starting portfolio
infra-apply: starting hypernova
infra-apply: starting tunnel
infra-apply: starting ai
infra-apply: starting media
infra-apply: Watchtower is running again
infra-apply: every container is running and healthy, and has run for at least 30s without a restart
infra-apply: Traefik routes arbikullakshi.com/api/health www.arbikullakshi.com/ hypernova.arbikullakshi.com/ hypernova.arbikullakshi.com/api/health to their apps
infra-apply: the Cloudflare Tunnel is connected (cloudflared /ready answers 200)
infra-apply: the tailnet-only ports open-webui:8080 jellyfin:8096 audiobookshelf:13378 kavita:5000 home:80 home-tls:443 beszel:8090 garage:3900 sftpgo:8091 immich-server:2283 are bound to 100.x.y.z alone
infra-apply: home-tls serves https with a trusted certificate on 100.x.y.z for home.arbikullakshi.com ai.home.arbikullakshi.com photos.home.arbikullakshi.com jellyfin.home.arbikullakshi.com audiobooks.home.arbikullakshi.com books.home.arbikullakshi.com files.home.arbikullakshi.com status.home.arbikullakshi.com s3.home.arbikullakshi.com
infra-apply: beszel-pair garage-setup immich-admin finished: the dashboard's agent is paired, S3 has its layout, the owner's key and the files bucket, and Immich has its admin
infra-apply: Traefik, Watchtower, autoheal and Beszel's agent reach Docker through their socket proxies with no refused calls
infra-apply: RELEASE OK: <id> is current, following :latest, auto-updates on
```

PostgreSQL initialises the empty `pgdata-v18` volume on this first start, and `provision.sql`
creates the `prizm` and `portfolio` roles and databases; the apps create their schemas. The
portfolio can take up to 180 s to report healthy. The `ai` and `media` stacks need the GPU,
the `WEBUI_SECRET_KEY` secret and (for a library off the SSD) the disks; set them up first
([section 12](#12-gpu-ai-and-media)), since a release refuses without the first two. In the Cloudflare dashboard the tunnel now
shows **Healthy** with connections.

The release ends by asking the public hostnames through Cloudflare from the server
("Cloudflare serves …", just before `RELEASE OK`). If the DNS records still point at the old
server, that check fails although the release is current and verified; section 10 fixes the
records and ends with a second `release` whose public check proves the new path.

## 10. DNS switch-over and decommissioning the old server

**Owner action.** This is the only moment the sites change hands, and the only section that
touches the old Hetzner server. Nothing is copied from it: the new server started empty.

1. **Replace the old records with the tunnel's.** Delete the `A` and `AAAA` records of
   `arbikullakshi.com`, `www.arbikullakshi.com` and `hypernova.arbikullakshi.com` (they point
   at the Hetzner server), then create, for each of the three names, a proxied `CNAME` to
   `<tunnel id>.cfargotunnel.com`:

   ```bash
   # (done 2026-10-15) 1. Delete the old records (ids from `cf dns records list -z $Z`)
   Z=b548cd8d33527abe0bc4f3fc106096d1
   cf dns records delete <record id> -z $Z --force

   # 2. Route the three hostnames to the tunnel
   for n in arbikullakshi.com www hypernova; do
     cf dns records create -z $Z --body "{\"type\":\"CNAME\",\"name\":\"$n\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true}" >/dev/null && echo "ok $n"
   done

   # 3. Check: each name is a proxied CNAME to the tunnel, no A/AAAA left
   cf dns records list -z $Z | jq -r '.[] | select(.type=="A" or .type=="AAAA" or .type=="CNAME") | "\(.type) \(.name) \(.content) proxied=\(.proxied)"'
   ```

   In the dashboard: **DNS → Records**, delete the three names' `A`/`AAAA` records; then in
   **Zero Trust → Networks → Tunnels → home-server → Public Hostnames**, re-save each
   hostname (adding a public hostname creates its proxied CNAME). Leave the zone's other
   records (mail: `MX`, `TXT`, Resend's DKIM) alone.
2. **Check from outside**, for example from a phone off Wi-Fi or the laptop (Cloudflare's
   proxy answers at once; there is no TTL to wait out for proxied records):

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' https://arbikullakshi.com/api/health            # 200
   curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://www.arbikullakshi.com/ # 301 https://arbikullakshi.com/
   curl -sS -o /dev/null -w '%{http_code}\n' https://hypernova.arbikullakshi.com/api/health  # 200
   curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' http://arbikullakshi.com/      # 301 https://arbikullakshi.com/
   ```

   A `530` (error 1033) means the tunnel has no connector or no Public Hostname for that
   name; a `502` that cloudflared cannot reach `edge-traefik:80`; a `404` that Traefik has no
   router for that host.
3. **Run `release` again** (Actions → Deploy, action `release`). Its public check now goes
   through the tunnel and prints "Cloudflare serves https://arbikullakshi.com/api/health
   https://www.arbikullakshi.com/ https://hypernova.arbikullakshi.com/ …" before `RELEASE OK`.
4. **Set up the portfolio again**: sign in at `https://arbikullakshi.com/admin` with
   `PORTFOLIO_ADMIN_PASSWORD`, enrol TOTP and passkeys afresh, and reconnect Google Calendar
   if you use it. Sign in to hypernova with `HYPERNOVA_ADMIN_PASSWORD`.
5. **Decommission the old server**, in the Hetzner Cloud console (<https://console.hetzner.cloud>),
   only after step 3 is green. There is nothing to snapshot (no data moves):
   - the project's **Servers** → the old server → **Delete** (this also deletes its primary
     IPs unless they are protected; delete any that remain under **Primary IPs**);
   - **Volumes**: delete any volume that was attached to it;
   - **Firewalls**, **Floating IPs**, **Networks** and **Snapshots/Backups** that belonged to
     it: delete them;
   - then check the project's **Usage** shows nothing billable, and cancel the project if it is
     empty.
6. **Clean up the rest of the old setup**: in the Tailscale console, remove the old server's
   node if it is still listed and revoke any unused auth key; in GitHub, delete any old
   repository-level secrets (Settings → Secrets and variables → Actions) that the
   `production` Environment now holds.

## 11. Day-2 operations

### Releases, status, rollback, resume

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
- "FAILED: before the app stacks changed, …" then "release `<id>` is installed but not
  current; … a rollback cannot fix this …": the database did not come up healthy or
  `provision.sql` failed. The database runs the new definition, portfolio and hypernova the
  previous one, and `current` still names the previous release. A `rollback` does not help
  here: it only re-pins the app images and renders `stack/database`, `provision.sql` and the
  secrets from `master` again. Revert the `stack/database` or secret change on `master` (or fix
  the secret in the `production` Environment) and run `release`.
- "release `<id>` is current but not verified; … (the last verified release was `<id>`:
  `<summary>`)": an app stack or the tunnel did not start, or the release did not verify; the
  new release is `current`, and `previous` still names the last verified one. Read the failure
  line above it (which container was not healthy, which route answered what, whether
  cloudflared reached Cloudflare). Run `rollback` only when an app image is the cause: it
  changes nothing but the three app image references. A broken `stack/` file, env template or
  secret (a revoked `CF_TUNNEL_TOKEN` among them) comes back with a rollback (it is rendered
  from `master` again), so fix that on `master` or in the Environment and run `release`. The
  release kept in `/opt/infra/releases/` cannot be re-applied.

### Rotating a secret

Change it in the `production` Environment, then run `release`. That is the whole procedure for
most values:

- **Database passwords**: `provision.sql` re-sets each role's password in the same release
  that renders the new DSN, so the two cannot drift. `POSTGRES_SUPERUSER_PASSWORD` is re-set
  the same way. Generate with `openssl rand -hex 24`.
- **`CF_TUNNEL_TOKEN`**: in the dashboard, **Zero Trust → Networks → Tunnels → home-server →
  Refresh token** (or delete the tunnel and repeat section 6 steps 1–2 under the same name, then section 10 step 2 for the new id), store the new token,
  then run `release`: it recreates `cloudflared` with the new token, and the old token stops
  working. The sites are unreachable from the token refresh until the release's tunnel check
  passes, about a minute.
- **`PORTFOLIO_ADMIN_PASSWORD`** is used only when the portfolio's operator account does not
  exist yet; changing it does not change an existing account. Change that password in
  `/admin`, then store the same value here.
- **`PORTFOLIO_TOTP_ENCRYPTION_KEY`**: never rotate it casually. A new key makes every enrolled
  TOTP secret permanently unreadable; re-enrolment is the only recovery.
- **`GHCR_TOKEN`**: a release logs in again, which also refreshes the credentials Watchtower
  reads from `/root/.docker`.
- **`SSH_PRIVATE_KEY`** (the CI deploy key): make a new pair as in section 5, commit the public
  half, provision (it replaces `deploy`'s one line), then set the secret.
- **`TS_OAUTH_SECRET`**: generate a new OAuth client as in section 4 and replace both values.
- **`HOME_TLS_CF_DNS_TOKEN`**: create a new token as in [The links page](#the-links-page), set
  it, `release`, then delete the old token (Cloudflare dashboard, My Profile → API Tokens).
  The certificate already issued keeps working; only renewals use the token.
- **`WEBUI_SECRET_KEY`**: `openssl rand -hex 32`, then `release`. It only signs Open WebUI's
  sessions, so everyone is signed out and nothing else changes.
- **`SEARXNG_SECRET`**: `openssl rand -hex 32` (saved to "infra production secrets" in
  1Password as in section 12), then `release`. Nothing else changes.
- **`BESZEL_PASSWORD`** creates the dashboard login only on the hub's first start. To change
  it: change it in the dashboard (top right → Settings → Password), store the same value in
  1Password and here, then `release` (`beszel-pair` signs in with it; a mismatch fails the
  release at "beszel-pair exited with status 1").
- **`BESZEL_AGENT_TOKEN`**: `openssl rand -hex 24`, then `release`; `beszel-pair` makes the new
  value the universal token, and the agent, recognised by its fingerprint, keeps its history.
- **`GARAGE_ADMIN_TOKEN`**: `openssl rand -hex 32`, then `release`. Only the admin API uses it.
- **`GARAGE_RPC_SECRET`**: `openssl rand -hex 32`, then `release`. A single node only talks to itself.
- **`GARAGE_OWNER_ACCESS_KEY_ID` and `GARAGE_OWNER_SECRET_KEY`**: rotate **both together**
  (Garage never reuses a deleted key ID): `GK$(openssl rand -hex 12)` and `openssl rand -hex 32`,
  as in section 12, then `release`. `garage-setup` imports the new key, gives it the `files`
  bucket and deletes the old one, and `sftpgo` picks the new key up on its restart; update
  rclone and your S3 apps.
- **`FILES_PASSWORD`**: `openssl rand -hex 16` (saved to "infra production secrets" as in
  section 12), then `release`. `sftpgo` reloads its user at start, so the new password works
  at once and the old one stops; update WebDAV mounts.
- **`IMMICH_ADMIN_PASSWORD`** only creates the first admin. Change your Immich password in
  Immich (Account Settings → Password); the secret can stay as it is.
- **`IMMICH_DB_PASSWORD`**: initdb sets it once, so change it inside the database first, then
  everywhere else: `p="$(openssl rand -hex 32)"; ssh -t admin@infra-host "sudo docker exec
  immich-postgres psql -U postgres -c \"ALTER USER postgres PASSWORD '$p'\""`, save `$p` to
  "infra production secrets" (field `IMMICH_DB_PASSWORD`) and `gh secret set IMMICH_DB_PASSWORD`,
  `unset p`, then `release`; `immich-server` connects with the new value on its restart.

Every value must pass the formats in [docs/deploying.md](docs/deploying.md#secrets-and-variables);
the render on the runner refuses one that does not, before the host is touched.

### Provisioning again

```bash
ansible-playbook -u admin --ask-become-pass provision.yml                 # everything
ansible-playbook -u admin --ask-become-pass provision.yml --tags edge     # one role
```

Run it when a role changes on `master`. It never touches the app stacks or their data.

### Locked out

The way in that depends on neither sshd, keys nor the tailnet is the **server's own keyboard
and monitor**: log in as `admin` with its password. From there:

- **The tailnet is down or the server left it**: `tailscale status`. If it is logged out,
  `sudo tailscale up --auth-key=<new one-off key, tag:infra-server> --hostname=infra-host
  --advertise-tags=tag:infra-server --ssh=false --accept-dns=false --accept-routes=false`
  (make the key as in section 4).
- **fail2ban banned you** (only possible from outside the tailnet, so only while LAN 22 is
  open; the tailnet range is never banned): `sudo fail2ban-client set sshd unbanip <your IP>`.
- **sshd refuses logins or will not start**: check
  `/etc/ssh/sshd_config.d/10-hardening.conf` and `sudo sshd -t`. Provisioning validates the
  file with `sshd -t` before installing it and reloads (never restarts) sshd, so a provision
  should not cause this; another drop-in in `/etc/ssh/sshd_config.d/` that overrides it would
  (provisioning stops with "Locked out" when `sshd -T` does not apply its policy).
- **You need SSH over the LAN for one run**: `sudo ufw allow 22/tcp` at the console, run
  provisioning with `ansible_host=<LAN address>` as `admin`, then once more over the tailnet,
  which deletes the rule again.
- **The server does not come back after a power cut**: the firmware setting of section 2 is
  off, or the board's deep power-saving mode overrides it. Press the power button, then fix it
  in the firmware.

### The sites are down but the server is up

```bash
ssh admin@infra-host sudo docker ps --format '{{.Names}} {{.Status}}'
ssh admin@infra-host sudo docker logs --tail 50 cloudflared
```

`cloudflared` restarts on its own (`restart: always`, and autoheal when it reports
unhealthy). Logs saying the token is invalid mean the tunnel was deleted or its token
refreshed: store the current token as `CF_TUNNEL_TOKEN` and run `release`. A home internet
outage takes the sites down until the line is back; cloudflared reconnects by itself, and a
change of the home's public IP needs nothing at all.

### Re-pinning third-party images

Every non-app image (PostgreSQL, Traefik, cloudflared, the socket proxies, Watchtower,
autoheal) is pinned `<image>:<tag>@sha256:<digest>`, one version per repository across
`stack/` and `roles/*/files/`, and the bundle build refuses anything else. To move one (a
Watchtower that the Engine calls "too old", a Traefik, cloudflared or PostgreSQL patch
release), follow [docs/agents.md](docs/agents.md#re-pinning-third-party-images), then
provision with that role's tag, or run `release` for `postgres` (a minor version only; a
major is a dump and restore, [docs/database.md](docs/database.md#upgrades)) and `cloudflared`
(`stack/tunnel`).

### Restoring from the backup disk

The external disk holds, under `/srv/backup/snapshots/` (root only), one folder per night,
`<YYYY-MM-DD>/`, and `latest` pointing at the newest:

```
snapshots/<date>/postgres.sql.gz       pg_dumpall of the shared PostgreSQL
snapshots/<date>/immich.sql.gz         Immich's own database
snapshots/<date>/volumes/<volume>/     the apps' volumes as plain trees: jellyfin-config,
                                       audiobookshelf-config, audiobookshelf-metadata, kavita-config,
                                       open-webui-data, portfolio-media, hypernova_prizm-storage,
                                       beszel-data, garage-meta, sftpgo-data
snapshots/<date>/media/<name>/         audiobooks, books, podcasts, photos (Immich) and s3
                                       (Garage's objects, the Files bucket)
```

Kept: the last 14 nights, plus the first night of each of the last 8 weeks, so anything
deleted within about two months is still in an older snapshot. Unchanged files are hard links
between snapshots, so each night only costs what changed. Movies, shows and the Ollama models
are not backed up: re-rip or re-download them. Check last night's run with
`ssh admin@infra-host journalctl -u infra-backup.service --since yesterday`; a failed one also
logs "the nightly backup FAILED" at error priority, and its unfinished
`snapshots/.<date>.partial` stays until the next run.

**Find a file in the snapshots** (books, audiobooks, podcasts and photos are plain files):

```bash
ssh -t admin@infra-host
sudo ls /srv/backup/snapshots/
sudo find /srv/backup/snapshots/*/media/books -iname '*orwell*'
sudo find /srv/backup/snapshots/*/media/photos/library -name 'IMG_1234*'
```

**A deleted book, audiobook or podcast episode:** copy it back from a night that still has it:

```bash
sudo cp -a /srv/backup/snapshots/<date>/media/books/<path> /srv/media/books/<path>
```

Kavita and Audiobookshelf pick it up at their next scan.

**A deleted photo:** first look in Immich's own trash (it keeps deleted photos for 30 days).
Past that, copy the original out of a snapshot and upload it again in Immich (web: Upload):

```bash
sudo find /srv/backup/snapshots/*/media/photos/library -name '<file name>'
sudo cp /srv/backup/snapshots/<date>/media/photos/library/<...>/<file> /tmp/ && sudo chown admin /tmp/<file>
scp admin@infra-host:/tmp/<file> .          # from the laptop, then upload it in Immich
```

**A deleted file from Files (the S3 bucket):** Garage stores objects as hashed blocks, not as
plain files, so start a throwaway Garage on a copy of that night's metadata and blocks, and copy
the file out of it with rclone. On the server:

```bash
d=<date>; s=/srv/backup/snapshots/$d; t=/srv/media/restore-$d
sudo mkdir -p "$t"
sudo cp -a "$s/volumes/garage-meta" "$t/meta"     # small; Garage writes to its metadata
sudo cp -al "$s/media/s3" "$t/data"               # hard links: instant, no extra space
sudo tee "$t/meta/garage.toml" >/dev/null <<'TOML'
metadata_dir = "/meta/db"
data_dir = "/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "127.0.0.1:3911"
rpc_public_addr = "127.0.0.1:3911"
[s3_api]
s3_region = "garage"
api_bind_addr = "127.0.0.1:3910"
TOML
sudo docker run -d --name garage-restore --network host --user "$(sudo stat -c %u:%g "$t/data")" \
  -e GARAGE_RPC_SECRET="$(openssl rand -hex 32)" -e GARAGE_CONFIG_FILE=/meta/garage.toml \
  -v "$t/meta:/meta" -v "$t/data:/data" \
  dxflrs/garage:v2.4.1@sha256:9c96caa2612d3411acc5b0e6701fb238dbfba33e533a6d7d3d811a4b12d0d020 /garage server
```

Then from the laptop, through an SSH tunnel, with the same key as the live bucket (it is in
that night's metadata):

```bash
ssh -N -L 3910:127.0.0.1:3910 admin@infra-host &
k="$(op item get 'infra production secrets' --vault 'Home Server' --fields label=GARAGE_OWNER_ACCESS_KEY_ID --reveal)"
p="$(op item get 'infra production secrets' --vault 'Home Server' --fields label=GARAGE_OWNER_SECRET_KEY --reveal)"
old=":s3,provider=Other,endpoint=http://127.0.0.1:3910,region=garage,force_path_style=true,access_key_id=$k,secret_access_key=$p:files"
rclone ls "$old/<folder>"                                   # find it
rclone copyto "$old/<folder>/<file>" "home:files/<folder>/<file>"   # back into the live bucket
unset k p old; kill %1
```

On the server, throw the copy away: `sudo docker rm -f garage-restore && sudo rm -rf /srv/media/restore-<date>`.

**One app's data** (here Jellyfin; the same for `audiobookshelf-config`,
`audiobookshelf-metadata`, `kavita-config`, `open-webui-data`, `beszel-data`, `sftpgo-data`):
stop its container, copy the volume back from a snapshot, start. The trees keep numeric owners.

```bash
ssh -t admin@infra-host
sudo docker stop jellyfin
v="$(sudo docker volume inspect --format '{{.Mountpoint}}' jellyfin-config)"
sudo rsync -a --delete --numeric-ids /srv/backup/snapshots/<date>/volumes/jellyfin-config/ "$v/"
sudo docker start jellyfin
```

**All of Garage** (the whole `files` bucket as it was that night): its metadata and objects
must come from the same snapshot:

```bash
sudo docker stop garage sftpgo
v="$(sudo docker volume inspect --format '{{.Mountpoint}}' garage-meta)"
sudo rsync -a --delete --numeric-ids /srv/backup/snapshots/<date>/volumes/garage-meta/ "$v/"
sudo rsync -a --delete --numeric-ids /srv/backup/snapshots/<date>/media/s3/ /srv/media/s3/
sudo docker start garage sftpgo
```

**Immich** (its database and its photos together, from the same snapshot): restore the dump
into an empty `immich-pgdata`, then the photos; thumbnails and encoded video rebuild by
themselves (Administration → Jobs → *Missing*).

```bash
sudo docker stop immich-server immich-machine-learning
sudo docker stop immich-postgres
v="$(sudo docker volume inspect --format '{{.Mountpoint}}' immich-pgdata)"
sudo find "$v" -mindepth 1 -delete
sudo docker start immich-postgres    # initdb runs again with IMMICH_DB_PASSWORD; wait until healthy
gzip -cd /srv/backup/snapshots/<date>/immich.sql.gz | sudo docker exec -i immich-postgres psql -U postgres -d postgres
sudo rsync -a --delete --numeric-ids --exclude=/thumbs/ --exclude=/encoded-video/ /srv/backup/snapshots/<date>/media/photos/ /srv/media/photos/
sudo docker start immich-server immich-machine-learning
```

**The database**, all roles and databases at once, into the running cluster (a dump of the
whole cluster; restoring it over existing databases fails on objects that exist, so for one
app drop its database first, or restore into a fresh `pgdata-v18` after a reinstall):

```bash
sudo docker stop portfolio prizm-provider prizm-web
gzip -cd /srv/backup/snapshots/<date>/postgres.sql.gz | sudo docker exec -i postgresql psql -U postgres -d postgres
sudo docker start portfolio prizm-provider prizm-web
```

Restore `portfolio-media` from the same snapshot as the dump: the portfolio's `media` table is
a ledger of that volume ([docs/database.md](docs/database.md#backups)).

**Everything on the media disk**, after replacing the internal disk (format it as in
[Disks](#disks), put the new UUID in `production.yml`, provision):

```bash
sudo rsync -a --numeric-ids /srv/backup/snapshots/latest/media/ /srv/media/   # owners, groups and modes come back as they were
```

**A new server**: install and provision as in sections 3–9 with the same `production.yml`
(the backup disk's UUID included), release once so every volume exists, then restore each
app volume, Garage, Immich and the database as above, all from the same snapshot.

**Before snapshots** (backups written before this layout): the first snapshot run deletes the
old `media/` mirror and `apps/` folder once a complete snapshot exists (it links to the old
mirror, so nothing is copied twice), and the old `postgres/` and `immich/` dumps once 14
snapshots exist.

### More recipes

PostgreSQL access, disk, backups, a major PostgreSQL upgrade, Watchtower and a hung site are
in [docs/operations.md](docs/operations.md).

## 12. GPU, AI and media

**Owner action.** Turns on what the rest of the hardware is for: Ollama with Open WebUI (presets,
web search through SearXNG, image generation through ComfyUI) on the RTX 2060, Jellyfin, Audiobookshelf, Kavita and the Immich photo library on the 1 TB internal HDD, and a nightly backup to
the 1 TB external USB HDD. None of it is public: it is reachable only over the tailnet, on the
server's Tailscale address, and only by the Tailscale accounts the policy names (you). Video
never goes through the Cloudflare Tunnel. Do the steps in this order; each one says how to
check it.

Every service has an https name under `home.arbikullakshi.com` with a real certificate, served by
`home-tls` on the Tailscale address (443). Use these: browsers allow the clipboard, the microphone
and installing a site as an app only over https. The old `http://infra-host:<port>` addresses
still work (apps set up with them keep running) and may be retired later.

| Service | Address (on the tailnet) | Also, older | Container port |
| --- | --- | --- | --- |
| Links page (the seven below as tiles) | `https://home.arbikullakshi.com/` | `http://infra-host/` | 80 |
| Open WebUI | `https://ai.home.arbikullakshi.com` | `http://infra-host:8080` | 8080 |
| Photos (Immich) | `https://photos.home.arbikullakshi.com` (the phone app too) | `http://infra-host:2283` | 2283 |
| Jellyfin | `https://jellyfin.home.arbikullakshi.com` | `http://infra-host:8096` | 8096 |
| Audiobookshelf | `https://audiobooks.home.arbikullakshi.com` | `http://infra-host:13378` | 13378 |
| Kavita | `https://books.home.arbikullakshi.com` | `http://infra-host:5000` | 5000 |
| Files (SFTPGo, the file manager) | `https://files.home.arbikullakshi.com` (web client at `/web/client`, WebDAV at `/dav`) | `http://infra-host:8091/web/client` | 8091, 8092 |
| Beszel (server status) | `https://status.home.arbikullakshi.com` | `http://infra-host:8090` | 8090 |
| Garage (S3 behind Files) | `https://s3.home.arbikullakshi.com` (path-style, region `garage`) | `http://infra-host:3900` | 3900 |

The names come from one map, `home_hosts` in `production.yml` (key: the service; value: the first
label). Changing a label there changes the tile, the route, the app's own public URL and the
release check together.

### Disks

At the server's console (or `ssh admin@infra-host`), with both HDDs connected. **Formatting
erases the disk**: check the model, size, serial and transport twice, and never touch the SSD
that holds Ubuntu (the one with the `ubuntu-vg` partitions).

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS
```

The internal 1 TB HDD shows `TRAN` `sata`, the external one `usb`. Below, `/dev/sdX` is the
internal disk and `/dev/sdY` the external one; use the names `lsblk` printed. For each of the
two (here the internal one; the external one the same way with `-L backup`):

```bash
sudo wipefs -a /dev/sdX                          # removes every old partition table and signature
printf 'label: gpt\ntype=linux\n' | sudo sfdisk /dev/sdX   # one GPT partition over the whole disk: /dev/sdX1
sudo mkfs.ext4 -L media /dev/sdX1                # the external one: sudo mkfs.ext4 -L backup /dev/sdY1
sudo blkid /dev/sdX1 /dev/sdY1                   # UUID="…" of each
```

Copy the two `UUID="…"` values into `production.yml` and commit them to `master`:

```yaml
media_disk_uuid: "<UUID of /dev/sdX1>"
backup_disk_uuid: "<UUID of /dev/sdY1>"
```

Provisioning (below) mounts them by UUID at `/srv/media` and `/srv/backup`
(`nofail,x-systemd.device-timeout=10s`, so the server still boots in seconds with the external
disk unplugged), creates the library folders `shows`, `movies`, `audiobooks`, `podcasts` and
`books` (owned by the `media` account, setgid, group-writable) and keeps the backup disk
root-only. While a configured disk is missing its mountpoint stays empty and unwritable, so
nothing lands on the SSD in its place. Check after provisioning:

```bash
ssh admin@infra-host findmnt /srv/media /srv/backup        # both, ext4, by UUID
ssh admin@infra-host ls -l /srv/media                      # the five folders, drwxrwsr-x media media
```

### Tailscale grants

In the Tailscale admin console, **Access controls**, add exactly this grant to the policy file
(section 4 already lists it for a new tailnet; an older policy needs it added) and nothing
else for `tag:infra-server`:

```json
{"src": ["autogroup:admin"], "dst": ["tag:infra-server"], "ip": ["tcp:80", "tcp:443", "tcp:2283", "tcp:3900", "tcp:8080", "tcp:8090", "tcp:8091", "tcp:8096", "tcp:13378", "tcp:5000"]}
```

An existing policy gets the ports it lacks from `~/.cache/infra-tailscale-setup.sh links`
(shows the diff, asks before saving).

`tag:infra-ci` gets no new port. Check from the laptop once the release below is done:
`nc -z -w 5 infra-host 8096` succeeds, and `nc -z -w 5 192.168.1.50 8096` (the LAN address)
times out.

### The Open WebUI and SearXNG secrets

```bash
gh secret set WEBUI_SECRET_KEY --env production --body "$(openssl rand -hex 32)"
k="$(openssl rand -hex 32)"
op item edit "infra production secrets" --vault "Home Server" "SEARXNG_SECRET[password]=$k" >/dev/null &&
  printf %s "$k" | gh secret set SEARXNG_SECRET --env production; unset k
```

`WEBUI_SECRET_KEY` signs Open WebUI's sessions and reaches only the `open-webui` container;
`SEARXNG_SECRET` is SearXNG's key and reaches only `searxng`. Nobody needs to know either. A
release refuses to render without both.

### Provision, reboot and check the GPU

`production.yml` already has `gpu_enabled: true` and `nvidia_driver_major: 580`. On the server,
check that Ubuntu offers that branch for the card:

```bash
lspci | grep -i nvidia                       # the RTX 2060 (TU106)
ubuntu-drivers list --gpgpu                  # must include nvidia-driver-580-server
```

If it lists another `-server` branch instead, set `nvidia_driver_major` to it (through
`master`). Then provision from the laptop:

```bash
ansible-playbook -u admin --ask-become-pass provision.yml
```

The `gpu` role installs the driver and the NVIDIA Container Toolkit; `host` writes the
Tailscale address into `/etc/infra/host.env`, turns on non-local binds, adds the second
firewall hook, the `ai`, `llm` and `media` networks, the `ai` and `media` accounts (and puts
`admin` in the `media` group) with their volumes, mounts the disks and installs the nightly
backup. A first run ends the `gpu` part with "The NVIDIA driver was installed or updated since the last boot
and is not loaded yet … Reboot when it suits you": the driver loads at the next boot. Reboot
(the sites are back when Docker has restarted the stacks, about a minute), then verify:

```bash
ssh -t admin@infra-host sudo reboot
ansible-playbook -u admin --ask-become-pass provision.yml --tags gpu,host
ssh admin@infra-host nvidia-smi                        # the RTX 2060, 12288MiB, driver 580.x
ssh admin@infra-host sudo docker info --format '{{json .Runtimes}}'    # includes "nvidia"
ssh admin@infra-host systemctl list-timers infra-backup.timer           # next run tonight, 02:30 UTC
```

The second run passes "Require nvidia-smi to see the GPU through the loaded driver". With
Secure Boot on, Ubuntu's signed modules load without any key enrolment; if `nvidia-smi` says it
cannot communicate with the driver, `sudo dmesg | grep -i nvidia` says why.

### Release

Run `release` (Actions → Deploy). Besides the usual lines, expect the `ai` and `media` stacks
accepted with their tailnet ports, library mounts and GPU, "starting ai", "starting media", and
"the tailnet-only ports open-webui:8080 jellyfin:8096 audiobookshelf:13378 kavita:5000 home:80 home-tls:443
beszel:8090 garage:3900 sftpgo:8091 immich-server:2283 are bound to 100.x.y.z alone". The images are large (Open WebUI about 4 GB, ComfyUI about 7 GB, Immich's CUDA machine learning about 4 GB);
the first pull takes a while. In the background, after the release:

- `ollama-pull` downloads `ollama_models` in order: `qwen3:4b` (2.6 GB, so **Quick** works
  first), `qwen2.5-coder:14b` (9 GB) and `qwen3:14b` (9.3 GB), about 21 GB on the SSD;
  roughly 30 minutes at 100 Mbit/s.
- `comfyui-fetch` downloads the Stable Diffusion XL checkpoint (6.9 GB) and checks its sha256.
- `webui-presets` writes the five presets into Open WebUI (once you have signed up; on a
  fresh volume it waits for the next release).

```bash
ssh admin@infra-host sudo docker logs -f ollama-pull      # "every model in ollama_models is present"
ssh admin@infra-host sudo docker logs -f comfyui-fetch    # "… verified (6616 MiB in … s)"
ssh admin@infra-host sudo docker logs webui-presets       # "added quick, …" or "every preset is current"
ssh admin@infra-host sudo docker exec ollama nvidia-smi -L   # GPU 0: NVIDIA GeForce RTX 2060 (inside the container)
ssh admin@infra-host sudo docker exec ollama ollama ps    # after a chat: 100% GPU
ssh admin@infra-host sudo docker ps --format '{{.Names}} {{.Ports}}'   # ports only on 100.x.y.z
```

hypernova's AI features use the same Ollama over the internal `llm` network from this release
on.

### First logins

Right after the release, before anyone else could, from the laptop (on the tailnet). Use a
password from your password manager for each.

1. **Open WebUI**, `https://ai.home.arbikullakshi.com`: **sign up**; the first account becomes the
   admin. Nothing else to set: sign-up, web search, image generation and the presets come from
   `stack/ai/docker-compose.yml` on every start, and the admin panel's changes last only until
   the next restart ([docs/stacks.md](docs/stacks.md#ai)). `ENABLE_SIGNUP=false` still lets
   the very first account sign up, and nobody after it. On a fresh volume, run `release` once
   more after signing up: the first run's `webui-presets` found no admin to own the presets.
   The picker shows **Quick** (the default), **MCU Coder**, **Robotics**, **Research** and
   **Image** once `ollama-pull` has fetched their models.
2. **Jellyfin**, `https://jellyfin.home.arbikullakshi.com`: the setup wizard. Create the admin user; add two
   libraries: **Shows** (content type Shows, folder `/media/shows`) and **Movies** (Movies,
   `/media/movies`); leave "Allow remote connections" on (the tailnet is "remote" to Jellyfin)
   and finish. Then **Dashboard → Playback → Transcoding**: Hardware acceleration **NVIDIA
   NVENC**, enable hardware decoding for H.264, HEVC, VC-1, VP9 (the RTX 2060 has no AV1
   decoder), and **Allow encoding in HEVC format**; save. A transcoded film shows the
   `ffmpeg` process in `nvidia-smi` on the server.
3. **Audiobookshelf**, `https://audiobooks.home.arbikullakshi.com`: create the root user. **Settings →
   Libraries → Add**: **Audiobooks** (media type Books, folder `/audiobooks`) and **Podcasts**
   (media type Podcasts, folder `/podcasts`).
4. **Kavita**, `https://books.home.arbikullakshi.com`: create the admin account; **Server settings →
   Libraries → Add library**: type Book (or Comic/Manga for those), folder `/books`.
5. **Beszel**, `https://status.home.arbikullakshi.com`: nothing to set up. Sign in with `status_owner_email`
   (`production.yml`) and `BESZEL_PASSWORD`; `infra-host` is already listed
   ([The status dashboard](#the-status-dashboard)).
6. **Files**, `https://files.home.arbikullakshi.com/web/client` (the Files tile): nothing to set up. Sign in as
   `owner` with `FILES_PASSWORD` ([Files](#files-s3-storage)).
7. **Photos**, `https://photos.home.arbikullakshi.com` (the Photos tile): sign in with `status_owner_email` and
   `IMMICH_ADMIN_PASSWORD`; Immich asks for a new password straight away (keep it in 1Password)
   and walks through a short onboarding (theme, privacy, storage template: leave its choices,
   the settings are code). Then the phone app and the Google Takeout ([Photos](#photos-immich)).

Jellyfin and Kavita see the library read-only; Audiobookshelf may write in `/audiobooks` and
`/podcasts` (podcast downloads, covers).

### The links page

`https://home.arbikullakshi.com/` (or `http://infra-host/`) on any device on the tailnet shows
seven tiles (two columns on a phone too, Status across the bottom row): Open WebUI, Photos
(Immich), Jellyfin, Audiobookshelf, Kavita, Files (the file manager; other ways in at
`https://home.arbikullakshi.com/files.html`) and Status (Beszel), so nobody has to remember an
address; bookmark it or add it to the home screen. Each tile opens the service's https name
from the table above.

Two containers in the media stack serve it, each on the Tailscale address only, like the
others:

- `home` (busybox `httpd`, the page is in `stack/media/docker-compose.yml`) on port 80, for
  `http://infra-host/`.
- `home-tls` (Traefik, the edge image) on port 443, for `https://home.arbikullakshi.com/` and
  every `<label>.home.arbikullakshi.com`: it routes each name to its container over the media
  network (and the ai network, for Open WebUI alone), with no read or write timeout, so big
  uploads and long streams pass. The apex sends HSTS with `includeSubDomains`, so a browser
  that has seen arbikullakshi.com only ever opens these names over https. `home-tls` gets one
  Let's Encrypt certificate for `home.arbikullakshi.com` and `*.home.arbikullakshi.com` by the
  DNS-01 challenge through Cloudflare's API, so nothing on the internet has to reach the server,
  and keeps it in the `home-tls-acme` volume (not backed up: a lost one is simply reissued).

`home` and `*.home` are DNS-only records (grey cloud, not proxied) to the server's Tailscale
address. Off the tailnet that address leads nowhere, so the records reveal nothing usable:

```bash
Z=b548cd8d33527abe0bc4f3fc106096d1
cf dns records create -z $Z --body '{"type":"A","name":"home","content":"100.126.107.95","proxied":false,"comment":"tailnet-only links page"}'
cf dns records create -z $Z --body '{"type":"A","name":"*.home","content":"100.126.107.95","proxied":false,"comment":"tailnet-only service names (home-tls)"}'
```

**The certificate's token.** `home-tls` needs a Cloudflare API token that may read the zone and
edit its DNS records, on arbikullakshi.com only, stored as the `HOME_TLS_CF_DNS_TOKEN` secret.
Create it, keep it in 1Password and set the secret without it ever showing on screen:

```bash
policies='[{"effect":"allow","resources":{"com.cloudflare.api.account.zone.b548cd8d33527abe0bc4f3fc106096d1":"*"},"permission_groups":[{"id":"4755a26eedb94da69e1066d98aa820be"},{"id":"c8fed203ed3043cba015a93ad1616f1f"}]}]'
tok="$(cf user tokens create -q --name 'infra home-tls (arbikullakshi.com DNS edit)' --policies "$policies" | sed -n '/^{/,$p' | jq -r .value)"
[ -n "$tok" ] && [ "$tok" != null ] && op item create --category password --vault "Home Server" --title "Cloudflare DNS token (home TLS)" "password=$tok" >/dev/null &&
  printf %s "$tok" | gh secret set HOME_TLS_CF_DNS_TOKEN --env production -R somethim/infra && echo "token stored and set"
unset tok
```

(The two permission groups are **DNS Write** and **Zone Read**.) If `cf` may not create tokens
with its login, use the dashboard instead: **My Profile → API Tokens → Create Token → Edit zone
DNS** template, add the permission **Zone · Zone · Read**, **Zone Resources: Include · Specific
zone · arbikullakshi.com**, create, then store and set it from the clipboard:

```bash
read -rsp 'token: ' tok; echo
op item create --category password --vault "Home Server" --title "Cloudflare DNS token (home TLS)" "password=$tok" >/dev/null &&
  printf %s "$tok" | gh secret set HOME_TLS_CF_DNS_TOKEN --env production -R somethim/infra; unset tok
```

A tailnet whose policy predates the page needs `tcp:80` and `tcp:443` added to the admins' grant
to `tag:infra-server` ([Tailscale grants](#tailscale-grants)); until then the page times out.
Provisioning opens 443 in ufw and creates the `home-tls-acme` volume, so provision once before
the release that brings `home-tls`. The release then asks every name over https on the
Tailscale address and waits up to 5 minutes each for the certificate ("home-tls serves https
with a trusted certificate on 100.x.y.z for home.arbikullakshi.com ai.home… s3.home…"): the
links page must answer 200, a service 2xx, 3xx, 401 or 403 (a 404 means no route, 502 a
container home-tls cannot reach). A refused token shows in
`ssh admin@infra-host sudo docker logs home-tls`.

### The status dashboard and S3 secrets

Six new secrets, generated here and kept in the "infra production secrets" item in 1Password
(the dashboard password and the S3 key are the ones you use); none is printed:

```bash
item="infra production secrets"
set_secret() { op item edit "$item" --vault "Home Server" "$1[password]=$2" >/dev/null && printf %s "$2" | gh secret set "$1" --env production -R somethim/infra; }
set_secret BESZEL_PASSWORD "$(openssl rand -hex 16)"
set_secret BESZEL_AGENT_TOKEN "$(openssl rand -hex 24)"
set_secret GARAGE_RPC_SECRET "$(openssl rand -hex 32)"
set_secret GARAGE_ADMIN_TOKEN "$(openssl rand -hex 32)"
set_secret GARAGE_OWNER_ACCESS_KEY_ID "GK$(openssl rand -hex 12)"
set_secret GARAGE_OWNER_SECRET_KEY "$(openssl rand -hex 32)"
unset -f set_secret; unset item
```

The file manager (SFTPGo) adds one more, its sign-in password, the same way:

```bash
p="$(openssl rand -hex 16)"; op item edit "infra production secrets" --vault "Home Server" "FILES_PASSWORD[password]=$p" >/dev/null && printf %s "$p" | gh secret set FILES_PASSWORD --env production -R somethim/infra; unset p
```

Immich adds two more, its database password and the password its first admin is created with:

```bash
item="infra production secrets"
set_secret() { op item edit "$item" --vault "Home Server" "$1[password]=$2" >/dev/null && printf %s "$2" | gh secret set "$1" --env production -R somethim/infra; }
set_secret IMMICH_DB_PASSWORD "$(openssl rand -hex 32)"
set_secret IMMICH_ADMIN_PASSWORD "$(openssl rand -hex 16)"
unset -f set_secret; unset item
```

A release refuses to render without all nine. Then provision (it creates the `beszel-data`,
`beszel-agent-data` and `garage-meta` volumes, `/srv/media/s3` and `/srv/media/.beszel`, the
`beszel` role's socket proxy, and opens 3900 and 8090 in ufw; with the file manager also
`sftpgo-data` and 8091; with Immich also `immich-pgdata`, `immich-ml-cache`, the internal
`immich` network, `/srv/media/photos` and 2283), then `release`.

### The status dashboard

Beszel at `https://status.home.arbikullakshi.com` (the Status tile): CPU, memory, load, temperatures, the GPU
(use, memory, power), the SSD, the media disk and the backup disk, and every container's CPU,
memory and network, with history. Sign in with `status_owner_email` from `production.yml` and
`BESZEL_PASSWORD`:

```bash
op item get "infra production secrets" --vault "Home Server" --fields label=BESZEL_PASSWORD --reveal
```

Everything is code: the hub (`beszel`) creates that login on its first start; `beszel-pair`
makes `BESZEL_AGENT_TOKEN` your universal token and hands the agent the hub's key; the agent
(`beszel-agent`) connects and appears as `infra-host`. It sees Docker only through
`beszel-socket-proxy` (`roles/beszel`), which allows four reads (version, engine info, the
container list, one container's stats): no inspect, so no container's environment, and no
logs, which is why the dashboard's container "details" and "logs" buttons show nothing. The
agent is not on the host network, so the host's own network totals are not shown, only each
container's. The backup disk's size shows once it is mounted; after mounting it by hand,
`ssh admin@infra-host sudo docker restart beszel-agent`. Alerts (e-mail or a webhook) can be set
in the dashboard; they live in `beszel-data`, which the nightly backup copies.

### Files (S3 storage)

**The file manager.** `https://files.home.arbikullakshi.com/web/client` (the Files tile) is SFTPGo's web
client on the `files` bucket, made to work like Google Drive:

- **click** a row to select it (Ctrl/⌘-click adds to the selection); **double-click** opens it. On a
  phone, a **tap** opens it.
- Files open in a **full-screen preview** (PDF, images, video, audio, text) with **‹ ›** (or the
  arrow keys) for the previous and next file, **⤓** to download, **✕** or Esc to close. Other files
  show a Download button.
- **Right-click** a row for Open, Download, Rename, Move or copy, Share, Delete. The **⤓** button on
  each row downloads (a folder downloads as a zip).
- Folders open on double-click; drag files onto the page to upload; the search box filters.

Sign in as `owner` with `FILES_PASSWORD`. A sign-in lasts 12 hours,
renewed while you use it (SFTPGo allows no longer), and survives closing the browser and
releases; signing out, or 12 hours without opening the page, ends it:

```bash
op item get "infra production secrets" --vault "Home Server" --fields label=FILES_PASSWORD --reveal
```

**As a drive (WebDAV).** `https://files.home.arbikullakshi.com/dav` (through `home-tls`, so with
the real certificate; `https://home.arbikullakshi.com/dav` still works for older mounts), user
`owner`, the same password. On the laptop: Nautilus, Other Locations,
`davs://files.home.arbikullakshi.com/dav`, or `rclone config create homedav webdav
url=https://files.home.arbikullakshi.com/dav vendor=other user=owner pass="$(rclone obscure "$(op item
get 'infra production secrets' --vault "Home Server" --fields label=FILES_PASSWORD --reveal)")"`. On
Android: a WebDAV-capable file manager (Material Files, Solid Explorer) with that address.

Everything is code: `sftpgo` loads its user from the compose file on every start (mode 0: added,
or updated to match), so the password follows `FILES_PASSWORD` and the storage is always the
`files` bucket with the owner's S3 key. SFTP, FTP, the admin web UI and the REST API are off; an
admin account exists only because SFTPGo requires one, with a random password made new at every
start. Share links, sessions and the key that signs them (`web-signing.key`, made once) live in
`sftpgo-data`, which the nightly backup copies (SFTPGo stopped). The log's first line is `files:
Drive-style file list on`; `files: WARNING … serving SFTPGo's own file list` means the image's
file-list page is not the one the Drive behaviour was written against (a re-pin skipped
`ci/files-ui.sh`): everything still works, only clicks and previews are SFTPGo's own. `ssh admin@infra-host sudo docker logs sftpgo` shows sign-ins and transfers.

**Straight to S3.** Garage at `https://s3.home.arbikullakshi.com` (or `http://infra-host:3900`): S3-compatible storage, region `garage`, path-style
addressing, bucket `files`, over the tailnet only (plain http; Tailscale encrypts the link).
Objects are on the media disk (`/srv/media/s3`), the metadata on the SSD (`garage-meta`); the
nightly backup stops Garage and copies `garage-meta` and `/srv/media/s3` into the same snapshot, so the two match; a file deleted from the bucket stays in older snapshots for about two months.
`http://infra-host/files.html` (the Files tile) shows the same instructions.

The key is the one in 1Password; with rclone on the laptop:

```bash
rclone config create home s3 provider=Other endpoint=https://s3.home.arbikullakshi.com \
  region=garage force_path_style=true \
  access_key_id="$(op item get 'infra production secrets' --vault "Home Server" --fields label=GARAGE_OWNER_ACCESS_KEY_ID --reveal)" \
  secret_access_key="$(op item get 'infra production secrets' --vault "Home Server" --fields label=GARAGE_OWNER_SECRET_KEY --reveal)"
rclone copy ~/Documents/report.pdf home:files/
rclone ls home:files
rclone mount home:files ~/S3 --vfs-cache-mode writes     # optional: as a folder
```

Any S3 app works the same way (Cyberduck, S3 Files, FolderSync, …): S3-compatible, server
`infra-host`, port 3900, no TLS, path-style. `garage-setup` assigns the node's layout once,
imports your key (`garage-setup.env`) and gives it read, write and owner rights on `files` on
every release; `ssh admin@infra-host sudo docker logs garage-setup` shows what it did. More
buckets: add their names to `GARAGE_BUCKETS` in `stack/media/docker-compose.yml` and release.
Garage's own web UIs are not used (the one community UI has had no release in a year and would
need Garage's full admin token); the file manager above is the interface.

### Photos (Immich)

Immich at `https://photos.home.arbikullakshi.com` (the Photos tile) is the photo library: a timeline, albums,
a map, people (face recognition) and smart search ("beach at sunset"), on the GPU. The originals
are on the media disk under `/srv/media/photos/library/<user>/<year>/<year>-<month>-<day>/`,
its database on the SSD, and both reach the backup disk every night (the database dumped first,
then the photos copied without the thumbnails and encoded video Immich can rebuild) into a dated snapshot kept for about two months.

**First login**: `status_owner_email` from `production.yml` and the bootstrap password, then a new
password of your own (Immich insists; keep it in 1Password):

```bash
op item get "infra production secrets" --vault "Home Server" --fields label=IMMICH_ADMIN_PASSWORD --reveal
```

**The phone.** Install the Immich app (Play Store, F-Droid or the APK on Immich's GitHub
release), keep Tailscale on, and enter the server address `https://photos.home.arbikullakshi.com`. Sign in, then
**Backup** (the cloud icon) → pick the albums (Camera at least) → **Enable backup**; turn on
background backup in its settings. Once your photos are in Immich, switch off Google Photos'
own backup on the phone.

**Google Photos, once, from the laptop** with [immich-go](https://github.com/simulot/immich-go)
(pinned here to v0.32.0):

1. **Export**: <https://takeout.google.com> → *Deselect all* → tick **Google Photos** → *Next* →
   *Export once*, `.zip`, **50 GB** files (fewer parts) → *Create export*. Download every
   `takeout-*.zip` into one folder (about 26 GB here); don't unpack them.
2. **API key**: in Immich, your avatar → **Account Settings** → **API Keys** → **New API Key**,
   name `immich-go`, permissions **All** (it pauses Immich's jobs during the upload, which needs
   an admin's key). Copy it once into 1Password as "Immich API key (immich-go)".
3. **immich-go**, checked against the release's checksums:

   ```bash
   mkdir -p ~/.local/share/immich-go && cd ~/.local/share/immich-go
   v=v0.32.0
   curl -fsSLO "https://github.com/simulot/immich-go/releases/download/$v/immich-go_Linux_x86_64.tar.gz"
   curl -fsSLO "https://github.com/simulot/immich-go/releases/download/$v/checksums.txt"
   grep ' immich-go_Linux_x86_64.tar.gz$' checksums.txt | sha256sum -c - && tar -xzf immich-go_Linux_x86_64.tar.gz immich-go
   ```
4. **Upload** (resumable: run it again after an interruption and it skips what is already there):

   ```bash
   ~/.local/share/immich-go/immich-go upload from-google-photos \
     --server=https://photos.home.arbikullakshi.com \
     --api-key="$(op item get 'Immich API key (immich-go)' --vault "Home Server" --fields label=password --reveal)" \
     --concurrent-tasks=4 --client-timeout=60m --on-errors=continue --session-tag \
     ~/Downloads/takeout/takeout-*.zip
   ```

   It keeps Google's albums, dates and locations (from the JSON files next to each photo). Over
   the LAN the upload itself takes well under an hour; afterwards Immich spends some hours on
   thumbnails, faces and smart search (Administration → Jobs shows progress). Chats in Open WebUI
   are slower meanwhile: the GPU is shared.

Everything else is code: the settings (`IMMICH_CONFIG_JSON` in `stack/media/docker-compose.yml`)
show read-only in Administration → Settings; change them there in the repo and `release`.

### Copying media in

`admin` is in the `media` group, and the library folders are setgid `media` and
group-writable, so `admin` copies straight into them over the tailnet and the files stay
readable by the containers. From the laptop:

```bash
rsync -rtpvP --chmod=D2775,F664 ~/Videos/x admin@infra-host:/srv/media/movies/
rsync -rtpvP --chmod=D2775,F664 ~/Shows/Show\ Name admin@infra-host:/srv/media/shows/
rsync -rtpvP --chmod=D2775,F664 ~/Audiobooks/Author admin@infra-host:/srv/media/audiobooks/
rsync -rtpvP --chmod=D2775,F664 ~/Books/ admin@infra-host:/srv/media/books/
```

`-a` would also try to keep the laptop's owner and group, which `admin` cannot set; `-rtp`
with `--chmod` keeps the times and gives folders `2775` and files `664`. (The first `admin`
login after provisioning picks up the new group; an open SSH session does not.) Name things
the way the apps expect: `shows/Show Name (2019)/Season 01/Show Name S01E01.mkv`,
`movies/Film (2001)/Film (2001).mkv`, `audiobooks/Author/Book/…`. Jellyfin and Kavita notice
new files on their next scan (or **Scan library** now).

### Phones and TVs

Install Tailscale on the device (App Store / Play Store; Android TV and Apple TV have it too)
and sign in with the same account as the laptop, so it is one of `autogroup:admin`'s devices.
Then open `https://home.arbikullakshi.com/` (the links page) or the https names in the table
above. In the apps, use the https names as the server address:

- Immich: `https://photos.home.arbikullakshi.com`
- Jellyfin: `https://jellyfin.home.arbikullakshi.com`
- Audiobookshelf: `https://audiobooks.home.arbikullakshi.com`
- Kavita in the browser, or an OPDS reader with the OPDS link from Kavita's user settings (it
  starts with `https://books.home.arbikullakshi.com`)
- Open WebUI in the browser (`https://ai.home.arbikullakshi.com`; add it to the home screen)
- S3 apps: server `s3.home.arbikullakshi.com`, port 443, TLS on, path-style, region `garage`

The phone resolves these names through public DNS (the records point at the Tailscale address),
so Tailscale's own DNS setting does not matter. A device that is not on the tailnet gets
nothing, by design. Apps already set up with `http://infra-host:<port>` keep working; switch them
when convenient. A TV app that cannot use a name can still use the server's `100.x.y.z` address
(`tailscale ip -4 infra-host` on the laptop) with the old port.

## 13. CI runners for synis-ai

Four self-hosted GitHub Actions runners for `synis-ai/synis-ai` (`home-ci-1` … `home-ci-4`,
labels `self-hosted, linux, x64, synis`) run in an Incus system container, `ci-runners`, on this
host (roles/ci_runners, [docs/host.md](docs/host.md#ci-runners)). Jobs run repository code and
receive Synis's deploy secrets, so they never run on the host itself:

- **Unprivileged container**, Ubuntu 26.04, 4 CPUs, 8 GiB of memory with no swap (a hard cap,
  so CI can never take memory from the AI, Immich or Jellyfin), a 60 GiB btrfs disk image on
  the SSD (`/var/lib/incus`), nested Docker for the jobs' `services:` containers.
- **Its own NAT bridge, `incusbr-ci` (10.250.0.0/24), off the tailnet.** ci-runners-firewall
  lets it open connections to the internet only: not to the tailnet (100.64.0.0/10), the LAN,
  any private range (every Docker network) or the host. A TUN device lets deploy.yml bring its
  own Tailscale up inside a job; the host's tailscaled is out of reach.
- **Inside**: Docker Engine, Google Chrome (`google-chrome`), git, curl, unzip, xz-utils, jq,
  python3-yaml, build-essential, classic sudo without a password for the `runner` account; no
  Go or bun (the workflows' setup actions install them).
- **Every job starts clean**: a job-completed hook empties the runner's work directory (keeping
  only `_tool`) and prunes stopped containers, unused volumes, networks and dangling images; a
  job-started hook and the disk guard keep the disk under 80%; `ci-docker-prune.timer` runs
  `docker system prune` weekly (Sundays 04:30).

Provision (the laptop's `gh` must be logged in: it makes the one-hour registration token, which
goes to the container on stdin and is never written down):

```bash
git -C ~/Work/Personal/infra fetch -q && cd ~/.cache/infra-clean && git checkout -q --detach origin/master
ansible-playbook -u admin --ask-become-pass provision.yml --tags ci_runners
```

Expect the four runners online at the end (`gh api repos/synis-ai/synis-ai/actions/runners`)
and the read-back: caps, Docker, Chrome, the TUN device, disk, GitHub reachable and the host's
tailnet address not.

- **Switch the repository to them**: its workflows read `runs-on` from the `RUNS_ON` repository
  variable: `gh variable set RUNS_ON -R synis-ai/synis-ai --body '["self-hosted","linux","x64","synis"]'`.
- **Back to GitHub-hosted runners**: `gh variable delete RUNS_ON -R synis-ai/synis-ai`; every job
  falls back to `ubuntu-latest`.
- **More or fewer runners**: change `ci_runners_count` (roles/ci_runners/defaults/main.yml) and
  provision with `--tags ci_runners`. To remove one: stop it inside the container
  (`sudo incus exec ci-runners -- systemctl disable --now 'actions.runner.*.home-ci-4.service'`),
  delete it on GitHub (Settings → Actions → Runners), then
  `sudo incus exec ci-runners -- rm -rf /home/runner/runners/4`.
- **Re-register after a reset**: `sudo incus exec ci-runners -- rm /home/runner/runners/N/.runner`
  and provision again.
- **Inspect**: `sudo incus exec ci-runners -- bash`, `sudo incus info ci-runners` (memory and
  CPU use), `sudo incus exec ci-runners -- journalctl -u 'actions.runner.*' -f`.
- **Start over**: `sudo incus delete --force ci-runners`, delete the runners on GitHub, provision.
- **Resources**: CI is capped at 4 CPUs and 8 GiB, so the host keeps 8 GB for everything else.
  Avoid big AI jobs (a 14B model chat, image generation) during long CI runs: with both at their
  peak the AI can still be slowed by memory pressure, though never killed by CI.
