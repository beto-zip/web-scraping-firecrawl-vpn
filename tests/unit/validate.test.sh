#!/usr/bin/env bash
# shellcheck disable=SC2154
# Unit tests for scripts/validate.sh (no network, no compose).

test_valid_env_passes()         { assert_rc 0 "$V" --env "$F/valid.env" --skip-compose; }
test_empty_key_rejected()       { assert_rc 1 "$V" --env "$F/empty-key.env" --skip-compose; }
test_short_key_rejected()       { assert_rc 1 "$V" --env "$F/short-key.env" --skip-compose; }
test_quoted_key_consistent()    { assert_rc 0 "$V" --env "$F/quoted-key.env" --skip-compose; }
test_empty_password_rejected()  { assert_rc 1 "$V" --env "$F/empty-redis-pw.env" --skip-compose; }
test_public_bind_rejected()     { assert_rc 1 "$V" --env "$F/public-bind.env" --skip-compose; }
test_public_bind_allowed_flag() { assert_rc 0 "$V" --env "$F/public-bind.env" --skip-compose --allow-public-bind; }
test_bad_port_rejected()        { assert_rc 1 "$V" --env "$F/bad-port.env" --skip-compose; }
test_missing_env_rejected()     { assert_rc 1 "$V" --env "$TMP/nope.env" --skip-compose; }

# CRLF fixture is generated (a committed one would be normalized by .gitattributes).
test_crlf_env_rejected() {
  sed 's/$/\r/' "$F/valid.env" > "$TMP/crlf.env"
  assert_rc 1 "$V" --env "$TMP/crlf.env" --skip-compose
}

test_secret_never_printed() {
  local out
  out="$("$V" --env "$F/valid.env" --skip-compose 2>&1)"
  [[ "$out" != *AAAAAAAAAAAA* && "$out" != *fixture-* ]] || fail_test "secret leaked in output"
  out="$("$V" --env "$F/short-key.env" --skip-compose 2>&1)"
  [[ "$out" != *AAAAAAAAAA* ]] || fail_test "secret leaked in error output"
}

test_port_in_use_warns() {
  command -v python3 >/dev/null || { skip_test "python3 not available"; return; }
  python3 -m http.server 38123 --bind 127.0.0.1 >/dev/null 2>&1 &
  local pid=$! out rc=0
  sleep 2
  out="$("$V" --env "$F/port-38123.env" --skip-compose 2>&1)" || rc=$?
  kill "$pid" 2>/dev/null
  assert_eq 0 "$rc" "port in use is a warning only"
  [[ "$out" == *WARN*38123* ]] || fail_test "no port warning: $out"
}
