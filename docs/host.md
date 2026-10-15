# The host

A dedicated PC at the owner's home running Ubuntu Server (`ubuntu_release` in
`production.yml`, 26.04 LTS `resolute`), wired to a consumer router on the home LAN, with a
dynamic public IP that nothing depends on. Nothing on it is reachable from the internet: the
public arrives through the Cloudflare Tunnel, which dials out ([edge.md](edge.md)), and SSH
only over the tailnet. Everything below is provisioning: `roles/common`, `roles/tailscale`,
`roles/docker` and `roles/host`, run from the owner's laptop with `provision.yml`.

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

ufw denies inbound by default and allows only **22 on `tailscale0`**. There is no web port:
the Cloudflare Tunnel is an outbound connection. Outbound is unrestricted (image pulls,
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
Provisioning reads both chains back and stops if the hook is not first or a port is admitted.
The interface and ports come from `/etc/infra/host.env`.

The ufw tasks use the `command` module with `changed_when: false`: ufw rules are idempotent
already, and `command` keeps the repo free of collection dependencies.

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

`daemon.json`:

- caps container logs at 30 MB each (3 × 10 MB). Without it the `json-file` driver keeps
  every line a container has ever written, and one crash-looping container fills the disk.
  The limit applies to containers created after the daemon picks it up.
- sets **`live-restore`**, so containers keep running while the daemon itself restarts (an
  Engine package update).

The handler **reloads** the daemon, never restarts it: `systemctl restart docker` would stop
every container; SIGHUP re-reads `daemon.json` in place.

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
