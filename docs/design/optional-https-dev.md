# Optional HTTPS layer for dev

**Status**: Proposal — implementation prototyped on `feature/caddy-tls-sidecar`
**Author**: Initial draft from the staging deployment debug session, 2026-05-19; reframed 2026-05-20
**Affects**: `webprotege-deploy`, contributor onboarding


## TL;DR

Plain HTTP stays the default for local dev — `docker compose up -d` and go,
no cert tooling, no setup steps.  Add an **optional** opt-in layer that
puts a TLS terminator (Caddy + locally-trusted cert via `mkcert`) in front
of the stack for contributors working on auth flows, OIDC, proxy headers,
WebSocket upgrades, or anything else that behaves differently under HTTPS.
The opt-in is a single `make dev-https-up` invocation after a one-time
`make dev-certs` per machine.


## Problem

`webprotege-deploy` runs in two distinct topologies:

1. **Dev (current default)**: browser talks plain HTTP to `webprotege-nginx`
   on port 80.  No TLS anywhere.
2. **Prod / staging**: browser talks HTTPS to an externally managed nginx
   (puppet + letsencrypt) on port 443, which terminates TLS and proxies
   plain HTTP to `webprotege-nginx` on `127.0.0.1:8080`.  The in-stack
   containers see HTTP requests carrying `X-Forwarded-Proto: https`.

These topologies look superficially the same but exercise the code very
differently.  Anything that constructs an absolute URL from the incoming
request — Spring's `request.getRequestURL()`, Tomcat's `request.getScheme()`,
the legacy Keycloak adapter's redirect_uri builder, nginx's `$scheme` —
gets "http" in dev and (correctly) "https" in prod *only if* every layer
of the stack honours the forwarded-headers contract.  Layers that hardcode
`$scheme` or trust the literal TCP connection silently produce wrong URLs.

This means contributors who work on auth flows / OIDC / WebSocket upgrades
/ proxy-aware code can't fully test their changes in the default HTTP-only
dev path.  Bugs only surface when someone deploys to staging or production
behind a real TLS terminator.


## Evidence: six bugs caught only by staging

Every bug below was diagnosed and fixed in the May 2026 staging bring-up.
None of them surface in HTTP-only dev because HTTP-only dev has no TLS
termination upstream, no `X-Forwarded-Proto: https` header, no scheme
mismatch between TCP and forwarded view.

