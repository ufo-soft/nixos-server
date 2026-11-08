#!/usr/bin/env bash
# Pull the latest config and switch to it. Run on the server:
#   ./scripts/rebuild.sh            # pull + switch + health check
#   ./scripts/rebuild.sh --no-pull  # switch to the working tree as it is
set -euo pipefail

NIXOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$NIXOS_DIR"

if [[ "${1:-}" != "--no-pull" ]]; then
  # --autostash: a locally modified flake.lock must not block the pull.
  git pull --ff-only --autostash
fi

echo "==> switching to $(git log --oneline -1)"
# --impure: app modules read image digests from /var/lib/deploy at eval time.
sudo nixos-rebuild switch --flake "$NIXOS_DIR#server" --impure

echo
systemctl --failed --no-legend || true
"$NIXOS_DIR/scripts/health-check.sh"
