#!/usr/bin/env bash
# Changes the VPN exit IP by reconnecting the tunnel (gluetun stays up, api/playwright are not restarted).
# Usage: scripts/rotate-ip.sh [--max-attempts N]   (stack must be running; reads .env)
#   --max-attempts N  reconnects to try while the IP stays the same (1-10, default 3)
# Exit: 0 rotated, 1 IP unchanged, 2 control/tunnel error, 3 rotation in progress, 64 usage,
#       129/130/143 interrupted (tunnel restored first).
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/rotate.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rotate.sh"

usage() { sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MAX_ATTEMPTS=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-attempts)
      if ! [[ "${2:-}" =~ ^[0-9]{1,2}$ ]] || (( 10#$2 < 1 || 10#$2 > 10 )); then
        echo "ERROR: --max-attempts needs an integer 1-10" >&2
        exit 64
      fi
      MAX_ATTEMPTS=$((10#$2))
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

LOCK_DIR="${FVPN_LOCK_DIR:-$FVPN_ROOT/.rotate.lock}"
LOCK_OWNED=0

# shellcheck disable=SC2317  # invoked via traps
cleanup() {
  if [[ "$ROTATE_VPN_STOPPED" -eq 1 ]]; then
    echo "-- restoring VPN" 2>/dev/null || true
    vpn_set_status running || true
    vpn_wait_up 180 || { echo "WARN  VPN did not come back; run: docker compose restart gluetun" >&2; } 2>/dev/null || true
    ROTATE_VPN_STOPPED=0
  fi
  # Cleanup runs twice on signals (trap, then EXIT): never remove a lock taken meanwhile by another run.
  if [[ "$LOCK_OWNED" -eq 1 ]] && rmdir "$LOCK_DIR" 2>/dev/null; then LOCK_OWNED=0; fi
}
# Output may go to a closed pipe: never let a failed write skip the restore.
trap '' PIPE
trap cleanup EXIT
trap 'cleanup; reraise INT' INT
trap 'cleanup; reraise TERM' TERM
trap 'cleanup; reraise HUP' HUP

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "ERROR: rotation in progress (lock $LOCK_DIR); if no rotation is running, remove that directory" >&2
  exit 3
fi
LOCK_OWNED=1

load_env "$FVPN_ROOT/.env" || exit 2

rc=0
rotate_ip "$MAX_ATTEMPTS" || rc=$?
exit "$rc"
