#!/usr/bin/env bash
#
# Tests for install.sh's string handling.
#
# These functions rewrite the production database connection string. A bad
# substitution does not crash — it produces a URL that looks plausible and
# fails at connect time with a driver error that points nowhere near the
# cause, on a server, mid-deploy. That is worth testing on a laptop.
#
# The real install.sh is sourced (INSTALL_LIB_ONLY=1) rather than copied,
# so these cannot drift away from what actually ships.
#
#   bash test-install.sh

set -uo pipefail

cd "$(dirname "$0")"
ROOT_DIR="$PWD"
INSTALL_LIB_ONLY=1 . ./install.sh
. ./deployment-lib.sh
# Sourcing install.sh applies its `set -euo pipefail` to this shell too. This
# harness deliberately runs failing commands, so turn -e back off — otherwise
# the first negative test ends the run and the later checks never report at
# all, which looks like a pass.
set +e

PASS=0; FAIL=0
check() {
  # check "what" "expected" "actual"
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"
  fi
}

RDS="salessphere-db.cjyie0ui2gb3.ap-south-1.rds.amazonaws.com"
CA="/app/certs/rds-global-bundle.pem"

echo
echo "db_url_host"
check "plain host"           "$RDS"       "$(db_url_host "postgresql://u:p@${RDS}:5432/postgres")"
check "no port"              "$RDS"       "$(db_url_host "postgresql://u:p@${RDS}/postgres")"
check "no credentials"       "$RDS"       "$(db_url_host "postgresql://${RDS}:5432/db")"
check "password holds an @"  "$RDS"       "$(db_url_host "postgresql://u:p@ss@${RDS}:5432/db")"
check "password holds an @ AND a colon" "$RDS" "$(db_url_host "postgresql://u:p@ss:x@${RDS}:5432/db")"
check "port survives an @ in the password"  "5432" "$(db_url_port "postgresql://u:p@ss@${RDS}:5432/db")"
check "query string present" "$RDS"       "$(db_url_host "postgresql://u:p@${RDS}:5432/db?sslmode=require")"
check "localhost"            "localhost"  "$(db_url_host "postgresql://u:p@localhost:5432/dev")"

echo
echo "db_url_port"
check "explicit port" "5432"  "$(db_url_port "postgresql://u:p@${RDS}:5432/postgres")"
check "non-standard"  "25060" "$(db_url_port "postgresql://u:p@host:25060/db?sslmode=require")"
check "defaults"      "5432"  "$(db_url_port "postgresql://u:p@host/db")"
# A colon in the password must not be mistaken for the port separator.
check "colon in password" "5432" "$(db_url_port "postgresql://u:pa:ss@host/db")"

echo
echo "url_drop_param"
check "only param"    "postgresql://h/db" \
                      "$(url_drop_param "postgresql://h/db?sslmode=require" sslmode)"
check "first of two"  "postgresql://h/db?x=1" \
                      "$(url_drop_param "postgresql://h/db?sslmode=require&x=1" sslmode)"
check "last of two"   "postgresql://h/db?x=1" \
                      "$(url_drop_param "postgresql://h/db?x=1&sslmode=require" sslmode)"
check "absent"        "postgresql://h/db?x=1" \
                      "$(url_drop_param "postgresql://h/db?x=1" sslmode)"

echo
echo "rds_tls_url"
check "adds params when there is no query string" \
  "postgresql://u:p@${RDS}:5432/postgres?sslmode=verify-full&sslrootcert=${CA}" \
  "$(rds_tls_url "postgresql://u:p@${RDS}:5432/postgres" "$CA")"

check "replaces a bare sslmode=require — the exact case that broke the deploy" \
  "postgresql://u:p@${RDS}:5432/postgres?sslmode=verify-full&sslrootcert=${CA}" \
  "$(rds_tls_url "postgresql://u:p@${RDS}:5432/postgres?sslmode=require" "$CA")"

check "keeps unrelated params" \
  "postgresql://u:p@${RDS}:5432/postgres?application_name=erp&sslmode=verify-full&sslrootcert=${CA}" \
  "$(rds_tls_url "postgresql://u:p@${RDS}:5432/postgres?sslmode=require&application_name=erp" "$CA")"

# Non-RDS hosts are left completely alone: another provider's URL must not
# acquire a path to an Amazon CA bundle that does not describe it.
check "leaves another provider untouched" \
  "postgresql://u:p@db.provider.example:25060/defaultdb?sslmode=require" \
  "$(rds_tls_url "postgresql://u:p@db.provider.example:25060/defaultdb?sslmode=require" "$CA")"
