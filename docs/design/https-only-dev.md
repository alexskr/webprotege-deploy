# Make HTTPS the default for dev (not just prod)

**Status**: Proposal — not yet implemented
**Author**: Initial draft from the staging deployment debug session, 2026-05-19
**Affects**: `webprotege-deploy`, `alexskr/webprotege-nginx`, `alexskr/webprotege-keycloak`, contributor onboarding


## TL;DR

Today the stack defaults to plain HTTP for development and switches to HTTPS
only when deploying behind a TLS-terminating reverse proxy.  This proposal
argues we should flip the default so that dev runs the same TLS-terminated
topology prod does, with a one-time `mkcert`-based cert generation step.  The
empirical case: every HTTPS bug we hit while bringing up staging was a class of
bug that fundamentally cannot surface in HTTP-only dev, so each one cost a
full debug arc *after* TLS was first turned on in production.


## Problem

`webprotege-deploy` is deployed in two distinct topologies:

1. **Dev**: browser talks plain HTTP to `webprotege-nginx` (the in-stack nginx
   container) directly on port 80.  No TLS anywhere.
2. **Prod / staging**: browser talks HTTPS to an externally managed nginx
   (puppet + letsencrypt) on port 443, which terminates TLS and proxies
   plain HTTP to `webprotege-nginx` on `127.0.0.1:8080`.  The in-stack
   containers see HTTP requests carrying `X-Forwarded-Proto: https`.

These topologies look superficially the same but exercise the code very
differently.  Anything that constructs an absolute URL from the incoming
request — Spring's `request.getRequestURL()`, Tomcat's `request.getScheme()`,
the legacy Keycloak adapter's redirect_uri builder, nginx's `$scheme` — gets
"http" in dev and (correctly) "https" in prod *only if* every layer of the
stack honours the forwarded-headers contract.  Layers that hardcode `$scheme`
or trust the literal TCP connection silently produce wrong URLs.

The current design treats this as a configurable axis: a `PUBLIC_SCHEME` env
var (defaulting to `http`) gets interpolated into 12 sites in
`docker-compose.yml`, and the keycloak entrypoint reads it to pick the scheme
when patching the realm.  The contract works on paper.  In practice we
discovered six distinct bugs across four layers — *each invisible in dev,
each catastrophic in prod* — only when staging actually came up.


## Evidence: six bugs caught only by staging

Every bug below was diagnosed and fixed in the May 2026 staging bring-up.
None of them surface in HTTP-only dev because HTTP-only dev has no TLS
termination upstream, no `X-Forwarded-Proto: https` header, no scheme
mismatch between TCP and forwarded view.

