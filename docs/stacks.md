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
