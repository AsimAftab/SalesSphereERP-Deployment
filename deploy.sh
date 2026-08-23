#!/usr/bin/env bash
#
# Production deployment entrypoint.
# Usage: ./deploy.sh <backend|frontend|all> [sha-tag]

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
step() { echo -e "${GREEN}==>${NC} ${BOLD}$1${NC}"; }
dim()  { echo -e "    ${DIM}$1${NC}"; }
warn() { echo -e "${YELLOW}!! ${NC} $1"; }
fail() { echo -e "${RED}xx ${NC}${BOLD}$1${NC}" >&2; exit 1; }

cd "$(dirname "$0")"
. ./deployment-lib.sh

[ -f docker-compose.yml ] || fail "docker-compose.yml is missing."

TARGET="${1:-}"
TAG_OVERRIDE="${2:-}"
[ "$#" -le 2 ] || fail "Usage: ./deploy.sh <backend|frontend|all> [sha-tag]"
case "$TARGET" in
  backend|frontend|all) ;;
  *) fail "Usage: ./deploy.sh <backend|frontend|all> [sha-tag]" ;;
esac
if [ -n "$TAG_OVERRIDE" ] && [[ ! "$TAG_OVERRIDE" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  fail "Invalid image tag: $TAG_OVERRIDE"
fi
[ -f .env ] || fail ".env is missing — run install.sh first."

LOCK_FILE="${SALESSPHERE_DEPLOY_LOCK:-/home/deploy/.salessphere-erp-deploy.lock}"
if [ "${DEPLOY_LOCK_HELD:-0}" != "1" ]; then
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  exec 9>"$LOCK_FILE" || fail "Cannot open deployment lock: $LOCK_FILE"
  step "Waiting for the server deployment lock"
  flock -w "${DEPLOY_LOCK_TIMEOUT:-900}" 9 \
    || fail "Another deployment still holds $LOCK_FILE after ${DEPLOY_LOCK_TIMEOUT:-900}s."
fi

# Re-exec after reset so this process never continues reading a script while
# git is replacing that same file. Descriptor 9 survives exec and keeps the
# deployment lock held across the refresh.
if [ "${DEPLOY_REFRESHED:-0}" != "1" ]; then
  step "Refreshing deployment configuration from origin/main"
  git rev-parse --is-inside-work-tree > /dev/null 2>&1 \
    || fail "Deployment directory is not a Git worktree."
  git fetch --depth 1 origin main
  git reset --hard origin/main
  [ -f .env ] || fail ".env disappeared during refresh; refusing to continue."
  [ -f Caddyfile.template ] || fail "Caddyfile.template is missing after refresh."
  [ -r data/public_suffix_list.dat ] \
    || fail "The vendored Public Suffix List is missing or unreadable after refresh."
  export DEPLOY_REFRESHED=1 DEPLOY_LOCK_HELD=1
  if [ -n "$TAG_OVERRIDE" ]; then
    exec bash "$PWD/deploy.sh" "$TARGET" "$TAG_OVERRIDE"
  fi
  exec bash "$PWD/deploy.sh" "$TARGET"
fi

env_value() {
  grep -E "^$1=" .env 2>/dev/null | head -n1 | cut -d= -f2- || true
}

API_DOMAIN="${API_DOMAIN:-$(env_value API_DOMAIN)}"
FRONTEND_DOMAIN="${FRONTEND_DOMAIN:-$(env_value FRONTEND_DOMAIN)}"
AUTH_SITE_DOMAIN="${AUTH_SITE_DOMAIN:-$(env_value AUTH_SITE_DOMAIN)}"
require_public_suffix_list \
  || fail "The vendored Public Suffix List is unavailable; deployment validation fails closed."
[ -n "$API_DOMAIN" ] || API_DOMAIN="$(domain_from_url "$(env_value APP_URL)")"
[ -n "$FRONTEND_DOMAIN" ] || FRONTEND_DOMAIN="$(domain_from_url "$(env_value CORS_ORIGIN)")"
validate_domain "$API_DOMAIN" || fail "API_DOMAIN is missing or invalid in .env."
validate_domain "$FRONTEND_DOMAIN" || fail "FRONTEND_DOMAIN is missing or invalid in .env."
validate_domain "$AUTH_SITE_DOMAIN" || fail "AUTH_SITE_DOMAIN is missing or invalid in .env."
validate_auth_site_domains "$API_DOMAIN" "$FRONTEND_DOMAIN" "$AUTH_SITE_DOMAIN" \
  || fail "API_DOMAIN and FRONTEND_DOMAIN must be different and each must equal
       AUTH_SITE_DOMAIN or be its proper subdomain. Lookalike suffixes and hosts
       outside the explicitly configured auth site are rejected."

if [ -n "$TAG_OVERRIDE" ]; then
  case "$TARGET" in
    backend) export IMAGE_TAG="$TAG_OVERRIDE" ;;
    frontend) export FRONTEND_IMAGE_TAG="$TAG_OVERRIDE" ;;
    all) export IMAGE_TAG="$TAG_OVERRIDE" FRONTEND_IMAGE_TAG="$TAG_OVERRIDE" ;;
  esac
  step "Targeting ${TARGET} image tag ${TAG_OVERRIDE}"
