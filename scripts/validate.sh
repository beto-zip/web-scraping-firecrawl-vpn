#!/usr/bin/env bash
# Validates .env before deploy. Never prints secret values.
# Usage: scripts/validate.sh [--env FILE] [--allow-public-bind] [--skip-compose]
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ENV_FILE="$FVPN_ROOT/.env"
ALLOW_PUBLIC_BIND=0
SKIP_COMPOSE=0
REQUIRED_SECRETS=(POSTGRES_PASSWORD REDIS_PASSWORD RABBITMQ_PASSWORD GLUETUN_CONTROL_API_KEY)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILE="$2"; shift 2 ;;
    --allow-public-bind) ALLOW_PUBLIC_BIND=1; shift ;;
    --skip-compose) SKIP_COMPOSE=1; shift ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

report_init "validate ($(basename "$ENV_FILE"))"

if ! load_env "$ENV_FILE"; then
  fail env_file_readable "missing file or CRLF line endings (see message above)"
  report_summary || exit 1
fi
pass env_file_readable

# WireGuard key: base64 of exactly 32 bytes.
key="${WIREGUARD_PRIVATE_KEY:-}"
if [[ -z "$key" ]]; then
  fail wireguard_key "WIREGUARD_PRIVATE_KEY is empty (see docs/protonvpn.md)"
elif [[ ! "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || [[ "$(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c)" -ne 32 ]]; then
  fail wireguard_key "WIREGUARD_PRIVATE_KEY is not a base64-encoded 32-byte key"
else
  pass wireguard_key
fi

for name in "${REQUIRED_SECRETS[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    fail "secret_$name" "$name is empty"
  elif [[ ! "${!name}" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    fail "secret_$name" "$name must use only URL-safe characters [A-Za-z0-9._~-] (it is embedded in connection URLs)"
  else
    pass "secret_$name"
  fi
done

bind="${API_BIND_ADDRESS:-127.0.0.1}"
if [[ "$bind" == 127.0.0.1 || "$bind" == ::1 ]]; then
  pass api_bind_loopback
elif [[ "$ALLOW_PUBLIC_BIND" -eq 1 ]]; then
  pass api_bind_loopback "non-loopback $bind allowed by --allow-public-bind"
else
  fail api_bind_loopback "API_BIND_ADDRESS=$bind exposes the unauthenticated API; use --allow-public-bind to confirm"
fi

port="${FIRECRAWL_PORT:-3002}"
if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
  pass firecrawl_port
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo "WARN  port $port already in use on 127.0.0.1 (fine if this stack is already running)"
  fi
else
  fail firecrawl_port "FIRECRAWL_PORT=$port is not a valid port"
fi

if [[ "$(uname -s)" == Linux ]]; then
  if [[ -c /dev/net/tun ]]; then pass dev_net_tun; else
    echo "WARN  /dev/net/tun not found on host; Gluetun needs it (see docs/installation.md)"
  fi
fi

if [[ "$SKIP_COMPOSE" -eq 0 ]]; then
  if dc --env-file "$ENV_FILE" config -q >/dev/null 2>&1; then
    pass compose_config
  else
    fail compose_config "docker compose config failed; run: docker compose --env-file $ENV_FILE config"
  fi
fi

report_summary
