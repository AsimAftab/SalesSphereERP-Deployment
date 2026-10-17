#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
[ "$#" -eq 4 ] \
  || { echo "Usage: release.sh <backend|frontend> <sha-tag> <github-user> <prepare-only:true|false>" >&2; exit 1; }
target="$1"; tag="$2"; github_user="$3"; prepare_only="$4"
case "$target" in
  backend) image=ghcr.io/asimaftab/salessphere-erp-backend ;;
  frontend) image=ghcr.io/asimaftab/salessphere-erp-frontend ;;
  *) echo "Invalid release target." >&2; exit 1 ;;
esac
[[ "$tag" =~ ^sha-[a-f0-9]{7}$ ]] \
  || { echo "An immutable sha-<7 hex digits> tag is required." >&2; exit 1; }
[[ "$github_user" =~ ^[A-Za-z0-9_-]+$ ]] \
  || { echo "Invalid GitHub username." >&2; exit 1; }
[[ "$prepare_only" = true || "$prepare_only" = false ]] \
  || { echo "prepare-only must be true or false." >&2; exit 1; }

# Serialize registry credentials as well as rollouts across both application repos.
exec 9>"${SALESSPHERE_DEPLOY_LOCK:-/home/deploy/.salessphere-erp-deploy.lock}"
flock -w "${DEPLOY_LOCK_TIMEOUT:-900}" 9 \
  || { echo "Timed out waiting for the deployment lock." >&2; exit 1; }
docker login ghcr.io --username "$github_user" --password-stdin
chmod 600 "${DOCKER_CONFIG:-$HOME/.docker}/config.json"
docker pull "${image}:${tag}"
if [ "$prepare_only" = true ]; then
  echo "Image prepared; no services, migrations, or DNS changed."
  exit 0
fi
export DEPLOY_LOCK_HELD=1
exec bash ./deploy.sh "$target" "$tag"
