#!/usr/bin/env bash
# Proves fail-closed behavior: private destinations blocked, and with the tunnel stopped
# nothing leaves the scraping namespace. Always restarts the VPN on exit.
# Usage: scripts/test-killswitch.sh   (stack must be running; reads .env)
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env "$FVPN_ROOT/.env"

API="$(api_url)"
CONTROL="http://127.0.0.1:8000"
report_init killswitch

vpn_set() {
  netns_probe -s -m 15 -X PUT -H "X-API-Key: ${GLUETUN_CONTROL_API_KEY}" -H 'Content-Type: application/json' \
    -d "{\"status\":\"$1\"}" "$CONTROL/v1/vpn/status" </dev/null >/dev/null 2>&1
}

# Waits until the tunnel is up again and gluetun reports a public IP (max 180s).
vpn_wait_up() {
  local waited=0 ip
  while (( waited < 180 )); do
    ip="$(netns_probe -s -m 5 -H "X-API-Key: ${GLUETUN_CONTROL_API_KEY}" "$CONTROL/v1/publicip/ip" </dev/null 2>/dev/null \
      | jqr -r '.public_ip // empty' 2>/dev/null || true)"
    [[ -n "$ip" ]] && wait_healthy gluetun 60 && return 0
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

VPN_STOPPED=0
restore_vpn() {
  if [[ "$VPN_STOPPED" -eq 1 ]]; then
    echo "-- restoring VPN"
    vpn_set running || true
    vpn_wait_up || echo "WARN  VPN did not come back; run: docker compose restart gluetun" >&2
    VPN_STOPPED=0
  fi
}
trap restore_vpn EXIT
# On interruption: restore the tunnel, then stop (never continue checks with a changed tunnel state).
trap 'restore_vpn; exit 130' INT
trap 'restore_vpn; exit 143' TERM

# PASS when the probe could run and the destination was NOT reachable.
# Firewall DROP shows as timeout (28) or no DNS (6). Connection refused (7) or any
# HTTP answer (0) means packets reached the destination -> FAIL.
expect_blocked() {
  local name="$1" rc=0
  shift
  netns_probe -s -o /dev/null "$@" </dev/null 2>/dev/null || rc=$?
  case "$rc" in
    6|28) pass "$name" "curl rc=$rc" ;;
    125) fail "$name" "could not probe: gluetun not running" ;;
    *) fail "$name" "destination reachable from scraping namespace (curl rc=$rc)" ;;
  esac
}

scrape_success() {
  curl -s -m "${2:-120}" -X POST "$API/v2/scrape" -H 'Content-Type: application/json' \
    -d "{\"url\":\"$1\",\"formats\":[\"markdown\"]}" 2>/dev/null \
    | jqr -r '.success // false' 2>/dev/null || echo false
}

if ! dc ps --status running -q gluetun | grep -q .; then
  fail stack_running "gluetun is not running (docker compose up -d)"
  report_summary || exit 1
fi

# --- Tunnel up: private destinations must still be blocked -----------------------
edge_gw="$(docker network inspect "${EDGE_NETWORK_NAME:-firecrawl-edge}" -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
if [[ -n "$edge_gw" ]]; then
  expect_blocked private_host_gateway_blocked -m 5 "http://$edge_gw/"
else
  fail private_host_gateway_blocked "could not read edge network gateway"
fi
expect_blocked metadata_blocked -m 5 http://169.254.169.254/
expect_blocked tailscale_range_blocked -m 5 http://100.100.100.100/

# Backend must stay reachable (redis answers PING, NOAUTH also proves reachability).
redis_reply="$(printf 'PING\r\nQUIT\r\n' | netns_probe -s -m 5 telnet://redis:6379 2>/dev/null || true)"
if [[ "$redis_reply" == *PONG* || "$redis_reply" == *NOAUTH* ]]; then
  pass backend_reachable
else
  fail backend_reachable "redis did not answer from scraping namespace"
fi

# Firecrawl itself must refuse private targets (SSRF guard), e.g. a backend IP.
rabbit_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(dc ps -q rabbitmq)" 2>/dev/null || true)"
if [[ -n "$rabbit_ip" && "$(scrape_success "http://$rabbit_ip:15672/" 60)" != true ]]; then
  pass api_refuses_private_target
else
  fail api_refuses_private_target "scrape of backend address ${rabbit_ip:-?} succeeded or could not run"
fi

# --- Tunnel down: nothing may leave ---------------------------------------------
if vpn_set stopped; then
  VPN_STOPPED=1
  sleep 3
  pass vpn_stopped
  expect_blocked direct_egress_blocked -m 10 https://1.1.1.1/
  expect_blocked direct_ip_egress_blocked -m 10 http://8.8.8.8/
  if [[ "$(scrape_success https://example.com 90)" != true ]]; then
    pass scrape_fails_when_down
  else
    fail scrape_fails_when_down "scrape succeeded with the tunnel stopped (LEAK)"
  fi
else
  fail vpn_stopped "control server refused to stop the VPN (GLUETUN_CONTROL_API_KEY?)"
fi

# --- Tunnel back up --------------------------------------------------------------
restore_vpn
# Gluetun rebuilds firewall rules on reconnect: private ranges must stay blocked.
if [[ -n "$edge_gw" ]]; then
  expect_blocked private_host_gateway_blocked_after_reconnect -m 5 "http://$edge_gw/"
fi
if [[ "$(scrape_success https://example.com)" == true ]]; then
  pass scrape_recovers
else
  fail scrape_recovers "scrape still failing after VPN restart"
fi

report_summary
