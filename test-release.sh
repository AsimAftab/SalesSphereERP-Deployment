#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
test_root="$(mktemp -d "$PWD/.test-release.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/docker"
cp release.sh "$test_root/release.sh"
export DOCKER_CONFIG="$test_root/docker"
export DOCKER_TEST_LOG="$test_root/docker.log"
export SALESSPHERE_DEPLOY_LOCK="$test_root/deploy.lock"
export PATH="$test_root/bin:$PATH"

cat > "$test_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DOCKER_TEST_LOG"
case "$1" in
  login)
    [ "$(cat)" = "test-token" ]
    printf '{}\n' > "$DOCKER_CONFIG/config.json"
    ;;
  pull) [ "${FAIL_PULL:-false}" != true ] ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$test_root/bin/docker"
cat > "$test_root/deploy.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$DEPLOY_LOCK_HELD" = 1 ]
if flock -n -E 33 "$SALESSPHERE_DEPLOY_LOCK" -c true; then
  echo "Release lost the shared deployment lock." >&2
  exit 1
else
  [ "$?" = 33 ]
fi
printf 'deploy %s %s\n' "$1" "$2" >> "$DOCKER_TEST_LOG"
EOF

for target in backend frontend; do
  printf 'test-token' | bash "$test_root/release.sh" "$target" sha-abcdef0 test-user true > "$test_root/output"
  grep -q "pull ghcr.io/asimaftab/salessphere-erp-${target}:sha-abcdef0" "$DOCKER_TEST_LOG"
  ! grep -q '^deploy ' "$DOCKER_TEST_LOG"
done
[ "$(stat -c %a "$DOCKER_CONFIG/config.json")" = 600 ]
! grep -q test-token "$DOCKER_TEST_LOG" "$test_root/output"
echo "ok: preparation authenticates and pulls both images without rollout or token disclosure"

for args in \
  "invalid sha-abcdef0 test-user true" \
  "frontend latest test-user true" \
  "frontend sha-abcdef0 invalid/user true" \
  "frontend sha-abcdef0 test-user invalid"; do
  read -r -a argv <<< "$args"
  if printf 'test-token' | bash "$test_root/release.sh" "${argv[@]}" > /dev/null 2>&1; then
    echo "FAIL: invalid release arguments were accepted" >&2
    exit 1
  fi
done
echo "ok: invalid target, mutable tag, username, and preparation mode fail explicitly"

if printf 'test-token' | FAIL_PULL=true bash "$test_root/release.sh" frontend sha-abcdef0 test-user false > /dev/null 2>&1; then
  echo "FAIL: failed pull was ignored" >&2
  exit 1
fi
! grep -q '^deploy ' "$DOCKER_TEST_LOG"
echo "ok: registry failure prevents rollout"

printf 'test-token' | bash "$test_root/release.sh" frontend sha-abcdef0 test-user false
grep -q '^deploy frontend sha-abcdef0$' "$DOCKER_TEST_LOG"
echo "ok: real release delegates with the shared lock still held"
