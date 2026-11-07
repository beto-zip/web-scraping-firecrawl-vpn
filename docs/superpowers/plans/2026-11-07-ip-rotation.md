# IP Rotation Primitive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A scriptable, interrupt-safe `scripts/rotate-ip.sh` that changes the Proton exit IP by reconnecting the tunnel through Gluetun's control server, plus a live suite proving it changes the IP, does not restart api/playwright and never leaks the host IP.

**Architecture:** Shared VPN helpers move from the test scripts into `scripts/lib/common.sh`. Rotation logic lives in `scripts/lib/rotate.sh` (`rotate_ip`), unit-tested by stubbing those helpers; `scripts/rotate-ip.sh` adds argument parsing, a lock and signal traps. `scripts/test-rotation.sh` proves behavior against the running stack.

**Tech Stack:** Bash, Docker Compose, Gluetun v3.41.3 control server, existing unit runner `tests/unit/run.sh`.

**Spec:** `docs/superpowers/specs/2026-11-07-ip-rotation-design.md`

## Global Constraints

- Work on branch `dev`. Never commit `.env` or keys. Never print secrets or unmasked IPs (use `mask_ip`).
- Control server is reached only inside gluetun's namespace: `netns_probe ... http://127.0.0.1:8000/...` with header `X-API-Key: ${GLUETUN_CONTROL_API_KEY}`. No new host ports, no compose changes.
- rotate-ip.sh needs only bash + Docker on the host (`netns_probe`, `jqr`); no host curl.
- New `scripts/*.sh` are stored as 100755 in git (`git update-index --chmod=+x`); `scripts/lib/*.sh` stay 100644.
- Exit codes of rotate-ip.sh: `0` rotated, `1` unchanged after N attempts, `2` control/tunnel error, `3` rotation in progress, `64` usage, `129/130/143` on HUP/INT/TERM.
- `--max-attempts N`: integer 1..10, default 3.
- Lock: directory `$FVPN_ROOT/.rotate.lock`, created with `mkdir`, git-ignored.
- Every commit ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01R4L2xn4aZvAA5Zx9nUhYHE
  ```
- Before each commit: `bash tests/unit/run.sh`, `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 scripts/*.sh scripts/lib/*.sh tests/unit/*.sh` clean.

## Review Focus

1. Ctrl-C / SSH drop while the tunnel is stopped → tunnel restored, lock removed, exit 130/129 (Task 3 live step).
2. Exit pool yields the same IP every time (e.g. one-server `SERVER_CITIES`) → stops after N attempts with rc 1 and a clear message, never loops forever (Task 2 unit test).
3. Wrong `GLUETUN_CONTROL_API_KEY` / control server refusing → rc 2 quickly, no hang (Task 2 unit test).
4. Scrape in flight during rotation → fails or uses the new tunnel, never the host IP (Task 4 `inflight_scrape_no_leak`).
5. Two rotations at once (future queue) → second exits 3 without touching the tunnel; stale lock message tells how to clear it (Task 3 unit test).

---

### Task 1: Shared VPN helpers in common.sh

**Files:**
- Modify: `scripts/lib/common.sh` (append section `# ---------- vpn ----------`)
- Modify: `scripts/test-killswitch.sh:12-31` (remove `CONTROL`, `vpn_set`, `vpn_wait_up`; call helpers)
- Modify: `scripts/test-vpn.sh:13-23,26` (remove `gluetun_public_ip`, `scraped_ip`, host curl line; call helpers)
- Test: `tests/unit/common.test.sh`

**Interfaces:**
- Produces (all in `common.sh`):
  - `CONTROL_URL="http://127.0.0.1:8000"`
  - `vpn_public_ip` → prints exit IP from `GET $CONTROL_URL/v1/publicip/ip` (`.public_ip`), empty on error; rc 0.
  - `vpn_set_status <stopped|running>` → `PUT $CONTROL_URL/v1/vpn/status`; rc 2 if arg not `stopped`/`running` (checked before any docker call); otherwise curl's rc (`-f` so HTTP 401 is non-zero).
  - `vpn_wait_up [timeout_s=180]` → rc 0 when `vpn_public_ip` non-empty and gluetun healthy; rc 1 when total elapsed (`SECONDS`-based deadline, including `wait_healthy`) exceeds timeout.
  - `host_public_ip` → host IP via `curl -s -m 10 https://api.ipify.org` (moved from test-vpn.sh).
  - `scrape_seen_ip <json_body>` → moved verbatim from test-vpn.sh `scraped_ip`; uses `$(api_url)`.

- [ ] **Step 1: Write failing unit test**

```bash
test_vpn_set_status_rejects_bad_value() {
  assert_rc 2 vpn_set_status paused
  assert_rc 2 vpn_set_status ""
}
```

- [ ] **Step 2: Run** `bash tests/unit/run.sh` — Expected: FAIL `test_vpn_set_status_rejects_bad_value` (command not found → rc 127).
- [ ] **Step 3: Add the helpers to common.sh** with the signatures above; `vpn_wait_up` computes `deadline=$((SECONDS + timeout))` and passes the remaining seconds to `wait_healthy`.
- [ ] **Step 4: Switch test-killswitch.sh and test-vpn.sh to the helpers** (`vpn_set` → `vpn_set_status`, `gluetun_public_ip` → `vpn_public_ip`, `scraped_ip` → `scrape_seen_ip`, inline host curl → `host_public_ip`). Behavior unchanged.
- [ ] **Step 5: Run** unit tests + shellcheck — Expected: all PASS, shellcheck clean.
- [ ] **Step 6: Live regression:** `./scripts/test-vpn.sh && ./scripts/test-killswitch.sh` — Expected: `vpn: PASS 8 / FAIL 0`, `killswitch: PASS 15 / FAIL 0`.
- [ ] **Step 7: Commit** `refactor: move VPN control helpers into common.sh`

### Task 2: rotate_ip core logic

**Files:**
- Create: `scripts/lib/rotate.sh` (100644, sourced)
- Test: `tests/unit/rotate.test.sh`

**Interfaces:**
- Consumes: `vpn_public_ip`, `vpn_set_status`, `vpn_wait_up`, `ips_differ`, `mask_ip` (Task 1).
- Produces: `rotate_ip <max_attempts>` → rc 0 rotated / 1 unchanged / 2 error. Sets global `ROTATE_VPN_STOPPED=1` immediately before `vpn_set_status stopped` and `0` after `vpn_wait_up` succeeds (callers' traps restore when 1). Prints to stdout:
  - success: `rotated: <masked old> -> <masked new> (attempt K, Ss)`
  - per unchanged attempt: `attempt K: IP unchanged (<masked>)`
  - rc 1: `ERROR: exit IP unchanged after N attempts; widen SERVER_COUNTRIES/SERVER_CITIES` (stderr)
  - rc 2: `ERROR: no current VPN IP (stack up? GLUETUN_CONTROL_API_KEY?)`, `ERROR: control server refused to change VPN status`, `ERROR: tunnel did not come back within 180s` (stderr)

- [ ] **Step 1: Write failing tests** in `tests/unit/rotate.test.sh`. Source `common.sh` then `rotate.sh`, then redefine stubs per test. Stubs read IPs from a queue file so each `vpn_public_ip` call returns the next line:

```bash
source "$ROOT/scripts/lib/common.sh"; source "$ROOT/scripts/lib/rotate.sh"
ips() { printf '%s\n' "$@" > "$TMP/ips"; }
vpn_public_ip() { head -n1 "$TMP/ips"; sed -i 1d "$TMP/ips"; }
vpn_set_status() { echo "$1" >> "$TMP/calls"; }
vpn_wait_up() { return 0; }

test_rotate_first_attempt()      { ips 1.1.1.1 2.2.2.2; assert_rc 0 rotate_ip 3; }
test_rotate_second_attempt()     { ips 1.1.1.1 1.1.1.1 2.2.2.2; assert_rc 0 rotate_ip 3; }
test_rotate_gives_up() {
  ips 1.1.1.1 1.1.1.1 1.1.1.1; assert_rc 1 rotate_ip 2
  assert_eq 4 "$(wc -l < "$TMP/calls" | tr -d ' ')" "stop+start per attempt"
}
test_rotate_no_initial_ip()      { ips ""; assert_rc 2 rotate_ip 3; [[ ! -s "$TMP/calls" ]] || fail_test "touched tunnel"; }
test_rotate_stop_refused()       { ips 1.1.1.1; vpn_set_status() { return 22; }; assert_rc 2 rotate_ip 3; }
test_rotate_tunnel_not_back()    { ips 1.1.1.1; vpn_wait_up() { return 1; }; assert_rc 2 rotate_ip 3; }
test_rotate_output_masked() {
  ips 189.40.12.7 45.1.2.3
  local out; out="$(rotate_ip 3 2>&1)"
  [[ "$out" == *"189.x.x.x -> 45.x.x.x"* && "$out" != *189.40* ]] || fail_test "unmasked: $out"
}
```

- [ ] **Step 2: Run** `bash tests/unit/run.sh` — Expected: the 7 new tests FAIL (`rotate.sh` missing).
- [ ] **Step 3: Implement `rotate_ip`** in `scripts/lib/rotate.sh`: read old IP (empty → rc 2 before touching tunnel); loop K=1..N: stop (fail → rc 2), start (fail → rc 2), `vpn_wait_up 180` (fail → rc 2), read new IP, `ips_differ` → print and rc 0. After loop rc 1. Duration from `SECONDS`.
- [ ] **Step 4: Run** unit tests + shellcheck — Expected: all PASS.
- [ ] **Step 5: Commit** `feat: add rotate_ip core logic`

### Task 3: scripts/rotate-ip.sh (CLI, lock, traps)

**Files:**
- Create: `scripts/rotate-ip.sh` (100755)
- Modify: `.gitignore` (add `.rotate.lock/` under `# Test reports` → rename section `# Runtime state`)
- Test: `tests/unit/rotate.test.sh` (append)

**Interfaces:**
- Consumes: `rotate_ip`, `ROTATE_VPN_STOPPED` (Task 2), `vpn_set_status`, `vpn_wait_up`, `load_env`.
- Produces: CLI `scripts/rotate-ip.sh [--max-attempts N] [-h|--help]` with the exit codes in Global Constraints. Order: parse args (before `load_env`, so usage errors need no `.env`) → acquire lock → `load_env "$FVPN_ROOT/.env"` → `rotate_ip`. Lock busy message: `ERROR: rotation in progress (lock $FVPN_ROOT/.rotate.lock); if no rotation is running, remove that directory` → rc 3. `FVPN_LOCK_DIR` env overrides the lock path (tests only).
- Traps (pattern from test-killswitch.sh): `trap '' PIPE`; EXIT → restore if `ROTATE_VPN_STOPPED=1` (`vpn_set_status running; vpn_wait_up 180`) then `rmdir` lock (only if this process created it); INT → 130, TERM → 143, HUP → 129.

- [ ] **Step 1: Append failing tests**

```bash
R="$ROOT/scripts/rotate-ip.sh"
test_rotate_cli_help()          { assert_rc 0 "$R" --help; }
test_rotate_cli_bad_flag()      { assert_rc 64 "$R" --bogus; }
test_rotate_cli_attempts_zero() { assert_rc 64 "$R" --max-attempts 0; }
test_rotate_cli_attempts_big()  { assert_rc 64 "$R" --max-attempts 11; }
test_rotate_cli_attempts_text() { assert_rc 64 "$R" --max-attempts x; }
test_rotate_cli_busy() {
  mkdir "$TMP/lock"
  export FVPN_LOCK_DIR="$TMP/lock"   # test runs in a subshell: export does not leak
  assert_rc 3 "$R"
  [[ -d "$TMP/lock" ]] || fail_test "removed someone else's lock"
}
```

- [ ] **Step 2: Run** unit tests — Expected: 6 new tests FAIL.
- [ ] **Step 3: Implement `scripts/rotate-ip.sh`**; `git add` then `git update-index --chmod=+x scripts/rotate-ip.sh`.
- [ ] **Step 4: Run** unit tests (includes `test_scripts_are_executable_in_git`) + shellcheck — Expected: all PASS.
- [ ] **Step 5: Live run:** `time ./scripts/rotate-ip.sh` — Expected: rc 0, `rotated: a.x.x.x -> b.x.x.x (attempt 1..3, Ns)`; `ls .rotate.lock` → not found.
- [ ] **Step 6: Live interrupt:** `./scripts/rotate-ip.sh & sleep 4; kill -INT $!; wait $!; echo rc=$?` — Expected: `rc=130`; then `./scripts/test-vpn.sh` → `PASS 8`; no `.rotate.lock`.
- [ ] **Step 7: Commit** `feat: add rotate-ip.sh to change the VPN exit IP`

### Task 4: Live suite test-rotation.sh

**Files:**
- Create: `scripts/test-rotation.sh` (100755)
- Modify: `scripts/run-tests.sh` (`suites=(... test-killswitch.sh test-rotation.sh)`; recovery stays last)

**Interfaces:**
- Consumes: `vpn_public_ip`, `host_public_ip`, `scrape_seen_ip`, `mask_ip`, `ips_differ`, `report_*`, `dc` (Task 1); `scripts/rotate-ip.sh` (Task 3).
- Env knob: `ROTATE_SCRIPT` (default `$FVPN_ROOT/scripts/rotate-ip.sh`) selects the rotation command.
- Produces: suite `rotation` with checks in this order: `ip_before_known`, `rotate_changes_ip`, `inflight_scrape_no_leak`, `scrape_sees_new_ip`, `api_not_restarted`, `playwright_not_restarted`.

- [ ] **Step 1: Implement the suite.** Before rotating: record `host_public_ip`, `vpn_public_ip`, and `docker inspect -f '{{.State.StartedAt}}' "$(dc ps -q <svc>)"` for `api` and `playwright`. Start `scrape_seen_ip '{"url":"https://api.ipify.org","formats":["markdown"],"maxAge":0}'` in background writing to a temp file (trap EXIT kills it and removes the file), `sleep 2`, then run `rotate-ip.sh`.
  - `rotate_changes_ip`: rc 0 and `ips_differ before after` (after from `vpn_public_ip`, independent of the script's output).
  - `inflight_scrape_no_leak`: wait for the background job; PASS if result empty (`failed`) or `ips_differ host result`; detail `outcome=failed|ok <masked>`; FAIL `LEAK` if result equals host IP; FAIL if host IP unknown (cannot verify).
  - `scrape_sees_new_ip`: new scrape result == after IP and differs from host.
  - `*_not_restarted`: StartedAt equal before/after.
- [ ] **Step 2: RED check:** temporarily run with `ROTATE_SCRIPT=/bin/true` (env override for the script path, default `$FVPN_ROOT/scripts/rotate-ip.sh`) — Expected: `rotate_changes_ip` FAIL. Revert nothing (override is a supported knob).
- [ ] **Step 3: GREEN:** `./scripts/test-rotation.sh` — Expected: `rotation: PASS 6 / FAIL 0`. Note the `inflight_scrape_no_leak` outcome and rotation duration for sub-project 3.
- [ ] **Step 4: Full run:** `./scripts/run-tests.sh` — Expected: `RESULT: ALL PASS`; `grep -cE '([0-9]{1,3}\.){3}[0-9]{1,3}' reports/<latest>` shows no unmasked host/VPN IP.
- [ ] **Step 5: Commit** `test: prove IP rotation changes exit IP without leaks or restarts`

### Task 5: Docs

**Files:**
- Modify: `docs/protonvpn.md` (new section `## Rotate the exit IP` after "Check the current exit IP": command, exit codes, retries, same-IP case, stale lock)
- Modify: `docs/architecture.md` (limitation/ADR note: tunnel reconnect keeps the namespace; container restart does not)
- Modify: `README.md`, `README.pt-BR.md` (Features bullet; Tests table rows for `rotate-ip.sh` and `test-rotation.sh`)
- Modify: `docs/troubleshooting.md` (`rotation in progress` / rc 1 entries)

- [ ] **Step 1: Write the docs** using the exit codes and messages from Tasks 2-3 verbatim.
- [ ] **Step 2: Verify** links resolve: `grep -o '](docs/[^)#]*' README*.md | sort -u` → each path exists; `yamllint`/unit/shellcheck still clean.
- [ ] **Step 3: Commit** `docs: document exit IP rotation`
