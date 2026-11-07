#!/usr/bin/env bash
# Proves fail-closed behavior: private destinations blocked, and with the tunnel stopped
# nothing leaves the scraping namespace. Always restarts the VPN on exit.
# Usage: scripts/test-killswitch.sh   (stack must be running; reads .env)
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env "$FVPN_ROOT/.env"

API="$(api_url)"
report_init killswitch

VPN_STOPPED=0
# Output may go to a pipe that is already gone (Ctrl-C killed `tee`): never let a failed
# write stop the restore. Messages are best effort.
restore_vpn() {
  if [[ "$VPN_STOPPED" -eq 1 ]]; then
    echo "-- restoring VPN" 2>/dev/null || true
    vpn_set_status running || true
    vpn_wait_up 180 || { echo "WARN  VPN did not come back; run: docker compose restart gluetun" >&2; } 2>/dev/null || true
    VPN_STOPPED=0
  fi
}
# Ignore SIGPIPE: a write to a closed pipe then fails (set -e exits) and the EXIT trap restores.
trap '' PIPE
trap 'restore_vpn; cleanup_listener' EXIT
# On interruption (Ctrl-C, kill, SSH disconnect): restore the tunnel, then stop.
trap 'restore_vpn; reraise INT' INT
trap 'restore_vpn; reraise TERM' TERM
trap 'restore_vpn; reraise HUP' HUP

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

# Prints "true" or "false" when the API answered with JSON, "noanswer" otherwise.
# Checks that expect a refusal require "false": an API that is down proves nothing.
scrape_result() {
  local out
  out="$(curl -s -m "${2:-120}" -X POST "$API/v2/scrape" -H 'Content-Type: application/json' \
    -d "{\"url\":\"$1\",\"formats\":[\"markdown\"]}" 2>/dev/null \
    | jqr -r 'if (.success | type) == "boolean" then (.success | tostring) else "noanswer" end' 2>/dev/null || true)"
  echo "${out:-noanswer}"
}

LISTENER=""
LISTENER_IMAGE="${LISTENER_IMAGE:-python:3.12-alpine@sha256:e064671ca452259bab50e8e2c7bd896e39e9a343bb06ca25234adf6fe18d0fc7}"
EDGE_NET="${EDGE_NETWORK_NAME:-firecrawl-edge}"
cleanup_listener() {
  if [[ -n "$LISTENER" ]]; then docker rm -f "$LISTENER" >/dev/null 2>&1 || true; fi
  LISTENER=""
}

# Positive-controlled check: a throwaway HTTP listener on the edge network must be reachable
# from outside the scraping namespace (control) and unreachable from inside it.
check_edge_peer_blocked() {
  local name="$1" ip ctl=0
  if [[ -z "$LISTENER" ]]; then
    LISTENER="$(docker run -d --rm --network "$EDGE_NET" "$LISTENER_IMAGE" \
      python -m http.server 8080 --directory /tmp 2>/dev/null || true)"
    sleep 3
  fi
  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$LISTENER" 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    fail "$name" "could not start edge listener"
    return
  fi
  docker run --rm --network "$EDGE_NET" "$CURL_IMAGE" -s -o /dev/null -m 5 "http://$ip:8080/" >/dev/null 2>&1 || ctl=$?
  if [[ "$ctl" -ne 0 ]]; then
    fail "$name" "inconclusive: control probe from edge could not reach listener (curl rc=$ctl)"
    return
  fi
  expect_blocked "$name" -m 5 "http://$ip:8080/"
}

post_rules_loaded() {
  local n
  n="$(dc exec -T gluetun iptables -S OUTPUT 2>/dev/null | grep -c -- '--ctstate NEW -j DROP' || true)"
  if [[ "${n:-0}" -ge 5 ]]; then
    pass "$1" "$n private-range DROP rules"
  else
    fail "$1" "expected >=5 private-range DROP rules, found ${n:-0} (config/gluetun/post-rules.txt mounted?)"
  fi
}

if ! dc ps --status running -q gluetun | grep -q .; then
  fail stack_running "gluetun is not running (docker compose up -d)"
  report_summary || exit 1
fi

# --- Tunnel up: private destinations must still be blocked -----------------------
# Raw/packet sockets bypass netfilter: scraping containers must not hold CAP_NET_RAW (bit 13).
for svc in api playwright; do
  capeff="$(dc exec -T "$svc" sh -c "grep CapEff /proc/self/status" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)"
  cap_rc=0
  cap_bit_set "$capeff" 13 || cap_rc=$?
  case "$cap_rc" in
    0) fail "no_net_raw_$svc" "$svc has CAP_NET_RAW (CapEff=$capeff): raw sockets could bypass the firewall" ;;
    1) pass "no_net_raw_$svc" "CapEff=$capeff" ;;
    *) fail "no_net_raw_$svc" "could not read capabilities of $svc" ;;
  esac
done

post_rules_loaded post_rules_loaded
check_edge_peer_blocked edge_peer_blocked
# No positive control is possible for these on most hosts: they confirm, the edge check proves.
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
res="$(scrape_result "http://$rabbit_ip:15672/" 60)"
if [[ -n "$rabbit_ip" && "$res" == false ]]; then
  pass api_refuses_private_target
else
  fail api_refuses_private_target "scrape of backend address ${rabbit_ip:-?}: $res (expected an API refusal)"
fi

# --- Tunnel down: nothing may leave ---------------------------------------------
# Mark before the request: if interrupted mid-request the tunnel may already be stopped.
# Restoring an already running tunnel is harmless.
VPN_STOPPED=1
if vpn_set_status stopped; then
  sleep 3
  pass vpn_stopped
  expect_blocked direct_egress_blocked -m 10 https://1.1.1.1/
  expect_blocked direct_ip_egress_blocked -m 10 http://8.8.8.8/
  res="$(scrape_result https://example.com 90)"
  case "$res" in
    false) pass scrape_fails_when_down ;;
    true) fail scrape_fails_when_down "scrape succeeded with the tunnel stopped (LEAK)" ;;
    *) fail scrape_fails_when_down "API did not answer; cannot tell (is api running?)" ;;
  esac
else
  fail vpn_stopped "control server refused to stop the VPN (GLUETUN_CONTROL_API_KEY?)"
fi

# --- Tunnel back up --------------------------------------------------------------
restore_vpn
# Gluetun rebuilds firewall rules on reconnect: private ranges must stay blocked.
post_rules_loaded post_rules_loaded_after_reconnect
check_edge_peer_blocked edge_peer_blocked_after_reconnect
cleanup_listener
if [[ "$(scrape_result https://example.com)" == true ]]; then
  pass scrape_recovers
else
  fail scrape_recovers "scrape still failing after VPN restart"
fi

report_summary
