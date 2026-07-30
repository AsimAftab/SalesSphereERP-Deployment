#!/usr/bin/env bash
#
# SalesSphere ERP — server bootstrap.
#
# Run on a fresh Ubuntu 22.04+ host as root. Walks the whole setup:
# system deps, firewall, deploy user, config, image pull, migrations,
# stack start, health check, credentials summary.
#
# ── Re-running ────────────────────────────────────────────────────────
# Every phase is idempotent, and a completed phase is recorded, so a
# failure partway does NOT mean starting over:
#
#   bash install.sh --resume     continue after the last phase that passed
#   bash install.sh --from=9     re-run from a specific phase
#   bash install.sh -y           accept every saved answer, ask nothing
#
# `--resume -y` is the normal "it broke, I fixed the cause, carry on"
# invocation: no prompts, no repeated work.
#
# ── Honesty ───────────────────────────────────────────────────────────
# The script exits non-zero if anything failed, and the summary says so.
# It will not print a super-admin password for an account the seed never
# managed to create.
#
# ── Usage ─────────────────────────────────────────────────────────────
#   curl -fsSL https://raw.githubusercontent.com/AsimAftab/SalesSphereERP-Deployment/main/install.sh -o install.sh
#   sudo bash install.sh
#
# Values can be pre-set as env vars to skip prompts entirely (CI):
#   DOMAIN=api.example.com DATABASE_URL=postgresql://... \
#   GHCR_USER=... GHCR_TOKEN=... DEPLOY_SSH_KEY="ssh-ed25519 ..." \
#   sudo -E bash install.sh -y

set -euo pipefail

# ============================================================
# Constants + presentation
# ============================================================
DEPLOY_USER="deploy"
DEPLOY_HOME="/home/${DEPLOY_USER}"
REPO_URL="https://github.com/AsimAftab/SalesSphereERP-Deployment.git"
REPO_DIR="${DEPLOY_HOME}/SalesSphereERP-Deployment"
GHCR_IMAGE_DEFAULT="ghcr.io/asimaftab/salessphere-erp-backend"
SUMMARY_FILE="${DEPLOY_HOME}/credentials-summary.txt"
# NOT under $DEPLOY_HOME: that directory does not exist until phase 3, and
# recording phase 1's completion there crashed the very first run on a fresh
# machine — the one case resumability exists for.
STATE_DIR="/var/lib/salessphere-erp"
STATE_FILE="${STATE_DIR}/install-state"
LOG_FILE="/var/log/salessphere-install.log"

# Where the app image keeps the CA roots it trusts for the database.
# Matches `COPY certs ./certs` with WORKDIR /app in the backend Dockerfile.
CA_BUNDLE_IN_IMAGE="/app/certs/rds-global-bundle.pem"

TOTAL_PHASES=11

if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; NC=''
fi

banner() {
  echo
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}${BOLD} $1${NC}"
  echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
step() { echo -e "${GREEN}==>${NC} ${BOLD}$1${NC}"; }
note() { echo -e "    $1"; }
dim()  { echo -e "    ${DIM}$1${NC}"; }
warn() { echo -e "${YELLOW}!! ${NC} $1"; }
fail() { echo -e "${RED}xx ${NC}${BOLD}$1${NC}"; exit 1; }

# Problems that do not stop the run but MUST reach the summary. Without
# this the script used to finish "successfully" while the seed had failed
# and the health check never went green.
declare -a ISSUES=()
issue() {
  ISSUES+=("$1")
  warn "$1"
}

# ============================================================
# Arguments
# ============================================================
FROM_PHASE=1
NON_INTERACTIVE=0
SKIP_SEED=0
RESUME=0

usage() {
  # Only the leading comment block, stopping at the first non-comment line —
  # a line-number range silently starts printing code the moment the header
  # grows or shrinks.
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
  cat <<EOF

Options:
  --resume            Continue after the last phase that completed
  --from=N            Start at phase N (1-${TOTAL_PHASES})
  -y, --non-interactive
                      Never prompt; use saved .env values / env vars / defaults
  --skip-seed         Do not run the super-admin seed
  --reset-state       Forget recorded progress, then run normally
  -h, --help          This message

Phases:
  1 System packages     5 Configuration      9  Migrations + seed
  2 Firewall            6 Secrets + render   10 Start stack + health
  3 Deploy user         7 GHCR + image pull  11 Summary
  4 Deployment repo     8 Preflight checks
EOF
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --resume)          RESUME=1 ;;
    --from=*)          FROM_PHASE="${arg#--from=}" ;;
    -y|--non-interactive) NON_INTERACTIVE=1 ;;
    --skip-seed)       SKIP_SEED=1 ;;
    --reset-state)     rm -f "$STATE_FILE" ;;
    -h|--help)         usage ;;
    *) fail "Unknown option: $arg  (try --help)" ;;
  esac
done

case "$FROM_PHASE" in
  ''|*[!0-9]*) fail "--from must be a number between 1 and ${TOTAL_PHASES}" ;;
