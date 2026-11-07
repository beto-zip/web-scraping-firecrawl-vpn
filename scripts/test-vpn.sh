#!/usr/bin/env bash
# Proves scraping egress uses the VPN: target sees the VPN IP, never the host IP; DNS via gluetun; no IPv6 leak.
# Usage: scripts/test-vpn.sh   (stack must be running; reads .env)
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env "$FVPN_ROOT/.env"

API="$(api_url)"
report_init vpn

# Public IP as seen by gluetun (control server, inside the netns).
gluetun_public_ip() {
  netns_probe -s -m 10 -H "X-API-Key: ${GLUETUN_CONTROL_API_KEY}" http://127.0.0.1:8000/v1/publicip/ip 2>/dev/null \
    | jqr -r '.public_ip // empty' 2>/dev/null || true
}

# IP that a scraped target sees: Firecrawl scrapes api.ipify.org and returns the page body.
scraped_ip() {
  curl -s -m 120 -X POST "$API/v2/scrape" -H 'Content-Type: application/json' -d "$1" 2>/dev/null \
    | jqr -r 'if .success == true then (.data.markdown // "" | gsub("\\s"; "")) else empty end' 2>/dev/null || true
}

host_ip="$(curl -s -m 10 https://api.ipify.org || true)"
if [[ -n "$host_ip" ]]; then pass host_ip_known "$(mask_ip "$host_ip")"; else fail host_ip_known "could not get host public IP"; fi

vpn_ip="$(gluetun_public_ip)"
if [[ -n "$vpn_ip" ]]; then pass gluetun_ip_known "$(mask_ip "$vpn_ip")"; else fail gluetun_ip_known "control server gave no public IP (stack up? GLUETUN_CONTROL_API_KEY?)"; fi

if ips_differ "$host_ip" "$vpn_ip"; then
  pass egress_not_host
else
  fail egress_not_host "host=$(mask_ip "$host_ip") vpn=$(mask_ip "$vpn_ip")"
fi

for variant in default waitfor; do
  body='{"url":"https://api.ipify.org","formats":["markdown"]}'
  [[ "$variant" == waitfor ]] && body='{"url":"https://api.ipify.org","formats":["markdown"],"waitFor":1000}'
  seen="$(scraped_ip "$body")"
  if [[ -n "$seen" && "$seen" == "$vpn_ip" ]] && ips_differ "$host_ip" "$seen"; then
    pass "scrape_${variant}_sees_vpn_ip" "$(mask_ip "$seen")"
  else
    fail "scrape_${variant}_sees_vpn_ip" "target saw $(mask_ip "$seen"), vpn=$(mask_ip "$vpn_ip"), host=$(mask_ip "$host_ip")"
  fi
done

nameservers="$(dc exec -T api sh -c "grep '^nameserver' /etc/resolv.conf | awk '{print \$2}'" 2>/dev/null | tr -d '\r' | sort -u | tr '\n' ' ' || true)"
if [[ "$nameservers" == "127.0.0.1 " ]]; then
  pass dns_via_gluetun
else
  fail dns_via_gluetun "api resolv.conf nameservers: '${nameservers:-none}' (expected only 127.0.0.1)"
fi

v6_rc=0
v6_seen="$(netns_probe -6 -s -m 10 https://api6.ipify.org 2>/dev/null)" || v6_rc=$?
if [[ "$v6_rc" -eq 125 ]]; then
  fail ipv6_no_leak "could not probe: gluetun not running"
elif [[ "$v6_rc" -ne 0 ]]; then
  pass ipv6_no_leak "no IPv6 egress from netns (curl rc=$v6_rc)"
else
  host_v6="$(curl -6 -s -m 10 https://api6.ipify.org || true)"
  if [[ -n "$host_v6" ]] && ips_differ "$host_v6" "$v6_seen"; then
    pass ipv6_no_leak "IPv6 egress via VPN $(mask_ip "$v6_seen")"
  else
    fail ipv6_no_leak "IPv6 egress $(mask_ip "$v6_seen") could not be told apart from host $(mask_ip "$host_v6")"
  fi
fi

report_summary
