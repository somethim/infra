# The edge proxy

One Traefik container, `edge-traefik` (`traefik:v3.7.13`, pinned by digest), owns ports 80
and 443 for the whole host and routes by `Host()` header to whichever stack claims that
domain. It is the `edge` compose project in `/opt/edge`, installed by `roles/edge` at
provision time; releases never change it.

## The socket proxy

Traefik never sees the Docker socket. It reads container labels through `edge-socket-proxy`
(`wollomatic/socket-proxy`, pinned), on an internal network of their own (`edge-socket`).
The proxy mounts the socket read-only, accepts connections only from `traefik`, and allows
only `GET` of `_ping`, `version`, the container list, a container's JSON and `events` (plus
`HEAD _ping`). Everything else is refused and logged as `blocked request`.

Provisioning and every release check that the proxy is running and has refused none of
Traefik's calls since it started. A Traefik upgrade that needs another endpoint shows up
there first; widen the `-allowGET` rule in `roles/edge/files/docker-compose.yml` to exactly
what the log names.

## Routing by label

Traefik reads its configuration from Docker labels on the containers themselves
(`--providers.docker`, through the socket proxy), scoped to the `edge` network. An application declares its own
routing in its own compose file, and **adding a project requires no change to the edge
role**.

`--providers.docker.exposedbydefault=false` means a container is invisible to Traefik
until it opts in with `traefik.enable=true`. That is why a container can sit
on the `edge` network without being publicly reachable.

`traefik.docker.network=edge` is set on every routed container because several of them
are attached to more than one network. Without it Traefik may pick the wrong address.

### Conventions an app stack must follow

- Router names must be **unique across the whole host**, not just within the stack. They
  share one namespace. Prefixing with the stack name (`portfolio-www`, `hypernova-web`)
  is enough.
- Set `traefik.http.services.<name>.loadbalancer.server.port` explicitly. Traefik guesses
  otherwise, and guesses wrong on images that expose several ports.
- Attach the container to `edge`.
- Add `traefik.http.routers.<name>.middlewares=cloudflare-only@file` (first in the list,
  ahead of any other middleware) to every router. All three app domains are
  Cloudflare-proxied, and the portfolio stack trusts the `Cf-Connecting-Ip` header for
  rate-limit keying — that header is only trustworthy if the origin is reachable *only*
  through Cloudflare's edge. `cloudflare-only` is defined in
  `roles/edge/files/dynamic.yml` via Traefik's file provider and restricts every router
  to Cloudflare's published IP ranges. See that file's header comment for the full
  rationale and for what to do if a domain is ever un-proxied.

Provisioning owns `dynamic.yml` (`/opt/edge/dynamic/`); a release refuses to run without it.
A release proves the allowlist on every public host: Traefik on the host itself must answer
**403** for each of them and for hypernova's `/api/` (a 404 means no router serves it). The
Deploy workflow's smoke step then checks the same hosts through Cloudflare.

### Priorities

Traefik matches the most specific rule first, but ties are resolved by rule length,
which is not something to rely on. Where two routers can match the same request, set
`priority` explicitly.

hypernova does this: `hypernova-provider` matches `Host(...) && PathPrefix(/api)` at
priority 100, and `hypernova-web` matches the same host at priority 1. The provider
serves its API at the root, so a `stripprefix` middleware removes `/api` before
forwarding.

The portfolio uses a `redirectregex` middleware to send `www.` to the apex permanently,
with `service=portfolio` so both routers share one backend.

## TLS

Certificates come from Let's Encrypt over the **HTTP-01** challenge, with a single ACME
account shared by every domain, stored in the `edge_edge-acme` volume (project `edge`, key
`edge-acme`; both names are load-bearing, and keep every existing certificate). The account
email is `acme_email` in `production.yml`.

All three app domains are actually Cloudflare-proxied (orange-clouded), not plain A
records — Cloudflare forwards the `.well-known/acme-challenge` request through to this
host on :80, so HTTP-01 issuance still works. The real constraint is that nothing may
*terminate* :80 before Traefik does — if Cloudflare's proxying were ever replaced with
something that intercepts or answers on :80 itself (a different CDN, a WAF appliance,
Cloudflare's "Always Use HTTPS" acting at the edge in a way that never reaches origin),
the challenge fails and the certificate never issues. This is the constraint to remember
before changing what sits in front of the origin.

Certificates for domains no longer routed are simply left in `acme.json`. Traefik does
not renew what no router references, so a retired subdomain needs no cleanup.

### Authenticated Origin Pulls (optional, off)

`roles/edge` can make every TLS router require Cloudflare's origin-pull client certificate
(`edge_origin_pull_enabled`, with the CA in `edge_origin_pull_ca`), so the origin answers
nothing but Cloudflare even at the TLS layer. It is off by default. Turn it on in the
Cloudflare dashboard **first**, or Cloudflare is cut off; the steps are in
[RUNBOOK.md](../RUNBOOK.md#optional-authenticated-origin-pulls). While it is on, the
release's local route check cannot complete a TLS handshake and says so instead of
proving the routes; the smoke step through Cloudflare still does.

## Timeouts

`--entrypoints.websecure.transport.respondingTimeouts.readTimeout=1800s`

Traefik v3 gives a request body 60 seconds by default. A large video upload to the
portfolio admin exceeds that, and Traefik cuts the connection with nothing on the origin
to explain it — the application sees a truncated request and logs nothing useful.

It is bounded at 30 minutes rather than disabled with `0`, because `0` means a
held-open request costs nothing to keep and a slow-loris becomes free.

## Logs

`--log.level=ERROR`. Traefik at `INFO` narrates every router change, which on a host
where Watchtower recreates containers regularly buries anything worth reading.
