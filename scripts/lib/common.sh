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

# ---------- vpn (gluetun control server, reached inside gluetun's namespace) ----------
CONTROL_URL="http://127.0.0.1:8000"

# Prints the tunnel's public IP, empty when unknown.
vpn_public_ip() {
  netns_probe -s -m 10 -H "X-API-Key: ${GLUETUN_CONTROL_API_KEY:-}" "$CONTROL_URL/v1/publicip/ip" </dev/null 2>/dev/null \
    | jqr -r '.public_ip // empty' 2>/dev/null || true
}

# vpn_set_status stopped|running. Returns 2 on a bad value, otherwise curl's code (-f: HTTP errors fail).
vpn_set_status() {
  [[ "${1:-}" == stopped || "${1:-}" == running ]] || return 2
  netns_probe -sf -m 15 -X PUT -H "X-API-Key: ${GLUETUN_CONTROL_API_KEY:-}" -H 'Content-Type: application/json' \
    -d "{\"status\":\"$1\"}" "$CONTROL_URL/v1/vpn/status" </dev/null >/dev/null 2>&1
}

# Waits until the tunnel reports a public IP and gluetun is healthy. Hard total limit (default 180s).
vpn_wait_up() {
  local timeout="${1:-180}" deadline left
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if [[ -n "$(vpn_public_ip)" ]]; then
      left=$((deadline - SECONDS))
      (( left > 0 )) && wait_healthy gluetun "$left" && return 0
      return 1
    fi
    sleep 5
  done
  return 1
}

# Host's own public IP (outside the tunnel), empty when unknown.
host_public_ip() { curl -s -m 10 https://api.ipify.org 2>/dev/null || true; }

# IP that a scraped target sees: Firecrawl scrapes an IP echo page; body comes back as markdown.
scrape_seen_ip() {
  curl -s -m 120 -X POST "$(api_url)/v2/scrape" -H 'Content-Type: application/json' -d "$1" 2>/dev/null \
    | jqr -r 'if .success == true then (.data.markdown // "" | gsub("\\s"; "")) else empty end' 2>/dev/null || true
}
