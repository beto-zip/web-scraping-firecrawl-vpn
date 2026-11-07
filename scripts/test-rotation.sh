#!/usr/bin/env bash
# Proves exit IP rotation: the IP changes, a scrape in flight never leaks the host IP,
# scraping sees the new IP afterwards, and api/playwright are not restarted.
# Usage: scripts/test-rotation.sh   (stack must be running; reads .env)
#   ROTATE_SCRIPT=<cmd>  rotation command (default scripts/rotate-ip.sh)
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env "$FVPN_ROOT/.env"

ROTATE_SCRIPT="${ROTATE_SCRIPT:-$FVPN_ROOT/scripts/rotate-ip.sh}"
IP_BODY='{"url":"https://api.ipify.org","formats":["markdown"],"maxAge":0}'
report_init rotation

INFLIGHT_PID="" INFLIGHT_OUT="$(mktemp)"
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
  if [[ -n "$INFLIGHT_PID" ]]; then kill "$INFLIGHT_PID" 2>/dev/null || true; fi
  rm -f "$INFLIGHT_OUT"
}
trap cleanup EXIT

started_at() { docker inspect -f '{{.State.StartedAt}}' "$(dc ps -q "$1")" 2>/dev/null || true; }

host_ip="$(host_public_ip)"
before="$(vpn_public_ip)"
api_started="$(started_at api)"
pw_started="$(started_at playwright)"

if [[ -n "$before" ]]; then
  pass ip_before_known "$(mask_ip "$before")"
else
  fail ip_before_known "control server gave no public IP (stack up? GLUETUN_CONTROL_API_KEY?)"
fi

# A scrape still running when the tunnel goes down: the target answers after 8s and echoes
# the requester IP ("origin"), so a leak would show the host IP in the response.
curl -s -m 150 -X POST "$(api_url)/v2/scrape" -H 'Content-Type: application/json' \
  -d '{"url":"https://httpbin.org/delay/8","formats":["markdown"],"maxAge":0,"timeout":120000}' \
  > "$INFLIGHT_OUT" 2>/dev/null &
INFLIGHT_PID=$!
sleep 2

rot_rc=0
rot_out="$("$ROTATE_SCRIPT" 2>&1)" || rot_rc=$?
after="$(vpn_public_ip)"
if [[ "$rot_rc" -eq 0 ]] && ips_differ "$before" "$after"; then
  rot_out="${rot_out%)}"
  pass rotate_changes_ip "$(mask_ip "$before") -> $(mask_ip "$after"); ${rot_out##*(}"
else
  fail rotate_changes_ip "rc=$rot_rc before=$(mask_ip "$before") after=$(mask_ip "$after"): ${rot_out:-no output}"
fi

wait "$INFLIGHT_PID" 2>/dev/null || true
INFLIGHT_PID=""
inflight="$(cat "$INFLIGHT_OUT")"
if [[ -z "$host_ip" ]]; then
  fail inflight_scrape_no_leak "host IP unknown: cannot verify"
elif [[ "$inflight" == *"$host_ip"* ]]; then
  fail inflight_scrape_no_leak "target saw the host IP (LEAK)"
elif [[ "$inflight" == *'"success":true'* ]]; then
  pass inflight_scrape_no_leak "outcome=ok"
else
  pass inflight_scrape_no_leak "outcome=failed"
fi

# The first scrape right after a reconnect can fail once; record when a retry was needed.
retry=0
seen="$(scrape_seen_ip "$IP_BODY")"
if [[ -z "$seen" ]]; then
  retry=1
  sleep 5
  seen="$(scrape_seen_ip "$IP_BODY")"
fi
if [[ -n "$seen" && "$seen" == "$after" ]] && ips_differ "$host_ip" "$seen"; then
  pass scrape_sees_new_ip "$(mask_ip "$seen") retry=$retry"
else
  fail scrape_sees_new_ip "target saw $(mask_ip "$seen"), vpn=$(mask_ip "$after"), host=$(mask_ip "$host_ip")"
fi

for svc in api playwright; do
  [[ "$svc" == api ]] && was="$api_started" || was="$pw_started"
  now="$(started_at "$svc")"
  if [[ -n "$was" && "$was" == "$now" ]]; then
    pass "${svc}_not_restarted"
  else
    fail "${svc}_not_restarted" "StartedAt changed or unknown (before=${was:-?} after=${now:-?})"
  fi
done

report_summary
