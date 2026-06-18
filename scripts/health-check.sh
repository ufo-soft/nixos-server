#!/usr/bin/env bash
# Quick health check for all apps and infrastructure services.
# Run from your local machine — pings each service's external URL.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass=0
fail=0

check() {
  local name="$1" url="$2" expected="${3:-200}"
  status=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")
  if [ "$status" = "$expected" ]; then
    printf "  ${GREEN}✓${NC} %-25s %s\n" "$name" "$status"
    pass=$((pass + 1))
  else
    printf "  ${RED}✗${NC} %-25s %s (expected %s)\n" "$name" "$status" "$expected"
    fail=$((fail + 1))
  fi
}

echo ""
echo "Apps"
echo "────────────────────────────────────"
check "family-archive"       "https://mariasfamilyarchive.com"
check "home-cooking"         "https://home-cooking.timothymarias.com/health"

echo ""
echo "Infrastructure"
echo "────────────────────────────────────"
check "healthchecks"         "https://healthchecks.timothymarias.com/api/v3/status/"
check "grafana"              "https://grafana.timothymarias.com"

echo ""
echo "────────────────────────────────────"
printf "  ${GREEN}${pass} passed${NC}"
if [ "$fail" -gt 0 ]; then
  printf "  ${RED}${fail} failed${NC}"
fi
echo ""

exit "$fail"