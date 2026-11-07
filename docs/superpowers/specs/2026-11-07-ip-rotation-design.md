# IP rotation primitive — design (sub-project 1 of anti-blocking)

## Context

Goal of the larger effort: scraping with Firecrawl that survives blocking. When a site blocks
the exit IP, rotate it and resume, never exposing the host IP, with nothing installed on the host
but Docker. Decomposed into:

1. **IP rotation primitive** (this spec)
2. Toolbox container: validate/tests/reports run in Docker, host needs only Docker
3. Anti-blocking layer: block detection (403/429/challenge), rotate + retry, challenge/CAPTCHA solving
4. In-stack URL queue with resume (future)

Sub-projects 3 and 4 call this primitive; it must be scriptable, safe to interrupt, and proven.

## Evidence it builds on

- Restarting the **gluetun container** destroys the shared network namespace: `api`/`playwright`
  stay without network until `docker compose restart api playwright` (test-recovery.sh).
- Reconnecting the **tunnel** via the control server (`PUT /v1/vpn/status` stopped -> running)
  keeps the container and namespace: test-killswitch.sh `scrape_recovers` passes without restarts.
- Gluetun picks a server at random among those matching `SERVER_COUNTRIES`/`SERVER_CITIES` on each
  connect, so a reconnect usually yields a different exit IP. Not guaranteed: same server is possible.

## Design

- **Mechanism:** tunnel reconnect through the control server, inside gluetun's namespace
  (`netns_probe`, no host port, no host curl). Container is never restarted.
- **`scripts/rotate-ip.sh [--max-attempts N]`** (N 1..10, default 3): reads current exit IP, cycles
  the tunnel, waits until it is up, compares. Retries while the IP is unchanged.
  Exit codes: `0` rotated, `1` IP unchanged after N attempts, `2` control/tunnel error,
  `3` another rotation in progress, `64` usage. Interrupted: restores the tunnel, exits 129/130/143.
  Output shows masked IPs only, plus duration and attempt number.
- **Lock:** directory `$FVPN_ROOT/.rotate.lock` (atomic `mkdir`), removed on exit. Stale lock after
  `kill -9` is removed by hand (documented).
- **Core logic in `scripts/lib/rotate.sh`** (`rotate_ip <max_attempts>`), sourced by the script,
  unit-tested by stubbing the VPN helpers.
- **Shared VPN helpers move to `scripts/lib/common.sh`:** `vpn_public_ip`, `vpn_set_status`,
  `vpn_wait_up` (hard total timeout; fixes the deferred ~40 min worst case), `host_public_ip`,
  `scrape_seen_ip`. test-vpn.sh and test-killswitch.sh use them.
- **Fail-closed is unchanged:** while the tunnel is down gluetun's firewall drops everything; an
  in-flight scrape fails or completes through the new tunnel, never via the host.

## Proof (`scripts/test-rotation.sh`, added to run-tests.sh)

| Check | Pass when |
|---|---|
| `ip_before_known` | control server reports an exit IP |
| `rotate_changes_ip` | rotate-ip.sh exits 0 and control server IP differs from before |
| `inflight_scrape_no_leak` | a scrape running during rotation failed, or saw an IP other than the host's (outcome recorded) |
| `scrape_sees_new_ip` | after rotation the target sees the new VPN IP, not the host IP |
| `api_not_restarted`, `playwright_not_restarted` | container `StartedAt` unchanged |

## Out of scope

Block detection, automatic retry, CAPTCHA, queue (sub-projects 3-4); moving host tooling into a
container (sub-project 2). rotate-ip.sh itself needs only bash + Docker; the test suite still uses
host curl like the existing suites.
