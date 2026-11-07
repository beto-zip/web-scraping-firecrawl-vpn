#!/usr/bin/env bash
# Runs every check and writes a redacted report to reports/report-<UTC>.txt.
# Usage: scripts/run-tests.sh [--skip-recovery]
#   --skip-recovery  skip test-recovery.sh (it restarts containers)
set -uo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SKIP_RECOVERY=0
[[ "${1:-}" == --skip-recovery ]] && SKIP_RECOVERY=1

[[ -f "$FVPN_ROOT/.env" ]] && load_env "$FVPN_ROOT/.env" 2>/dev/null

mkdir -p "$FVPN_ROOT/reports"
REPORT="$FVPN_ROOT/reports/report-$(date -u +%Y%m%dT%H%M%SZ).txt"

suites=(validate.sh test-firecrawl.sh test-vpn.sh test-killswitch.sh test-rotation.sh)
[[ "$SKIP_RECOVERY" -eq 0 ]] && suites+=(test-recovery.sh)

overall=0
{
  echo "# web-scraping-firecrawl-vpn test report"
  echo "date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit:   $(git -C "$FVPN_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "os:       $(uname -sr)"
  echo "docker:   $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)"
  echo "country:  ${SERVER_COUNTRIES:-unset}"
  echo
  for s in "${suites[@]}"; do
    bash "$FVPN_ROOT/scripts/$s" 2>&1 || overall=1
    echo
  done
  if [[ "$overall" -eq 0 ]]; then echo "RESULT: ALL PASS"; else echo "RESULT: FAILURES PRESENT"; fi
} | ( trap '' INT HUP; redact ) | ( trap '' INT HUP; tee "$REPORT" )
# redact/tee ignore Ctrl-C so the running suite can still write while it restores state.

echo "report written to: $REPORT"
grep -q '^RESULT: ALL PASS$' "$REPORT"
