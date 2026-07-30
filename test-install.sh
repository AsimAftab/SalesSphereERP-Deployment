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
INSTALL_LIB_ONLY=1 . ./install.sh
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

# Non-RDS hosts are left completely alone: a DigitalOcean or Neon URL must
# not acquire a path to an Amazon CA bundle that does not describe it.
check "leaves DigitalOcean untouched" \
  "postgresql://u:p@db.ondigitalocean.com:25060/defaultdb?sslmode=require" \
  "$(rds_tls_url "postgresql://u:p@db.ondigitalocean.com:25060/defaultdb?sslmode=require" "$CA")"
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

STATE_FILE="$(mktemp)"
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

tmpdir="$(mktemp -d)"; pushd "$tmpdir" > /dev/null
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

popd > /dev/null; rm -rf "$tmpdir"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All ${PASS} checks passed."
  exit 0
fi
echo "${FAIL} failed, ${PASS} passed."
exit 1
