#!/usr/bin/env bash
# Shared helpers for web-scraping-firecrawl-vpn scripts. Source, do not execute.
# Library: does not set shell options; callers use `set -euo pipefail`.

FVPN_ROOT="${FVPN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"

# ---------- report ----------
REPORT_SUITE="" REPORT_PASS=0 REPORT_FAIL=0 REPORT_SKIP=0

report_init() {
  REPORT_SUITE="$1" REPORT_PASS=0 REPORT_FAIL=0 REPORT_SKIP=0
  echo "== $REPORT_SUITE"
}
pass() { REPORT_PASS=$((REPORT_PASS + 1)); echo "PASS  $1${2:+  ($2)}"; }
fail() { REPORT_FAIL=$((REPORT_FAIL + 1)); echo "FAIL  $1  -- $2"; }
skip() { REPORT_SKIP=$((REPORT_SKIP + 1)); echo "SKIP  $1  -- $2"; }
report_summary() {
  echo "-- $REPORT_SUITE: PASS $REPORT_PASS / FAIL $REPORT_FAIL / SKIP $REPORT_SKIP"
  [[ "$REPORT_FAIL" -eq 0 ]]
}

# ---------- IP helpers ----------
mask_ip() {
  local ip="${1:-}"
  if [[ -z "$ip" ]]; then
    echo "<empty>"
  elif [[ "$ip" == *:* ]]; then
    echo "${ip%%:*}:x::"
  elif [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${ip%%.*}.x.x.x"
  else
    echo "<invalid>"
  fi
}

# 0 only when both are non-empty and different.
ips_differ() { [[ -n "${1:-}" && -n "${2:-}" && "$1" != "$2" ]]; }

# ---------- env ----------
# Parses KEY=VALUE like docker compose: skips comments/blank lines, strips
# surrounding quotes, strips " #comment" from unquoted values. Exports keys.
# Returns 1 if file missing, 2 if it contains CR characters.
load_env() {
  local file="$1" line key value
  [[ -f "$file" ]] || { echo "ERROR: env file not found: $file" >&2; return 1; }
  # grep on Git Bash/MSYS hides CR; count CR bytes portably instead.
  if [[ "$(tr -dc '\r' < "$file" | wc -c)" -gt 0 ]]; then
    echo "ERROR: $file has Windows (CRLF) line endings; convert to LF (e.g. dos2unix)" >&2
    return 2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    key="${key#export }"
    key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="${line#*=}"
    if [[ "$value" =~ ^\"(.*)\"[[:space:]]*$ || "$value" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value="${value%%[[:space:]]#*}"
      value="${value%"${value##*[![:space:]]}"}"
    fi
    export "$key=$value"
  done < "$file"
}

# stdin filter: replaces values of secret-looking variables with ***.
redact() {
  local -a secrets=()
  local name line s
  for name in $(compgen -v); do
    if [[ "$name" == WIREGUARD_PRIVATE_KEY || "$name" == *_PASSWORD || "$name" == *_KEY ]]; then
      [[ -n "${!name:-}" ]] && secrets+=("${!name}")
    fi
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    for s in "${secrets[@]+"${secrets[@]}"}"; do
      [[ ${#s} -ge 3 ]] && line="${line//"$s"/***}"
    done
    printf '%s\n' "$line"
  done
}

# ---------- docker ----------
dc() { docker compose --project-directory "$FVPN_ROOT" "$@"; }

# 0 when service reports healthy before timeout (seconds), 1 otherwise.
wait_healthy() {
  local service="$1" timeout="$2" waited=0 health
  while (( waited < timeout )); do
    health="$(dc ps --format '{{.Health}}' "$service" 2>/dev/null || true)"
    [[ "$health" == healthy ]] && return 0
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

# Runs pinned curl inside gluetun's network namespace. Returns curl's exit code
# (125 if gluetun is not running).
netns_probe() {
  local cid
  cid="$(dc ps -q gluetun 2>/dev/null || true)"
  [[ -n "$cid" ]] || { echo "gluetun not running" >&2; return 125; }
  docker run --rm -i --network "container:$cid" "$CURL_IMAGE" "$@"
}

api_url() { echo "http://127.0.0.1:${FIRECRAWL_PORT:-3002}"; }

# jq wrapper: local jq if installed, otherwise the pinned jq container image.
JQ_IMAGE="${JQ_IMAGE:-ghcr.io/jqlang/jq:1.7.1}"
jqr() {
  if command -v jq >/dev/null 2>&1; then
    jq "$@"
  else
    docker run --rm -i "$JQ_IMAGE" "$@"
  fi
}

# cap_bit_set <CapEff-hex> <bit>: 0 if set, 1 if clear, 2 if the value is not plain hex.
# The value comes from inside a container, so it is validated before arithmetic evaluation.
cap_bit_set() {
  local hex="${1:-}" bit="$2"
  [[ "$hex" =~ ^[0-9a-fA-F]{1,16}$ && "$bit" =~ ^[0-9]+$ ]] || return 2
  (( (16#$hex >> bit) & 1 ))
}
