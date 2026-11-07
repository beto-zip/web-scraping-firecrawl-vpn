# web-scraping-firecrawl-vpn Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Docker Compose distribution of self-hosted Firecrawl v2.11.0 whose only internet egress is a Proton VPN WireGuard tunnel managed by Gluetun, with shell test scripts that prove fail-closed behavior.

**Architecture:** `api` and `playwright` run with `network_mode: service:gluetun` (shared netns, B1), so every outbound connection passes Gluetun's firewall (only `wg0` + backend subnet allowed). `redis`, `rabbitmq`, `nuq-postgres` live on an `internal: true` network. Bash scripts validate config and produce a masked PASS/FAIL report.

**Tech Stack:** Docker Compose v2, Gluetun v3.41.3, Firecrawl v2.11.0 images (pinned by digest), Redis, RabbitMQ, Bash + curl + jq, GitHub Actions (shellcheck, gitleaks, yamllint).

**Spec:** `docs/superpowers/specs/2026-11-06-web-scraping-firecrawl-vpn-design.md`

## Global Constraints

- Gluetun image: `qmcgaw/gluetun:v3.41.3`. Firecrawl images: v2.11.0, pinned by `@sha256:` digest (fallback: remote `build:` from `https://github.com/firecrawl/firecrawl.git#v2.11.0:apps/<app>`). Redis/RabbitMQ: exact version tags, never `latest`.
- Probe image for tests: `curlimages/curl` with an exact version tag, run as `docker run --rm --network container:<gluetun-container-id> ...`.
- Never `network_mode: host`. Never publish database/queue ports. API published only on the `gluetun` service as `${API_BIND_ADDRESS:-127.0.0.1}:${FIRECRAWL_PORT:-3002}:3002`.
- Only real, consumed env vars (see spec §4). No `VPN_ENABLED`, `VPN_REQUIRED`, `PROXY_*`, `*_MODE`.
- Secrets never printed by any script or test; IPs in reports masked (`189.x.x.x`).
- Scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, shellcheck-clean, LF line endings, runtime deps limited to `docker`, `curl`, `jq`, coreutils.
- Default `SERVER_COUNTRIES=Netherlands`. Project/compose name: `web-scraping-firecrawl-vpn`.
- README states: community project, **not official**, no affiliation with Firecrawl or Proton.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Local runs require Docker Desktop (WSL2) running and a real Proton WireGuard key in `.env` (user-provided, never committed).

## Review Focus

1. **`.env` edited on Windows (CRLF, quotes, trailing spaces)** — a key like `abc=\r` must be rejected by `validate.sh` with a clear message, not silently passed to Gluetun. → Task 2 test `crlf_env_rejected`, `quoted_key_accepted_or_rejected_consistently`.
2. **IP lookup returns empty/error during tests** — empty host IP or empty VPN IP must yield FAIL, never PASS by "different strings". → Task 1 test `ips_differ_requires_both_nonempty`, used by Task 4.
3. **Invalid `SERVER_COUNTRIES` / wrong key** — Gluetun never healthy; `api` must not start and `run-tests.sh` must report FAIL with a hint, not hang forever. → Task 3 step: `wait_healthy` timeout test.
4. **Port 3002 already used on host** — `validate.sh` warns before `compose up`. → Task 2 test `port_in_use_warns`.
5. **Kill-switch test leaves tunnel stopped if it crashes midway** — `test-killswitch.sh` must restart the VPN in a `trap ... EXIT`. → Task 5 step.

---

## File Map

