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