check "leaves Neon untouched" \
  "postgresql://u:p@ep-x.neon.tech/neondb?sslmode=require" \
  "$(rds_tls_url "postgresql://u:p@ep-x.neon.tech/neondb?sslmode=require" "$CA")"
check "leaves localhost untouched" \
  "postgresql://u:p@localhost:5432/dev" \
  "$(rds_tls_url "postgresql://u:p@localhost:5432/dev" "$CA")"

# An operator who named their own CA has made a deliberate choice.
check "never overrides an explicit sslrootcert" \
  "postgresql://u:p@${RDS}/db?sslrootcert=/custom/ca.pem" \
  "$(rds_tls_url "postgresql://u:p@${RDS}/db?sslrootcert=/custom/ca.pem" "$CA")"

# Idempotence: --resume re-runs phase 8 over an already-normalised URL, and
# it must not accumulate a second copy of the parameters.
once="$(rds_tls_url "postgresql://u:p@${RDS}/db?sslmode=require" "$CA")"
check "applying twice changes nothing" "$once" "$(rds_tls_url "$once" "$CA")"

echo
echo "validators"
check "valid email"    "0" "$(is_email 'admin@example.com'; echo $?)"
check "invalid email"  "1" "$(is_email 'not-an-email'; echo $?)"
check "postgres URL"   "0" "$(is_pgurl 'postgresql://h/db'; echo $?)"
check "postgres:// URL" "0" "$(is_pgurl 'postgres://h/db'; echo $?)"
check "not a pg URL"   "1" "$(is_pgurl 'mysql://h/db'; echo $?)"

# ----------------------------------------------------------------------
# Phase orchestration — the part that makes a failed run resumable instead
# of something you start over from scratch.
# ----------------------------------------------------------------------
echo
echo "phase state + run_phase"

TEST_ROOT="${PWD}/.test-install.$$"
mkdir -p "$TEST_ROOT"
STATE_FILE="${TEST_ROOT}/install-state"
: > "$STATE_FILE"

mark_completed 3
check "records a completed phase"      "0" "$(phase_completed 3; echo $?)"
check "does not invent completions"    "1" "$(phase_completed 4; echo $?)"
mark_completed 3
check "recording twice stays one line" "1" "$(wc -l < "$STATE_FILE" | tr -d ' ')"

RAN=""
ok_phase()   { RAN="${RAN}${1:-x}"; return 0; }
run_ok()     { RAN="${RAN}R"; return 0; }
run_bad()    { RAN="${RAN}B"; return 1; }

# --from skips earlier phases without running them.
FROM_PHASE=5
RAN=""; FAILED_PHASES=()
run_phase 3 "early" run_ok  > /dev/null
check "phase before --from does not run" "" "$RAN"

RAN=""
run_phase 5 "at boundary" run_ok > /dev/null
check "phase at --from runs" "R" "$RAN"
check "and is recorded"      "0" "$(phase_completed 5; echo $?)"

# A non-critical failure is recorded and the run continues.
FROM_PHASE=1
RAN=""; FAILED_PHASES=(); ISSUES=()
run_phase 8 "soft" run_bad 0 > /dev/null
check "non-critical failure continues"     "B" "$RAN"
check "non-critical failure is recorded"   "1" "${#FAILED_PHASES[@]}"
check "non-critical failure raises an issue" "1" "${#ISSUES[@]}"
check "a failed phase is NOT marked done"  "1" "$(phase_completed 8; echo $?)"

# A critical failure aborts, so the operator cannot miss it. Run it in a
# subshell and capture the status explicitly — `fail` calls `exit`.
FAILED_PHASES=(); ISSUES=()
( run_phase 9 "hard" run_bad 1 > /dev/null 2>&1 ); rc=$?
check "critical failure exits non-zero" "1" "$rc"

rm -f "$STATE_FILE"

# ----------------------------------------------------------------------
# load_env_var must survive a key that is simply absent.
#
# Regression: under `set -o pipefail`, grep finding nothing failed the
# pipeline, failed the assignment, and `set -e` then killed the whole run
# with NO message. On the server this looked like the script quietly
# stopping between Phase 4 and Phase 5.
# ----------------------------------------------------------------------
echo
echo "load_env_var"

tmpdir="${TEST_ROOT}/sparse-env"; mkdir -p "$tmpdir"; pushd "$tmpdir" > /dev/null
printf 'APP_URL=https://api.example.test
IMAGE_TAG=latest
' > .env

