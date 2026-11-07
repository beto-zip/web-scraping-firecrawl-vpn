#!/usr/bin/env bash
# Exit IP rotation by reconnecting the tunnel through gluetun's control server.
# Source after common.sh. Library: does not set shell options or traps.

# 1 while this process has the tunnel stopped (or not confirmed back up); callers' traps
# must then run: vpn_set_status running; vpn_wait_up
# shellcheck disable=SC2034  # read by callers (traps)
ROTATE_VPN_STOPPED=0

# rotate_ip <max_attempts>: 0 rotated, 1 IP unchanged after max_attempts, 2 control/tunnel error.
# Prints masked IPs only.
rotate_ip() {
  local max="$1" old new attempt start
  start=$SECONDS
  old="$(vpn_public_ip)"
  if [[ -z "$old" ]]; then
    echo "ERROR: no current VPN IP (stack up? GLUETUN_CONTROL_API_KEY?)" >&2
    return 2
  fi
  for (( attempt = 1; attempt <= max; attempt++ )); do
    # Mark before the request: an interruption mid-request may already have stopped it.
    ROTATE_VPN_STOPPED=1
    if ! vpn_set_status stopped || ! vpn_set_status running; then
      echo "ERROR: control server refused to change VPN status" >&2
      return 2
    fi
    if ! vpn_wait_up 180; then
      echo "ERROR: tunnel did not come back within 180s" >&2
      return 2
    fi
    ROTATE_VPN_STOPPED=0
    new="$(vpn_public_ip)"
    if ips_differ "$old" "$new"; then
      echo "rotated: $(mask_ip "$old") -> $(mask_ip "$new") (attempt $attempt, $((SECONDS - start))s)"
      return 0
    fi
    echo "attempt $attempt: IP unchanged ($(mask_ip "$new"))"
  done
  echo "ERROR: exit IP unchanged after $max attempts; widen SERVER_COUNTRIES/SERVER_CITIES" >&2
  return 1
}
