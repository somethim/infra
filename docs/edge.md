# The edge proxy

One Traefik v3 container, `edge-traefik`, owns ports 80 and 443 for the whole host and
routes by `Host()` header to whichever stack claims that domain.

## Routing by label

Traefik reads its configuration from Docker labels on the containers themselves
(`--providers.docker`), scoped to the `edge` network. An application declares its own
routing in its own compose file, and **adding a project requires no change to the edge
role**.

`--providers.docker.exposedbydefault=false` means a container is invisible to Traefik
until it opts in with `traefik.enable=true`. That is why `crm-provider` and
`prizm-provider` can sit on the `edge` network without being publicly reachable.

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
  Cloudflare-proxied, and `stacks/portfolio` trusts the `Cf-Connecting-Ip` header for
  rate-limit keying — that header is only trustworthy if the origin is reachable *only*
  through Cloudflare's edge. `cloudflare-only` is defined in
  `roles/edge/files/dynamic.yml` via Traefik's file provider and restricts every router
  to Cloudflare's published IP ranges. See that file's header comment for the full
  rationale and for what to do if a domain is ever un-proxied.

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
account shared by every domain, stored in the `edge-acme` volume.

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