| # | Layer | Failure mode in prod | Fix |
|---|-------|----------------------|-----|
| 1 | `webprotege-nginx` (in-container nginx) | Hardcoded `proxy_set_header X-Forwarded-Proto $scheme` overwrote `https` with `http` even when the front nginx had set it correctly.  Downstream Keycloak adapter then constructed http URLs. | Fork (`alexskr/webprotege-nginx`): added a `map` that trusts upstream `X-Forwarded-Proto` when present, falls back to `$scheme`.  Backward-compatible. |
| 2 | `webprotege-keycloak` entrypoint | `kcadm update` of realm `frontendUrl` + `webprotege` client `baseUrl`/`redirectUris`/`webOrigins` used literal `http://${SERVER_HOST}/...`.  Discovery doc advertised http issuer; Spring's issuer-uri validation in `webprotege-gwt-api-gateway` failed. | Fork (`alexskr/webprotege-keycloak`): added `PUBLIC_SCHEME` env (default `http`), composed `${PUBLIC_SCHEME}://${SERVER_HOST}` everywhere. |
| 3 | `webprotege-keycloak` runtime | `KC_HOSTNAME` as bare hostname meant Keycloak emitted http URLs in *back-channel* discovery doc fetches (no X-Forwarded-Proto present on the bridge-internal hop), even though the front-facing path used https. | Switched `KC_HOSTNAME` in `docker-compose.yml` to full-URL form: `${PUBLIC_SCHEME:-http}://${SERVER_HOST}/keycloak`.  Keycloak then ignores per-request headers and uses the configured value. |
| 4 | `docker-compose.yml` + `webprotege-nginx` | `webprotege-nginx` container had `hostname: ${SERVER_HOST}`.  On a user-defined bridge, Docker's embedded DNS resolves every sibling's `hostname` field, so any service that did back-channel HTTPS to the public name resolved it to the nginx container's bridge IP (no 443 listener) → connection refused. | Prod overlay: `hostname: webprotege-nginx-internal`; `extra_hosts: !reset []` on api-gateway. |
| 5 | `webprotege-gwt-ui-server` (Tomcat 9 + legacy Keycloak adapter) | Plain Tomcat ignores `X-Forwarded-Proto` without a `RemoteIpValve` in `server.xml`.  The Keycloak adapter then constructed `redirect_uri=http://...` from `request.getScheme()`.  Keycloak's allowed redirectUris contained only `https://...`.  "Invalid parameter: redirect_uri." | Bind-mounted a patched `server.xml` with `RemoteIpValve` configured to trust X-Forwarded-Proto from RFC1918/loopback peers. |
| 6 | Keycloak master realm | `sslRequired=external` (Keycloak's stock default) refuses plain HTTP for any host not on loopback.  Surfaces only in dev (where admins reach `http://<hostname>/keycloak/admin/`), but a real symptom — admin console flatly refuses. | Fork entrypoint flips master to `sslRequired=NONE` when `PUBLIC_SCHEME=http`, leaves the secure default for https. |

The pattern: **each layer of the stack had its own copy of "trust TCP scheme,
not forwarded headers"**, and each one was discovered in production-after-the-
fact rather than during dev.

If dev ran the same TLS-terminated topology with the same forwarded-headers
contract, every one of these bugs would have manifested the first time a
contributor brought the stack up.  The cost of catching them in dev is
~minutes (visible misbehaviour on the first page load); the cost of catching
them in prod is hours of staging-time debug per bug.


## Proposal: dev runs the prod topology, with a one-time mkcert step

The single-topology version is:

```
browser
   │  TLS  (real letsencrypt in prod, mkcert in dev)
   ▼
host-level nginx (puppet-managed in prod, sidecar container in dev)
   │  http + X-Forwarded-Proto/Host/Port
   ▼
webprotege-nginx (container)
   │  http + propagated forwarded headers
   ▼
gwt-ui-server / api-gateway / keycloak / others
```

In prod the host nginx is provisioned by `webprotege::proxy`.  In dev we add
a TLS-terminating sidecar to the compose stack that does the same job at
`https://127.0.0.1:443` with a [mkcert](https://github.com/FiloSottile/mkcert)-
issued cert.  Dev users run `make dev-certs` once per machine; everything
downstream is identical to staging.


## Concrete deliverables

Everything below is additive to the existing repo — the HTTP path remains
supported during the transition.

### 1. `bin/dev-setup-certs` (one-time, ~30 lines bash)

- Detect or `brew install` / `apt install` `mkcert`.
- Run `mkcert -install` (installs the local CA into the system trust store;
  browsers auto-trust thereafter).
- Generate `./certs/webprotege-local.edu.{pem,key}` for the dev hostname plus
  `localhost` and `127.0.0.1`.
- Print a confirmation + the next-step compose-up command.

### 2. `docker-compose.dev-https.yml` (compose overlay, ~25 lines)

Adds a single `dev-tls` service:

- Image: `nginx:1.27-alpine`
- `ports: ["${DEV_HTTPS_PORT:-443}:443"]`
- Volumes: mount `./certs/` and a dev nginx config
- Config: terminates TLS, proxies to `webprotege-nginx:80` with the same
  `X-Forwarded-Proto/Host/Port` headers the puppet-managed prod nginx sets
- `depends_on: [webprotege-nginx]`

### 3. `dev-nginx.conf` (~40 lines)

Mirror of the puppet-managed `webprotege::proxy` template, minus the
letsencrypt-specific parts.  Forwarded-headers pattern is identical.

### 4. Container truststore plumbing (2 services)

Services that make outbound HTTPS to the public hostname during boot need
to trust the mkcert root CA.  Currently `webprotege-gwt-api-gateway` does
this when fetching the OIDC discovery doc.  Two bind-mount lines suffice:

```yaml
webprotege-gwt-api-gateway:
  volumes:
    - ${MKCERT_ROOTCA:-/dev/null}:/usr/local/share/ca-certificates/mkcert-root.crt:ro
  environment:
    JDK_JAVA_OPTIONS: "... -Djavax.net.ssl.trustStore=... or import on container init"
```

The `${MKCERT_ROOTCA:-/dev/null}` form preserves the HTTP dev path — if
mkcert isn't installed, nothing breaks; the bind-mount points at an empty
file and the JVM uses its default truststore.

### 5. Compose-up invocation

Documented as:

```bash
make dev-certs                   # once per machine
docker compose \
  -f docker-compose.yml \
  -f docker-compose.prod.yml \
  -f docker-compose.dev-https.yml \
  --env-file .env up -d
```

Same prod overlay as staging; the dev-https overlay only adds the TLS
terminator.  Dev/prod parity by construction.

### 6. README rewrite (small)

A "Recommended (HTTPS)" path becomes the default in the README.  The
existing HTTP-only path moves to a "Minimal / legacy" section, retained
for contributors who can't or won't install mkcert.

### 7. `.gitignore`

`certs/` added so generated certs never leak into the repo.


## What goes away (long-term)

Once HTTPS-dev is the documented default and we trust it, the following
become dead weight that can be removed:

- `PUBLIC_SCHEME` / `PUBLIC_WS_SCHEME` parameterization (12 sites in
  `docker-compose.yml`).
- The conditional in `webprotege-keycloak`'s entrypoint that flips
  `sslRequired` based on `PUBLIC_SCHEME`.
- The full-URL vs bare-hostname `KC_HOSTNAME` decision.
- README phrases like "for dev only", "when behind a proxy", "depending on
  PUBLIC_SCHEME".  One topology, one story.

This is the long-tail simplification.  It's not the goal of step 1 — step 1
just adds the HTTPS dev option additively.  The removals come later, after
the HTTPS path has proved itself.


## Rationale

### Why this is worth doing

1. **Empirically backed.**  Six bugs in three weeks, all of class "only
   surfaces with TLS in front".  This is not a hypothetical "what if HTTPS
   has issues" — it's a track record.  Forcing HTTPS-in-dev would have
   caught every one on the contributor's machine.

2. **Dev/prod parity is the actual goal.**  We already deploy to staging
   with the prod topology.  The simpler the dev path is to bring up "the
   same way as prod," the fewer surprises ship.

3. **Marginal infrastructure cost is bounded.**  mkcert is mature, widely
   used, cross-platform (macOS / Linux / Windows), and the entire dev cert
   flow is one command per machine.  The TLS-terminator sidecar is ~25
   lines of compose + ~40 of nginx config — small additive surface area.

4. **The complexity we'd remove later is real.**  The `PUBLIC_SCHEME`
   parameterization touches 12 lines today, plus three conditionals in
   entrypoint logic and one in the healthcheck.  Removing it eliminates a
   class of "dev-vs-prod" bugs entirely.

5. **The current "HTTP for dev" simplicity is increasingly a fiction.**
   Setup already requires: a `/etc/hosts` entry, the
   `webprotege-local.edu` ritual, Docker Desktop, three-image fork
   handling for the GHCR images, the `tomcat-server.xml` bind-mount,
   etc.  "It just works on `docker compose up`" is already not the
   pitch — adding `make dev-certs` doesn't materially change the
   onboarding shape.

### Why this might not be worth doing (counterarguments worth answering)

1. **Academic / OSS users may not be deep on TLS.**  Real concern.
   Mitigation: provide both paths during the transition (HTTPS is the
   *recommended* default, HTTP remains supported); make the cert script
   bulletproof and detect-and-install dependencies; document the
   troubleshooting path for the common "browser still doesn't trust the
   cert" failure mode (usually `mkcert -install` needed sudo and was
   skipped).

2. **CI cost.**  CI environments need mkcert installed too.  Minor —
   `mkcert -install` is a single `apt-get install mkcert && mkcert -install`
   line in a CI-setup step.  Many existing CI configs already do this.

3. **Windows-specific friction.**  mkcert works on Windows but the
   trust-store integration is fiddlier than Mac/Linux.  Mitigation: keep
   the HTTP-only fallback documented; most Windows devs use WSL anyway
   where the Linux flow applies.

4. **Cert rotation in dev.**  mkcert certs are valid 2+ years.  When they
   expire, the dev re-runs `make dev-certs`.  Annoying once, every two
   years.  Acceptable.

5. **"Why not just fix each layer when we find a bug?"**  That's what
   we've been doing.  The point of HTTPS-in-dev is to *find* the bugs
   in dev rather than in prod.  The find-cost is what's expensive, not
   the fix-cost.

### Why staged rather than all-at-once

The "make HTTPS the only dev option" version of this proposal would be
faster to execute and produces a cleaner end state, but it forces every
existing contributor to install mkcert before they can `docker compose
up`.  That's a one-day pain.  The staged version:

1. **Step 1 (this proposal)** — add HTTPS dev as an *option*.  Risk-
   bounded; existing HTTP-dev path keeps working.  No forced migration.

2. **Step 2 (after ~1 month of HTTPS-dev being available)** — flip the
   README's recommended path to HTTPS.  Mark HTTP as legacy.

3. **Step 3 (after ~3 months)** — drop the HTTP path.  Reduce compose
   to single-topology.

The staged path is what lets us deliver value incrementally and back
out if HTTPS-dev turns out to have unforeseen friction.

### Why we shouldn't put this in the puppet module instead

`webprotege-puppet` provisions the *host* TLS terminator for staging /
prod.  That layer is already correct.  The dev case doesn't run puppet;
adding "puppet for dev" would be a much larger lift than a compose
sidecar.  The dev TLS terminator belongs in the deploy repo, beside the
compose files it works with.


## Estimated work

| Deliverable | LOC | Effort |
|---|---|---|
| `bin/dev-setup-certs` | ~30 | 1 hr |
| `docker-compose.dev-https.yml` | ~25 | 30 min |
| `dev-nginx.conf` | ~40 | 1 hr (mostly translating the puppet template) |
| Container truststore mounts | ~10 | 1 hr (testing the JVM trust path) |
| README rewrite | ~80 | 1 hr |
| `Makefile` target or shell helper | ~10 | 15 min |
| Manual testing (Mac + Linux) | — | 1-2 hr |

Total: half a day to a day of focused work.  Smaller than any single
debug arc in the staging bring-up.


## Open questions

1. **Should the dev-tls sidecar be in the base `docker-compose.yml` (with
   a profile guard) or in its own overlay file?**  Lean: separate overlay.
   Keeps the base file describing "the application" and the overlay files
   describing "the deployment topology."

2. **Should we also bake the `RemoteIpValve` into the gwt-ui-server fork
   instead of bind-mounting `tomcat-server.xml`?**  Yes, eventually — but
   independent of this proposal.  Filing as a separate follow-up.

3. **Do we eventually fork `webprotege-gwt-ui-server`?**  Probably yes,
   to land the valve change.  Not blocking on this proposal.

4. **Can we make the dev TLS terminator share more with the prod nginx
   config?**  Worth investigating — a single nginx config that just
   templates the cert paths and listen ports would be cleaner.  Probably
   out of scope for step 1.


## Decision

To be determined.  This document captures the case; the decision is the
team's.  If approved, the next step is implementing the seven deliverables
in the "Concrete deliverables" section, on a branch, with a small writeup
in the PR description and a public-facing changelog note.
