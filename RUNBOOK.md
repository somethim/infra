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
   `tag:infra-server`. Admins (you) and the CI runners reach the server on tcp 22 only;
   OpenSSH, not Tailscale SSH, is the login:

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
op item create --category password --vault Personal --title "Cloudflare tunnel token (home-server)" \
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
gh secret set CF_TUNNEL_TOKEN --env production                     # paste the token (eyJ...)

# GHCR: an account and a classic token with read:packages that can read
# ghcr.io/somethim/portfolio and the ghcr.io/hypernova3643725 images
gh variable set GHCR_USERNAME --env production --body '<github user>'
gh secret set GHCR_TOKEN --env production                          # paste the token

# Database: three different passwords, 48 hex characters each; nobody needs to know them
for name in POSTGRES_SUPERUSER_PASSWORD PRIZM_DB_PASSWORD PORTFOLIO_DB_PASSWORD; do
  gh secret set "$name" --env production --body "$(openssl rand -hex 24)"
done

# Apps: generated secrets
gh secret set PORTFOLIO_TOTP_ENCRYPTION_KEY --env production --body "$(openssl rand -base64 32)"
gh secret set HYPERNOVA_SESSION_SECRET --env production --body "$(openssl rand -hex 24)"

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
ssh admin@infra-host sudo ufw status            # Status: active; 22/tcp on tailscale0, nothing else
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
infra-apply: bundle accepted: 14 files, manifest checksums match
infra-apply: Watchtower is stopped until the app stacks are up
infra-apply: pulling images
infra-apply: starting the database
infra-apply: database roles, passwords and grants are in place
infra-apply: starting portfolio
infra-apply: starting hypernova
infra-apply: starting tunnel
infra-apply: Watchtower is running again
infra-apply: every container is running and healthy, and has run for at least 30s without a restart
infra-apply: Traefik routes arbikullakshi.com/api/health www.arbikullakshi.com/ hypernova.arbikullakshi.com/ hypernova.arbikullakshi.com/api/health to their apps
infra-apply: the Cloudflare Tunnel is connected (cloudflared /ready answers 200)
infra-apply: Traefik, Watchtower and autoheal reach Docker through their socket proxies with no refused calls
infra-apply: RELEASE OK: <id> is current, following :latest, auto-updates on
```

PostgreSQL initialises the empty `pgdata-v18` volume on this first start, and `provision.sql`
creates the `prizm` and `portfolio` roles and databases; the apps create their schemas. The
portfolio can take up to 180 s to report healthy. In the Cloudflare dashboard the tunnel now
shows **Healthy** with connections.

The smoke step that follows checks the hostnames through Cloudflare. Until section 10 they
still resolve to the old server, so a green smoke step here proves nothing about this one; a
red one only means the old server is down. Section 10 ends with a second `release` whose
smoke step proves the new path.

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
3. **Run `release` again** (Actions → Deploy, action `release`). Its smoke step now goes
   through the tunnel: `OK 200` for `https://arbikullakshi.com/api/health`,
   `https://hypernova.arbikullakshi.com/` and its `/api/health`, `OK 301` for `www.` and for
   `http://arbikullakshi.com/api/health`.
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

### More recipes

PostgreSQL access, disk, backups, a major PostgreSQL upgrade, Watchtower and a hung site are
in [docs/operations.md](docs/operations.md).
