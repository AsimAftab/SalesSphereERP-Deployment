# SalesSphereERP-Deployment

Provider-neutral production deployment for the SalesSphere ERP API and web
frontend. Application images are pulled from GHCR; only Caddy publishes server
ports.

## Topology

```text
API_DOMAIN ───────┐
                  ├─ Caddy :80/:443 ── app:3000 ── managed Postgres
FRONTEND_DOMAIN ──┘             └───── frontend:8080
                                      app ── redis:6379
```

Services:

- `app` — backend image
  `ghcr.io/asimaftab/salessphere-erp-backend:${IMAGE_TAG:-latest}`.
  The service name and `IMAGE_TAG` remain compatible with existing automation.
- `frontend` — internal-only web image
  `ghcr.io/asimaftab/salessphere-erp-frontend:${FRONTEND_IMAGE_TAG:-latest}`.
- `redis` — internal-only BullMQ storage with AOF persistence.
- `caddy` — automatic TLS, compression, security headers, JSON access logs,
  API/WebSocket proxying, and frontend proxying.

## First installation

Use an Ubuntu 22.04+ server with ports 22, 80, and 443 available:

```bash
curl -fsSL https://raw.githubusercontent.com/AsimAftab/SalesSphereERP-Deployment/main/install.sh -o install.sh
sudo bash install.sh
```

The installer is resumable:

```bash
sudo bash install.sh --resume -y
sudo bash install.sh --from=5 -y
sudo bash install.sh --help
```

It installs Docker, configures the firewall and `deploy` user, clones this
repository, preserves existing secrets, renders `.env`, atomically renders and
validates Caddy, pulls both images, applies backend migrations, seeds the
platform admin, starts both services, and tests:

- `app`: `/health/ready`
- `frontend`: `/healthz`

Pre-set values may be supplied:

```bash
API_DOMAIN=api.example.com \
FRONTEND_DOMAIN=example.com \
AUTH_SITE_DOMAIN=example.com \
MARKETING_URL=https://example.com \
DATABASE_URL=postgresql://user:password@host:5432/database \
GHCR_USER=AsimAftab \
GHCR_TOKEN=github-token \
DEPLOY_SSH_KEY="ssh-ed25519 AAAA..." \
sudo -E bash install.sh -y
```

`AUTH_SITE_DOMAIN` is the explicit SameSite auth boundary. `API_DOMAIN` and
`FRONTEND_DOMAIN` must each equal it or be a proper subdomain.
`AUTH_SITE_DOMAIN` itself must be the registrable domain (eTLD+1). Validation
uses the complete ICANN and PRIVATE Mozilla/publicsuffix.org list vendored at
`data/public_suffix_list.dat`, including wildcard and exception rules, with no
runtime network request. Missing or unreadable PSL data fails installation and
deployment explicitly. For hosted domains, configure the tenant-owned site
(for example `foo.blogspot.com`), never the provider suffix (`blogspot.com`).

Legacy installations preserve every existing rendered `.env` value, including
Cloudinary, Resend, SMTP, IRD, logging, JWT, refresh, CSRF, and super-admin
settings.
The auth site is derived only when one configured host is the exact parent of
the other. Sibling hosts require explicit `AUTH_SITE_DOMAIN` input; unattended
migration fails safely rather than guessing from their final labels.

The generated `.env` sets `APP_URL`, `CORS_ORIGIN`, `MARKETING_URL`,
`PASSWORD_RESET_URL`, and `EMAIL_VERIFICATION_URL` from the explicit hosts.

## DNS

Point both host records at the server before expecting automatic TLS:

```text
API_DOMAIN       -> server public IP
FRONTEND_DOMAIN  -> server public IP
```

## Deployments

All deployments use one server-wide `flock`, refresh this repository from
`origin/main`, and validate a newly rendered Caddy configuration before
installing it.

```bash
./deploy.sh backend [sha-tag]
./deploy.sh frontend [sha-tag]
./deploy.sh all [sha-tag]
```

Backend migrations run from the new image before the running backend is
replaced. Each service is pulled, started, and health-checked independently.
On failure, the script exits non-zero, prints logs, identifies the previous
image, and prints rollback guidance.

`update.sh` remains compatible:

```bash
./update.sh                 # backend using .env IMAGE_TAG
./update.sh sha-abc123      # backend at a specific tag
./update.sh frontend [tag]
./update.sh all [tag]
```

Manual rollback:

```bash
./deploy.sh backend sha-previous
./deploy.sh frontend sha-previous
```

Database migrations are forward-only; use a compensating migration when
schema changes must be corrected.

## Shared GitHub deployment secrets

Backend and frontend workflows use the same names:

| Secret | Value |
|---|---|
| `SERVER_HOST` | Server IP or stable SSH hostname |
| `SERVER_USER` | `deploy` |
| `SERVER_SSH_KEY` | Private deployment key |
| `SERVER_SSH_PORT` | SSH port, normally `22` |
| `DEPLOYMENT_DIR` | `/home/deploy/SalesSphereERP-Deployment` |

Create a `production` GitHub Environment for deployment protection rules.

## Operations

```bash
docker compose ps
docker compose logs -f app
docker compose logs -f frontend
docker compose logs -f caddy
docker compose exec app wget -qO- http://localhost:3000/health/ready
docker compose exec frontend wget -qO- http://127.0.0.1:8080/healthz
```

The installer writes `/home/deploy/credentials-summary.txt` with server,
image, health, secret-name, and day-to-day command details.

## Validation

```bash
bash -n install.sh deploy.sh update.sh deployment-lib.sh test-install.sh
bash test-install.sh
source ./deployment-lib.sh && require_public_suffix_list
cp .env.example .env
docker compose config
rm .env
```

The GitHub validation workflow also renders and validates the Caddy template
with the official Caddy image.