| File | Responsibility | Task |
|---|---|---|
| `docs/spike-notes.md` | Answers to spike questions (kept, feeds architecture.md) | 0 |
| `.gitattributes` | Force LF on `*.sh`, `*.yaml`, `.env*` | 1 |
| `scripts/lib/common.sh` | Shared helpers: report, masking, env loading, health wait, probe | 1 |
| `tests/unit/run.sh`, `tests/unit/common.test.sh` | Minimal bash test runner + helper tests (no network) | 1 |
| `scripts/validate.sh`, `tests/unit/validate.test.sh`, `tests/fixtures/*.env` | Config validation | 2 |
| `compose.yaml`, `.env.example` | The stack | 3 |
| `scripts/test-firecrawl.sh` | Functional scrape/crawl | 3 |
| `scripts/test-vpn.sh` | Egress = VPN, DNS, IPv6 | 4 |
| `scripts/test-killswitch.sh` | Fail-closed + private destinations | 5 |
| `scripts/test-recovery.sh`, `scripts/run-tests.sh` | Restart/persistence + aggregated report | 6 |
| `examples/client/` | Simulated consumer on `edge` network | 7 |
| `README.md`, `README.pt-BR.md`, `LICENSE`, `docs/*.md` | Docs, ADRs | 8 |
| `.github/workflows/validate.yml` | CI | 9 |

---

### Task 0: Spike (throwaway code, kept notes)

**Files:**
- Create: `docs/spike-notes.md`
- Scratch (not committed): `spike/compose.yaml`, `spike/.env`

**Interfaces:**
- Produces: `docs/spike-notes.md` with one section per question below, each stating the answer, the evidence (command + trimmed output, secrets/IPs masked) and the resulting decision. Tasks 3–6 read it.

Prerequisites: Docker Desktop running; user puts real `WIREGUARD_PRIVATE_KEY` in `spike/.env` (add `spike/` to `.gitignore` first).

- [ ] **Step 1:** Add `spike/` to `.gitignore`; copy upstream v2.11.0 `docker-compose.yaml` services into `spike/compose.yaml`, add `gluetun` (Proton/WireGuard/Netherlands), switch `api` + `playwright-service` to `network_mode: service:gluetun`, `backend` network `internal: true`.
- [ ] **Step 2: Q1 DNS** — inside netns (`docker run --rm --network container:<gluetun> curlimages/curl ... ` or `nslookup` via busybox) resolve `redis`, `rabbitmq`, `nuq-postgres`. Decision: service names OR fixed IPs via `ipam` on `backend` (record subnet chosen, e.g. `172.30.0.0/24`).
- [ ] **Step 3: Q2 inbound** — with port published on gluetun, `curl http://127.0.0.1:3002/` from host. Record whether `FIREWALL_INPUT_PORTS=3002` is needed. Same from a container on `edge` network.
- [ ] **Step 4: Q3 images** — `docker buildx imagetools inspect ghcr.io/firecrawl/firecrawl:<tag>` for `v2.11.0`-style tags on `firecrawl`, `playwright-service`, `nuq-postgres`. Record exact digests or decide remote build.
- [ ] **Step 5: Q4 internal credentials** — confirm how Firecrawl takes Redis password (`REDIS_URL=redis://:pass@host:6379`), RabbitMQ creds (`NUQ_RABBITMQ_URL=amqp://user:pass@host:5672` + `RABBITMQ_DEFAULT_USER/PASS`), Postgres (`POSTGRES_PASSWORD` used by api and nuq-postgres). Record final variable names.
- [ ] **Step 6: Q5 control server** — confirm Gluetun v3.41.3 control server auth config (API key mechanism) and endpoints for public IP (`GET /v1/publicip/ip`) and VPN stop/start (`PUT /v1/vpn/status`). Record exact env vars and endpoints.
- [ ] **Step 7: Q6 engines** — determine how to force `fetch` vs `playwright` engine via `/v2/scrape` in self-host (e.g. `waitFor` forces browser) and how to verify which engine ran (api logs). Record request bodies.
- [ ] **Step 8: Q7 healthchecks** — which binaries exist in each image (`curl`, `wget`, `node`, `redis-cli`, `pg_isready`, `rabbitmq-diagnostics`); record healthcheck command per service and port conflicts in shared netns (3000/3002/3004/3005/8000).
- [ ] **Step 9:** Write `docs/spike-notes.md`; `docker compose -f spike/compose.yaml down -v`; commit notes only.

```bash
git add .gitignore docs/spike-notes.md
git commit -m "docs: record spike findings for netns, images and control server"
```

