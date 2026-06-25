# infra — shared host provisioning + edge proxy

The **one** pipeline that prepares the shared Hetzner box and runs the single Traefik
edge proxy for every app co-hosted on it (currently `crm` and `prizm-lodge`). Ansible,
manually triggered from GitHub Actions.

Run this **first** — once per server, and again after a server/IP swap. The app repos
(`crm`, `prizm-lodge`) deploy their own stacks afterward and attach to the networks
this creates.

## What it does

1. **common** — base packages + a **strict default-deny firewall** (`ufw`). Only ports
   **22 / 80 / 443** are reachable; everything else is dropped. No Tailscale, no
   Cloudflare — the lockdown is the whole story. Data services (Postgres/Redis/Typesense)
   are never published to the host, so they stay unreachable regardless.
2. **docker** — Docker Engine + compose plugin.
3. **edge** — creates the shared `edge` (Traefik routing) and `data` (shared Postgres)
   Docker networks, then brings up Traefik on 80/443 with a single Let's Encrypt account
   (**HTTP-01** challenge).

> TLS uses the Let's Encrypt **HTTP-01** challenge, so the app domains must resolve
> **directly to this host** (plain A records at the server IP — no proxy in front, or the
> port-80 challenge can't reach Traefik).

## Run it

GitHub → **Actions → "Provision host + edge" → Run workflow**.

Required repo secrets:

| Secret | Meaning |
| --- | --- |
| `SERVER_HOST` | Public IP of the shared host — **the one place the IP lives in this repo** |
| `SERVER_PASSWORD` | Root SSH password |
| `SERVER_USER` | *(optional)* SSH user, defaults to `root` |

The Let's Encrypt email is baked in (`contact@arbikullakshi.com`, in
`roles/edge/defaults/main.yml`) — not a secret.

Local equivalent:

```bash
cp inventory/hosts.example inventory/hosts   # edit the IP
ansible-playbook playbook.yml --ask-pass
```

## Deploy order on a fresh / swapped server

1. Update `SERVER_HOST` (here) + `TF_VAR_server_host` in **crm** and **prizm-lodge**.
2. **infra** → run this provision workflow.
3. **crm** → run its deploy workflow (brings up shared Postgres; auto-bootstraps the
   `prizm` role + database on first init).
4. **prizm-lodge** → run its deploy job (provider connects to `crm-pgsql`/`prizm`).
5. Point DNS (`crm.arbikullakshi.com`, `hypernova.arbikullakshi.com`) at the new IP.

## Adding another project later

Nothing changes here. The new app just:
- attaches its public container to the external `edge` network and adds Traefik labels
  (`Host(...)`), and attaches to `data` if it needs the shared Postgres;
- gets a DNS record pointing at the host.

Traefik discovers it automatically via Docker labels — no edge config edit, no redeploy
of this stack.
