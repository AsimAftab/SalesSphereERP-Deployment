#!/usr/bin/env bash
#
# Manual deploy / refresh. The GitHub Actions workflow does the same thing
# on every push to main; this is for when CI is down, for a rollback, or
# for smoke-testing a fresh server.
#
# Usage:
#   ./update.sh                 # deploy whatever IMAGE_TAG .env names
#   ./update.sh sha-1a2b3c4     # deploy a specific build (rollback / pin)
#   ./update.sh --no-migrate    # skip migrations (rolling back to an older
#                               # image whose schema is already applied)
#
# On failure it prints the app log and exits non-zero, and on a health-check
# failure it names the previous image so a rollback is one command away.

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

step() { echo -e "${GREEN}==>${NC} ${BOLD}$1${NC}"; }
dim()  { echo -e "    ${DIM}$1${NC}"; }
warn() { echo -e "${YELLOW}!! ${NC} $1"; }
fail() { echo -e "${RED}xx ${NC}${BOLD}$1${NC}"; exit 1; }

cd "$(dirname "$0")"

[ -f docker-compose.yml ] || fail "Run this from the SalesSphereERP-Deployment directory."
[ -f .env ]               || fail ".env not found — run install.sh first."
[ -f Caddyfile ]          || fail "Caddyfile not found — run install.sh (it renders from Caddyfile.template)."

RUN_MIGRATIONS=1
TAG_OVERRIDE=""
for arg in "$@"; do
  case "$arg" in
    --no-migrate) RUN_MIGRATIONS=0 ;;
    -*)           fail "Unknown option: $arg" ;;
    *)            TAG_OVERRIDE="$arg" ;;
  esac
done

# What is running right now — needed to name a rollback target if the new
# image fails its health check.
PREVIOUS_IMAGE="$(docker inspect --format '{{.Config.Image}}' salessphere-app 2>/dev/null || echo '')"

if [ -n "$TAG_OVERRIDE" ]; then
  export IMAGE_TAG="$TAG_OVERRIDE"
  step "Targeting image tag ${IMAGE_TAG} (override)"
else
  step "Targeting image tag $(grep -E '^IMAGE_TAG=' .env | cut -d= -f2- || echo latest)"
fi
[ -n "$PREVIOUS_IMAGE" ] && dim "Currently running: ${PREVIOUS_IMAGE}"

# ----------------------------------------------------------------------
step "Pulling deployment config (compose / Caddyfile template)"
git fetch --depth 1 origin main
# .env and the rendered Caddyfile are gitignored, so this cannot clobber them.
git reset --hard origin/main

# The template may have changed upstream; re-render so a Caddy config fix
# actually reaches this server instead of sitting in git.
if [ -f Caddyfile.template ]; then
  DOMAIN_FROM_ENV="$(grep -E '^APP_URL=' .env | head -n1 | sed -E 's|^APP_URL=https?://||' | cut -d/ -f1)"
  if [ -n "$DOMAIN_FROM_ENV" ]; then
    sed "s|{{DOMAIN}}|${DOMAIN_FROM_ENV}|g" Caddyfile.template > Caddyfile.new
    if ! cmp -s Caddyfile Caddyfile.new; then
      cp Caddyfile "Caddyfile.bak.$(date +%Y%m%d-%H%M%S)"
      mv Caddyfile.new Caddyfile
      step "Caddyfile re-rendered from an updated template"
    else
      rm -f Caddyfile.new
    fi
  fi
fi

# ----------------------------------------------------------------------
step "Pulling app image"
docker compose pull app
dim "Digest: $(docker compose images app --format json 2>/dev/null \
  | head -c 400 | grep -oE '"Digest":"[^"]*"' | head -1 | cut -d'"' -f4 || echo 'unknown')"

# ----------------------------------------------------------------------
if [ "$RUN_MIGRATIONS" -eq 1 ]; then
  step "Applying pending migrations"
  # --no-deps: this is a one-off task container, it does not need the whole
  # stack, and starting Caddy here would bind :80 before the new app is up.
  if ! docker compose run --rm --no-deps app bunx prisma migrate deploy; then
    fail "Migrations failed — the running container was NOT replaced.
       The previous version is still serving. Investigate, then re-run.
       If the database is unreachable, check its firewall allows this host."
  fi
else
  warn "Skipping migrations (--no-migrate)"
fi

# ----------------------------------------------------------------------
step "Rolling out new app container"
docker compose up -d app

# ----------------------------------------------------------------------
step "Waiting for /health/ready (up to 60s)"
HEALTH_OK=0
for attempt in $(seq 1 20); do
  sleep 3
  if curl -fsS --max-time 5 http://localhost:3000/health/ready > /dev/null 2>&1; then
    HEALTH_OK=1
    echo "    OK after $((attempt * 3))s"
    break
  fi
  [ $((attempt % 5)) -eq 0 ] && dim "still waiting (${attempt}/20)…"
done

if [ "$HEALTH_OK" -ne 1 ]; then
  echo
  warn "Last 40 lines of the app log:"
  docker compose logs app --tail=40 2>&1 | sed 's/^/      /' || true
  echo
  if [ -n "$PREVIOUS_IMAGE" ]; then
    PREV_TAG="${PREVIOUS_IMAGE##*:}"
    fail "Health check failed after 60s.
       Roll back with:
         ./update.sh ${PREV_TAG} --no-migrate
       (--no-migrate because the newer schema is already applied; an older
        image is normally forward-compatible, but verify before relying on it.)"
  fi
  fail "Health check failed after 60s — see the log above."
fi

# ----------------------------------------------------------------------
# Only prune once the new container is proven healthy: the old image is the
# rollback target, and pruning it first would mean re-pulling under pressure.
step "Cleaning up dangling images"
docker image prune -f > /dev/null

step "Done"