**Gate:** show spike-notes summary to user before Task 3.

---

### Task 1: Shared helpers + unit test runner

**Files:**
- Create: `.gitattributes`, `scripts/lib/common.sh`, `tests/unit/run.sh`, `tests/unit/common.test.sh`

**Interfaces:**
- Produces (sourced by all scripts):
  - `report_init <suite-name>`; `pass <check> [detail]`; `fail <check> <reason>`; `skip <check> <reason>`; `report_summary` → prints `PASS n / FAIL n / SKIP n`, returns 1 if any FAIL.
  - `mask_ip <ip>` → IPv4 `a.x.x.x`; IPv6 `first-hextet:x::`; empty → `<empty>`.
  - `ips_differ <a> <b>` → 0 only if both non-empty and different.
  - `load_env <path>` → exports vars; rejects CR characters (returns 2 with message naming the file).
  - `redact` → stdin filter replacing values of `WIREGUARD_PRIVATE_KEY`, `*_PASSWORD`, `*_KEY` (from loaded env) with `***`.
  - `wait_healthy <service> <timeout-seconds>` → 0 healthy, 1 timeout (uses `docker compose ps --format json`).
  - `netns_probe <args...>` → runs pinned `curlimages/curl` in gluetun's netns, returns curl's exit code.
  - `api_url` → `http://127.0.0.1:${FIRECRAWL_PORT:-3002}`.
- `tests/unit/run.sh` runs every `tests/unit/*.test.sh`; a test file defines `test_*` functions; helpers `assert_eq <expected> <actual> <msg>`, `assert_rc <expected-rc> <cmd...>`, `fail_test <msg>`, `skip_test <msg>`; exports `$TMP` (fresh temp dir per test), `$V` (`scripts/validate.sh`), `$F` (`tests/fixtures`).

- [ ] **Step 1:** `.gitattributes`: `*.sh text eol=lf`, `*.yaml text eol=lf`, `*.yml text eol=lf`, `.env* text eol=lf`.
- [ ] **Step 2: Write failing tests** in `tests/unit/common.test.sh`:

```bash
test_mask_ipv4()        { assert_eq "189.x.x.x" "$(mask_ip 189.40.12.7)" ipv4; }
test_mask_ipv6()        { assert_eq "2804:x::" "$(mask_ip 2804:14c:1:2::5)" ipv6; }
test_mask_empty()       { assert_eq "<empty>" "$(mask_ip '')" empty; }
test_ips_differ_requires_both_nonempty() {
  assert_rc 1 ips_differ "" "1.2.3.4"
  assert_rc 1 ips_differ "1.2.3.4" ""
  assert_rc 1 ips_differ "1.2.3.4" "1.2.3.4"
  assert_rc 0 ips_differ "1.2.3.4" "5.6.7.8"
}
test_load_env_rejects_crlf() { printf 'A=1\r\n' > "$TMP/crlf.env"; assert_rc 2 load_env "$TMP/crlf.env"; }
test_redact_hides_secrets() {
  WIREGUARD_PRIVATE_KEY=s3cr3tKEY REDIS_PASSWORD=pw1
  assert_eq "k=*** p=***" "$(echo 'k=s3cr3tKEY p=pw1' | redact)" redact
}
test_summary_fails_on_any_fail() { report_init t; pass a; fail b x; assert_rc 1 report_summary; }
```

- [ ] **Step 3:** Run `bash tests/unit/run.sh` → FAIL (`common.sh` missing).
- [ ] **Step 4:** Implement `tests/unit/run.sh` and `scripts/lib/common.sh` per Interfaces.
- [ ] **Step 5:** Run `bash tests/unit/run.sh` → all PASS. Run `shellcheck scripts/lib/common.sh tests/unit/*.sh` (via `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable` if not installed) → no findings.
- [ ] **Step 6: Commit** — `git commit -m "feat: add shared script helpers and unit test runner"`

---

### Task 2: `validate.sh`

