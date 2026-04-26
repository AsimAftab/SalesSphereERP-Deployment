#!/usr/bin/env bash
#
# One-time droplet setup for the SalesSphere ERP backend.
#
# Usage:
#   1. Provision a fresh Ubuntu 22.04+ droplet on DigitalOcean.
#   2. SSH in as root and create a non-root deploy user:
#        adduser --disabled-password --gecos "" deploy
#        usermod -aG sudo deploy
#        mkdir -p /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
#        # Paste the GitHub Actions deploy public key:
#        nano /home/deploy/.ssh/authorized_keys
#        chmod 600 /home/deploy/.ssh/authorized_keys
#        chown -R deploy:deploy /home/deploy/.ssh
#   3. Switch to the deploy user: su - deploy
#   4. Clone this repo into ~/SalesSphereERP-Deployment
#   5. Run this script: bash bootstrap.sh
#
# The script is idempotent — safe to re-run if something fails partway.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}!! ${NC} $1"; }
fail() { echo -e "${RED}xx ${NC} $1"; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
    fail "Don't run this as root. Switch to the 'deploy' user first."
fi

if [ ! -f docker-compose.yml ]; then
    fail "Run this script from the SalesSphereERP-Deployment directory."
fi

# ----------------------------------------------------------------------
step "Updating apt package index"
sudo apt-get update -y

# ----------------------------------------------------------------------
step "Installing Docker Engine + Compose plugin"
if ! command -v docker > /dev/null 2>&1; then
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
else
    echo "    Docker already installed: $(docker --version)"
fi

# ----------------------------------------------------------------------
step "Adding $USER to the 'docker' group"
if id -nG "$USER" | grep -qw docker; then
    echo "    Already in the docker group."
else
    sudo usermod -aG docker "$USER"
    warn "Group membership won't take effect until you log out and back in."
    warn "After that, you can run 'docker' commands without sudo."
fi

# ----------------------------------------------------------------------
step "Setting up firewall (ufw — allow SSH + HTTP + HTTPS)"
if ! command -v ufw > /dev/null 2>&1; then
    sudo apt-get install -y ufw
fi
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# ----------------------------------------------------------------------
step "Checking for .env"
if [ ! -f .env ]; then
    warn ".env not found. Copy .env.example to .env and fill in real values:"
    warn "  cp .env.example .env"
    warn "  nano .env"
    warn "  chmod 600 .env"
    echo
    echo "    Re-run this script (or just the GHCR login + compose steps below)"
    echo "    once the .env is in place."
    exit 0
fi

if [ "$(stat -c %a .env)" != "600" ]; then
    warn ".env permissions are not 600 — fixing."
    chmod 600 .env
fi

# ----------------------------------------------------------------------
step "Logging in to GitHub Container Registry"
echo
echo "  Generate a Personal Access Token (classic) at:"
echo "    https://github.com/settings/tokens  →  scopes: read:packages"
echo
echo "  Then run, replacing <token> + <user>:"
echo "    echo <token> | docker login ghcr.io -u <user> --password-stdin"
echo
echo "  (Skipping automated login here so the token never lands in this script's history.)"

# ----------------------------------------------------------------------
step "Verifying Caddyfile has your real domain"
if grep -q "api.salessphere.com" Caddyfile; then
    warn "Caddyfile still references the placeholder 'api.salessphere.com'."
    warn "Edit it to use your real hostname before starting Caddy."
fi

# ----------------------------------------------------------------------
step "Bootstrap done"
cat <<EOF

Next steps (after logging out + back in for docker group to apply):

  1. Log in to GHCR (see above).
  2. Verify .env is populated and Caddyfile points at your real domain.
  3. Pull the image and start the stack:
       docker compose pull
       docker compose up -d
  4. Apply migrations (one-shot — safe to re-run):
       docker compose run --rm app bunx prisma migrate deploy
  5. Seed the platform super-admin (idempotent):
       docker compose run --rm app bun run db:seed
  6. Smoke test:
       curl -fsS http://localhost:3000/health/ready

  After your domain's A record points at this droplet's IP, Caddy will
  provision the TLS cert on the first request to https://<your-domain>.

EOF
