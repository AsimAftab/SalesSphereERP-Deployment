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
    ├── .env.example             production env template (copy → .env on droplet)
    ├── bootstrap.sh             one-time droplet setup (Docker, firewall, GHCR login)
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

## First-time droplet setup

1. **Provision** a fresh Ubuntu 22.04+ droplet on DigitalOcean (1 vCPU / 1 GB RAM is plenty for v1).

2. **Create a non-root deploy user** (SSH as root once):
   ```bash
   adduser --disabled-password --gecos "" deploy
   usermod -aG sudo deploy
   mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
   # Paste the public half of the GitHub Actions deploy SSH key:
   nano /home/deploy/.ssh/authorized_keys
   chmod 600 /home/deploy/.ssh/authorized_keys
   chown -R deploy:deploy /home/deploy/.ssh
   ```

3. **Switch to deploy** + clone this repo:
   ```bash
   su - deploy
   cd ~
   git clone https://github.com/AsimAftab/SalesSphereERP-Deployment.git
   cd SalesSphereERP-Deployment
   ```

4. **Run bootstrap** (installs Docker + Compose + UFW + opens 80/443):
   ```bash
   bash bootstrap.sh
   ```
   Log out + back in once it finishes (so the `docker` group membership takes effect).

5. **Fill in production `.env`**:
   ```bash
   cp .env.example .env
   nano .env                       # paste real DATABASE_URL, secrets, SMTP creds
   chmod 600 .env
   ```
   Generate fresh JWT/CSRF secrets — never reuse dev values:
   ```bash
   openssl rand -base64 48         # 32+ char string for each
   ```

6. **Edit `Caddyfile`** to use your real hostname (replace `api.salessphere.com`).

7. **Log in to GHCR** so the droplet can pull the image:
   ```bash
   # On GitHub: Settings → Developer settings → Personal access tokens
   # → Tokens (classic) → Generate new token, scope: read:packages
   echo "ghp_<your-token>" | docker login ghcr.io -u <your-github-username> --password-stdin
   ```

8. **Pull the image and start the stack**:
   ```bash
   docker compose pull
   docker compose up -d
   ```

9. **Apply migrations** (one-shot; safe to re-run):
   ```bash
   docker compose run --rm app bunx prisma migrate deploy
   ```

10. **Seed the platform super-admin** (idempotent):
    ```bash
    docker compose run --rm app bun run db:seed
    ```

11. **Verify**:
    ```bash
    docker compose ps                                # all services Up
    docker compose logs app --tail=50                # boot output
    curl -fsS http://localhost:3000/health/ready     # {"status":"ok",...}
    ```

12. **Point your domain** at the droplet IP. Caddy provisions the TLS cert on the first hit to `https://<your-domain>`.

## Day-to-day

After step 1–12 above, you should never touch the droplet again. The backend repo's CI handles deploys on every push to `main`:

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

**`docker: command not found` after bootstrap** — log out and back in. The `docker` group membership only applies to new shells.

**`error: failed to solve: ghcr.io/...: failed to fetch`** — the droplet hasn't logged in to GHCR. Re-run the `docker login ghcr.io` step from the bootstrap.

**Caddy "no certificates" / 502** — your A record probably doesn't point at the droplet yet, OR the firewall blocks ports 80/443. `sudo ufw status` should show both Allow.

**App container restarts on a loop** — `docker compose logs app --tail=100`. Most common: `DATABASE_URL` is wrong / missing, or there's a pending migration that never ran (run `bunx prisma migrate deploy` once).

**`prisma migrate deploy` fails partway** — fix the migration locally, push a new commit. The `_prisma_migrations` row for the failed migration may need manual `prisma migrate resolve --rolled-back <name>` first.
