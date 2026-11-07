#!/usr/bin/env bash
# Static checks on the resolved compose configuration (needs docker, no containers started).
# shellcheck source=../../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

compose_json() {
  env -u API_BIND_ADDRESS -u FIRECRAWL_PORT docker compose --project-directory "$ROOT" \
    --env-file "$F/valid.env" config --format json 2>/dev/null
}

# Without IPv6 on the networks the scraping namespace has no IPv6 path to the host or peers.
test_networks_disable_ipv6() {
  command -v docker >/dev/null || { skip_test "docker not available"; return; }
  local json
  json="$(compose_json)" || { fail_test "docker compose config failed"; return; }
  assert_eq "false" "$(printf '%s' "$json" | jqr -r '.networks.edge.enable_ipv6')" "edge enable_ipv6"
  assert_eq "false" "$(printf '%s' "$json" | jqr -r '.networks.backend.enable_ipv6')" "backend enable_ipv6"
}

test_scraping_services_drop_all_capabilities() {
  command -v docker >/dev/null || { skip_test "docker not available"; return; }
  local json
  json="$(compose_json)" || { fail_test "docker compose config failed"; return; }
  assert_eq "ALL" "$(printf '%s' "$json" | jqr -r '.services.api.cap_drop | join(",")')" "api cap_drop"
  assert_eq "ALL" "$(printf '%s' "$json" | jqr -r '.services.playwright.cap_drop | join(",")')" "playwright cap_drop"
}
