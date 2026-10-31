# SalesSphereERP-Deployment

Provider-neutral production deployment for the SalesSphere ERP API and web
frontend. Application images are pulled from GHCR; only Caddy publishes server
ports.

Azure uses one existing VM for all four containers and one existing PostgreSQL
16 Flexible Server. Terraform adopts these resources rather than recreating
them. See [the Azure/Terraform runbook](docs/azure-terraform.md) for infrastructure,
cost/credit constraints, state bootstrap, manual Terraform approval, and cutover.
Production readiness still requires database credentials, read-only data checks,
and verified DNS/TLS; provisioning alone is not a completed deployment.

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
| `SERVER_KNOWN_HOSTS` | Host keys verified through a trusted channel |
| `SERVER_SSH_PORT` | SSH port, normally `22` |
| `DEPLOYMENT_DIR` | `/home/deploy/SalesSphereERP-Deployment` |

Create a `production` GitHub Environment for deployment protection rules.

Application CI authenticates to GHCR through `release.sh` using its short-lived
GitHub token over SSH stdin; authentication, pulls, and rollout share the same
cross-repository lock. The normal `deploy.sh` command remains available for manual
operations. `prepare_only=true` on either app workflow pulls the new image
without starting services, migrations, or public smoke tests, even while the
normal deploy gate is disabled.

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

### Viewing live tracking

`scripts/sstrack.sh` shows field reps' live tracking and raw GPS pings from the
server. It is **read-only**: it opens the database with
`default_transaction_read_only=on`, so no command can change data. It runs
`psql` in a throwaway `postgres:16-alpine` container (pulled once), reads
`DATABASE_URL` from `.env` without printing it, and restarts nothing.

Once per server, make it a command you can type from anywhere:

```bash
sudo ~/SalesSphereERP-Deployment/scripts/sstrack.sh install
```

| Command | Shows |
|---|---|
| `sstrack live [--org NAME]` | Everyone being tracked now: last ping, minutes since, pings, battery, accuracy, current address. Refreshes every 10 s; Ctrl+C stops. |
| `sstrack follow EMAIL [--keep]` | One user's GPS pings as they arrive, like `logs -f`. Notes when tracking pauses or resumes, and stops when the session ends (`--keep` waits for the next one). Ctrl+C stops sooner. |
| `sstrack user EMAIL [DAY]` | One user's sessions and every GPS ping, start to end. Prints and stops. |
| `sstrack users [DAY] [--org NAME] [--pings]` | Every tracked user, one line each; `--pings` lists each user's pings under their name. |
| `sstrack session SESSION_ID` | Every ping of one session. |
| `sstrack find TEXT` | Find a user's email by name or email. |

`DAY` is optional: nothing means today; `yesterday`, `3d` (the last 3 days, up to
`15d`) or a date like `2026-10-30` also work. Times are Nepal time. Add `--csv`
to `user`, `users` or `session` to save a file (`... --csv > ajay.csv`) and
download it over SFTP. Pings are deleted after `TRACKING_RETENTION_DAYS`
(15 days), so older days come back empty.

On screen each ping shows only what says whether pings are arriving and where
the user is: `#` (its place in the session), a mark (`▶ START` / `● LATEST`),
time, address, accuracy, battery, and `sent N min late` for a ping the phone
held with no signal. `--csv` keeps every column (lat/lng, speed, nearest stop,
a Google Maps link, ...).

Each ping shows the address the phone saved. The app looks one up only now and
then (it costs money and battery), so pings without their own show the last
known address in that session, marked `~`. `sstrack` never looks up addresses
itself. A session's km is its cleaned distance, filled in when the session
ends; an open session shows `(open)` (the web shows its distance so far).

### Reading the server logs

`scripts/sslogs.sh` turns the containers' JSON logs into one readable line
each, in Nepal time, without request ids, IP addresses or process details, and
with tokens in URLs masked. It only reads `docker logs`; it changes and
restarts nothing.

```bash
sudo ~/SalesSphereERP-Deployment/scripts/sslogs.sh install
```

| Command | Shows |
|---|---|
| `sslogs status` | Containers, CPU/memory, server load, disk, and how fast the API and website answer. |
| `sslogs errors [--since 1h]` | Warnings and errors from the API, with the error's message and where it came from. |
| `sslogs slow [--since 2h] [--top 25]` | The slowest API requests, slowest first. |
| `sslogs api [--since 30m] [-f]` | API requests and events, one line each; `-f` keeps streaming. |
| `sslogs user EMAIL [--since 24h]` | Log lines about one user (tracking, sockets, jobs). Plain API requests carry no user. |
| `sslogs web [--since 1h] [--errors]` | Website + API access log from Caddy; `--errors` keeps only 4xx/5xx. |

`--since` takes `30m`, `2h` or `1d`, as far back as the container still holds.

## Validation

```bash
bash -n install.sh deploy.sh release.sh update.sh deployment-lib.sh test-install.sh test-release.sh bootstrap-host.sh scripts/terraform-init.sh scripts/sstrack.sh scripts/sslogs.sh
bash test-install.sh
bash test-release.sh
source ./deployment-lib.sh && require_public_suffix_list
cp .env.example .env
docker compose config
rm .env
```

The GitHub validation workflow also renders and validates the Caddy template
with the official Caddy image.