unset PRESENT_KEY ABSENT_KEY
( set -euo pipefail; load_env_var IMAGE_TAG; ) > /dev/null 2>&1
check "present key does not abort"  "0" "$?"
( set -euo pipefail; load_env_var GHCR_IMAGE; ) > /dev/null 2>&1
check "ABSENT key does not abort"   "0" "$?"

IMAGE_TAG=""; load_env_var IMAGE_TAG
check "reads the value"             "latest" "$IMAGE_TAG"

IMAGE_TAG="pinned"; load_env_var IMAGE_TAG
check "does not clobber a set value" "pinned" "$IMAGE_TAG"

# The whole preamble, as run_phase would reach it.
unset DOMAIN
( set -euo pipefail
  DOMAIN=$(grep -E '^APP_URL=' .env 2>/dev/null | head -n1 | sed -E 's|^APP_URL=https?://||' | cut -d/ -f1) || true
  for k in CORS_ORIGIN SUPERADMIN_EMAIL DATABASE_URL GHCR_IMAGE SMTP_PASS; do
    load_env_var "$k"
  done
) > /dev/null 2>&1
check "a whole load_config pass survives a sparse .env" "0" "$?"

popd > /dev/null

# ----------------------------------------------------------------------
# Dual-domain migration and Caddy template rendering.
# ----------------------------------------------------------------------
echo
echo "dual-domain configuration"

check "valid API domain" "0" "$(validate_domain 'api.example.test'; echo $?)"
check "rejects URL as domain" "1" "$(validate_domain 'https://api.example.test'; echo $?)"
check "fails closed for unsupported IDN A-labels" "1" \
  "$(validate_domain 'api.xn--p1ai'; echo $?)"
check "extracts URL host" "app.example.test" "$(domain_from_url 'https://app.example.test/path')"
check "accepts root frontend and API subdomain" "0" \
  "$(validate_auth_site_domains 'api.example.test' 'example.test' 'example.test'; echo $?)"
check "accepts root API and frontend subdomain" "0" \
  "$(validate_auth_site_domains 'example.test' 'app.example.test' 'example.test'; echo $?)"
check "rejects suffix lookalike" "1" \
  "$(validate_auth_site_domains 'api.example.test' 'badexample.test' 'example.test'; echo $?)"
check "rejects public-suffix cross-sites" "1" \
  "$(validate_auth_site_domains 'api.foo.blogspot.com' 'app.bar.blogspot.com' 'foo.blogspot.com'; echo $?)"
check "accepts production registrable domain" "0" \
  "$(validate_auth_site_domains 'api.salessphere360.tech' 'salessphere360.tech' 'salessphere360.tech'; echo $?)"
check "rejects ICANN public suffix root" "1" \
  "$(validate_auth_site_domains 'api.co.uk' 'app.co.uk' 'co.uk'; echo $?)"
check "rejects PRIVATE public suffix root" "1" \
  "$(validate_auth_site_domains 'api.blogspot.com' 'app.blogspot.com' 'blogspot.com'; echo $?)"
check "rejects top-level public suffix" "1" \
  "$(validate_auth_site_domains 'api.example.com' 'app.example.com' 'com'; echo $?)"
check "accepts tenant registrable domain under PRIVATE suffix" "0" \
  "$(validate_auth_site_domains 'api.foo.blogspot.com' 'foo.blogspot.com' 'foo.blogspot.com'; echo $?)"
check "wildcard rule makes a.ck a public suffix" "a.ck" "$(public_suffix 'a.ck')"
check "wildcard public suffix cannot be auth site" "1" \
  "$(validate_auth_site_domains 'api.a.ck' 'app.a.ck' 'a.ck'; echo $?)"
check "exception rule makes www.ck registrable" "www.ck" "$(registrable_domain 'www.ck')"
check "exception registrable domain is accepted" "0" \
  "$(validate_auth_site_domains 'api.www.ck' 'www.ck' 'www.ck'; echo $?)"
check "rejects a deeper auth boundary than the registrable domain" "1" \
  "$(validate_auth_site_domains 'api.auth.example.com' 'app.auth.example.com' 'auth.example.com'; echo $?)"
check "accepts sibling hosts with an explicit parent" "0" \
  "$(validate_auth_site_domains 'api.example.test' 'app.example.test' 'example.test'; echo $?)"
check "derives exact frontend parent" "example.test" \
  "$(derive_auth_site_domain 'api.example.test' 'example.test')"
check "does not derive from sibling labels" "1" \
  "$(derive_auth_site_domain 'api.example.test' 'app.example.test' >/dev/null; echo $?)"

rendered="${TEST_ROOT}/Caddyfile"
render_caddy_template "api.example.test" "example.test" "example.test" \
  Caddyfile.template "$rendered"