esac
[ "$FROM_PHASE" -ge 1 ] && [ "$FROM_PHASE" -le "$TOTAL_PHASES" ] \
  || fail "--from must be between 1 and ${TOTAL_PHASES}"

# ============================================================
# Pre-flight
#
# INSTALL_LIB_ONLY=1 defines the helpers and stops: it lets the test
# script exercise the real functions rather than a copy of them that
# would drift out of step with this file.
# ============================================================
if [ "${INSTALL_LIB_ONLY:-0}" != "1" ]; then
  [ "$(id -u)" -eq 0 ] || fail "Run as root: sudo bash $0 $*"

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
      warn "This script targets Ubuntu — you're on ${ID:-unknown}. Continuing anyway."
    elif [ "${VERSION_ID%%.*}" -lt 22 ]; then
      warn "Ubuntu < 22.04 detected (${VERSION_ID}). 22.04+ recommended."
    fi
  fi

  # Everything below is also appended to a log, so a failed run can be read
  # back afterwards instead of scrolled for in a terminal buffer.
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo -e "${DIM}Log: ${LOG_FILE}${NC}"
fi

# ============================================================
# Phase state — what makes --resume work
# ============================================================
if [ "${INSTALL_LIB_ONLY:-0}" != "1" ]; then
  mkdir -p "$STATE_DIR"
  touch "$STATE_FILE"
fi
phase_completed() { grep -qxF "phase-$1" "$STATE_FILE" 2>/dev/null; }
mark_completed()  {
  phase_completed "$1" || echo "phase-$1" >> "$STATE_FILE"
}

if [ "$RESUME" -eq 1 ] && [ "${INSTALL_LIB_ONLY:-0}" != "1" ]; then
  last_done=0
  for n in $(seq 1 "$TOTAL_PHASES"); do
    phase_completed "$n" && last_done="$n"
  done
  if [ "$last_done" -eq 0 ]; then
    note "No recorded progress — starting from phase 1."
  else
    # Resume AT the last completed phase, not after it. Phases are
    # idempotent, and re-running the one that "passed" is cheap insurance
    # against it having half-finished before something downstream blew up.
    FROM_PHASE="$last_done"
    note "Resuming at phase ${FROM_PHASE} (phases 1-$((FROM_PHASE - 1)) already completed)."
  fi
fi

declare -a FAILED_PHASES=()

# run_phase NUMBER "Name" function [critical]
#   critical=1 (default) aborts the run; critical=0 records and continues.
run_phase() {
  local num="$1" name="$2" fn="$3" critical="${4:-1}"

  if [ "$num" -lt "$FROM_PHASE" ]; then
    echo -e "${DIM}── Phase ${num} — ${name} … skipped${NC}"
    return 0
  fi

  banner "Phase ${num}/${TOTAL_PHASES} — ${name}"
  if "$fn"; then
    mark_completed "$num"
    return 0
  fi

  FAILED_PHASES+=("${num} — ${name}")
  if [ "$critical" -eq 1 ]; then
    echo
    fail "Phase ${num} (${name}) failed.
       Fix the cause, then continue without redoing the earlier phases:
         sudo bash $0 --from=${num} -y"
  fi
  issue "Phase ${num} (${name}) did not complete — see above."
  return 0
}

# ============================================================
# Prompt helpers — respect pre-set env vars and -y
# ============================================================
prompt() {
  # prompt VAR_NAME "Description" "default"
  local var_name="$1" desc="$2" default="${3:-}"
  local current="${!var_name:-}"

  if [ -n "$current" ]; then
    # Already set: a pre-set env var (CI) or loaded from .env on a rerun.
    if [ "$NON_INTERACTIVE" -eq 1 ] || [ ! -t 0 ]; then
      note "$desc: ${BOLD}$current${NC}"
      return 0
    fi
    local value
    read -r -p "  $desc [$current]: " value
    [ -n "$value" ] && printf -v "$var_name" '%s' "$value"
    # Explicit `return 0` — a bare `return` would propagate the exit status
    # of the test above (1 when ENTER was pressed), which under `set -e`
    # kills the script on every ENTER-to-keep prompt.
    return 0
  fi

  if [ "$NON_INTERACTIVE" -eq 1 ] || [ ! -t 0 ]; then
    printf -v "$var_name" '%s' "$default"
    note "$desc: ${BOLD}${default:-<empty>}${NC} (default)"
    return 0
  fi

  local value
  if [ -n "$default" ]; then
    read -r -p "  $desc [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "  $desc: " value
  fi
  printf -v "$var_name" '%s' "$value"
  return 0
}

prompt_secret() {
  local var_name="$1" desc="$2"
  local current="${!var_name:-}"

  if [ -n "$current" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ] || [ ! -t 0 ]; then
      note "$desc: ${BOLD}<kept>${NC}"
      return 0
    fi
    local value
    read -r -s -p "  $desc [ENTER to keep current]: " value
    echo
    [ -n "$value" ] && printf -v "$var_name" '%s' "$value"
    return 0
  fi

  if [ "$NON_INTERACTIVE" -eq 1 ] || [ ! -t 0 ]; then
    # Define it as empty rather than leaving it unset. An undefined name here
    # trips `set -u` inside the .env heredoc — and since `cat > .env` has
    # already truncated the file by then, skipping an optional secret (SMTP,
    # say) used to leave a ZERO-BYTE .env behind and break everything after.
    printf -v "$var_name" '%s' ""
    return 0
  fi
  local value
  read -r -s -p "  $desc: " value
  echo
  printf -v "$var_name" '%s' "$value"
  return 0
}