**Files:**
- Create: `scripts/validate.sh`, `tests/unit/validate.test.sh`, `tests/fixtures/valid.env`, `tests/fixtures/*.env` (one per failure)

**Interfaces:**
- Consumes: `load_env`, `report_*` from Task 1.
- Produces: `scripts/validate.sh [--env FILE] [--allow-public-bind] [--skip-compose]` → exit 0 valid, 1 invalid. Prints one line per check; never prints secret values. `--skip-compose` used by unit tests and CI before compose exists.

Checks (spec §4.1): key non-empty and base64 decoding to exactly 32 bytes; `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_PASSWORD`, `GLUETUN_CONTROL_API_KEY` non-empty (final names from spike Q4/Q5); `API_BIND_ADDRESS` is `127.0.0.1`/`::1` unless `--allow-public-bind`; `FIRECRAWL_PORT` numeric 1–65535; port free on host (warning only); `/dev/net/tun` missing → warning; `docker compose config -q` succeeds unless `--skip-compose`; file without CR.

- [ ] **Step 1: Write failing tests** (fixture key for valid: `$(head -c32 /dev/zero | base64)` = `AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`):

```bash
test_valid_env_passes()        { assert_rc 0 "$V" --env "$F/valid.env" --skip-compose; }
test_empty_key_rejected()      { assert_rc 1 "$V" --env "$F/empty-key.env" --skip-compose; }
test_short_key_rejected()      { assert_rc 1 "$V" --env "$F/short-key.env" --skip-compose; }   # 16 bytes
test_crlf_env_rejected()       { assert_rc 1 "$V" --env "$F/crlf.env" --skip-compose; }
test_empty_password_rejected() { assert_rc 1 "$V" --env "$F/empty-redis-pw.env" --skip-compose; }
test_public_bind_rejected()    { assert_rc 1 "$V" --env "$F/public-bind.env" --skip-compose; }
test_public_bind_allowed_flag(){ assert_rc 0 "$V" --env "$F/public-bind.env" --skip-compose --allow-public-bind; }
test_secret_never_printed()    { out=$("$V" --env "$F/valid.env" --skip-compose 2>&1); [[ "$out" != *AAAAAAAAAAAA* ]] || fail_test "key leaked"; }
test_port_in_use_warns()       { # needs python3; skip_test if absent
  python3 -m http.server 38123 --bind 127.0.0.1 >/dev/null 2>&1 & pid=$!; sleep 1
  out=$("$V" --env "$F/port-38123.env" --skip-compose 2>&1); rc=$?; kill "$pid"
  assert_eq 0 "$rc" "warning only"; [[ "$out" == *WARN*38123* ]] || fail_test "no port warning"; }
test_quoted_key_consistent()   { assert_rc 0 "$V" --env "$F/quoted-key.env" --skip-compose; }  # KEY="..." stripped of quotes, same as docker compose
```

- [ ] **Step 2:** `bash tests/unit/run.sh` → validate tests FAIL.
- [ ] **Step 3:** Implement `scripts/validate.sh` (quote-stripping must mirror docker compose `.env` parsing: surrounding single/double quotes removed).
- [ ] **Step 4:** `bash tests/unit/run.sh` → PASS; shellcheck clean.
- [ ] **Step 5: Commit** — `git commit -m "feat: add .env validation script"`

---

### Task 3: Stack (`compose.yaml`, `.env.example`) + functional test

**Files:**
- Create: `compose.yaml`, `.env.example`, `scripts/test-firecrawl.sh`

**Interfaces:**
- Consumes: `docs/spike-notes.md` (DNS mode, subnet, digests, credential var names, healthchecks, engine-forcing bodies); Task 1 helpers; `validate.sh`.
- Produces: compose services `gluetun`, `api`, `playwright`, `redis`, `rabbitmq`, `nuq-postgres`; networks `backend` (internal, fixed subnet from spike) and `edge` (name `${EDGE_NETWORK_NAME:-firecrawl-edge}`); `scripts/test-firecrawl.sh` → exit 0/1, uses `report_*`.

