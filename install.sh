#!/usr/bin/env bash
#
# SalesSphere ERP — one-command droplet bootstrap.
#
# Run on a fresh Ubuntu 22.04+ DigitalOcean droplet as root. Walks through
# every step end-to-end:
#
#   1. Installs system deps (Docker, Compose plugin, UFW, openssl, jq, git)
#   2. Configures the firewall (SSH + HTTP + HTTPS)
#   3. Creates the non-root `deploy` user, installs the GitHub Actions
#      deploy SSH public key
#   4. Clones (or pulls) this repo into /home/deploy/SalesSphereERP-Deployment
#   5. Prompts for required values (domain, DATABASE_URL, GHCR token, etc.)
#   6. Auto-generates JWT/CSRF secrets + the super-admin password
#   7. Renders .env from template
#   8. Renders Caddyfile with your real domain
#   9. Logs in to GHCR + pulls the app image
#  10. Applies pending Prisma migrations
#  11. Seeds the platform super-admin
#  12. Brings up the stack with docker compose
#  13. Smoke-tests /health/ready
#  14. Prints a summary with credentials + the GitHub secrets you still
#      need to add to the backend repo
#
# Idempotent — safe to re-run if something fails partway. Existing files
# are backed up to .bak before being overwritten.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AsimAftab/SalesSphereERP-Deployment/main/install.sh -o install.sh
#   bash install.sh
#
# Or with values pre-set as env vars (skips prompts for whatever's set):
#   DOMAIN=api.salessphere.com \
#   DATABASE_URL=postgresql://... \
#   GHCR_USER=AsimAftab \
#   GHCR_TOKEN=ghp_... \
#   DEPLOY_SSH_KEY="ssh-ed25519 AAAA... github-deploy" \
#   bash install.sh

set -euo pipefail

# ============================================================
# Constants + colour helpers
# ============================================================
DEPLOY_USER="deploy"
DEPLOY_HOME="/home/${DEPLOY_USER}"
REPO_URL="https://github.com/AsimAftab/SalesSphereERP-Deployment.git"
REPO_DIR="${DEPLOY_HOME}/SalesSphereERP-Deployment"
GHCR_IMAGE_DEFAULT="ghcr.io/asimaftab/salessphere-backend"
SUMMARY_FILE="${DEPLOY_HOME}/credentials-summary.txt"

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

banner() {
  echo
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}${BOLD} $1${NC}"
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
step() { echo -e "${GREEN}==>${NC} ${BOLD}$1${NC}"; }
note() { echo -e "    $1"; }
warn() { echo -e "${YELLOW}!! ${NC} $1"; }
fail() { echo -e "${RED}xx ${NC}${BOLD}$1${NC}"; exit 1; }

# ============================================================
# Pre-flight
# ============================================================
[ "$(id -u)" -eq 0 ] || fail "Run as root: sudo bash $0"

if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    warn "This script targets Ubuntu — you're on ${ID:-unknown}. Continuing anyway."
  elif [ "${VERSION_ID%%.*}" -lt 22 ]; then
    warn "Ubuntu < 22.04 detected (${VERSION_ID}). 22.04+ recommended."
  fi
fi