check "renders API host" "1" "$(grep -c '^api.example.test {' "$rendered")"
check "renders frontend host" "1" "$(grep -c '^example.test {' "$rendered")"
check "removes placeholders" "0" "$(grep -c '{{' "$rendered")"
check "rejects equal hosts" "1" \
  "$(render_caddy_template 'api.example.test' 'api.example.test' 'api.example.test' Caddyfile.template "${TEST_ROOT}/bad"; echo $?)"
check "Caddy render rejects invalid auth contract" "1" \
  "$(render_caddy_template 'api.foo.blogspot.com' 'app.bar.blogspot.com' 'foo.blogspot.com' Caddyfile.template "${TEST_ROOT}/bad"; echo $?)"

saved_psl="$PUBLIC_SUFFIX_LIST"
PUBLIC_SUFFIX_LIST="${TEST_ROOT}/missing-psl.dat"
check "missing PSL fails closed" "1" \
  "$(validate_auth_site_domains 'api.example.test' 'example.test' 'example.test' >/dev/null 2>&1; echo $?)"
PUBLIC_SUFFIX_LIST="$saved_psl"

legacy="${TEST_ROOT}/legacy"; mkdir -p "$legacy"
cat > "${legacy}/.env" <<'EOF'
APP_URL=https://api.legacy.test
CORS_ORIGIN=https://legacy.test
JWT_SECRET=keep-me
JWT_REFRESH_SECRET=keep-me-too
CSRF_SECRET=keep-csrf
SUPERADMIN_PASSWORD=keep-admin
EOF
old_repo_dir="$REPO_DIR"
REPO_DIR="$legacy"
unset API_DOMAIN FRONTEND_DOMAIN AUTH_SITE_DOMAIN DOMAIN JWT_SECRET JWT_REFRESH_SECRET CSRF_SECRET SUPERADMIN_PASSWORD
load_config
check "migrates API_DOMAIN from APP_URL" "api.legacy.test" "$API_DOMAIN"
check "migrates FRONTEND_DOMAIN from CORS_ORIGIN" "legacy.test" "$FRONTEND_DOMAIN"
check "safely derives AUTH_SITE_DOMAIN from exact parent" "legacy.test" "$AUTH_SITE_DOMAIN"
check "preserves JWT secret" "keep-me" "$JWT_SECRET"
check "preserves refresh secret" "keep-me-too" "$JWT_REFRESH_SECRET"
check "preserves CSRF secret" "keep-csrf" "$CSRF_SECRET"
check "preserves admin password" "keep-admin" "$SUPERADMIN_PASSWORD"

legacy_siblings="${TEST_ROOT}/legacy-siblings"; mkdir -p "$legacy_siblings"
cat > "${legacy_siblings}/.env" <<'EOF'
APP_URL=https://api.legacy.test
CORS_ORIGIN=https://app.legacy.test
JWT_SECRET=keep-sibling-secret
EOF
REPO_DIR="$legacy_siblings"
unset API_DOMAIN FRONTEND_DOMAIN AUTH_SITE_DOMAIN DOMAIN JWT_SECRET
load_config
check "does not guess auth site from sibling hosts" "" "${AUTH_SITE_DOMAIN:-}"
check "still preserves secrets when auth site needs input" "keep-sibling-secret" "$JWT_SECRET"

: > "$STATE_FILE"
for phase in $(seq 1 "$TOTAL_PHASES"); do mark_completed "$phase"; done
check "--resume returns legacy sibling config to phase 5" "5" "$(resume_start_phase)"

printf 'AUTH_SITE_DOMAIN=legacy.test\n' >> "${legacy_siblings}/.env"
unset API_DOMAIN FRONTEND_DOMAIN AUTH_SITE_DOMAIN DOMAIN JWT_SECRET
load_config
check "accepts explicit auth site for sibling hosts" "0" \
  "$(validate_auth_site_domains "$API_DOMAIN" "$FRONTEND_DOMAIN" "$AUTH_SITE_DOMAIN"; echo $?)"
cat >> "${legacy_siblings}/.env" <<'EOF'
API_DOMAIN=api.legacy.test
FRONTEND_DOMAIN=app.legacy.test
EOF
check "--resume keeps verification behavior after migration" "8" "$(resume_start_phase)"