| # | Layer | Failure mode in prod | Fix |
|---|-------|----------------------|-----|
| 1 | `webprotege-nginx` (in-container nginx) | Hardcoded `proxy_set_header X-Forwarded-Proto $scheme` overwrote `https` with `http` even when the front nginx had set it correctly.  Downstream Keycloak adapter then constructed http URLs. | Added a `map` that trusts upstream `X-Forwarded-Proto` when present, falls back to `$scheme`.  Backward-compatible. |
| 2 | `webprotege-keycloak` entrypoint | `kcadm update` of realm `frontendUrl` + `webprotege` client `baseUrl`/`redirectUris`/`webOrigins` used literal `http://${SERVER_HOST}/...`.  Discovery doc advertised http issuer; Spring's issuer-uri validation in `webprotege-gwt-api-gateway` failed. | Added `PUBLIC_SCHEME` env (default `http`), composed `${PUBLIC_SCHEME}://${SERVER_HOST}` everywhere. |
| 3 | `webprotege-keycloak` runtime | `KC_HOSTNAME` as bare hostname meant Keycloak emitted http URLs in *back-channel* discovery doc fetches (no X-Forwarded-Proto present on the bridge-internal hop), even though the front-facing path used https. | Switched `KC_HOSTNAME` in `docker-compose.yml` to full-URL form: `${PUBLIC_SCHEME:-http}://${SERVER_HOST}/keycloak`.  Keycloak then ignores per-request headers and uses the configured value. |
| 4 | `docker-compose.yml` + `webprotege-nginx` | `webprotege-nginx` container had `hostname: ${SERVER_HOST}`.  On a user-defined bridge, Docker's embedded DNS resolves every sibling's `hostname` field, so any service that did back-channel HTTPS to the public name resolved it to the nginx container's bridge IP (no 443 listener) → connection refused. | Drop the `hostname:` directive from base compose; rely on extra_hosts mappings where needed. |
| 5 | `webprotege-gwt-ui-server` (Tomcat 9 + legacy Keycloak adapter) | Plain Tomcat ignores `X-Forwarded-Proto` without a `RemoteIpValve` in `server.xml`.  The Keycloak adapter then constructed `redirect_uri=http://...` from `request.getScheme()`.  Keycloak's allowed redirectUris contained only `https://...`.  "Invalid parameter: redirect_uri." | Bind-mounted a patched `server.xml` with `RemoteIpValve` configured to trust X-Forwarded-Proto from RFC1918/loopback peers. |
| 6 | Keycloak master realm | `sslRequired=external` (Keycloak's stock default) refuses plain HTTP for any host not on loopback.  Surfaces only in dev (where admins reach `http://<hostname>/keycloak/admin/`), but a real symptom — admin console flatly refuses. | Flip master to `sslRequired=NONE` when `PUBLIC_SCHEME=http`, leave the secure default for https. |

Each one was invisible until staging actually came up.  Six bugs, one debug
arc per bug, each one blocking until fixed.  Most of these are infrastructure-
shaped bugs that surface in the proxy chain; they're cheaper to find in dev
than in prod, *for the contributors who happen to be working on those code
paths*.

That last qualifier is the key one.  Most contributors most of the time are
working on UI components, ontology logic, RabbitMQ messaging, MongoDB
queries — code where HTTPS makes no difference.  Forcing HTTPS-by-default on
those contributors costs more than it saves.  But contributors who *are*
touching auth / proxy / scheme-sensitive code benefit a lot from being able
to flip into the prod-equivalent topology quickly.

That's the case for **optional**, not required.


## Proposal: opt-in HTTPS layer, plain HTTP stays the default

Plain `docker compose up -d` continues to work exactly as it does today —
HTTP on `webprotege-local.edu`, no cert tooling required.  The optional
HTTPS layer adds a TLS-terminating sidecar via a separate compose overlay
plus a one-time-per-machine cert generator:

```
browser
   │  TLS  (mkcert in dev opt-in; real letsencrypt in prod)
   ▼
TLS terminator (Caddy sidecar in dev opt-in; puppet-managed nginx in prod)
   │  http + X-Forwarded-Proto/Host/Port
   ▼
webprotege-nginx (container)
   │  http + propagated forwarded headers
   ▼
gwt-ui-server / api-gateway / keycloak / others
```

In the optional dev case the TLS-terminating Caddy sidecar uses a mkcert-
issued cert.  Dev users who want HTTPS run `make dev-certs` once per
machine and then `make dev-https-up` whenever they want the HTTPS path
active.  Everything downstream is identical to staging.


## Concrete deliverables

All additive — the existing plain-HTTP dev path is unchanged.

### 1. `bin/dev-setup-certs` (one-time-per-machine, ~30 lines bash)

- Detect or print install instructions for `mkcert` (per-platform).
- Run `mkcert -install` (installs the local CA into the system trust store;
  browsers auto-trust thereafter).
- Generate `./certs/webprotege-local.edu.{pem,key}` for the dev hostname
  plus `localhost` and `127.0.0.1`.

### 2. `docker-compose.tls.yml` (compose overlay)

Adds a single `caddy` service:

- Image: `caddy:2.8-alpine`
- `ports: ["${CADDY_HTTPS_PORT:-443}:443", "${CADDY_HTTP_PORT:-80}:80"]`
- Volumes: mount `./certs/` and `./caddy/Caddyfile`
- Caddyfile uses env vars so the same config works for dev (mkcert) and
  single-host prod (auto-letsencrypt)
- Also drops `webprotege-nginx`'s host port binding so Caddy becomes the
  only public entry point

### 3. `caddy/Caddyfile`

Single config with env-var switches between mkcert (dev) and auto-LE (prod).

### 4. Makefile convenience targets

- `make dev-up` — current plain-HTTP path (unchanged behaviour)
- `make dev-certs` — one-time cert generation
- `make dev-https-up` — bring up with the TLS overlay; sets
  `PUBLIC_SCHEME=https` / `PUBLIC_WS_SCHEME=wss` so the in-stack URL
  parameterization picks https.

### 5. README

Add a "want HTTPS?" sub-section to the Starting WebProtege chapter.  Frame
it as an option, not a default.  Brief on why someone would want it (auth
work, OIDC tweaks, cookie behaviour, proxy headers).

### 6. JVM truststore plumbing OR upstream image fix

The optional HTTPS layer needs the JVM-based services to either trust the
mkcert root CA (so back-channel HTTPS discovery doc fetches work), *or*
skip the back-channel HTTPS fetch entirely.  Two paths:

- **Today**: bind-mount the mkcert root CA into the four JVM services and
  run `keytool -importcert` via an entrypoint wrapper.  Works, but adds
  per-image specifics (jar names, JVM args) to the overlay.  Implemented
  on the `feature/caddy-tls-sidecar` branch.
- **After upstream fix**: once
  [protegeproject/webprotege-gwt-api-gateway#45](https://github.com/protegeproject/webprotege-gwt-api-gateway/issues/45)
  lands (remove hardcoded `webprotege-local.edu` defaults from
  `application.yaml`), the overlay can simply unset the `issuer-uri`
  env vars to skip the back-channel HTTPS path entirely.  No truststore
  plumbing required.  Prototyped (as a documented dead-end pending
  upstream) on `feature/caddy-tls-drop-issuer-uri` — the approach is
  correct but blocked because the jar's baked-in default short-circuits
  env-var nulling.


## Rationale

### Why opt-in rather than default

1. **Most contributors don't touch the HTTPS-sensitive code paths.**
   UI, ontology logic, RabbitMQ, MongoDB work — none of these notice
   HTTPS vs HTTP.  Forcing every contributor through cert setup is a
   tax on people who don't benefit from it.

2. **`docker compose up -d` should keep working as a one-liner.**  It's
   a meaningful onboarding promise.  The project is consumed by academic
   teams, students, casual researchers — not just our own deployment
   workflow.  Lowering the floor matters.

3. **The benefit is concentrated on a smaller group.**  Contributors
   working on the proxy chain, auth flows, OIDC tokens, Tomcat valves,
   Keycloak adapters — they need this path.  Making it easy for them
   doesn't require imposing it on everyone.

### Why ship it at all

1. **Six bugs in three weeks** during the staging bring-up, all of class
   "only surfaces with TLS in front" (see the evidence table above).  If
   contributors working on those code paths had an easy way to flip on
   HTTPS in dev, those bugs would have been caught before staging.

2. **Dev/prod parity for the slice that needs it.**  Optional HTTPS in
   dev lets the people who write auth code test under the same shape as
   prod, without forcing the rest of the team into the same workflow.

3. **Marginal infrastructure cost is bounded.**  `mkcert` is mature,
   widely used, cross-platform.  The TLS terminator sidecar is ~25 lines
   of compose + ~50 of Caddyfile.  One-time setup per machine.

### Counterarguments worth answering

1. **"Why not require HTTPS for everyone, since dev/prod parity matters?"**
   Because the cost of forcing every contributor to install `mkcert` and
   trust a local CA is non-trivial, especially for casual / academic /
   student users who never touch the proxy chain.  Optional is the
   compromise: zero friction for the default path; an easy on-ramp for
   the contributors who need it.

2. **"Won't optional get less use and surface fewer bugs?"**  Probably,
   yes — fewer than HTTPS-by-default would surface.  But the right
   comparison isn't optional-vs-by-default, it's optional-vs-nothing.
   Today there's no path; we miss 100% of the dev-discoverable HTTPS
   bugs.  Optional catches the subset where the contributor touching
   that code remembers to flip it on.  That's still a big win over zero.

3. **"CI should run the HTTPS path then."**  Yes, agreed — and that's
   independent of dev defaults.  CI can run both paths.  Worth a separate
   follow-up.

4. **"Cert rotation in dev."**  mkcert certs are valid 2+ years.  When
   they expire, the dev re-runs `make dev-certs`.  Acceptable.


## Estimated work

| Deliverable | LOC | Effort |
|---|---|---|
| `bin/dev-setup-certs` | ~30 | 1 hr |
| `docker-compose.tls.yml` | ~70 | 1 hr |
| `caddy/Caddyfile` | ~50 | 1 hr |
| Makefile targets | ~40 | 30 min |
| README update | ~50 | 30 min |
| JVM truststore plumbing (until upstream #45 lands) | ~80 | 2 hr |
| Manual testing (Mac + Linux) | — | 1-2 hr |

Total: a day of focused work.  The bulk of it is already done on
`feature/caddy-tls-sidecar`.


## Open questions

1. **Drop the JVM truststore plumbing once upstream #45 lands?**  Yes —
   `feature/caddy-tls-drop-issuer-uri` already prototypes the cleaner
   path that becomes possible.  Pick that branch up when the upstream
   change ships.

2. **Should we also patch `webprotege-gwt-ui-server` to bake in the
   `RemoteIpValve`?**  Bind-mounting `tomcat-server.xml` is fragile; an
   upstream PR is the cleaner end state.  Tracked as a separate follow-up.

3. **CI runs the HTTPS path too?**  Probably yes, but separate from this
   dev-side proposal.


## Decision

To be determined.  This document captures the case; the decision is the
team's.  If approved, the next step is reviewing the existing
`feature/caddy-tls-sidecar` branch (which already implements most of the
deliverables above) and either merging it or iterating on the design.
