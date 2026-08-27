# The host

A single Hetzner box. Everything below is `roles/common` and `roles/docker`, tagged
`host` so it can be applied without redeploying any stack.

## Firewall

Default-deny inbound, allowing only **22, 80 and 443**. Outbound is unrestricted (image
pulls, Let's Encrypt, Resend).

This is the whole network story — no Tailscale, no Cloudflare, nothing else exposed. The
data services are never *published* to the host: PostgreSQL, Redis and Typesense exist
only on Docker networks, so they are unreachable from outside regardless of what ufw
says. The only Docker-published ports on the box are Traefik's.

Two implementation notes:

- **Order matters.** SSH is allowed *before* the firewall is enabled, so turning it on
  can never lock out the session doing it.
- The tasks use the `command` module with `changed_when: false`. ufw rules are already
  idempotent, so reporting them as changed on every run would make the run summary
  meaningless. `command` also keeps the repo free of collection dependencies.

## SSH

Authentication is by key. CI uses the deploy key; you use whichever of your own keys the
host trusts.

The deploy key's **public** half is committed at `roles/common/files/deploy_key.pub`.
Public halves are not secret, and committing it means a rebuilt host trusts CI without
anyone remembering to paste anything.

It is installed with `lineinfile` rather than the `authorized_key` module, which lives in
a collection this repo deliberately does not depend on. `lineinfile` creates a missing
*file* but not a missing *parent directory*, which is why `/root/.ssh` is created
explicitly first — on a rebuilt host it does not exist yet.

### Password authentication

Port 22 is open to the internet and takes roughly 5,500 failed password attempts a day.
The real fix is to stop answering them:

```bash
ansible-playbook playbook.yml --tags hardening -e ssh_password_authentication=no
```

**This is not durable.** `ssh_password_authentication` defaults to `"yes"` in
`roles/common/defaults/main.yml`, and the template is re-rendered on every run — so a
full deploy puts `PasswordAuthentication yes` back. To make it stick, change that
default.

It is left on by default because CI is the one client that cannot be repaired from a
terminal afterwards. Confirm a Deploy run has authenticated with the key before turning
it off.

The switch writes `/etc/ssh/sshd_config.d/10-hardening.conf`. **The number matters:**
Hetzner's cloud-init ships `50-cloud-init.conf` containing `PasswordAuthentication yes`,
and sshd keeps the **first** value it reads for a keyword. A higher number would lose.

Two safety properties in that task:

- `validate: sshd -t -f %s` — a malformed drop-in makes sshd refuse to start, and the
  reload would then take the only way in with it.
- The handler **reloads** rather than restarts, so established sessions survive and a
  mistake is still recoverable from the terminal that made it.

The Hetzner Cloud console is the backstop either way; it does not go through sshd.

## fail2ban

Bans an SSH source after repeated failures. Only the SSH jail is enabled — the web ports
are Traefik's, and it has a rate limiter of its own; banning at the firewall on HTTP
patterns would sooner or later ban a reader.

The tuning is deliberate and reads oddly at first glance:

- `bantime = 1d`, doubling (`bantime.factor = 2`) to a maximum of one week.
- `maxretry = 10` within `findtime = 10m`.

Ten rather than five, and a day rather than a week to start, for the same reason: a bot
burns through any threshold in seconds and earns the week on its second visit anyway,
while the one human who ever authenticates with a password here is doing it because
their key stopped working — the worst possible moment to be locked out for a week.

`ignoreip` covers loopback and the Docker bridge ranges. A container talking to the host
must not be able to lock the operator out.

## Patching

`unattended-upgrades` installs security updates but by default never reboots, so a
kernel update sits on disk while the old kernel keeps running. The box was 14 kernel
revisions behind at 63 days of uptime before this was added.

`/etc/apt/apt.conf.d/20auto-upgrades-reboot` sets a **04:00 reboot**, including when
someone is logged in — an SSH session left open is otherwise enough to defer a kernel
patch indefinitely. The reboot takes every site down for about a minute.

## The Docker daemon

Installed from Docker's own convenience script rather than the apt repository: one URL
that keeps working across Ubuntu releases, and the compose plugin comes with it.

`daemon.json` caps container logs at 30 MB each (3 × 10 MB). Without it the `json-file`
driver keeps every line a container has ever written; one crash-looping container fills
the disk, and PostgreSQL's data directory is on the same one.

Two things about how it applies:

- The handler **reloads** the daemon, never restarts it. `systemctl restart docker`
  takes every container on the host down with it; SIGHUP re-reads `daemon.json` in place
  and nothing stops.
- The limit applies to containers **created after** the daemon picks it up. Already
  running containers keep their current unbounded logs until they are next recreated.

## Memory limits

Every application container has a `mem_limit`. The stateful ones — PostgreSQL, Redis,
Typesense — deliberately do not.

That asymmetry is the point: bounding the applications is what stops a runaway from
making the kernel's OOM killer pick PostgreSQL, which every stack depends on. The
ceilings are 4–6× observed usage, so they catch a runaway and nothing else.

Retune if a container is killed in normal work:

```bash
docker inspect <name> --format '{{.State.OOMKilled}}'
```
