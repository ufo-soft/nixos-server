#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

NIXOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="/var/lib/deploy"

usage() {
  echo "Usage: $0 <app-name> <new-image-sha>"
  echo ""
  echo "Updates the image SHA for an app and rebuilds the system."
  echo ""
  echo "Examples:"
  echo "  $0 example-api sha256:abc123..."
  echo "  $0 example-api \$(docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/you/example-api:latest | cut -d@ -f2)"
  exit 1
}

[[ $# -ne 2 ]] && usage

APP_NAME="$1"
NEW_SHA="$2"
APP_FILE=$(find "$NIXOS_DIR/apps" -name "${APP_NAME}.nix" -not -name '_template.nix' | head -1)
SHA_FILE="$DEPLOY_DIR/$APP_NAME.sha"

[[ -z "$APP_FILE" ]] && error "App file not found for: $APP_NAME"

# Validate SHA format
[[ ! "$NEW_SHA" =~ ^sha256:[a-f0-9]{64}$ ]] && error "Invalid SHA format. Expected: sha256:<64 hex chars>"

info "Updating $APP_NAME to $NEW_SHA"

# Write SHA to state file
sudo mkdir -p "$DEPLOY_DIR"
echo -n "$NEW_SHA" | sudo tee "$SHA_FILE" > /dev/null

info "Updated $SHA_FILE"

# Reset any previous failure state so the container can start fresh
sudo systemctl reset-failed "docker-${APP_NAME}" 2>/dev/null || true

info "Rebuilding NixOS configuration..."
sudo nixos-rebuild switch --impure --flake "$NIXOS_DIR#server"

info "Waiting for container to start..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
  STATUS=$(docker ps --filter "name=$APP_NAME" --format "{{.Status}}" 2>/dev/null || true)
  if [[ -n "$STATUS" ]]; then
    break
  fi
  sleep 1
  WAITED=$((WAITED + 1))
done

if [[ -z "$STATUS" ]]; then
  echo ""
  error "Container $APP_NAME failed to start within ${MAX_WAIT}s. Recent logs:
$(sudo journalctl -u "docker-${APP_NAME}" -n 15 --no-pager 2>/dev/null || echo 'Could not read logs')"
fi

info "Container running: $STATUS"

# Health check — try the /health endpoint if Traefik labels are configured
DOMAIN=$(grep -oP 'domain\s*=\s*"\K[^"]+' "$APP_FILE" 2>/dev/null || true)
if [[ -n "$DOMAIN" ]]; then
  info "Checking health at https://${DOMAIN}/health ..."
  HEALTH_WAIT=15
  HEALTH_OK=false
  for i in $(seq 1 $HEALTH_WAIT); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/health" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
      HEALTH_OK=true
      break
    fi
    sleep 1
  done

  if $HEALTH_OK; then
    info "Health check passed (HTTP 200)"
  else
    warn "Health check failed (last HTTP $HTTP_CODE) — container is running but may not be routable yet"
  fi
fi

info "Deploy complete."
docker ps --filter "name=$APP_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