fi

PREVIOUS_BACKEND="$(docker inspect --format '{{.Config.Image}}' salessphere-app 2>/dev/null || true)"
PREVIOUS_FRONTEND="$(docker inspect --format '{{.Config.Image}}' salessphere-frontend 2>/dev/null || true)"

rollback_guidance() {
  local service="$1" image="$2"
  [ -n "$image" ] || return 0
  local tag="${image##*:}"
  warn "Previous ${service} image: ${image}"
  if [ "$tag" != "$image" ]; then
    warn "Rollback command: ./deploy.sh ${service} ${tag}"
  else
    warn "Restore the previous ${service} image tag in .env, then redeploy it."
  fi
}

on_failure() {
  local rc=$?
  echo
  warn "Deployment failed explicitly (target=${TARGET}, exit=${rc})."
  case "$TARGET" in
    backend) rollback_guidance backend "$PREVIOUS_BACKEND" ;;
    frontend) rollback_guidance frontend "$PREVIOUS_FRONTEND" ;;
    all)
      rollback_guidance backend "$PREVIOUS_BACKEND"
      rollback_guidance frontend "$PREVIOUS_FRONTEND"
      ;;
  esac
  exit "$rc"
}
trap on_failure ERR

step "Rendering and validating Caddy configuration"
install_caddy_config "$API_DOMAIN" "$FRONTEND_DOMAIN" "$AUTH_SITE_DOMAIN"

wait_for_health() {
  local service="$1" url="$2" attempts="${3:-20}"
  step "Waiting for ${service} ${url} (up to $((attempts * 3))s)"
  local attempt
  for attempt in $(seq 1 "$attempts"); do
    sleep 3
    if docker compose exec -T "$service" wget -qO- --tries=1 "$url" > /dev/null 2>&1; then
      dim "${service} healthy after $((attempt * 3))s"
      return 0
    fi
    [ $((attempt % 5)) -eq 0 ] && dim "still waiting (${attempt}/${attempts})…"
  done
  docker compose logs "$service" --tail=40 2>&1 | sed 's/^/      /' || true
  return 1
}

deploy_backend() {
  step "Pulling backend image"
  docker compose pull app
  step "Applying backend migrations before replacement"
  docker compose run --rm --no-deps app bunx prisma migrate deploy
  step "Replacing backend service"
  docker compose up -d app
  wait_for_health app http://localhost:3000/health/ready
}

deploy_frontend() {
  step "Pulling frontend image"
  docker compose pull frontend
  step "Replacing frontend service"
  docker compose up -d frontend
  wait_for_health frontend http://127.0.0.1:8080/healthz
}

case "$TARGET" in
  backend) deploy_backend ;;
  frontend) deploy_frontend ;;
  all) deploy_backend; deploy_frontend ;;
esac

step "Applying validated Caddy configuration"
# Both dependencies were health-checked above (or were already running for a
# single-service deploy). Do not reconcile them here: the other service's
# immutable tag exists only in its deployment process environment, while
# `.env` intentionally retains `latest` as the manual default.
docker compose up -d --no-deps caddy
if docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile; then
  dim "Caddy reloaded"
else
  docker compose logs caddy --tail=40 2>&1 | sed 's/^/      /' || true
  if [ -f Caddyfile.rollback ]; then
    warn "Restoring the previous validated Caddy configuration."
    cp Caddyfile.rollback Caddyfile
    docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile || true
  fi
  fail "Caddy reload failed."
fi

trap - ERR
step "Deployment complete: ${TARGET}"
