# SalesSphereERP-Deployment

Production deployment topology for the [SalesSphere ERP backend](https://github.com/AsimAftab/SalesSphere-Backend-ERP). Lives on the DigitalOcean Ubuntu droplet, owns the docker-compose stack, the Caddy reverse-proxy config, and the production `.env`.

## What's where

```
SalesSphere-ERP/
├── SalesSphereERP-Backend/      ← source repo (Bun + Prisma + Express)
│                                  CI builds + pushes the Docker image to GHCR.
├── SalesSphereERP-Frontend/     ← Vite + React (separate concern)
└── SalesSphereERP-Deployment/   ← THIS REPO — what runs on the droplet.
    ├── docker-compose.yml       app (from GHCR) + redis + caddy
    ├── Caddyfile                reverse-proxy + auto Let's Encrypt
    ├── .env.example             production env template (used by install.sh)
    ├── install.sh               one-command droplet bootstrap (the magic)
    ├── update.sh                manual deploy / rollback (CI uses the same commands)
    └── README.md                you are here
```

The backend repo's CI builds the Docker image and pushes it to `ghcr.io/asimaftab/salessphere-backend:sha-<short-sha>`. This repo just orchestrates pulling that image + running migrations + restarting Caddy/Redis around it.

## Architecture

```
                       ┌──────────────────────────────────────┐
   Public Internet ───▶│ Caddy (80/443)  ─── auto Let's Encrypt
                       │     │
                       │     ▼ reverse_proxy
                       │ app:3000  ◀── image: ghcr.io/.../sha-<sha>
                       │     │
                       │     ▼ REDIS_URL=redis://redis:6379
                       │  redis:6379  (internal-only, AOF persistence)
                       └─────┬────────────────────────────────┘
                             │
                             ▼ DATABASE_URL
                  DigitalOcean Managed Postgres (Bangalore)
                   — separate from the droplet, has its own
                     daily backups + PITR
```

## First-time droplet setup — one command

Provision a fresh Ubuntu 22.04+ droplet on DigitalOcean (1 vCPU / 1 GB RAM is plenty for v1), then SSH in as root and run:

```bash
curl -fsSL https://raw.githubusercontent.com/AsimAftab/SalesSphereERP-Deployment/main/install.sh -o install.sh
bash install.sh
```

That's it. The script walks through every step interactively in ~1 minute:

1. Installs Docker Engine + Compose plugin + UFW + base utilities (openssl, jq, curl, git)
2. Configures the firewall (allow SSH + HTTP + HTTPS)
3. Creates the non-root `deploy` user (sudo + docker groups)
4. Prompts you to paste the GitHub Actions deploy SSH **public** key
5. Clones this repo into `/home/deploy/SalesSphereERP-Deployment`
6. Prompts for: production domain, DATABASE_URL (Neon **or** DigitalOcean Managed Postgres — both speak vanilla Postgres), GHCR token, SMTP creds (skippable), super-admin email
7. **Auto-generates** JWT_SECRET, JWT_REFRESH_SECRET, CSRF_SECRET, SUPERADMIN_PASSWORD (random 48-char base64). On a rerun these are **preserved** from the existing `.env` so live sessions and the saved credentials summary stay valid.
8. Renders `.env` from the gathered values
9. Renders `Caddyfile` with your real hostname (substitutes the `api.salessphere.com` placeholder)
10. Logs in to GHCR + pulls the app image (copies the docker-config.json to the deploy user too)
11. Pre-checks DNS — warns if your A record doesn't resolve to this droplet's IP yet (Caddy needs that for the TLS handshake)
12. Applies pending Prisma migrations (one-shot container, same image)
13. Seeds the platform super-admin (idempotent — safe to re-run)
14. Brings up `docker compose up -d` + smoke-tests `/health/ready` with retries
15. Saves a credentials summary to `/home/deploy/credentials-summary.txt` (chmod 600) — has the auto-generated super-admin password, GitHub secrets to add, outstanding manual steps

**Idempotent** — safe to re-run if something fails partway. On a rerun the script reads the existing `.env`, pre-fills every prompt with its current value (press ENTER to keep, type to override), and reuses the auto-generated secrets so JWT sessions and the saved super-admin password stay valid. The previous `.env` and `Caddyfile` are still backed up to `.bak.<timestamp>` before being rewritten.

### Pre-set values via env vars (skip prompts entirely)

For repeatable provisioning across multiple droplets:

```bash
DOMAIN=api.salessphere.com \
DATABASE_URL=postgresql://user:pass@host:25061/db?sslmode=require \
GHCR_USER=AsimAftab \
GHCR_TOKEN=ghp_xxxx \
DEPLOY_SSH_KEY="ssh-ed25519 AAAA... github-deploy" \
SUPERADMIN_EMAIL=admin@salessphere.com \
SMTP_HOST=smtp.resend.com \
SMTP_USER=resend \
SMTP_PASS=re_xxxx \
bash install.sh
```

Any vars you don't set, the script prompts for. Mixed mode is fine — set what you have, get prompted for the rest.

### Outstanding manual steps after the script

The script prints these at the end (and saves them in the credentials file) — copy them down:

1. **Point `<your-domain>`'s A record at the droplet IP.** Caddy provisions the TLS cert on the first request to `https://<your-domain>`. Until DNS resolves, only `http://localhost:3000` from inside the droplet works.
2. **Add 6 GitHub secrets to the backend repo** (Settings → Secrets and variables → Actions): `DROPLET_HOST`, `DROPLET_USER` (`deploy`), `DROPLET_SSH_KEY` (the **private** half of the deploy SSH key), `DROPLET_SSH_PORT` (only if non-22), `DEPLOYMENT_DIR` (`/home/deploy/SalesSphereERP-Deployment`), `HEALTH_URL` (`https://<your-domain>/health/ready`).
3. **Create a `production` GitHub Environment** (Settings → Environments → New environment). Empty for v1; add deploy approvals when you have a team.
4. **Change the super-admin password.** Sign in with the auto-generated one in `credentials-summary.txt`, hit `POST /auth/forgot-password`, redeem the email, set your real password.
5. **Fill in any blanks in `.env`** you skipped during the prompt (Cloudinary, IRD, etc).

## Day-to-day

After the one-command bootstrap above, you should never touch the droplet again. The backend repo's CI handles deploys on every push to `main`:

```
main push → CI builds → GHCR pushes sha-<short-sha>
                     → SSH to droplet
                       → cd to this dir, git pull
                       → docker compose pull app
                       → docker compose run --rm app bunx prisma migrate deploy
                       → docker compose up -d app
                     → curl health check
```

When you do need manual intervention:

```bash
# Roll forward to whatever's tagged `latest` (or pinned in .env's IMAGE_TAG):
./update.sh

# Pin to a specific build (rollback):
./update.sh sha-9e34f12

# Tail logs:
docker compose logs -f app
docker compose logs -f caddy

# Restart just one service:
docker compose restart app

# Full reload (rare — usually after editing compose / Caddyfile):
docker compose down && docker compose up -d
```

## GitHub secrets the backend's workflow needs

Set these on the **backend repo** (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `DROPLET_HOST` | The droplet's public IP or stable DNS name |
| `DROPLET_USER` | `deploy` |
| `DROPLET_SSH_KEY` | Private half of the deploy SSH key (the public half is in `~deploy/.ssh/authorized_keys`) |
| `DROPLET_SSH_PORT` | Optional; defaults to 22 |
| `DEPLOYMENT_DIR` | `/home/deploy/SalesSphereERP-Deployment` |
| `HEALTH_URL` | `https://api.salessphere.com/health/ready` |

Plus the GitHub `production` environment (Settings → Environments → New environment) — empty is fine for v1; add deploy approvals when you have a team.

## Rollback

Two ways:

**(a) Via CI** — easiest. Revert the bad commit on `main` in the backend repo. The next push triggers a redeploy of the prior good state.

**(b) Manual on the droplet** — when CI is down, or when you need to pin to an older build than the previous commit:
```bash
ssh deploy@<droplet>
cd ~/SalesSphereERP-Deployment
docker images ghcr.io/asimaftab/salessphere-backend           # see tagged builds
./update.sh sha-1a2b3c4                                       # roll back to a specific build
```

Migrations don't roll back automatically — write a new compensating migration if a bad migration shipped. Never reverse a Prisma migration in place.

## Troubleshooting

**`Permission denied (publickey)` from CI** — the public half of the GitHub Actions deploy key isn't in `/home/deploy/.ssh/authorized_keys`, or its permissions are wrong (must be `0600`).

**`docker: command not found` after install** — log out and back in. The `docker` group membership only applies to new shells. (The script itself runs as root so this only affects you when you SSH in as `deploy` later.)

**`error: failed to solve: ghcr.io/...: failed to fetch`** or **`denied: denied`** during install — the GHCR Personal Access Token is missing, expired, or lacks the right scope. The token needs **`read:packages`** (classic tokens) or **Packages: read** (fine-grained tokens) and must belong to a user with read access to the image. Generate one at <https://github.com/settings/tokens>, then re-run `bash install.sh` — your previous answers are pre-filled, you only need to enter the new token. Or log in manually:
```bash
echo $GHCR_TOKEN | docker login ghcr.io -u <user> --password-stdin
```

**`install.sh` prompts I missed values for** — it's idempotent, just re-run. The current values from `.env` are pre-filled into every prompt (press ENTER to keep), and the existing file is backed up to `.env.bak.<timestamp>` before being rewritten. Or edit `.env` directly with `nano` and `docker compose up -d` to apply.

**Caddy "no certificates" / 502** — your A record probably doesn't point at the droplet yet, OR the firewall blocks ports 80/443. `sudo ufw status` should show both Allow.

**App container restarts on a loop** — `docker compose logs app --tail=100`. Most common: `DATABASE_URL` is wrong / missing, or there's a pending migration that never ran (run `bunx prisma migrate deploy` once).

**`prisma migrate deploy` fails partway** — fix the migration locally, push a new commit. The `_prisma_migrations` row for the failed migration may need manual `prisma migrate resolve --rolled-back <name>` first.
