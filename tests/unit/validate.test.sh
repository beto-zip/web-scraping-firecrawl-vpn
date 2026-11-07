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

test_url_unsafe_password_rejected() {
  sed 's|^REDIS_PASSWORD=.*|REDIS_PASSWORD=pa@ss/word|' "$F/valid.env" > "$TMP/unsafe.env"
  assert_rc 1 "$V" --env "$TMP/unsafe.env" --skip-compose
}

test_missing_bull_auth_key_rejected() {
  grep -v '^BULL_AUTH_KEY=' "$F/valid.env" > "$TMP/nobull.env"
  assert_rc 1 "$V" --env "$TMP/nobull.env" --skip-compose
}

# The file passed with --env is authoritative: inherited shell variables must not mask a missing value.
test_inherited_env_does_not_mask_missing_value() {
  grep -v '^BULL_AUTH_KEY=' "$F/valid.env" > "$TMP/nobull.env"
  BULL_AUTH_KEY=from-shell assert_rc 1 env BULL_AUTH_KEY=from-shell "$V" --env "$TMP/nobull.env" --skip-compose
}

# docker compose gives shell variables priority over .env: an exported value that differs
# from the file would change the real deployment, so validate must fail.
test_inherited_public_bind_rejected() {
  assert_rc 1 env API_BIND_ADDRESS=0.0.0.0 "$V" --env "$F/valid.env" --skip-compose
}

test_inherited_identical_value_accepted() {
  assert_rc 0 env API_BIND_ADDRESS=127.0.0.1 "$V" --env "$F/valid.env" --skip-compose
}

# The hint shown when compose config fails must not lead the user to print every secret.
test_compose_failure_hint_is_quiet() {
  mkdir -p "$TMP/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/docker"
  chmod +x "$TMP/bin/docker"
  local out
  out="$(PATH="$TMP/bin:$PATH" "$V" --env "$F/valid.env" 2>&1)" || true
  [[ "$out" == *"config -q"* ]] || fail_test "hint should suggest 'config -q': $out"
}
