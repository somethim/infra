# The host

A single Hetzner box running Ubuntu (`ubuntu_release` in `production.yml`). Everything below
is provisioning: `roles/common`, `roles/tailscale`, `roles/docker` and `roles/host`, run from
the owner's machine with `provision.yml`.

## SSH: Tailscale only

SSH is reachable only over the tailnet. The server joins it as `infra-host` with the tag
`tag:infra-server`; the Tailscale policy lets only tailnet admins and the CI tag
`tag:infra-ci` reach it, on tcp 22 only ([RUNBOOK.md](../RUNBOOK.md#4-tailscale)). OpenSSH with
keys stays the login: Tailscale SSH, Tailscale DNS and accepted routes are off
(`--ssh=false --accept-dns=false --accept-routes=false`), set on every run.

### Accounts

| Account | Login | Can do |
| --- | --- | --- |
| `admin` | the owner's keys, copied once from root's `authorized_keys` on the first run | sudo, with a password (`--ask-become-pass`) |
| `deploy` | one root-owned line: `restrict,command="/usr/local/sbin/infra-deploy-gate" <CI key>` | `sudo -n infra-apply release` or `status`, nothing else |
| `root` | keys, only while a provisioning run itself logs in as root | the Hetzner web console takes its password |

Both are created with a locked password; the owner sets `admin`'s, for sudo only (sshd
accepts keys alone). `deploy` belongs to no group but its own (not
`docker`). Provisioning reads `sudo -l` back for both and stops if `admin` has a `NOPASSWD`
rule or `deploy` has anything but its one rule — a cloud image's
`/etc/sudoers.d/90-cloud-init-users` or the `sudo` group would add more. It also stops if root
or `admin` trusts the CI key, or if `deploy`'s file is not exactly that line, owned by root.

The CI key's public half is committed at `roles/common/files/deploy_key.pub`; provisioning
and the release render refuse to run while it is still the placeholder. The CI key root
trusted before this layout (`legacy_ci_deploy_key` in `production.yml`) is removed from root
on the first run.

### sshd policy

`ssh_access.yml` runs last on every provision, whatever the tags, and writes
`/etc/ssh/sshd_config.d/10-hardening.conf`:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no            (prohibit-password while the run itself logs in as root)
ExposeAuthInfo yes
```

**The number matters.** sshd keeps the **first** value it reads for a keyword, and Hetzner's
cloud-init ships `50-cloud-init.conf` with `PasswordAuthentication yes`; `10-` sorts before
it. Provisioning also deletes that file.

Safety properties of that step:

- Root login closes only after `admin` has logged in with the copied keys (on the root run)
  and has a sudo password (on the admin run). The first run therefore leaves root at
  `prohibit-password`; the second, as `admin`, sets `no`.
- `validate: sshd -t -f %s` on the file and `sshd -t` on the whole configuration — a
  malformed drop-in would make sshd refuse to start, and the reload would take the only way
  in with it.
- The handler **reloads** rather than restarts, so established sessions survive.
- `sshd -T` is read back afterwards; if another file overrides the policy, the run stops.

The Hetzner Cloud web console is the backstop either way; it does not go through sshd.
[RUNBOOK.md](../RUNBOOK.md#10-locked-out) has the procedure.

## Firewall

ufw denies inbound by default and allows only **22 on `tailscale0`, 80 and 443**. Outbound
is unrestricted (image pulls, Let's Encrypt, Resend, Tailscale).

Public 22 is lockout-safe: a run that did not come in over the tailnet (the first one, over the public address) adds
`ufw allow 22/tcp` and says so at the end; a run that came in over the tailnet deletes it.
"Over the tailnet" means positive evidence only: the server address in the run's own
`SSH_CONNECTION` is a Tailscale address (`100.64.0.0/10` or `fd7a:115c:a1e0::/48`,
`tasks/ssh-route.yml`). A run over the public IPv6, a Floating IP or any other address, or one
whose `SSH_CONNECTION` cannot be read, counts as public and keeps 22 open.
No run can cut the session it runs in, and the public port closes only once the tailnet has
been proven by a run over it.

ufw does not see Docker's published ports, which are NAT rules. `roles/host` installs
`/usr/local/sbin/infra-firewall` and `infra-firewall.service`, which run after every Docker
start: they build a chain `INFRA-PUBLIC` that lets new connections on the public interface
reach only `public_ports` (80 and 443) and drops the rest, and hook it first in Docker's
`DOCKER-USER` chain. Provisioning reads both chains back and stops if the hook is not first or
the ports differ. The interface and ports come from `/etc/infra/host.env`.

The ufw tasks use the `command` module with `changed_when: false`: ufw rules are idempotent
already, and `command` keeps the repo free of collection dependencies.

## fail2ban

Bans an SSH source after repeated failures. Only the SSH jail is enabled — the web ports are
Traefik's, and banning at the firewall on HTTP patterns would sooner or later ban a reader.

- `bantime = 1d`, doubling (`bantime.factor = 2`) to a maximum of one week.
- `maxretry = 10` within `findtime = 10m`.

`ignoreip` covers loopback, the Docker bridge ranges and the tailnet (`100.64.0.0/10`): a
container talking to the host, or the owner on the tailnet, must not be able to lock the
operator out. With public 22 closed, a ban matters only during the cut-over window.

## Patching

`unattended-upgrades` installs security updates but by default never reboots, so a kernel
update sits on disk while the old kernel keeps running.
`/etc/apt/apt.conf.d/20auto-upgrades-reboot` sets a reboot at **`reboot_time`** (`04:00`,
`production.yml`), including when someone is logged in — an SSH session left open is
otherwise enough to defer a kernel patch indefinitely. The clock is kept on UTC, the clock that
time is read in. The reboot takes every site down for about a minute.

## journald and swap

- The journal is capped (`/etc/systemd/journald.conf.d/50-infra.conf`: 500 MB on disk, 32 MB
  files, one month), so it cannot fill the disk PostgreSQL's data lives on.
- A swap file of `swap_size` (`2G`) is created only when the host has no swap, with
  `vm.swappiness = 10`; provisioning stops if the host has less than 1 GiB of swap. Swap is
  for a memory spike, not for steady use.

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
