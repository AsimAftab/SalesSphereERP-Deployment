#!/usr/bin/env bash
#
# Manual deploy / refresh helper. The GitHub Actions workflow does the
# same thing automatically on every push to `main`; this script is for
# emergencies (CI is down) or for first-deploy / smoke-testing on a fresh
# droplet.
#
# Usage:
#   ./update.sh                 # use whatever IMAGE_TAG is in .env (or `latest`)
#   ./update.sh sha-1a2b3c4     # deploy a specific build (rollback / pin)

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo -e "${GREEN}==>${NC} $1"; }
fail() { echo -e "${RED}xx ${NC} $1"; exit 1; }

if [ ! -f docker-compose.yml ]; then
    fail "Run this from the SalesSphereERP-Deployment directory."
fi

if [ ! -f .env ]; then
    fail ".env not found. Run bootstrap.sh first."
fi

# Allow override via first arg; otherwise leave compose to use whatever
# IMAGE_TAG resolves to from .env (defaulting to `latest`).
if [ "$#" -ge 1 ]; then
    export IMAGE_TAG="$1"
    step "Targeting image $IMAGE_TAG (override)"
else
    step "Targeting image $(grep -E '^IMAGE_TAG=' .env | cut -d= -f2- || echo latest)"
fi

# ----------------------------------------------------------------------
step "Pulling deployment config (compose / Caddyfile updates)"
git fetch --depth 1 origin main
git reset --hard origin/main

# ----------------------------------------------------------------------
step "Pulling app image"
docker compose pull app

# ----------------------------------------------------------------------
step "Applying pending migrations"
docker compose run --rm app bunx prisma migrate deploy

# ----------------------------------------------------------------------
step "Rolling out new app container"
docker compose up -d app

# ----------------------------------------------------------------------
step "Cleaning up dangling images"
docker image prune -f

# ----------------------------------------------------------------------
step "Smoke test"
sleep 3
if curl -fsS --max-time 5 http://localhost:3000/health/ready > /dev/null; then
    echo "    OK"
else
    fail "Health check failed — investigate with: docker compose logs app --tail=100"
fi

step "Done"
