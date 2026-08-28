# The application stacks

What is peculiar about each one. The mechanics they share are in
[architecture.md](architecture.md).

## crm

Laravel provider plus a Next.js BFF, with Redis and Typesense of its own.

Only `web` is exposed to Traefik. `app` (Laravel) is internal-only and reached at
`http://app:8080` from the BFF — there is no public route to it, which is why it can sit
on the `edge` network without `traefik.enable`.

Redis and Typesense are **not** shared with anything and stay in this stack. Moving them
alongside PostgreSQL would create the same coupling the database split removed, in the
opposite direction.

Two non-obvious settings:

- `web` sets `HOSTNAME: "0.0.0.0"`. Next.js standalone binds to `$HOSTNAME`, and Docker
  sets that to the container id, which resolves to only **one** of the container's two
  network addresses. Without the override Traefik may be unable to reach it.
- `worker` disables its healthcheck. The image bakes a probe against the web port's
  `/up`, which the queue worker does not serve, so the container would sit permanently
  `unhealthy` — and, if it were ever labelled, be restarted forever by autoheal.

`app` and `worker` are on the `data` network for PostgreSQL. They cannot declare
`depends_on` for it; see [architecture.md](architecture.md#deploy-order).

## hypernova

One hostname serves both halves: the web app at `/` and the provider's API at `/api`,
split by router priority with a `stripprefix` middleware. See [edge.md](edge.md#priorities).

The provider connects to PostgreSQL with its own `prizm` role. The role name predates the
stack name — `prizm-lodge` was the original project — which is why the container names,
the database, and the role all say `prizm` while the stack says `hypernova`.

## portfolio

A Rust/Leptos server rather than a static site, so it carries state the other stacks do
not.

**The `portfolio-media` volume** holds uploads and the previews generated beside them. It
is the only application state outside PostgreSQL, and the `media` table is a ledger of
what is on it — the two must be backed up and restored together. See
[operations.md](operations.md#backups).

**A 180-second healthcheck grace.** The image carries the same probe, but on a first boot
the container applies migrations and seeds roughly 70 MB of media, generating a preview
for each. The image's 15-second grace is not enough, and without the override the
container would be killed mid-seed and start again from the beginning.

**`WEBAUTHN_ORIGIN` is load-bearing.** Passkeys are bound to that exact origin. Change it
and every enrolled credential stops working — there is no migration path, only
re-enrolment. It is also the base for links in outgoing mail.

**`CLIENT_IP_SOURCE=Cloudflare`** reads Cloudflare's authenticated `CF-Connecting-IP`
header instead of selecting an address from `X-Forwarded-For`. The public request reaches
Traefik through Cloudflare, so the rightmost forwarded address is a Cloudflare edge (and
was incorrectly reported as the visitor). This also keys the rate limiter by the actual
visitor instead of the edge proxy.

**Mail is optional.** Without `RESEND_API_KEY` the site still runs: contact messages and
comments are recorded and only the notifications are skipped and logged. The `From`
domain must be verified in Resend or every send is rejected.

The operator account is seeded on first boot against an empty database, because the site
has no signup path — without it nobody can sign in.

### The legacy site

`legacy.arbikullakshi.com` served a preserved Next.js portfolio from a second tag of the
same GHCR package. It was retired in August 2026: the DNS record, the container, the
image and the stack entry are all gone. Its certificate remains in `acme.json` and is
inert — Traefik does not renew what no router references.