# Every value already rendered by an older installer must survive the
# phase-5/6 domain migration. Secrets are deliberately unique so a blank,
# generated replacement, or accidental log disclosure is easy to detect.
legacy_all="${TEST_ROOT}/legacy-all"; mkdir -p "$legacy_all"
cat > "${legacy_all}/.env" <<'EOF'
IMAGE_TAG=sentinel-backend-tag
FRONTEND_IMAGE_TAG=sentinel-frontend-tag
GHCR_IMAGE=registry.example/sentinel-backend
FRONTEND_GHCR_IMAGE=registry.example/sentinel-frontend
NODE_ENV=sentinel-production
PORT=4321
APP_URL=https://api.preserve.test
CORS_ORIGIN=https://preserve.test
MARKETING_URL=https://marketing.preserve.test
DATABASE_URL=postgresql://sentinel-user:sentinel-db-secret@db.preserve.test:5432/sentinel
REDIS_URL=redis://sentinel-redis:6380
JWT_SECRET=sentinel-jwt-secret
JWT_REFRESH_SECRET=sentinel-refresh-secret
JWT_ACCESS_EXPIRES_IN=31m
JWT_REFRESH_EXPIRES_IN=19d
CSRF_SECRET=sentinel-csrf-secret
COOKIE_DOMAIN=sentinel-cookie.preserve.test
CLOUDINARY_CLOUD_NAME=sentinel-cloud-name
CLOUDINARY_API_KEY=sentinel-cloud-key
CLOUDINARY_API_SECRET=sentinel-cloud-secret
CLOUDINARY_UPLOAD_FOLDER=sentinel-upload-folder
EMAIL_PROVIDER=sentinel-email-provider
SMTP_HOST=sentinel.smtp.preserve.test
SMTP_PORT=2525
SMTP_USER=sentinel-smtp-user
SMTP_PASS=sentinel-smtp-secret
SMTP_SECURE=sentinel-secure-setting
SMTP_FROM=sentinel-from@preserve.test
SMTP_FROM_NAME=Sentinel Sender
PASSWORD_RESET_URL=https://sentinel.preserve.test/custom-reset
EMAIL_VERIFICATION_URL=https://sentinel.preserve.test/custom-verify
RESEND_API_KEY=sentinel-resend-secret
SUPERADMIN_EMAIL=sentinel-admin@preserve.test
SUPERADMIN_PASSWORD=sentinel-admin-secret
IRD_ENABLED=sentinel-ird-enabled
IRD_API_BASE=https://sentinel.ird.preserve.test
IRD_TAXPAYER_PAN=sentinel-taxpayer-pan
IRD_SOFTWARE_ID=sentinel-software-id
LOG_LEVEL=sentinel-log-level
EOF
cp "${legacy_all}/.env" "${legacy_all}/before.env"
cp "${ROOT_DIR}/Caddyfile.template" "${legacy_all}/Caddyfile.template"

rendered_keys="$(cut -d= -f1 "${legacy_all}/before.env")"
for key in $rendered_keys API_DOMAIN FRONTEND_DOMAIN AUTH_SITE_DOMAIN; do
  unset "$key"
done
REPO_DIR="$legacy_all"
NON_INTERACTIVE=1
DEPLOY_USER="$(id -un)"
load_config
install_caddy_config() { : > "${5:-Caddyfile}"; }
phase_config > "${legacy_all}/migration.log" 2>&1
phase_render >> "${legacy_all}/migration.log" 2>&1
migration_status=$?
if [ "$migration_status" -ne 0 ]; then
  sed 's/^/       /' "${legacy_all}/migration.log"
fi
check "phase 5/6 legacy migration completes" "0" "$migration_status"
while IFS='=' read -r key expected; do
  actual="$(grep -E "^${key}=" "${legacy_all}/.env" | head -n1 | cut -d= -f2-)"
  check "preserves existing ${key}" "$expected" "$actual"
done < "${legacy_all}/before.env"
check "migration adds API_DOMAIN" "api.preserve.test" \
  "$(grep '^API_DOMAIN=' "${legacy_all}/.env" | cut -d= -f2-)"
check "migration adds FRONTEND_DOMAIN" "preserve.test" \
  "$(grep '^FRONTEND_DOMAIN=' "${legacy_all}/.env" | cut -d= -f2-)"
check "migration adds AUTH_SITE_DOMAIN" "preserve.test" \
  "$(grep '^AUTH_SITE_DOMAIN=' "${legacy_all}/.env" | cut -d= -f2-)"
check "migration does not print secret sentinels" "1" \
  "$(grep -qE 'sentinel-(db|jwt|refresh|csrf|cloud|smtp|resend|admin)-secret' "${legacy_all}/migration.log"; echo $?)"

REPO_DIR="$old_repo_dir"
cd "$ROOT_DIR"

rm -rf "$TEST_ROOT"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All ${PASS} checks passed."
  exit 0
fi
echo "${FAIL} failed, ${PASS} passed."
exit 1
