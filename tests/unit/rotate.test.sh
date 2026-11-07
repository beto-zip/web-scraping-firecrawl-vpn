#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2317
# Unit tests for scripts/lib/rotate.sh: VPN helpers are stubbed, no docker involved.
# shellcheck source=../../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=../../scripts/lib/rotate.sh
source "$ROOT/scripts/lib/rotate.sh"

# Each vpn_public_ip call returns the next queued IP.
ips() { printf '%s\n' "$@" > "$TMP/ips"; }
vpn_public_ip() { head -n1 "$TMP/ips"; sed -i 1d "$TMP/ips"; }
vpn_set_status() { echo "$1" >> "$TMP/calls"; }
vpn_wait_up() { return 0; }

test_rotate_first_attempt()  { ips 1.1.1.1 2.2.2.2; assert_rc 0 rotate_ip 3; }
test_rotate_second_attempt() { ips 1.1.1.1 1.1.1.1 2.2.2.2; assert_rc 0 rotate_ip 3; }

test_rotate_gives_up() {
  ips 1.1.1.1 1.1.1.1 1.1.1.1
  assert_rc 1 rotate_ip 2
  assert_eq 4 "$(wc -l < "$TMP/calls" | tr -d ' ')" "stop+start per attempt"
}

test_rotate_no_initial_ip() {
  ips ""
  assert_rc 2 rotate_ip 3
  [[ ! -s "$TMP/calls" ]] || fail_test "touched the tunnel without a known IP"
}

test_rotate_stop_refused()    { ips 1.1.1.1; vpn_set_status() { return 22; }; assert_rc 2 rotate_ip 3; }
test_rotate_tunnel_not_back() { ips 1.1.1.1; vpn_wait_up() { return 1; }; assert_rc 2 rotate_ip 3; }

test_rotate_output_masked() {
  ips 189.40.12.7 45.1.2.3
  local out
  out="$(rotate_ip 3 2>&1)"
  [[ "$out" == *"189.x.x.x -> 45.x.x.x"* && "$out" != *189.40* ]] || fail_test "unmasked or missing: $out"
}

test_rotate_flag_cleared_after_success() {
  ips 1.1.1.1 2.2.2.2
  rotate_ip 3 >/dev/null
  assert_eq 0 "$ROTATE_VPN_STOPPED" "flag after success"
}

test_rotate_flag_set_when_tunnel_not_back() {
  ips 1.1.1.1
  vpn_wait_up() { return 1; }
  rotate_ip 3 >/dev/null 2>&1
  assert_eq 1 "$ROTATE_VPN_STOPPED" "flag left for caller's restore"
}
