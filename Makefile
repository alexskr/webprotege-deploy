# =============================================================================
# WebProtege deploy convenience targets
# =============================================================================
#
# Thin wrappers around docker-compose invocations.  The two-or-three -f
# flag dance gets verbose fast, especially when explaining the dev flow
# to new contributors — `make dev-up` is friendlier than the equivalent
# `docker compose -f ... -f ... up -d`.
#
# Nothing here does anything that bash + docker can't.  If you'd rather
# type the long form, you can ignore this file entirely.

SHELL := /usr/bin/env bash

COMPOSE       := docker compose
BASE_FILE     := docker-compose.yml
TLS_FILE      := docker-compose.tls.yml
PROD_FILE     := docker-compose.prod.yml

.DEFAULT_GOAL := help

.PHONY: help dev-certs dev-up dev-down dev-logs dev-https-up dev-https-down dev-https-logs prod-up prod-down

help: ## Show this help (default).
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ----------------------------------------------------------------------------
# Dev — plain HTTP (current default; kept while HTTPS is opt-in)
# ----------------------------------------------------------------------------

dev-up: ## Bring up the stack in plain-HTTP dev mode.
	$(COMPOSE) -f $(BASE_FILE) up -d

dev-down: ## Stop + remove the plain-HTTP dev stack.
	$(COMPOSE) -f $(BASE_FILE) down

dev-logs: ## Tail logs from the plain-HTTP dev stack.
	$(COMPOSE) -f $(BASE_FILE) logs -f

# ----------------------------------------------------------------------------
# Dev with HTTPS — Caddy sidecar terminating TLS with mkcert certs
# ----------------------------------------------------------------------------

dev-certs: ## One-time per machine: install mkcert + generate locally-trusted certs.
	bin/dev-setup-certs

# PUBLIC_SCHEME / PUBLIC_WS_SCHEME get baked into every URL the backend
# emits (issuer URI, allowed CORS origin, websocket URL, etc.) at compose-
# parse time.  Shell env wins over .env in compose interpolation, so
# overriding here flips the whole stack to https/wss without the user
# having to edit .env.  Apply the same overrides on -down and -logs so
# compose resolves the same service set (otherwise it warns about
# orphaned services).
HTTPS_ENV := PUBLIC_SCHEME=https PUBLIC_WS_SCHEME=wss

dev-https-up: ## Bring up the stack with Caddy + mkcert TLS in front.
	@if [ ! -f certs/cert.pem ]; then \
		echo "ERROR: certs/cert.pem not found — run 'make dev-certs' first."; \
		exit 1; \
	fi
	$(HTTPS_ENV) $(COMPOSE) -f $(BASE_FILE) -f $(TLS_FILE) up -d

dev-https-down: ## Stop + remove the HTTPS dev stack.
	$(HTTPS_ENV) $(COMPOSE) -f $(BASE_FILE) -f $(TLS_FILE) down

dev-https-logs: ## Tail logs from the HTTPS dev stack (including Caddy).
	$(HTTPS_ENV) $(COMPOSE) -f $(BASE_FILE) -f $(TLS_FILE) logs -f

# ----------------------------------------------------------------------------
# Prod — typically run on the deploy host, not on a contributor's laptop.
# Two shapes:
#   1. LB-fronted: external load balancer / nginx handles TLS, so the tls
#      overlay is NOT applied here.
#   2. Single-host: Caddy in the stack handles TLS via letsencrypt — apply
#      both prod and tls overlays.
# ----------------------------------------------------------------------------

prod-up: ## Bring up the stack for LB-fronted prod (no in-stack TLS).
	$(COMPOSE) -f $(BASE_FILE) -f $(PROD_FILE) --env-file .env.prod up -d

prod-down: ## Stop + remove the prod stack.
	$(COMPOSE) -f $(BASE_FILE) -f $(PROD_FILE) --env-file .env.prod down
