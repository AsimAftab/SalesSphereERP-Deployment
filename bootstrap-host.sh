#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ "$#" -eq 1 ] && [ -s "$1" ] \
  || { echo "Usage: sudo bash bootstrap-host.sh /path/to/deploy-key.pub" >&2; exit 1; }
DEPLOY_SSH_KEY="$(cat "$1")"
[[ "$DEPLOY_SSH_KEY" =~ ^ssh-(ed25519|rsa)[[:space:]] ]] \
  || { echo "An OpenSSH public key is required." >&2; exit 1; }
set --

INSTALL_LIB_ONLY=1 . ./install.sh
NON_INTERACTIVE=1
phase_packages
phase_firewall
phase_deploy_user
if [ -d "$REPO_DIR/.git" ]; then
  sudo -u "$DEPLOY_USER" git -C "$REPO_DIR" pull --ff-only
else
  phase_repo
fi
echo "Host prepared. No secrets, migrations, seed, containers, or DNS were changed."
