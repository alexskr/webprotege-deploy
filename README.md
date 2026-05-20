# webprotege-deploy

Docker Compose configuration for running WebProtege.

## Quick Start

```bash
cp .env.example .env
docker compose up -d
```

Then open http://webprotege-local.edu in your browser, click **Register**
to create an account, and sign in.

> **First time?**  You need to add `webprotege-local.edu` to your hosts
> file before this will work.  See [Configure Local Host Resolution](#configure-local-host-resolution)
> below.

## Prerequisites

### Docker

The Docker daemon must be running.  Verify with:

```bash
docker info
```

If this fails, start Docker through Docker Desktop or your system's
service manager.

### Configure Local Host Resolution

WebProtege uses a custom hostname for cookie handling and Keycloak
authentication flows.  Add this line to your system's hosts file:

```
127.0.0.1  webprotege-local.edu
```

**Hosts file location:**
- **Linux/macOS:** `/etc/hosts` (edit with `sudo nano /etc/hosts`)
- **Windows:** `C:\Windows\System32\drivers\etc\hosts` (edit as Administrator)

Self-hosted deployments using their own domain can skip this step and set
`SERVER_HOST` in `.env` to their public hostname instead.

### Environment Configuration

Copy the example environment file:

```bash
cp .env.example .env
```

The defaults are suitable for local development.  Self-hosted deployments
should edit `.env` and change `SERVER_HOST` to the public hostname.

See `.env.example` for documentation of each variable.

## Starting WebProtege

The default path is plain HTTP — `docker compose up -d` and go, no cert
tooling, no setup steps.  An **optional** HTTPS layer is available for
contributors working on auth flows, OIDC, proxy headers, WebSocket
upgrades, or anything else that behaves differently under HTTPS; flip it
on with one extra make target.

- **HTTP (default)** — fastest first-run, no cert setup, identical to the
  long-standing dev flow.
- **HTTPS (optional)** — Caddy + locally-trusted cert via
  [mkcert](https://github.com/FiloSottile/mkcert).  Mirrors the
  TLS-terminated topology used in staging and prod, so HTTPS-sensitive
  behaviour (cookie `Secure` flags, mixed-content, X-Forwarded-Proto
  handling, OIDC redirect_uri) is exercisable in dev.  See
  [docs/design/optional-https-dev.md](docs/design/optional-https-dev.md)
  for the full rationale.

### Option A — plain HTTP (default)

```bash
docker compose up -d
# or, equivalently:
make dev-up
```

Open `http://webprotege-local.edu`.

### Option B — HTTPS with a locally-trusted cert (optional)

One-time per machine, generate a [mkcert](https://github.com/FiloSottile/mkcert)
cert and install its CA into your system trust store:

```bash
make dev-certs
```

The script installs `mkcert` if missing (printing the install command
for your platform — it doesn't run sudo for you), runs `mkcert -install`
to add the local CA to the system store, and generates
`./certs/cert.pem` + `./certs/key.pem` for `webprotege-local.edu`.

Then bring up the stack with the TLS overlay:

```bash
make dev-https-up
# equivalent to:
# docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

This adds a Caddy sidecar in front of `webprotege-nginx`, terminates TLS
on `:443`, and proxies plain HTTP to the rest of the stack with the
correct `X-Forwarded-*` headers.

Keycloak will automatically import the WebProtege realm, configure the
protocol mappers, and set up redirect URIs on first boot.  This is
handled by the
[webprotege-keycloak](https://github.com/protegeproject/webprotege-keycloak)
image's entrypoint script — no manual Keycloak setup is required.

To follow startup progress:

```bash
make dev-logs           # or: make dev-https-logs
```

Look for `[entrypoint] Realm configuration complete.` to confirm the
realm is ready.  Press Ctrl+C to stop following logs.

## Accessing WebProtege

Open your browser:

- Option A (HTTP):  `http://webprotege-local.edu`
- Option B (HTTPS): `https://webprotege-local.edu`

Use the custom domain (not `localhost`) to ensure proper cookie handling
and authentication flow between WebProtege and Keycloak.

If you went with Option B and the browser complains about the cert, run
`mkcert -install` once more — the CA was probably not added to the
trust store on the first try (some browsers need a separate trust step;
mkcert handles this).

### Register a New User Account

1. Click **Register** on the login page
2. Fill out the registration form (email, password, name)
3. Click **Register**

### Sign In

After registration, sign in with your email and password.

**Successful login indicators:**
- Redirect to the WebProtege home page
- Your name appears in the top navigation
- You see options to create or access ontology projects

## First-Admin Bootstrap

On a fresh install, no user has administrative access. The first registered
user must be granted the `SystemAdmin` role in Keycloak before WebProtege's
admin features (creating projects, managing users, editing application
settings) become available.

This is a one-time manual step per install. A config-driven alternative is
tracked in
[webprotege-authorization-service#36](https://github.com/protegeproject/webprotege-authorization-service/issues/36).

### Grant the SystemAdmin role

1. Sign in to the Keycloak admin console at:

   ```
   http://webprotege-local.edu/keycloak/admin/
   ```

   Use the credentials from `KEYCLOAK_ADMIN` and `KEYCLOAK_ADMIN_PASSWORD`
   in your `.env` file.  **Change these from the defaults before any
   deployment that is reachable beyond your local machine.**

2. In the left sidebar, switch the realm dropdown from `master` to
   `webprotege`.

3. Navigate to **Clients → webprotege → Roles → SystemAdmin → Users in role**
   (or **Assign users**, depending on Keycloak version).

4. Assign the role to the user account you registered earlier.

5. Sign out of WebProtege and sign back in — the new role is picked up from
   the fresh JWT.  You now have full admin access.

### Enable self-service project creation

By default, only users with an explicit `ProjectCreator` role assignment can
create new projects.  To let any signed-in user create projects:

1. In WebProtege, navigate to **Application Settings** (admin menu).
2. Enable **Empty project creation allowed**.
3. Save.

## Services

The stack includes the following services:

| Service | Description | Port |
|---|---|---|
| webprotege-nginx | Reverse proxy (entry point) | 80 |
| webprotege-keycloak | Identity and access management | 8080 |
| mongo | MongoDB database | 27017 |
| rabbitmq | Message broker | 5672, 15672 |
| minio | Object storage | 9000, 9001 |
| mailpit | Development SMTP server | 1025, 8025 |
| webprotege-gwt-api-gateway | API gateway | 5008 |
| webprotege-gwt-ui-server | Web UI | 8888 |
| webprotege-backend-service | Core backend | 5005 |
| webprotege-authorization-service | Authorization | 5010 |
| webprotege-user-management-service | User management | — |
| webprotege-event-history-service | Event history | 5006 |
| webprotege-ontology-processing-service | Ontology processing | — |
| webprotege-initial-revision-history-service | Revision history | — |

## Deploying to staging / production

The repository ships a layered Compose setup so the same files can run
locally for development and behind an externally managed reverse proxy
for staging or production.  TLS termination is **not** handled by
docker-compose — staging/prod assumes a host-level nginx (e.g. managed
by puppet, with letsencrypt) terminates HTTPS and forwards plain HTTP
to a loopback port that this stack binds.

```
browser ── https ──▶ host nginx ── http ──▶ 127.0.0.1:8080 ──▶ webprotege-nginx ──▶ services
                   (puppet + LE)             (loopback only)        (docker bridge)
```

### Required external nginx configuration

The host nginx must:

- Forward `Host` unchanged: `proxy_set_header Host $host;`
- Tell the stack it terminated TLS: `proxy_set_header X-Forwarded-Proto https;`
- Pass websocket upgrade headers for the `/wsapps` location:
  `proxy_set_header Upgrade $http_upgrade;` and
  `proxy_set_header Connection "upgrade";` with `proxy_http_version 1.1;`
- Allow large uploads: `client_max_body_size 300m;` (or higher) to match
  WebProtege's `spring.servlet.multipart.max-file-size`.
- `proxy_pass http://127.0.0.1:8080;` (or whichever
  `WEBPROTEGE_HTTP_BIND`:`WEBPROTEGE_HTTP_PORT` you configured).

### Setup

```bash
cp .env.prod.example .env.staging      # or .env.prod for production
# edit .env.staging — at minimum set SERVER_HOST, KEYCLOAK_ADMIN_PASSWORD,
# MINIO_ROOT_PASSWORD, and ADMIN_CLI_SECRET (see chicken-and-egg note in
# .env.prod.example for how to obtain ADMIN_CLI_SECRET on first boot)
docker compose -f docker-compose.yml -f docker-compose.prod.yml \
  --env-file .env.staging up -d
```

Requires Docker Compose v2.24+ for the `!reset` / `!override` tags used
in `docker-compose.prod.yml`.  Older Compose: replace `!reset []` with
`[]` and drop the `!override` tag.

### What the prod overlay changes

- Drops host port bindings for every backing service (`mongo`, `rabbitmq`,
  `webprotege-keycloak`, `minio`, `mailpit`, plus the Java JDWP debug
  ports).  Services remain reachable to each other on the docker bridge.
- Rebinds the internal `webprotege-nginx` to
  `${WEBPROTEGE_HTTP_BIND:-127.0.0.1}:${WEBPROTEGE_HTTP_PORT:-8080}` so
  the external nginx can reach it without exposing the stack publicly.
- Force-fails startup if `KEYCLOAK_ADMIN_PASSWORD`, `MINIO_ROOT_PASSWORD`,
  or `ADMIN_CLI_SECRET` are not set in the env file (no silent fallback
  to dev defaults).

### Known limitations in staging

- **Outbound email does not work.**  Keycloak is wired to send mail to
  the bundled mailpit container, which catches messages in a volatile
  in-memory inbox.  In the prod overlay, mailpit's host ports are not
  bound, so the inbox is unreachable.  Password reset and email
  verification flows therefore have no effect from a user's perspective.
  Tracked as a follow-up; must be addressed before promoting to prod.

### Before promoting from staging to prod

- [ ] Real SMTP relay configured to replace mailpit.
- [ ] `KEYCLOAK_ADMIN_PASSWORD`, `MINIO_ROOT_PASSWORD`, `ADMIN_CLI_SECRET`
      rotated to prod-specific values and stored in a secrets manager.
- [ ] `ENABLE_JAVA_DEBUG` confirmed unset.
- [ ] Backup strategy for the named volumes (`mongo-data-directory`,
      `keycloak-h2-directory`, `minio_data`, `webprotege-data-directory`).
- [ ] First-admin bootstrap performed (see [First-Admin Bootstrap](#first-admin-bootstrap)).
- [ ] External nginx letsencrypt renewal hook confirmed to reload
      cleanly without dropping the loopback connection.

## Stopping and Resetting

**Stop all services** (preserves data):

```bash
docker compose down
```

**Stop and delete all data** (full reset):

```bash
docker compose down -v
```

**Reset Keycloak only** (forces realm re-import on next start):

```bash
docker compose down
docker volume rm webprotege-deploy_keycloak-h2-directory
docker compose up -d
```

## Verification

To verify the `webprotege_username` mapper is working correctly, check
the backend logs after signing in:

```bash
docker compose logs webprotege-backend-service | grep "from user"
```

The userId should show the `webprotege_username` value (e.g., `johardi`),
not the email address.

## Troubleshooting

**Port conflicts:** If a port is already in use, check which service
uses that port in the table above and modify the host port mapping in
`docker-compose.yml`.

**Permission errors:** Ensure your user has permissions to modify the
hosts file and run Docker commands.

**Service startup failures:** Check logs for a specific service:

```bash
docker compose logs <service-name>
```

**Authentication issues:** Verify that `SERVER_HOST` in `.env` matches
your hosts file entry.  Check the Keycloak entrypoint logs:

```bash
docker compose logs webprotege-keycloak | grep "\[entrypoint\]"
```

## SMTP Configuration

WebProtege requires an SMTP server for the migrated user password reset
flow.  In development, Mailpit is included in docker-compose.yml and
catches all outgoing email.  Access the Mailpit inbox at
http://webprotege-local.edu:8025.

The SMTP settings are defined in the Keycloak realm JSON
([`webprotege.json`](https://github.com/protegeproject/webprotege-keycloak/blob/main/webprotege.json))
under `smtpServer`.

**Staging / production:** the prod overlay does not bind mailpit's host
ports, so the inbox is unreachable.  Outgoing email goes into a volatile
fake inbox — password reset and email verification flows have no effect
from a user's perspective.  Real SMTP relay integration is a follow-up
item; see [Before promoting from staging to prod](#before-promoting-from-staging-to-prod).