gen_secret() { openssl rand -base64 48 | tr -d '\n=' | head -c 48; }

is_email() { [[ "$1" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; }
is_pgurl() { [[ "$1" =~ ^postgres(ql)?:// ]]; }

# Pre-fill a variable from an existing .env. Caller-supplied env vars and
# earlier prompts win; this only fills what is still empty.
#
# The `|| true` is load-bearing. Under `set -o pipefail`, grep finding
# nothing fails the whole pipeline, which fails the assignment, which under
# `set -e` kills the script — with no message at all. A key simply being
# absent from .env is the normal case, not an error, and without this the
# run died silently between phases on any .env that lacked one.
load_env_var() {
  local key="$1" var="${2:-$1}" file="${3:-.env}"
  [ -f "$file" ] || return 0
  [ -z "${!var:-}" ] || return 0
  local val
  val=$(grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | sed -E "s/^${key}=//") || true
  [ -n "$val" ] || return 0
  printf -v "$var" '%s' "$val"
  return 0
}

# --- Database URL helpers -------------------------------------------------
#
# host:port, with the scheme, credentials and path removed.
#
# `##*@` strips to the LAST `@`, not the first: an unescaped `@` in a
# password is common in pasted connection strings, and cutting at the first
# one yields a host like `ss@db.example.com`. That does not crash — it makes
# the TCP preflight fail against a hostname that was never real, which reads
# exactly like a firewall problem and sends you to the wrong place.
db_url_authority() {
  local authority
  authority=$(printf '%s' "$1" | sed -E 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|[/?].*$||')
  printf '%s' "${authority##*@}"
}

db_url_host() {
  local hostport; hostport="$(db_url_authority "$1")"
  printf '%s' "${hostport%%:*}"
}

db_url_port() {
  local hostport; hostport="$(db_url_authority "$1")"
  case "$hostport" in
    *:*) printf '%s' "${hostport##*:}" ;;
    *)   printf '5432' ;;
  esac
}

# Strip a query parameter from a URL, leaving the rest intact.
url_drop_param() {
  printf '%s' "$1" \
    | sed -E "s/([?&])$2=[^&]*&/\1/g; s/[?&]$2=[^&]*$//"
}

# Pin an Amazon RDS connection string to verified TLS against a named CA.
#
# Prisma's migration engine is a separate Rust binary: it reads only the
# connection string, ignores NODE_EXTRA_CA_CERTS, and against RDS fails with
# "self signed certificate in certificate chain" (or a bare, misleading
# P1001) unless the CA is named right here. The app server reads the same
# `sslrootcert`, so one string serves both.
#
# Returns the URL unchanged for non-RDS hosts, or when the caller already
# specified a CA — an explicit choice is never overridden.
rds_tls_url() {
  local url="$1" ca="$2" host base
  host="$(db_url_host "$url")"
  case "${host,,}" in
    *.rds.amazonaws.com) ;;
    *) printf '%s' "$url"; return 0 ;;
  esac
  if printf '%s' "$url" | grep -q 'sslrootcert='; then
    printf '%s' "$url"; return 0
  fi
  base="$(url_drop_param "$url" sslmode)"
  base="$(url_drop_param "$base" sslrootcert)"
  case "$base" in
    *\?*) printf '%s&sslmode=verify-full&sslrootcert=%s' "$base" "$ca" ;;
    *)    printf '%s?sslmode=verify-full&sslrootcert=%s' "$base" "$ca" ;;
  esac
}

# ============================================================
# Phase 1 — system packages
# ============================================================
phase_packages() {
  step "Updating apt index"
  apt-get update -qq

  step "Installing base utilities"
  DEBIAN_FRONTEND=noninteractive apt-get install -qq -y \
    ca-certificates curl gnupg openssl jq git ufw wget netcat-openbsd

  step "Installing Docker Engine + Compose plugin"
  if command -v docker > /dev/null 2>&1; then
    note "Docker already installed: $(docker --version)"
  else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${codename} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -qq -y \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi

  # The compose *plugin* is what every later phase calls. Docker being
  # present says nothing about it — a host with only docker.io installed
  # gets all the way to phase 7 before failing on `docker compose`.
  docker compose version > /dev/null 2>&1 \
    || fail "The Docker Compose plugin is missing. Install it with:
       apt-get install -y docker-compose-plugin"
}

# ============================================================
# Phase 2 — firewall
# ============================================================
phase_firewall() {
  ufw allow OpenSSH > /dev/null
  ufw allow 80/tcp  > /dev/null
  ufw allow 443/tcp > /dev/null
  ufw --force enable > /dev/null
  step "UFW enabled (allow: 22, 80, 443)"
}