Compose requirements (spec §3.3): `name: web-scraping-firecrawl-vpn`; gluetun `cap_add: [NET_ADMIN]`, `devices: [/dev/net/tun:/dev/net/tun]`, `VPN_SERVICE_PROVIDER=protonvpn`, `VPN_TYPE=wireguard`, `FIREWALL_OUTBOUND_SUBNETS=<backend subnet>`, HTTP proxy and Shadowsocks off, control server auth from spike; `api`/`playwright` `network_mode: service:gluetun` + `depends_on: {gluetun: {condition: service_healthy, restart: true}}`; `PLAYWRIGHT_MICROSERVICE_URL=http://localhost:3000/scrape`; no `PROXY_SERVER`; `restart: unless-stopped`; healthchecks on all six; logging `json-file` `max-size: 10m`, `max-file: "3"`; resource limits via `${API_CPUS:-4}`, `${API_MEMORY:-8G}`, `${PLAYWRIGHT_CPUS:-2}`, `${PLAYWRIGHT_MEMORY:-4G}`; named volumes for postgres, redis, rabbitmq, gluetun.

- [ ] **Step 1: Write `scripts/test-firecrawl.sh`** with checks:
  - `api_reachable` — `curl -sf $(api_url)/` within 10 s.
  - `scrape_fetch` — POST `/v2/scrape` `{"url":"https://example.com","formats":["markdown"]}` → `.success==true` and `.data.markdown` contains `Example Domain`.
  - `scrape_playwright` — same with the browser-forcing body from spike Q6.
  - `crawl_small` — POST `/v2/crawl` `{"url":"https://example.com","limit":2}` → poll `/v2/crawl/{id}` until `completed` (timeout 120 s) and `.data | length >= 1`.
- [ ] **Step 2:** Run `bash scripts/test-firecrawl.sh` → FAIL `api_reachable` (no stack).
- [ ] **Step 3:** Write `.env.example` (spec §4 + final names from spike + resource vars, each commented, empty secrets) and `compose.yaml`.
- [ ] **Step 4:** `cp .env.example .env`, user fills key/passwords; `bash scripts/validate.sh` → exit 0.
- [ ] **Step 5:** Review Focus 3 — set `SERVER_COUNTRIES=Atlantis` in a temp env, `docker compose --env-file <tmp> up -d`; `wait_healthy gluetun 90` returns 1 and `docker compose ps api` shows not running. Record in spike-notes. `docker compose down`.
- [ ] **Step 6:** `docker compose up -d`; `wait_healthy api 300`; `bash scripts/test-firecrawl.sh` → all PASS. Save masked output.
- [ ] **Step 7: Commit** — `git commit -m "feat: add compose stack with gluetun netns and functional test"`

---

### Task 4: `test-vpn.sh`

**Files:** Create `scripts/test-vpn.sh`

**Interfaces:**
- Consumes: `ips_differ`, `mask_ip`, `netns_probe`, `api_url`, control server endpoint/auth from spike.
- Produces: `scripts/test-vpn.sh` → exit 0/1.

Checks:
- `host_ip_known` — host IP via `curl -sf https://api.ipify.org` from host (non-empty, else FAIL).
- `gluetun_ip_known` — control server `GET /v1/publicip/ip` via `netns_probe` (non-empty).
- `egress_not_host` — `ips_differ host gluetun`.
- `scrape_sees_vpn_ip` — Firecrawl scrape of `https://api.ipify.org` (fetch body) → markdown IP == gluetun IP.
- `playwright_sees_vpn_ip` — same with browser-forcing body.
- `dns_via_gluetun` — `/etc/resolv.conf` in `api` container lists only `127.0.0.1` (or gluetun DNS address from spike).
- `ipv6_no_leak` — `netns_probe -6 -sf --max-time 10 https://api6.ipify.org` fails OR returns an address ≠ host IPv6 (host IPv6 lookup may be empty → then probe must fail).
- Output only masked IPs.

