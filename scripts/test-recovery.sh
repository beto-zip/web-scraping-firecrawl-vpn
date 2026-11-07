#!/usr/bin/env bash
# Proves persistence across down/up and documents Gluetun-restart behavior: any Gluetun
# restart (docker or compose) leaves api/playwright without network (fail-closed) until
# `docker compose restart api playwright`.
# Usage: scripts/test-recovery.sh   (stack must be running; restarts containers; reads .env)
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env "$FVPN_ROOT/.env"

API="$(api_url)"
report_init recovery

api_live() { curl -sf -m 5 -o /dev/null "$API/v0/health/liveness"; }

# Waits until the API answers and a scrape succeeds (max $1 seconds).
api_scrapes_within() {
  local timeout="$1" waited=0 ok
  while (( waited < timeout )); do
    if api_live; then
      ok="$(curl -s -m 90 -X POST "$API/v2/scrape" -H 'Content-Type: application/json' \
        -d '{"url":"https://example.com","formats":["markdown"]}' | jqr -r '.success // false' 2>/dev/null || echo false)"
      [[ "$ok" == true ]] && return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

redis_cli() { dc exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@" 2>/dev/null | tr -d '\r'; }

if ! api_live; then
  fail stack_running "API not reachable at $API (docker compose up -d)"
  report_summary || exit 1
fi

# --- persistence across down/up ---------------------------------------------------
marker="$(date -u +%s)"
redis_cli SET fvpn:marker "$marker" >/dev/null || true
dc down >/dev/null 2>&1
dc up -d >/dev/null 2>&1 || true
if wait_healthy api 300 && [[ "$(redis_cli GET fvpn:marker)" == "$marker" ]]; then
  pass persistence "redis data survived down/up"
else
  fail persistence "marker lost or stack not healthy after down/up"
fi
redis_cli DEL fvpn:marker >/dev/null || true

# --- gluetun restarted outside compose -> fail-closed ------------------------------
docker restart "$(dc ps -q gluetun)" >/dev/null
wait_healthy gluetun 180 || true
sleep 5
if api_live; then
  fail gluetun_restart_fails_closed "API still reachable after gluetun restart (unexpected: check netns sharing)"
else
  pass gluetun_restart_fails_closed "api has no network until restarted"
fi

dc restart api playwright >/dev/null 2>&1 || true
if api_scrapes_within 300; then
  pass manual_recovery "docker compose restart api playwright"
else
  fail manual_recovery "API did not recover after 'docker compose restart api playwright'"
fi

# --- compose-managed restart: also fail-closed, recovered by the same command ------
# (depends_on.restart restarted api before gluetun was back, leaving it on a dead netns.)
dc restart gluetun >/dev/null 2>&1 || true
wait_healthy gluetun 180 || true
sleep 5
if api_live; then
  fail compose_restart_fails_closed "API reachable right after 'docker compose restart gluetun' (unexpected)"
else
  pass compose_restart_fails_closed "api has no network until restarted"
fi
dc restart api playwright >/dev/null 2>&1 || true
if api_scrapes_within 300; then
  pass manual_recovery_after_compose_restart "docker compose restart api playwright"
else
  fail manual_recovery_after_compose_restart "API did not recover after 'docker compose restart api playwright'"
fi

report_summary
