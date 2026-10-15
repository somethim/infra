# The host

A dedicated PC at the owner's home running Ubuntu Server (`ubuntu_release` in
`production.yml`, 26.04 LTS `resolute`), wired to a consumer router on the home LAN, with a
dynamic public IP that nothing depends on. Nothing on it is reachable from the internet: the
public arrives through the Cloudflare Tunnel, which dials out ([edge.md](edge.md)), and SSH
only over the tailnet. Everything below is provisioning: `roles/common`, `roles/tailscale`,
`roles/docker`, `roles/gpu` and `roles/host`, run from the owner's laptop with `provision.yml`.

## SSH: Tailscale only

SSH is reachable only over the tailnet. The server joins it as `infra-host` with the tag
`tag:infra-server`; the Tailscale policy lets only tailnet admins and the CI tag
`tag:infra-ci` reach it, on tcp 22 only ([RUNBOOK.md](../RUNBOOK.md#4-tailscale)). OpenSSH with
keys stays the login: Tailscale SSH, Tailscale DNS and accepted routes are off
(`--ssh=false --accept-dns=false --accept-routes=false`), set on every run.

### Accounts

| Account | Login | Can do |
| --- | --- | --- |
| `admin` | the owner's keys, copied once from the installer's account on the first run | sudo, with a password (`--ask-become-pass`); the password also logs in at the local console |
| `deploy` | one root-owned line: `restrict,command="/usr/local/sbin/infra-deploy-gate" <CI key>` | `sudo -n infra-apply release` or `status`, nothing else |
| the installer's account (`setup`) | the owner's key, installed with `ssh-copy-id`; exists only between the first and the second run | sudo with its password; used by the bootstrap run only |
| `root` | never (`PermitRootLogin no`, and Ubuntu leaves root's password locked) | — |

#### The bootstrap

A fresh Ubuntu Server install has one account, the one the installer created, with sudo
through the `sudo` group and SSH with a password. The first run of `provision.yml` logs in as
that account over the LAN (`-u setup --ask-become-pass`, `ansible_host` = the LAN address);
`tasks/provision-checks.yml` calls it the **bootstrap run** (the login is not `admin`; `root`
and `deploy` are refused outright). It:

1. requires the account's `authorized_keys` to hold only plain public keys (no options, never
   the CI key), and copies them once to `admin`;
2. records the account's name in `/etc/infra/bootstrap-user`;
3. at the end, logs in as `admin` with those keys (`id -un` with `ansible_user: admin`) before
   it turns password login off, and stops if that fails.

The owner then sets `admin`'s password and runs provisioning as `admin` over the tailnet. That
run (and any later one) requires `admin` to have a password, removes the recorded installer
account with its home directory (`userdel --remove --force`, never `root`, `admin`, `deploy` or
the account the run itself uses), and forgets the record. From then on `admin` is the only
interactive account.

`admin` and `deploy` are created with a locked password; the owner sets `admin`'s, for sudo
and the local console only (sshd accepts keys alone). `deploy` belongs to no group but its own
(not `docker`). Provisioning reads `sudo -l` back for both and stops if `admin` has a
`NOPASSWD` rule or `deploy` has anything but its one rule — a cloud image's
`/etc/sudoers.d/90-cloud-init-users` or the `sudo` group would add more. It also stops if the
installer's account or `admin` trusts the CI key, or if `deploy`'s file is not exactly that
line, owned by root.

The CI key's public half is committed at `roles/common/files/deploy_key.pub`; provisioning
and the release render refuse to run while it is still the placeholder.

### sshd policy

`ssh_access.yml` runs last on every provision, whatever the tags, and writes
`/etc/ssh/sshd_config.d/10-hardening.conf`:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
ExposeAuthInfo yes
```

**The number matters.** sshd keeps the **first** value it reads for a keyword, and the Ubuntu
installer's cloud-init writes `50-cloud-init.conf` with `PasswordAuthentication yes` when you
allow password login over SSH during the install; `10-` sorts before it. Provisioning also
deletes that file.

Safety properties of that step:

- Password login closes only after `admin` has logged in with the copied keys (on the
  bootstrap run); the installer's account goes only on a run that `admin` itself logs in to
  and has a sudo password for.
- `validate: sshd -t -f %s` on the file and `sshd -t` on the whole configuration — a
  malformed drop-in would make sshd refuse to start, and the reload would take the only way
  in with it.
- The handler **reloads** rather than restarts, so established sessions survive.
- `sshd -T` is read back afterwards; if another file overrides the policy, the run stops.

The server's own keyboard and monitor are the backstop either way: the local console goes
through neither sshd nor the tailnet, and takes `admin`'s password.
[RUNBOOK.md](../RUNBOOK.md#locked-out) has the procedure.

## Firewall

ufw denies inbound by default and allows only **22 and the tailnet-only ports (80, 5000, 8080,
8096, 13378) on `tailscale0`** (`ufw_allowed`). There is no public web port (80 is the tailnet-only links page): the Cloudflare Tunnel is an outbound
connection. Outbound is unrestricted (image pulls,
Cloudflare, Resend, Tailscale, NTP). The router forwards no port to the host, so even LAN 22
is unreachable from the internet.

LAN 22 is lockout-safe: a run that did not come in over the tailnet (the bootstrap, over the
LAN) adds `ufw allow 22/tcp` and says so at the end; a run that came in over the tailnet
deletes it. "Over the tailnet" means positive evidence only: the server address in the run's
own `SSH_CONNECTION` is a Tailscale address (`100.64.0.0/10` or `fd7a:115c:a1e0::/48`,
`tasks/ssh-route.yml`, the `ssh_outside_tailnet` fact). A run over the LAN address, any other
IPv4 or IPv6, or one whose `SSH_CONNECTION` cannot be read, keeps 22 open. No run can cut the
session it runs in, and LAN 22 closes only once the tailnet has been proven by a run over it.

ufw does not see Docker's published ports, which are NAT rules. `roles/host` installs
`/usr/local/sbin/infra-firewall` and `infra-firewall.service`, which run after every Docker
start: they build a chain `INFRA-PUBLIC` that lets new connections on the LAN-facing
interface (`PUBLIC_INTERFACE`, the default route's) reach only `public_ports` — **none** on
this host, `public_ports: []` — and drops the rest, and hook it first in Docker's
`DOCKER-USER` chain. So every new connection from the LAN (or the internet, were a port ever
forwarded) to any container is dropped, even if a container published a port by mistake.
A second hook sends every new connection that Docker destination-NATed to a published port
(conntrack state `DNAT`) and that did not come in on `tailscale0` (`TAILNET_INTERFACE`) through
the same chain, so the tailnet-only ports answer only on the tailnet, whatever other interface
(Wi-Fi, a second NIC, a LAN host routing to the Tailscale address) a packet arrives on.
Provisioning reads both chains back and stops if the hooks are not first and second or a port
is admitted. The interfaces and ports come from `/etc/infra/host.env`.

The tailnet-only ports are bound to the Tailscale IPv4 (`TAILSCALE_IP` in `host.env`, read with
`tailscale ip -4` on every run). At boot Docker may start its containers before `tailscaled`
has brought that address up, so `/etc/sysctl.d/62-infra-tailnet-bind.conf` sets
`net.ipv4.ip_nonlocal_bind = 1` and the bind succeeds anyway; provisioning reads the setting
back. It also lists every port any container publishes (`docker ps`) and stops on one that is
not an allowlisted container's own port on that address. The node's Tailscale address stays
the same for as long as the node exists; if the server ever re-joins the tailnet as a new
node, run provisioning (it rewrites `host.env`) and then `release` (it re-binds the ports).

The ufw tasks use the `command` module with `changed_when: false`: ufw rules are idempotent
already, and `command` keeps the repo free of collection dependencies.

## Service accounts and their volumes

The hardened stacks never run as root. `roles/host` creates a system account per stack with a
fixed uid and gid from `production.yml` (`ai`: `ai_uid`/`ai_gid`, `2001`; `media`:
`media_uid`/`media_gid`, `2000`), no login shell, no home and a locked password, and writes them
to `host.env` (`AI_USER=2001:2001`, `MEDIA_USER=2000:2000`); the compose guard refuses an `ai`
or `media` service that runs as anything else. `admin` is in the `media` group, so it can copy
files into the library.

Their data lives in volumes provisioning creates (`ollama-models`, `open-webui-data`,
`jellyfin-config`, `jellyfin-cache`, `audiobookshelf-config`, `audiobookshelf-metadata`,
`kavita-config`), external
to the stacks like `pgdata-v18`, so a release can never create an empty one in its place. Each
volume's root is handed to its account, mode 0700, on every run; the stacks mount them with
`nocopy`, because Docker otherwise copies the image's directory, root ownership included, onto
an empty volume the first time it is mounted.

## Disks

| Disk | Mounted at | `production.yml` | Holds |
| --- | --- | --- | --- |
| 225 GB SSD | `/` | — | Ubuntu, Docker's data root (images, every volume: PostgreSQL, app configs, Ollama's models), swap |
| 1 TB internal HDD | `/srv/media` | `media_disk_uuid` | the library: `shows`, `movies`, `audiobooks`, `podcasts`, `books` |
| 1 TB external USB HDD | `/srv/backup` | `backup_disk_uuid` | the nightly backup ([operations.md](operations.md#backups)) |

`roles/host/tasks/disks.yml` mounts each HDD by its **filesystem UUID** (never `/dev/sdX`,
which can change between boots, least of all for USB), ext4, with
`nofail,x-systemd.device-timeout=10s,noatime,nodev,nosuid,noexec`: a missing disk costs the
boot at most ten seconds and never drops it into emergency mode, and nothing on either disk
can be executed or act as a device node. An empty UUID skips that disk with a message (the
library then lives on the SSD; the backup writes nothing). A UUID that is set but not attached
stops provisioning for the library disk and only warns for the backup disk, which may well be
unplugged.

While a configured disk is **not** mounted its mountpoint is an empty directory with the
immutable attribute (`chattr +i`), so nothing can be written there: the media containers,
whose library folders then do not exist, fail to start rather than serve or rescan an empty
library, and the backup cannot fill the SSD. A drop-in orders Docker after
`srv-media.mount` at boot. Provisioning reads back which filesystem is mounted where, and
creates the library folders as `media:media`, mode `2775` (setgid, group-writable: what
`admin` copies in stays in the `media` group), and the backup folders as `root`, `0700`. It
refuses to mount over a mountpoint that has files of its own (they would vanish under the
disk) and names the fix. Formatting and finding the UUIDs is in
[RUNBOOK.md](../RUNBOOK.md#disks).

## fail2ban

Bans an SSH source after repeated failures. Only the SSH jail is enabled — the web ports are
Traefik's, and banning at the firewall on HTTP patterns would sooner or later ban a reader.

- `bantime = 1d`, doubling (`bantime.factor = 2`) to a maximum of one week.
- `maxretry = 10` within `findtime = 10m`.

`ignoreip` covers loopback, the Docker bridge ranges and the tailnet (`100.64.0.0/10`): a
container talking to the host, or the owner on the tailnet, must not be able to lock the
operator out. With LAN 22 closed after the second provision, a ban can only happen during the
bootstrap; the console unbans (`fail2ban-client set sshd unbanip <ip>`).

## Patching

`unattended-upgrades` (installed and switched on by `/etc/apt/apt.conf.d/20auto-upgrades`)
installs security updates every day but by default never reboots, so a kernel update sits on
disk while the old kernel keeps running.
`/etc/apt/apt.conf.d/20auto-upgrades-reboot` sets a reboot at **`reboot_time`** (`04:00`,
`production.yml`), including when someone is logged in — an SSH session left open is
otherwise enough to defer a kernel patch indefinitely. The clock is kept on UTC, the clock that
time is read in (04:00 UTC is 05:00 or 06:00 in Central Europe). The reboot takes every site
down for about a minute; the containers and the tunnel come back by themselves
(`restart: always`).

## Time

`chrony` keeps the clock in sync (Ubuntu's default time daemon since 25.10; installing it
replaces `systemd-timesyncd`). TLS to Cloudflare, the tunnel's authentication and TOTP all
need a correct clock.

## Power

A home server must stay on. `roles/host/tasks/power.yml`:

- masks `sleep.target`, `suspend.target`, `hibernate.target`, `hybrid-sleep.target` and
  `suspend-then-hibernate.target`, so nothing (a desktop idle policy, a key, a stray
  `systemctl suspend`) can put it to sleep; provisioning reads them back as `masked`;
- writes `/etc/systemd/logind.conf.d/50-infra-server.conf`: the lid switch (on every power
  source), the suspend and hibernate keys, and idleness are ignored. logind reads it at boot;
  the masked targets already block sleep before then.

Coming back after a power cut is a firmware setting ("Restore on AC power loss: Power On"),
which provisioning cannot make ([RUNBOOK.md](../RUNBOOK.md#2-bios)). After a reboot,
Docker, the stacks, Tailscale and the tunnel all start by themselves.

## journald and swap

- The journal is capped (`/etc/systemd/journald.conf.d/50-infra.conf`: 500 MB on disk, 32 MB
  files, one month), so it cannot fill the disk PostgreSQL's data lives on.
- A swap file of `swap_size` (`2G`) is created only when the host has no swap, with
  `vm.swappiness = 10`; provisioning stops if the host has less than 1 GiB of swap. The Ubuntu
  installer usually creates `/swap.img` already, which counts. Swap is for a memory spike, not
  for steady use.

## The Docker daemon

Installed from **Docker's own apt repository** for `ubuntu_release`, its signing key pinned by
checksum, and the Engine held to **`docker_engine_major`** by an apt pin
(`/etc/apt/preferences.d/docker`, `5:<major>.*`). The pin is written by
`roles/docker/tasks/pin.yml`, which `roles/common` runs before its `apt upgrade` (the first
apt operation of a provision), so even the first run on a host that already has Docker from
Docker's repository upgrades only within the pinned major. Provisioning refuses to run when the
installed Engine has another major, so a major upgrade is a deliberate edit of
`production.yml`, never a side effect of `apt upgrade`. `ci/check_access.py` (rule 8) fails if
any apt task that upgrades or installs Docker runs before the pin.

`daemon.json` is rendered whole from `roles/docker/templates/daemon.json.j2`, with the `nvidia`
runtime when `gpu_enabled` ([The GPU](#the-gpu)), so no other tool (such as `nvidia-ctk runtime
configure`) edits it and no setting is lost on the next run:

- caps container logs at 30 MB each (3 × 10 MB). Without it the `json-file` driver keeps
  every line a container has ever written, and one crash-looping container fills the disk.
  The limit applies to containers created after the daemon picks it up.
- sets **`live-restore`**, so containers keep running while the daemon itself restarts (an
  Engine package update).

The handler **reloads** the daemon, never restarts it: `systemctl restart docker` would stop
every container; SIGHUP re-reads `daemon.json` in place.

## The GPU

An NVIDIA RTX 2060 with 12 GB. `roles/gpu` runs after `roles/docker` when `production.yml`
sets `gpu_enabled: true` (with `false` it only says so and touches nothing):

- **The driver** is Ubuntu's, the server branch `nvidia_driver_major` pins (`580`), installed
  with apt (`nvidia-driver-<major>-server` and `linux-modules-nvidia-<major>-server-generic`): the headless driver and
  Canonical's **signed, precompiled kernel modules**, so it loads with Secure Boot on and needs
  no DKMS build or MOK enrolment. The role first checks that `ubuntu-drivers list --gpgpu`
  offers that branch, and stops naming the ones it does offer otherwise. It also installs
  `nvidia-utils-<major>-server` (`nvidia-smi`) and the `libnvidia-encode`/`libnvidia-decode`
  libraries Jellyfin's NVENC/NVDEC need. Package names carry the branch, so `apt upgrade` and
  unattended-upgrades only ever bring updates within it; a new branch is a deliberate edit of
  `production.yml`.
- **The NVIDIA Container Toolkit** comes from NVIDIA's apt repository
  (`nvidia.github.io/libnvidia-container`), its signing key pinned by sha256 in
  `roles/gpu/defaults/main.yml`, like Docker's and Tailscale's. Containers get the GPU through a
  Compose device reservation (`driver: nvidia`, `capabilities: [gpu]`), which uses the toolkit's
  hook; `daemon.json` also registers the `nvidia` runtime (not as the default), which `docker
  info` shows.
- **No reboot.** A driver installed or updated in a run is not loaded until the next boot (a
  fresh Ubuntu may even have `nouveau` loaded). Provisioning then prints "The NVIDIA driver was
  installed or updated since the last boot and is not loaded yet … Reboot when it suits you" instead of
  failing, and the next run (`--tags gpu`) requires `nvidia-smi` to answer. Unattended-upgrades
  can update the driver within the branch; until the 04:00 reboot it schedules, `nvidia-smi`
  reports "Driver/library version mismatch" and a GPU container that restarts in that window
  cannot start. Provisioning names both cases.

Read back on every run: `docker info` lists the `nvidia` runtime, and `nvidia-smi` names the
card. To change the key pin: download `https://nvidia.github.io/libnvidia-container/gpgkey`,
check its fingerprint (`gpg --show-keys`: `C95B 321B 61E8 8C18 09C4 F759 DDCA E044 F796 ECB0`,
NVIDIA's published one), and put its `sha256sum` in the defaults.

## Memory limits

Every application and agent container has a `mem_limit`. The stateful one — PostgreSQL —
deliberately does not.

That asymmetry is the point: bounding the others is what stops a runaway from making the
kernel's OOM killer pick PostgreSQL, which every stack depends on. The ceilings are 4–6×
observed usage, so they catch a runaway and nothing else.

Retune if a container is killed in normal work:

```bash
sudo docker inspect <name> --format '{{.State.OOMKilled}}'
```