- [ ] **Step 1:** Write script; run with stack **down** → FAIL on `gluetun_ip_known` (proves checks don't false-pass).
- [ ] **Step 2:** Stack up → `bash scripts/test-vpn.sh` → all PASS. Save masked output.
- [ ] **Step 3:** shellcheck clean. **Commit** — `git commit -m "test: add VPN egress and DNS leak checks"`

---

### Task 5: `test-killswitch.sh`

**Files:** Create `scripts/test-killswitch.sh`

**Interfaces:**
- Consumes: `netns_probe`, control server stop/start endpoint, `wait_healthy`, `api_url`.
- Produces: `scripts/test-killswitch.sh` → exit 0/1. Always leaves VPN running (`trap vpn_start EXIT`).

Checks:
- `private_host_gateway_blocked` — `netns_probe --max-time 5` to host gateway IP of `edge` network (from `docker network inspect`) port 80 → non-zero.
- `metadata_blocked` — `netns_probe --max-time 5 http://169.254.169.254/` → non-zero.
- `tailscale_range_blocked` — `netns_probe --max-time 5 http://100.100.100.100/` → non-zero.
- `backend_reachable` — redis port reachable from netns (`netns_probe telnet://<redis>:6379` returns connect success) — proves internal comms intact.
- Stop VPN → `direct_egress_blocked`: `netns_probe --max-time 10 https://1.1.1.1` non-zero; `direct_ip_egress_blocked`: `netns_probe --max-time 10 http://8.8.8.8/` non-zero (raw IP, no DNS involved); `scrape_fails_when_down`: `/v2/scrape` example.com → `.success != true` or HTTP error, within 90 s.
- Start VPN → `wait_healthy gluetun 120` → `scrape_recovers`: example.com scrape succeeds.

- [ ] **Step 1:** Write script with `trap` first; run with stack down → FAIL quickly (no hang).
- [ ] **Step 2:** Stack up → run → all PASS. Kill script mid-run (Ctrl-C after "VPN stopped") → confirm `trap` restarted VPN (`test-vpn.sh` passes afterwards). Save masked output.
- [ ] **Step 3:** shellcheck clean. **Commit** — `git commit -m "test: add kill switch and private destination checks"`

---

### Task 6: `test-recovery.sh` + `run-tests.sh`

**Files:** Create `scripts/test-recovery.sh`, `scripts/run-tests.sh`

**Interfaces:**
- Consumes: all previous scripts and helpers.
- Produces: `scripts/run-tests.sh [--skip-recovery]` → runs `validate.sh`, `test-firecrawl.sh`, `test-vpn.sh`, `test-killswitch.sh`, `test-recovery.sh`; writes `reports/report-<UTC timestamp>.txt` (all output passed through `redact`); exit 1 if any FAIL. Add `reports/` to `.gitignore`.

`test-recovery.sh` checks:
- `gluetun_restart_breaks_netns` — `docker restart <gluetun>`; documents expected: api scrape fails (records behavior, PASS if fail-closed i.e. no success via host IP).
- `compose_up_recovers` — `docker compose up -d` → `wait_healthy api 300` → scrape succeeds (limitation (b)).
- `persistence` — write marker key into redis (`SET fvpn:marker <ts>`), `docker compose down` (no `-v`), `up -d`, marker still present.

- [ ] **Step 1:** Write both scripts; `run-tests.sh` with stack down → exit 1, report file created, contains no value of any secret (grep check in step).
- [ ] **Step 2:** Stack up → `bash scripts/run-tests.sh` → exit 0; `grep -c` of key/password values in report = 0.
- [ ] **Step 3:** shellcheck clean. **Commit** — `git commit -m "test: add recovery checks and aggregated masked report"`

---

### Task 7: Simulated client

**Files:** Create `examples/client/compose.yaml`, `examples/client/scrape.sh`, `examples/client/README.md`

**Interfaces:**
- Consumes: external network `${EDGE_NETWORK_NAME:-firecrawl-edge}`; API at `http://gluetun:3002`.
- Produces: `docker compose -f examples/client/compose.yaml run --rm client <url>` → prints scrape markdown; exit non-zero on failure.

- [ ] **Step 1:** With main stack up, run client against `https://example.com` → expect FAIL before files exist.
- [ ] **Step 2:** Implement (pinned `curlimages/curl` image + `jq`-free shell, or pinned alpine with curl/jq).
- [ ] **Step 3:** Run → markdown containing `Example Domain`. From a container **not** on `edge`, `http://gluetun:3002` must not resolve.
- [ ] **Step 4: Commit** — `git commit -m "feat: add simulated API client example"`

---

### Task 8: Documentation + license

**Files:** Create `README.md`, `README.pt-BR.md`, `LICENSE` (MIT, holder from git user), `docs/architecture.md`, `docs/installation.md`, `docs/protonvpn.md`, `docs/security.md`, `docs/troubleshooting.md`

Content requirements:
- `architecture.md`: diagram from spec §3.1; ADRs: B1 vs A (proxy, with code evidence achados 2–3), B2, WireProxy, LinuxServer WireGuard; spike results; known limitations (spec §9) incl. Gluetun restart (a)+(b) and the command `docker compose restart api playwright`.
- `installation.md`: the flow `git clone` → `cp .env.example .env` → edit → `./scripts/validate.sh` → `docker compose up -d` → `./scripts/run-tests.sh`; `/dev/net/tun`; Docker Desktop notes; updating digests.
- `protonvpn.md`: generating WireGuard key (link `https://account.proton.me/u/0/vpn/WireGuard`), key works for all servers, country/city selection, responsible use / ToS.
- `security.md`: threat model, what fail-closed covers, SSRF coverage and residual (`backend` reachable, mitigated by passwords), API unauthenticated → loopback/edge only, `BULL_AUTH_KEY`, never publish `ADMIN_INTERNAL_PORT`.
- `troubleshooting.md`: gluetun unhealthy, wrong country, port in use, CRLF `.env`, restart limitation, VPN IPs blocked by sites.
- READMEs: non-official disclaimer, quick start, links; CI does not run VPN tests.
- License: verify no AGPL file was copied (`git grep -l "GNU AFFERO"` empty) before choosing MIT; note third-party licenses (Firecrawl AGPL-3.0, Gluetun MIT) in README.

- [ ] **Step 1:** Write docs; check every command in `installation.md` by running it on the local stack.
- [ ] **Step 2:** `git grep -l "GNU AFFERO"` → empty. Link check: every relative link target exists (`grep -o '](\./[^)]*)'` + `test -e`).
- [ ] **Step 3: Commit** — `git commit -m "docs: add bilingual README, architecture ADRs and guides"`

---

### Task 9: CI

**Files:** Create `.github/workflows/validate.yml`, `.yamllint`

Jobs (ubuntu-latest, actions pinned by major version): `shellcheck` on `scripts/**/*.sh tests/**/*.sh`; `bash tests/unit/run.sh`; `cp .env.example .env` filled with fixture values from `tests/fixtures/valid.env` then `docker compose config -q` and `scripts/validate.sh --env .env`; `yamllint .`; `gitleaks/gitleaks-action` on full history.

- [ ] **Step 1:** Run each job's command locally (shellcheck/yamllint/gitleaks via docker images) → pass.
- [ ] **Step 2:** Plant a fake key `WIREGUARD_PRIVATE_KEY=<random 32-byte base64>` in a scratch file, run gitleaks locally → detected; remove file.
- [ ] **Step 3: Commit** — `git commit -m "ci: add validation workflow"`

---

### Task 10: Server validation (user-run gate)

- [ ] **Step 1:** User clones on server, fills `.env`, runs `./scripts/validate.sh && docker compose up -d && ./scripts/run-tests.sh`, pastes the masked report.
- [ ] **Step 2:** User confirms `tailscale status` and existing services unaffected; OpenClaw (or `examples/client`) reaches API via `edge` network.
- [ ] **Step 3:** Fix any FAIL via a new task in this plan. Publication to GitHub only after explicit user approval (spec §8 phase 5).