# ============================================================
# Phase 3 — deploy user + SSH key
# ============================================================
phase_deploy_user() {
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
  local auth_keys="${DEPLOY_HOME}/.ssh/authorized_keys"
  touch "$auth_keys"

  if [ -z "${DEPLOY_SSH_KEY:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ] && [ -t 0 ]; then
    echo
    note "Paste the GitHub Actions deploy public key (one line, then ENTER),"
    note "or press ENTER alone to skip:"
    read -r DEPLOY_SSH_KEY
  fi

  if [ -z "${DEPLOY_SSH_KEY:-}" ]; then
    if [ -s "$auth_keys" ]; then
      note "No key supplied; $(wc -l < "$auth_keys") already present in authorized_keys"
    else
      issue "No deploy SSH key installed — CI deploys will fail until one is added to ${auth_keys}"
    fi
  elif grep -qF "$DEPLOY_SSH_KEY" "$auth_keys"; then
    note "Key already in authorized_keys"
  else
    echo "$DEPLOY_SSH_KEY" >> "$auth_keys"
    note "Key appended"
  fi
  chmod 600 "$auth_keys"
  chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"
}

# ============================================================
# Phase 4 — deployment repo
# ============================================================
phase_repo() {
  if [ -d "$REPO_DIR/.git" ]; then
    step "Repo already cloned — pulling latest"
    sudo -u "$DEPLOY_USER" git -C "$REPO_DIR" fetch --depth 1 origin main
    # Discards local edits by design: this repo is config-as-code. .env and
    # the rendered Caddyfile are gitignored, so neither is touched.
    sudo -u "$DEPLOY_USER" git -C "$REPO_DIR" reset --hard origin/main
  else
    step "Cloning $REPO_URL into $REPO_DIR"
    sudo -u "$DEPLOY_USER" git clone --depth 1 "$REPO_URL" "$REPO_DIR"
  fi
  cd "$REPO_DIR"
}

# ============================================================
# Config loading — always runs, never a phase
#
# Later phases need DOMAIN / IMAGE_TAG / DATABASE_URL even when --from
# skips the prompt phase, so reading them is separate from asking for them.
# ============================================================
ENV_PRELOADED=0
load_config() {
  cd "$REPO_DIR" 2>/dev/null || return 0
  [ -f .env ] || return 0
  ENV_PRELOADED=1

  # DOMAIN isn't a literal .env key — recover it from APP_URL=https://<host>.
  # `|| true` for the same reason as load_env_var: a missing APP_URL is a
  # thing to prompt for, not a reason to die without saying anything.
  if [ -z "${DOMAIN:-}" ]; then
    DOMAIN=$(grep -E '^APP_URL=' .env 2>/dev/null \
      | head -n1 | sed -E 's|^APP_URL=https?://||' | cut -d/ -f1) || true
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
  # Preserving these matters: regenerating them invalidates every active
  # session and makes the saved credentials summary a lie.
  load_env_var JWT_SECRET
  load_env_var JWT_REFRESH_SECRET
  load_env_var CSRF_SECRET
  load_env_var SUPERADMIN_PASSWORD
  load_env_var GHCR_IMAGE
}

# ============================================================
# Phase 5 — interactive configuration
# ============================================================
phase_config() {
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    note "Non-interactive: using saved values, env vars and defaults."
  else
    note "Press ENTER to accept the value in [brackets]."
    [ "$ENV_PRELOADED" -eq 1 ] && note "Existing .env found — its values are pre-filled."
  fi
  echo

  prompt DOMAIN "Production domain (e.g. api.example.com)"
  [ -n "${DOMAIN:-}" ] || fail "DOMAIN is required"

  prompt CORS_ORIGIN "Frontend origin (CORS allowed)" "https://app.${DOMAIN#api.}"
  prompt SUPERADMIN_EMAIL "Platform super-admin email" "admin@${DOMAIN#api.}"
  is_email "$SUPERADMIN_EMAIL" || fail "Invalid email: $SUPERADMIN_EMAIL"

  prompt_secret DATABASE_URL "DATABASE_URL (managed Postgres connection string)"
  [ -n "${DATABASE_URL:-}" ] || fail "DATABASE_URL is required"
  is_pgurl "$DATABASE_URL" || fail "DATABASE_URL must start with postgresql:// or postgres://"

  prompt GHCR_USER "GHCR username" "AsimAftab"
  prompt_secret GHCR_TOKEN "GHCR Personal Access Token (read:packages scope)"
  # Deliberately NOT fatal here. The token is never stored in .env, so every
  # `--resume -y` would demand it again — even when the image is already on
  # the host and nothing needs pulling. Phase 7 decides, because only it
  # knows whether a pull is actually required.

  prompt GHCR_IMAGE "GHCR image (no tag)" "$GHCR_IMAGE_DEFAULT"
  prompt IMAGE_TAG "Image tag to deploy" "latest"

  echo
  note "SMTP — leave blank to skip (configurable later in .env)."
  prompt SMTP_HOST "SMTP host" ""
  prompt SMTP_PORT "SMTP port" "465"
  prompt SMTP_USER "SMTP username" ""
  prompt_secret SMTP_PASS "SMTP password (or app-specific password)"
  prompt SMTP_FROM "SMTP from address" "no-reply@${DOMAIN#api.}"
  prompt SMTP_FROM_NAME "SMTP from name" "SalesSphere"
}

# ============================================================
# Phase 6 — secrets + render config
# ============================================================
phase_render() {
  cd "$REPO_DIR"

  local generated=0 preserved=0 var
  for var in JWT_SECRET JWT_REFRESH_SECRET CSRF_SECRET SUPERADMIN_PASSWORD; do
    if [ -n "${!var:-}" ]; then
      preserved=$((preserved + 1))
    else
      printf -v "$var" '%s' "$(gen_secret)"
      generated=$((generated + 1))
    fi
  done
  step "Secrets: ${generated} generated, ${preserved} preserved (JWT × 2, CSRF, super-admin password)"

  if [ -f .env ]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    cp .env ".env.bak.${ts}"
    dim "Previous .env backed up to .env.bak.${ts}"
  fi

  # Every value the template interpolates, defaulted so one unset optional
  # cannot abort the write. Belt to the braces of prompt_secret always
  # defining its variable.
  local v
  for v in IMAGE_TAG GHCR_IMAGE CORS_ORIGIN SMTP_HOST SMTP_PORT SMTP_USER \
           SMTP_PASS SMTP_FROM SMTP_FROM_NAME; do
    printf -v "$v" '%s' "${!v:-}"
  done
  : "${IMAGE_TAG:=latest}"
  : "${GHCR_IMAGE:=$GHCR_IMAGE_DEFAULT}"

  step "Rendering .env"
  # Written to a temp file and moved into place: `cat > .env` truncates
  # before it writes, so any failure mid-render left a zero-byte .env and
  # took the whole deployment down with it.
  local env_tmp
  env_tmp="$(mktemp "${PWD}/.env.tmp.XXXXXX")"
  umask 077
  cat > "$env_tmp" <<EOF
# Generated by install.sh on $(date -Iseconds)
# Hand edits survive until the next run, which backs this up to .env.bak.<ts>.

# --- Image ---
IMAGE_TAG=${IMAGE_TAG}
GHCR_IMAGE=${GHCR_IMAGE}

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
  umask 022
  # Sanity-check before it replaces a working file: a .env that lost
  # DATABASE_URL is worse than no .env at all, because the stack starts and
  # then fails in a way that looks like a database problem.
  grep -q '^DATABASE_URL=' "$env_tmp" && grep -q '^JWT_SECRET=' "$env_tmp" \
    || { rm -f "$env_tmp"; fail "Rendered .env is incomplete — refusing to install it."; }
  mv "$env_tmp" .env
  chmod 600 .env
  chown "${DEPLOY_USER}:${DEPLOY_USER}" .env

  step "Rendering Caddyfile (domain: $DOMAIN)"
  [ -f Caddyfile.template ] \
    || fail "Caddyfile.template is missing — the deployment repo checkout is incomplete."
  [ -f Caddyfile ] && cp Caddyfile "Caddyfile.bak.$(date +%Y%m%d-%H%M%S)"
  sed "s|{{DOMAIN}}|${DOMAIN}|g" Caddyfile.template > Caddyfile
  # Belt and braces: an unsubstituted placeholder would make Caddy fail to
  # start with a parse error that says nothing about the real cause.
  if grep -q '{{DOMAIN}}' Caddyfile; then
    fail "Caddyfile still contains {{DOMAIN}} after rendering — check Caddyfile.template."
  fi
  chown "${DEPLOY_USER}:${DEPLOY_USER}" Caddyfile
}

# ============================================================
# Phase 7 — GHCR login + image pull
# ============================================================
phase_image() {
  cd "$REPO_DIR"
  local image="${GHCR_IMAGE:-$GHCR_IMAGE_DEFAULT}:${IMAGE_TAG}"

  # No token: fine, as long as the image is already here. Re-running after a
  # failure is the common case, and the image rarely changed in between.
  if [ -z "${GHCR_TOKEN:-}" ]; then
    if docker image inspect "$image" > /dev/null 2>&1; then
      issue "No GHCR_TOKEN given — using the ${IMAGE_TAG} image already on this host, which may be stale.
       To pull a newer build:  sudo GHCR_TOKEN=ghp_xxx bash $0 --resume -y"
      return 0
    fi
    fail "GHCR_TOKEN is required: ${image} is not on this host, so it has to be pulled.
       Supply it for this run (sudo passes VAR=value through):
         sudo GHCR_TOKEN=ghp_xxx bash $0 --resume -y
       Generate one at https://github.com/settings/tokens (classic, read:packages)."
  fi

  step "Logging in to ghcr.io as $GHCR_USER"
  if ! echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin > /dev/null 2>&1; then
    fail "GHCR login failed for user '$GHCR_USER'.
       The Personal Access Token must:
         • belong to a user with read access to ${GHCR_IMAGE:-$GHCR_IMAGE_DEFAULT},
         • have the 'read:packages' scope (classic) or 'Packages: read' (fine-grained),
         • not be expired.
       Generate a new one at https://github.com/settings/tokens, then:
         sudo bash $0 --from=7"
  fi

  # CI deploys over SSH as `deploy`, so that user needs the same credential.
  mkdir -p "${DEPLOY_HOME}/.docker"
  cp /root/.docker/config.json "${DEPLOY_HOME}/.docker/config.json"
  chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.docker"
  chmod 600 "${DEPLOY_HOME}/.docker/config.json"

  step "Pulling ${image}"
  IMAGE_TAG="$IMAGE_TAG" docker compose pull

  # Which build is actually running. `latest` is a moving target, and
  # "deployed successfully" against a stale image is a confusing hour.
  local digest built
  digest=$(docker image inspect --format '{{index .RepoDigests 0}}' \
    "$image" 2>/dev/null || echo '')
  built=$(docker image inspect --format '{{.Created}}' \
    "$image" 2>/dev/null || echo '')
  [ -n "$digest" ] && dim "Digest: ${digest##*@}"
  [ -n "$built" ] && dim "Built:  ${built}"
  # Explicit, and not decoration: a function ending in a conditional returns
  # that conditional's status. With no digest to print, `[ -n "" ]` is false,
  # the function returns 1, and run_phase reports a failed image pull that in
  # fact succeeded. Same trap the `prompt` helper documents.
  return 0
}

# ============================================================
# Phase 8 — preflight
#
# Everything cheap that predicts a later failure. These used to surface at
# phase 9 or 10, after minutes of work, as an opaque driver error.
# ============================================================
DB_REACHABLE=0
IMAGE_HAS_CA=0

phase_preflight() {
  cd "$REPO_DIR"

  # --- Disk ---
  local avail_mb
  avail_mb=$(df -Pm / | awk 'NR==2{print $4}')
  if [ "${avail_mb:-9999}" -lt 2048 ]; then
    issue "Only ${avail_mb}MB free on / — image pulls and logs may fail. Consider 'docker system prune -af'."
  else
    step "Disk: ${avail_mb}MB free on /"
  fi

  # --- Ports 80/443 ---
  local blocker
  for p in 80 443; do
    blocker=$(ss -lntp 2>/dev/null | awk -v port=":$p\$" '$4 ~ port {print $NF; exit}')
    if [ -n "$blocker" ] && [[ "$blocker" != *docker* ]] && [[ "$blocker" != *caddy* ]]; then
      issue "Port $p is already held by ${blocker} — Caddy will fail to bind."
    fi
  done

  # --- DNS ---
  DROPLET_IP="$(curl -fsS --max-time 5 https://api.ipify.org || echo 'unknown')"
  DNS_IP="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1 || echo '')"
  if [ -z "$DNS_IP" ]; then
    issue "$DOMAIN does not resolve. Caddy cannot obtain a certificate until an A record points at ${DROPLET_IP}."
  elif [ "$DNS_IP" != "$DROPLET_IP" ]; then
    issue "$DOMAIN resolves to ${DNS_IP}, but this host is ${DROPLET_IP}. Caddy cannot obtain a certificate until the A record is updated."
  else
    step "DNS: $DOMAIN → $DROPLET_IP"
  fi

  # --- Database TCP reachability ---
  local db_host db_port
  db_host="$(db_url_host "$DATABASE_URL")"
  db_port="$(db_url_port "$DATABASE_URL")"
  if timeout 8 bash -c "</dev/tcp/${db_host}/${db_port}" 2>/dev/null; then
    DB_REACHABLE=1
    step "Database reachable: ${db_host}:${db_port}"
  else
    DB_REACHABLE=0
    issue "Cannot open a TCP connection to ${db_host}:${db_port}.
       Usually the database firewall (AWS security group / DO trusted sources)
       does not allow this host's IP: ${DROPLET_IP}"
  fi

  # --- Does the image carry the database CA bundle? ---
  # Decides whether the RDS TLS parameters below can be used at all. An
  # image built before that shipped has no bundle, and pointing sslrootcert
  # at a missing file fails more confusingly than leaving it off.
  if docker compose run --rm --no-deps --entrypoint sh app \
       -c "[ -f '${CA_BUNDLE_IN_IMAGE}' ]" > /dev/null 2>&1; then
    IMAGE_HAS_CA=1
    dim "Image ships the database CA bundle"
  else
    IMAGE_HAS_CA=0
    dim "Image has no bundled CA at ${CA_BUNDLE_IN_IMAGE}"
  fi

  # --- Normalise TLS parameters for Amazon RDS ---
  if [[ "${db_host,,}" == *.rds.amazonaws.com ]]; then
    if printf '%s' "$DATABASE_URL" | grep -q 'sslrootcert='; then
      dim "DATABASE_URL already names a CA — leaving it alone"
    elif [ "$IMAGE_HAS_CA" -eq 1 ]; then
      DATABASE_URL="$(rds_tls_url "$DATABASE_URL" "$CA_BUNDLE_IN_IMAGE")"
      step "Amazon RDS detected — pinned TLS to verify-full against the image's CA bundle"
      # Phase 6 rendered .env with the un-normalised URL. Written with a
      # literal-safe replacement: a connection string routinely contains &,
      # / and other characters sed would otherwise interpret.
      local tmp; tmp="$(mktemp)"
      grep -v '^DATABASE_URL=' .env > "$tmp"
      printf 'DATABASE_URL=%s\n' "$DATABASE_URL" >> "$tmp"
      cat "$tmp" > .env && rm -f "$tmp"
      chmod 600 .env
    else
      issue "Amazon RDS detected, but this image ships no CA bundle, so certificate
       verification cannot succeed. Deploy an image built from backend main
       (which ships certs/), or set sslrootcert in DATABASE_URL yourself."
    fi
  fi

  # --- Credentials + TLS, for real ---
  if [ "$DB_REACHABLE" -eq 1 ]; then
    step "Verifying database credentials and TLS"
    local out
    if out=$(IMAGE_TAG="$IMAGE_TAG" docker compose run --rm --no-deps app \
               bunx prisma migrate status 2>&1); then
      dim "$(printf '%s' "$out" | grep -E 'migrations found|up to date|not yet been applied' | head -2)"
    else
      # migrate status exits non-zero merely for pending migrations, which is
      # not an error here — only a genuine connection problem is.
      if printf '%s' "$out" | grep -qE 'P1001|P1011|TlsConnectionError|authentication failed|does not exist'; then
        issue "Database check failed:
$(printf '%s' "$out" | grep -E 'Error|error:' | head -3)"
        DB_REACHABLE=0
      else
        dim "$(printf '%s' "$out" | grep -E 'not yet been applied|migrations found' | head -2)"
      fi
    fi
  fi
  # Preflight only ever *reports*; it must not fail the phase. Its findings
  # reach the summary through `issue`, and the phases that depend on them
  # (migrations) check DB_REACHABLE for themselves.
  return 0
}

# ============================================================
# Phase 9 — migrations + seed
# ============================================================
SEED_OK=0
phase_migrate() {
  cd "$REPO_DIR"

  if [ "$DB_REACHABLE" -ne 1 ]; then
    issue "Skipping migrations and seed — the database is not reachable (see phase 8)."
    return 1
  fi

  step "Applying pending Prisma migrations"
  IMAGE_TAG="$IMAGE_TAG" docker compose run --rm --no-deps app \
    bunx prisma migrate deploy || return 1

  if [ "$SKIP_SEED" -eq 1 ]; then
    note "Seed skipped (--skip-seed)"
    return 0
  fi

  step "Seeding platform super-admin (idempotent)"
  # Failure here used to be swallowed with `|| true`, and the summary went
  # on to print a super-admin password for an account that did not exist.
  if IMAGE_TAG="$IMAGE_TAG" docker compose run --rm --no-deps app bun run db:seed; then
    SEED_OK=1
  else
    SEED_OK=0
    issue "Super-admin seed failed — no platform admin account was created.
       Re-run it alone once the cause is fixed:
         cd ${REPO_DIR} && docker compose run --rm app bun run db:seed"
  fi
  return 0
}

# ============================================================
# Phase 10 — start the stack + health
# ============================================================
HEALTH_OK=0
phase_start() {
  cd "$REPO_DIR"
  IMAGE_TAG="$IMAGE_TAG" docker compose up -d

  # 60s: a cold start pulls a fiscal year, warms Prisma and connects Redis.
  # The old 30s window reported failure on a server that was merely slow.
  step "Waiting for /health/ready (up to 60s)"
  local attempt
  for attempt in $(seq 1 20); do
    sleep 3
    if curl -fsS --max-time 5 http://localhost:3000/health/ready > /dev/null 2>&1; then
      HEALTH_OK=1
      note "Healthy after $((attempt * 3))s"
      break
    fi
    [ $((attempt % 5)) -eq 0 ] && dim "still waiting (${attempt}/20)…"
  done

  if [ "$HEALTH_OK" -ne 1 ]; then
    issue "Health check never went green."
    # Show the logs instead of telling the operator to go find them —
    # the cause is almost always in the last few lines.
    echo
    warn "Last 40 lines of the app log:"
    docker compose logs app --tail=40 2>&1 | sed 's/^/      /' || true
    echo
    return 1
  fi
  return 0
}

# ============================================================
# Phase 11 — summary
# ============================================================
phase_summary() {
  cd "$REPO_DIR"

  local seed_block
  if [ "$SEED_OK" -eq 1 ]; then
    seed_block="  URL:       https://${DOMAIN}/api/v1/auth/login
  Email:     ${SUPERADMIN_EMAIL}
  Password:  ${SUPERADMIN_PASSWORD}

  → After first login, POST /api/v1/auth/forgot-password and reset it."
  elif [ "$SKIP_SEED" -eq 1 ]; then
    seed_block="  NOT SEEDED — you passed --skip-seed.
  The password below is in .env and will be used when you do seed:
    ${SUPERADMIN_PASSWORD}
  Run: cd ${REPO_DIR} && docker compose run --rm app bun run db:seed"
  else
    seed_block="  !! NO SUPER-ADMIN ACCOUNT EXISTS — the seed did not succeed.
  The password below is what .env will use once the seed runs:
    ${SUPERADMIN_PASSWORD}
  Fix the cause, then: cd ${REPO_DIR} && docker compose run --rm app bun run db:seed"
  fi

  local issues_block="  None."
  if [ ${#ISSUES[@]} -gt 0 ]; then
    issues_block=$(printf '  • %s\n' "${ISSUES[@]}")
  fi

  cat > "$SUMMARY_FILE" <<EOF
SalesSphere ERP — server setup summary
Generated: $(date -Iseconds)
Host IP:   ${DROPLET_IP:-unknown}
Image:     ${GHCR_IMAGE:-$GHCR_IMAGE_DEFAULT}:${IMAGE_TAG}

═════════════════════════════════════════════════════════════════
  Platform super-admin
═════════════════════════════════════════════════════════════════

${seed_block}

═════════════════════════════════════════════════════════════════
  Needs attention
═════════════════════════════════════════════════════════════════

${issues_block}

═════════════════════════════════════════════════════════════════
  GitHub secrets for the BACKEND repo
  (Settings → Secrets and variables → Actions → New)
═════════════════════════════════════════════════════════════════

  DROPLET_HOST       ${DROPLET_IP:-unknown}
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
  Day-to-day
═════════════════════════════════════════════════════════════════

  Tail logs:         docker compose logs -f app
  Manual deploy:     cd ${REPO_DIR} && ./update.sh
  Rollback:          cd ${REPO_DIR} && ./update.sh sha-<previous-sha>
  One-off command:   docker compose run --rm app <command>
  Re-run setup:      sudo bash install.sh --resume -y
  Install log:       ${LOG_FILE}

This summary is saved at: ${SUMMARY_FILE}
EOF
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "$SUMMARY_FILE"
  chmod 600 "$SUMMARY_FILE"
  cat "$SUMMARY_FILE"
}

# ============================================================
# Run
#
# Skipped entirely under INSTALL_LIB_ONLY so test-install.sh can source
# this file for its helpers without provisioning the machine it runs on.
# ============================================================
if [ "${INSTALL_LIB_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

run_phase 1  "System packages"      phase_packages
run_phase 2  "Firewall (UFW)"       phase_firewall
run_phase 3  "Deploy user"          phase_deploy_user
run_phase 4  "Deployment repo"      phase_repo

# Config is loaded outside the phase system so --from=9 still knows the
# domain, image tag and database URL.
load_config

# Starting past the configuration phase means trusting .env to hold the
# answers. If it does not, say which one is missing — the alternative is an
# "unbound variable" three phases later that names a shell variable and not
# the thing the operator actually has to fix.
if [ "$FROM_PHASE" -gt 5 ]; then
  : "${IMAGE_TAG:=latest}"
  : "${GHCR_USER:=AsimAftab}"
  : "${GHCR_IMAGE:=$GHCR_IMAGE_DEFAULT}"
  for required in DOMAIN DATABASE_URL; do
    [ -n "${!required:-}" ] || fail "Starting at phase ${FROM_PHASE} requires ${required}, and it is not
       set in ${REPO_DIR}/.env or the environment.
       Run the configuration phase too:
         sudo bash $0 --from=5 -y"
  done
fi

run_phase 5  "Configuration"        phase_config
run_phase 6  "Secrets + config"     phase_render
run_phase 7  "GHCR + image pull"    phase_image
run_phase 8  "Preflight checks"     phase_preflight 0
run_phase 9  "Migrations + seed"    phase_migrate   0
run_phase 10 "Start stack"          phase_start     0
run_phase 11 "Summary"              phase_summary

# ============================================================
# Verdict
# ============================================================
echo
if [ ${#ISSUES[@]} -eq 0 ]; then
  banner "✓ Setup complete"
  echo -e "${GREEN}${BOLD}Everything came up green.${NC}"
  echo -e "Summary: ${BOLD}${SUMMARY_FILE}${NC} (chmod 600)"
  echo
  exit 0
fi

banner "⚠ Setup finished with ${#ISSUES[@]} issue(s)"
printf '%s\n' "${ISSUES[@]}" | sed 's/^/  • /'
echo
echo -e "The stack may still be partly up. After fixing the cause, continue"
echo -e "without repeating the earlier phases:"
echo -e "  ${BOLD}sudo bash $0 --resume -y${NC}"
echo
echo -e "Summary: ${BOLD}${SUMMARY_FILE}${NC}   Log: ${BOLD}${LOG_FILE}${NC}"
echo
# Non-zero so CI and `&&` chains actually notice. The old script exited 0
# even when the seed had failed and health never came up.
exit 1
