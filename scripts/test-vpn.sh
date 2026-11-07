#!/usr/bin/env bash
# Proves scraping egress uses the VPN: target sees the VPN IP, never the host IP; DNS via gluetun; no IPv6 leak.
# Usage: scripts/test-vpn.sh   (stack must be running; reads .env)
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_env "$FVPN_ROOT/.env"

report_init vpn

host_ip="$(host_public_ip)"
if [[ -n "$host_ip" ]]; then pass host_ip_known "$(mask_ip "$host_ip")"; else fail host_ip_known "could not get host public IP"; fi

vpn_ip="$(vpn_public_ip)"
if [[ -n "$vpn_ip" ]]; then pass gluetun_ip_known "$(mask_ip "$vpn_ip")"; else fail gluetun_ip_known "control server gave no public IP (stack up? GLUETUN_CONTROL_API_KEY?)"; fi

if ips_differ "$host_ip" "$vpn_ip"; then
  pass egress_not_host
else
  fail egress_not_host "host=$(mask_ip "$host_ip") vpn=$(mask_ip "$vpn_ip")"
fi

for variant in default waitfor; do
  body='{"url":"https://api.ipify.org","formats":["markdown"]}'
  [[ "$variant" == waitfor ]] && body='{"url":"https://api.ipify.org","formats":["markdown"],"waitFor":1000}'
  seen="$(scrape_seen_ip "$body")"
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

# IPv6: the namespace must have no IPv6 address besides loopback, and a literal IPv6
# destination (no DNS involved) must be unreachable.
v6_addrs="$(dc exec -T gluetun sh -c "ip -6 -o addr show | awk '\$2 != \"lo\" {print \$2, \$4}'" 2>/dev/null | tr -d '\r' || true)"
if ! dc ps --status running -q gluetun | grep -q .; then
  fail no_ipv6_addresses "could not inspect: gluetun not running"
elif [[ -z "$v6_addrs" ]]; then
  pass no_ipv6_addresses
else
  fail no_ipv6_addresses "IPv6 addresses present in scraping namespace: $(echo "$v6_addrs" | awk '{print $1}' | tr '
' ' ')"
fi

v6_rc=0
netns_probe -g -s -o /dev/null -m 10 'http://[2606:4700:4700::1111]/' </dev/null 2>/dev/null || v6_rc=$?
case "$v6_rc" in
  7|28) pass ipv6_literal_blocked "curl rc=$v6_rc" ;;
  125) fail ipv6_literal_blocked "could not probe: gluetun not running" ;;
  *) fail ipv6_literal_blocked "IPv6 destination answered or unexpected error (curl rc=$v6_rc)" ;;
esac

report_summary