# ============================================================
# Helpers — prompts that respect pre-set env vars
# ============================================================
prompt() {
  # prompt VAR_NAME "Description" "default"
  local var_name="$1" desc="$2" default="${3:-}"
  local current="${!var_name:-}"
  if [ -n "$current" ]; then
    # Value already set — from a pre-set env var (CI use) or pre-loaded
    # from .env on rerun. In a non-interactive shell take it silently;
    # in a terminal show it as the default so the operator can override.
    if [ ! -t 0 ]; then
      note "$desc: ${BOLD}$current${NC} (from env)"
      return
    fi
    local value
    read -r -p "  $desc [$current]: " value
    [ -n "$value" ] && printf -v "$var_name" '%s' "$value"
    return
  fi
  local value
  if [ -n "$default" ]; then
    read -r -p "  $desc [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "  $desc: " value
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_secret() {
  local var_name="$1" desc="$2"
  local current="${!var_name:-}"
  if [ -n "$current" ]; then
    if [ ! -t 0 ]; then
      note "$desc: ${BOLD}<from env>${NC}"
      return
    fi
    # Interactive rerun: ENTER keeps the existing value (silent so the
    # secret never echoes). Any other input replaces it.
    local value
    read -r -s -p "  $desc [ENTER to keep current]: " value
    echo
    [ -n "$value" ] && printf -v "$var_name" '%s' "$value"
    return
  fi
  local value
  read -r -s -p "  $desc: " value
  echo
  printf -v "$var_name" '%s' "$value"
}

confirm() {
  # confirm "Question?" returns 0 if yes
  local q="$1" answer
  read -r -p "  $q [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

gen_secret() { openssl rand -base64 48 | tr -d '\n=' | head -c 48; }

is_email() { [[ "$1" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; }
is_url()   { [[ "$1" =~ ^https?:// ]]; }
is_pgurl() { [[ "$1" =~ ^postgres(ql)?:// ]]; }

# Idempotent re-run support: pre-fill a script variable from an existing
# .env file. Only sets if currently empty (caller-supplied env vars and
# values from prior `prompt`s win). Tolerates lines with `=` in the value.
load_env_var() {
  # load_env_var ENV_KEY [VAR_NAME=ENV_KEY] [FILE=.env]
  local key="$1" var="${2:-$1}" file="${3:-.env}"
  [ -f "$file" ] || return 0
  [ -z "${!var:-}" ] || return 0
  local val
  val=$(grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | sed -E "s/^${key}=//")
  [ -n "$val" ] || return 0
  printf -v "$var" '%s' "$val"
}

# ============================================================
# Phase 1 — system packages
# ============================================================
banner "Phase 1 — System packages"

step "Updating apt index"
apt-get update -qq

step "Installing base utilities"
DEBIAN_FRONTEND=noninteractive apt-get install -qq -y \
  ca-certificates curl gnupg openssl jq git ufw wget

step "Installing Docker Engine + Compose plugin"
if command -v docker > /dev/null 2>&1; then
  note "Docker already installed: $(docker --version)"
else
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -qq -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

# ============================================================
# Phase 2 — firewall
# ============================================================
banner "Phase 2 — Firewall (UFW)"
ufw allow OpenSSH > /dev/null
ufw allow 80/tcp  > /dev/null
ufw allow 443/tcp > /dev/null
ufw --force enable > /dev/null
step "UFW enabled (allow: 22, 80, 443)"

# ============================================================
# Phase 3 — deploy user + SSH key
# ============================================================
banner "Phase 3 — Deploy user"

if id "$DEPLOY_USER" > /dev/null 2>&1; then
  note "User '$DEPLOY_USER' already exists"
else
  step "Creating user '$DEPLOY_USER'"
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG sudo,docker "$DEPLOY_USER"

step "Installing GitHub Actions deploy SSH public key"
mkdir -p "${DEPLOY_HOME}/.ssh"
chmod 700 "${DEPLOY_HOME}/.ssh"
AUTH_KEYS="${DEPLOY_HOME}/.ssh/authorized_keys"
touch "$AUTH_KEYS"

if [ -z "${DEPLOY_SSH_KEY:-}" ]; then
  echo
  note "Paste the GitHub Actions deploy public key (one line, then ENTER):"
  read -r DEPLOY_SSH_KEY
fi

if [ -z "${DEPLOY_SSH_KEY:-}" ]; then
  warn "No SSH key provided — skipping. CI deploys will fail until you add one to ${AUTH_KEYS}."
elif grep -qF "$DEPLOY_SSH_KEY" "$AUTH_KEYS"; then
  note "Key already in authorized_keys"
else
  echo "$DEPLOY_SSH_KEY" >> "$AUTH_KEYS"
  note "Key appended"
fi
chmod 600 "$AUTH_KEYS"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"

# ============================================================
# Phase 4 — deployment repo
# ============================================================
banner "Phase 4 — Deployment repo"

if [ -d "$REPO_DIR/.git" ]; then
  step "Repo already cloned — pulling latest"
  sudo -u "$DEPLOY_USER" git -C "$REPO_DIR" fetch --depth 1 origin main
  sudo -u "$DEPLOY_USER" git -C "$REPO_DIR" reset --hard origin/main
else
  step "Cloning $REPO_URL into $REPO_DIR"
  sudo -u "$DEPLOY_USER" git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"

# Idempotent re-run: pull the previous run's values out of .env so the
# user can hit Enter through unchanged prompts and the auto-generated
# JWT/CSRF secrets + super-admin password are preserved (rotating them
# would invalidate every active session and break the saved credentials
# summary).
ENV_PRELOADED=0
if [ -f .env ]; then
  ENV_PRELOADED=1
  # DOMAIN isn't a literal .env key — recover it from APP_URL=https://<host>.
  if [ -z "${DOMAIN:-}" ]; then
    DOMAIN=$(grep -E '^APP_URL=' .env 2>/dev/null \
      | head -n1 | sed -E 's|^APP_URL=https?://||' | cut -d/ -f1)
  fi
  load_env_var CORS_ORIGIN
  load_env_var SUPERADMIN_EMAIL
  load_env_var DATABASE_URL
  load_env_var IMAGE_TAG
  load_env_var SMTP_HOST
  load_env_var SMTP_PORT
  load_env_var SMTP_USER
  load_env_var SMTP_PASS
  load_env_var SMTP_FROM
  load_env_var SMTP_FROM_NAME
  # Preserve generated secrets across reruns.
  load_env_var JWT_SECRET
  load_env_var JWT_REFRESH_SECRET
  load_env_var CSRF_SECRET
  load_env_var SUPERADMIN_PASSWORD
fi

# ============================================================
# Phase 5 — interactive configuration
# ============================================================
banner "Phase 5 — Configuration"

note "Press ENTER to accept defaults shown in [brackets]. Pre-set env vars are picked up automatically."
if [ "$ENV_PRELOADED" -eq 1 ]; then
  note "Existing .env detected — its values are pre-filled below; press ENTER to keep each."
fi
echo

prompt DOMAIN "Production domain (e.g. api.salessphere.com)"
[ -n "$DOMAIN" ] || fail "DOMAIN is required"

prompt CORS_ORIGIN "Frontend origin (CORS allowed)" "https://app.${DOMAIN#api.}"
prompt SUPERADMIN_EMAIL "Platform super-admin email" "admin@${DOMAIN#api.}"
is_email "$SUPERADMIN_EMAIL" || fail "Invalid email: $SUPERADMIN_EMAIL"

prompt_secret DATABASE_URL "DATABASE_URL (Neon or DO Managed Postgres connection string)"
is_pgurl "$DATABASE_URL" || fail "DATABASE_URL must start with postgresql:// or postgres://"

prompt GHCR_USER "GHCR username" "AsimAftab"
prompt_secret GHCR_TOKEN "GHCR Personal Access Token (read:packages scope)"
[ -n "$GHCR_TOKEN" ] || fail "GHCR_TOKEN is required to pull the app image"

prompt GHCR_IMAGE "GHCR image (no tag)" "$GHCR_IMAGE_DEFAULT"
prompt IMAGE_TAG "Image tag to deploy" "latest"

echo
note "SMTP — leave blank to skip (you can configure later in .env)."
prompt SMTP_HOST "SMTP host" ""
prompt SMTP_PORT "SMTP port" "465"
prompt SMTP_USER "SMTP username" ""
prompt_secret SMTP_PASS "SMTP password (or app-specific password)"
prompt SMTP_FROM "SMTP from address" "no-reply@${DOMAIN#api.}"
prompt SMTP_FROM_NAME "SMTP from name" "SalesSphere"

# ============================================================
# Phase 6 — secrets + render templates
# ============================================================
banner "Phase 6 — Generating secrets + rendering config"

# Reuse any secret that was preserved from an existing .env (idempotent
# rerun). Rotating these on every run would invalidate sessions and
# render the saved credentials-summary stale. Generate only what's missing.
GENERATED_COUNT=0
PRESERVED_COUNT=0
for var in JWT_SECRET JWT_REFRESH_SECRET CSRF_SECRET SUPERADMIN_PASSWORD; do
  if [ -n "${!var:-}" ]; then
    PRESERVED_COUNT=$((PRESERVED_COUNT + 1))
  else
    printf -v "$var" '%s' "$(gen_secret)"
    GENERATED_COUNT=$((GENERATED_COUNT + 1))
  fi
done
step "Secrets ready: ${GENERATED_COUNT} generated, ${PRESERVED_COUNT} preserved from existing .env (JWT × 2, CSRF, super-admin password)"

# Back up existing .env if present (idempotent re-runs)
if [ -f .env ] && ! cmp -s .env .env.example; then
  ts="$(date +%Y%m%d-%H%M%S)"
  step "Backing up existing .env to .env.bak.${ts}"
  cp .env ".env.bak.${ts}"
fi

step "Rendering .env"
cat > .env <<EOF
# Generated by install.sh on $(date -Iseconds)
# Edit by hand — install.sh re-run will back this up to .env.bak.<timestamp>.

# --- Image ---
IMAGE_TAG=${IMAGE_TAG}

# --- Server ---
NODE_ENV=production
PORT=3000
APP_URL=https://${DOMAIN}
CORS_ORIGIN=${CORS_ORIGIN}

# --- Database ---
DATABASE_URL=${DATABASE_URL}

# --- Redis (internal docker network) ---
REDIS_URL=redis://redis:6379

# --- Auth ---
JWT_SECRET=${JWT_SECRET}
JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}
JWT_ACCESS_EXPIRES_IN=15m
JWT_REFRESH_EXPIRES_IN=7d
CSRF_SECRET=${CSRF_SECRET}
COOKIE_DOMAIN=${DOMAIN}

# --- File storage (Cloudinary) — fill in after setup ---
CLOUDINARY_CLOUD_NAME=
CLOUDINARY_API_KEY=
CLOUDINARY_API_SECRET=
CLOUDINARY_UPLOAD_FOLDER=salessphere-prod

# --- Email ---
EMAIL_PROVIDER=smtp
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_SECURE=$([ "${SMTP_PORT}" = "465" ] && echo true || echo false)
SMTP_FROM=${SMTP_FROM}
SMTP_FROM_NAME=${SMTP_FROM_NAME}
PASSWORD_RESET_URL=${CORS_ORIGIN}/auth/reset-password
EMAIL_VERIFICATION_URL=${CORS_ORIGIN}/auth/verify-email
RESEND_API_KEY=

# --- Platform super-admin ---
SUPERADMIN_EMAIL=${SUPERADMIN_EMAIL}
SUPERADMIN_PASSWORD=${SUPERADMIN_PASSWORD}

# --- IRD (Nepal) — fill in once registered ---
IRD_ENABLED=false
IRD_API_BASE=
IRD_TAXPAYER_PAN=
IRD_SOFTWARE_ID=

# --- Logging ---
LOG_LEVEL=info
EOF
chmod 600 .env
chown "${DEPLOY_USER}:${DEPLOY_USER}" .env

step "Rendering Caddyfile (domain: $DOMAIN)"
if [ -f Caddyfile ] && ! grep -q "$DOMAIN" Caddyfile; then
  cp Caddyfile "Caddyfile.bak.$(date +%Y%m%d-%H%M%S)"
fi
sed -i.tmp "s|api\.salessphere\.com|${DOMAIN}|g" Caddyfile && rm -f Caddyfile.tmp

# ============================================================
# Phase 7 — GHCR login + pull
# ============================================================
banner "Phase 7 — GHCR login + image pull"

step "Logging in to ghcr.io as $GHCR_USER"
if ! echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin > /dev/null 2>&1; then
  fail "GHCR login failed for user '$GHCR_USER'.
       The Personal Access Token must:
         • belong to a user with read access to $GHCR_IMAGE,
         • have the 'read:packages' scope (classic) or 'Packages: read' permission (fine-grained),
         • not be expired.
       Generate a new one at https://github.com/settings/tokens (classic) and re-run this script."
fi

# Make the auth cred available to deploy too (CI runs as deploy via SSH).
mkdir -p "${DEPLOY_HOME}/.docker"
cp /root/.docker/config.json "${DEPLOY_HOME}/.docker/config.json"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.docker"
chmod 600 "${DEPLOY_HOME}/.docker/config.json"

step "Pulling $GHCR_IMAGE:$IMAGE_TAG"
IMAGE_TAG="$IMAGE_TAG" docker compose pull

# ============================================================
# Phase 8 — DNS pre-check (warn only)
# ============================================================
banner "Phase 8 — DNS pre-check"
DROPLET_IP="$(curl -fsS --max-time 5 https://api.ipify.org || echo 'unknown')"
DNS_IP="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1 || echo '')"
if [ -z "$DNS_IP" ]; then
  warn "$DOMAIN does not resolve yet. Caddy will fail to provision TLS until you point an A record at $DROPLET_IP."
elif [ "$DNS_IP" != "$DROPLET_IP" ]; then
  warn "$DOMAIN resolves to $DNS_IP but this droplet's IP is $DROPLET_IP. Update your DNS before Caddy can issue a cert."
else
  step "$DOMAIN → $DROPLET_IP ✓"
fi

# ============================================================
# Phase 9 — migrations + seed
# ============================================================
banner "Phase 9 — Migrations + super-admin seed"

step "Applying pending Prisma migrations"
IMAGE_TAG="$IMAGE_TAG" docker compose run --rm app bunx prisma migrate deploy

step "Seeding platform super-admin (idempotent)"
IMAGE_TAG="$IMAGE_TAG" docker compose run --rm app bun run db:seed || true

# ============================================================
# Phase 10 — start the stack
# ============================================================
banner "Phase 10 — Starting the stack"
IMAGE_TAG="$IMAGE_TAG" docker compose up -d

step "Waiting for /health/ready to come green"
HEALTH_OK=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  sleep 3
  if curl -fsS --max-time 5 http://localhost:3000/health/ready > /dev/null 2>&1; then
    HEALTH_OK=true
    note "Healthy after ${attempt} attempt(s)"
    break
  fi
  note "  Attempt $attempt: not ready yet, retrying..."
done

if ! $HEALTH_OK; then
  warn "Health check did not pass. Inspect with: docker compose logs app --tail=100"
fi

# ============================================================
# Phase 11 — summary
# ============================================================
banner "✓ Setup complete"

cat > "$SUMMARY_FILE" <<EOF
SalesSphere ERP — droplet setup summary
Generated: $(date -Iseconds)
Droplet IP: ${DROPLET_IP}

═════════════════════════════════════════════════════════════════
  Platform super-admin (CHANGE THE PASSWORD IMMEDIATELY)
═════════════════════════════════════════════════════════════════

  URL:       https://${DOMAIN}/api/v1/auth/login
  Email:     ${SUPERADMIN_EMAIL}
  Password:  ${SUPERADMIN_PASSWORD}

  → After first login, hit POST /api/v1/auth/forgot-password
    and reset to your real password.

═════════════════════════════════════════════════════════════════
  GitHub secrets to add to the BACKEND repo
  (Settings → Secrets and variables → Actions → New)
═════════════════════════════════════════════════════════════════

  DROPLET_HOST       ${DROPLET_IP}
  DROPLET_USER       ${DEPLOY_USER}
  DROPLET_SSH_KEY    <the PRIVATE half of the deploy SSH key pair>
  DROPLET_SSH_PORT   22  (only if non-standard)
  DEPLOYMENT_DIR     ${REPO_DIR}
  HEALTH_URL         https://${DOMAIN}/health/ready

  Plus: create a 'production' GitHub Environment
    (Settings → Environments → New environment).

═════════════════════════════════════════════════════════════════
  Health check
═════════════════════════════════════════════════════════════════

  Local:   http://localhost:3000/health/ready
  Public:  https://${DOMAIN}/health/ready  (after DNS + first cert)

═════════════════════════════════════════════════════════════════
  Outstanding manual steps
═════════════════════════════════════════════════════════════════

  1. Point ${DOMAIN}'s A record at ${DROPLET_IP} (if not already)
  2. Add the GitHub secrets above to the backend repo
  3. Fill in any blanks in ${REPO_DIR}/.env
     (Cloudinary, IRD, etc. — anything you skipped during the prompt)

═════════════════════════════════════════════════════════════════
  Day-to-day
═════════════════════════════════════════════════════════════════

  Tail logs:           docker compose logs -f app
  Manual deploy:       cd ${REPO_DIR} && ./update.sh
  Rollback:            cd ${REPO_DIR} && ./update.sh sha-<previous-sha>
  Run a one-off cmd:   docker compose run --rm app <command>

This summary is saved at: ${SUMMARY_FILE}
EOF
chown "${DEPLOY_USER}:${DEPLOY_USER}" "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

cat "$SUMMARY_FILE"

echo
echo -e "${GREEN}${BOLD}Done.${NC}"
echo -e "Summary saved to ${BOLD}${SUMMARY_FILE}${NC} (chmod 600)."
echo
