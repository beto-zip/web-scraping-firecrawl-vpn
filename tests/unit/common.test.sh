#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# shellcheck source=../../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

test_mask_ipv4()  { assert_eq "189.x.x.x" "$(mask_ip 189.40.12.7)" ipv4; }
test_mask_ipv6()  { assert_eq "2804:x::" "$(mask_ip 2804:14c:1:2::5)" ipv6; }
test_mask_empty() { assert_eq "<empty>" "$(mask_ip '')" empty; }

test_ips_differ_requires_both_nonempty() {
  assert_rc 1 ips_differ "" "1.2.3.4"
  assert_rc 1 ips_differ "1.2.3.4" ""
  assert_rc 1 ips_differ "1.2.3.4" "1.2.3.4"
  assert_rc 0 ips_differ "1.2.3.4" "5.6.7.8"
}

test_load_env_rejects_crlf() {
  printf 'A=1\r\n' > "$TMP/crlf.env"
  assert_rc 2 load_env "$TMP/crlf.env"
}

test_load_env_strips_quotes_and_comments() {
  printf '%s\n' '# c' 'QA="x y"' "QB='z'" 'QC=plain # note' '' > "$TMP/q.env"
  load_env "$TMP/q.env"
  assert_eq "x y" "$QA" double-quoted
  assert_eq "z" "$QB" single-quoted
  assert_eq "plain" "$QC" inline-comment
}

test_redact_hides_secrets() {
  WIREGUARD_PRIVATE_KEY=s3cr3tKEY
  REDIS_PASSWORD=pw1
  assert_eq "k=*** p=***" "$(echo 'k=s3cr3tKEY p=pw1' | redact)" redact
}

test_summary_fails_on_any_fail() {
  report_init t >/dev/null
  pass a >/dev/null
  fail b x >/dev/null
  assert_rc 1 report_summary
}

test_summary_passes_without_fail() {
  report_init t >/dev/null
  pass a >/dev/null
  skip c y >/dev/null
  assert_rc 0 report_summary
}

test_jqr_extracts_field() { assert_eq "1" "$(echo '{"a":1}' | jqr -r .a)" jqr; }

# CapEff comes from inside a container: never evaluate it unless it is plain hex.
test_cap_bit_set_reads_hex() {
  assert_rc 0 cap_bit_set 00000000a80425fb 13
  assert_rc 1 cap_bit_set 0000000000000000 13
}
test_cap_bit_set_rejects_non_hex() {
  # shellcheck disable=SC2016 # literal payload on purpose: must not be evaluated
  assert_rc 2 cap_bit_set 'a[$(touch $TMP/pwned)]' 13
  [[ ! -e "$TMP/pwned" ]] || fail_test "input was evaluated"
  assert_rc 2 cap_bit_set '' 13
}

test_vpn_set_status_rejects_bad_value() {
  assert_rc 2 vpn_set_status paused
  assert_rc 2 vpn_set_status ""
}

test_scrape_seen_ip_extracts_trimmed_body() {
  curl() { printf '%s' '{"success":true,"data":{"markdown":" 45.1.2.3\n"}}'; }
  assert_eq "45.1.2.3" "$(scrape_seen_ip '{}')" success
  curl() { printf '%s' '{"success":false,"error":"blocked"}'; }
  assert_eq "" "$(scrape_seen_ip '{}')" failure
}
