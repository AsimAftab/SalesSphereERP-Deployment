#!/usr/bin/env bash
#
# Backwards-compatible wrapper around deploy.sh.
#   ./update.sh                    -> backend
#   ./update.sh sha-abc123         -> backend sha-abc123
#   ./update.sh frontend [tag]     -> frontend
#   ./update.sh all [tag]          -> both services

set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  backend|frontend|all)
    exec ./deploy.sh "$@"
    ;;
  "")
    exec ./deploy.sh backend
    ;;
  --no-migrate)
    echo "update.sh: --no-migrate is no longer supported; backend migrations are mandatory before replacement." >&2
    exit 2
    ;;
  *)
    [ "$#" -eq 1 ] || {
      echo "Usage: ./update.sh [backend|frontend|all] [sha-tag]" >&2
      exit 2
    }
    exec ./deploy.sh backend "$1"
    ;;
esac
