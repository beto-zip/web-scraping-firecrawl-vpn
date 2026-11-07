# Spike notes (Task 0) — 2026-11-07

Environment: Windows 11, Docker Desktop 29.8.2 (WSL2), Gluetun v3.41.3, Proton VPN (paid), `SERVER_COUNTRIES=Netherlands`.
Throwaway compose: `spike/compose.yaml` (git-ignored, deleted). IPs below are masked.

## Q1 — Docker service names inside the Gluetun netns

**Answer:** resolve correctly. `/etc/resolv.conf` in `api` = `nameserver 127.0.0.1` (Gluetun DNS); `getent hosts redis|rabbitmq|nuq-postgres` returned the `backend` IPs. Firecrawl workers connected to Redis, RabbitMQ and Postgres.

**Decision:** use service names. Keep a fixed `backend` subnet (`172.30.0.0/24`) because `FIREWALL_OUTBOUND_SUBNETS` needs it; no fixed container IPs.

Note: Gluetun logged `using plaintext DNS at address 1.x.x.x` (upstream, inside the tunnel). **Decision:** set `DNS_UPSTREAM_RESOLVER_TYPE=dot` so upstream DNS is encrypted even past the VPN exit.

## Q2 — Inbound to the API port published on `gluetun`

**Answer:** works without `FIREWALL_INPUT_PORTS`.
- host → `127.0.0.1:3002/` → `200`
- container on `edge` → `http://gluetun:3002/` → `200`
- container not on `edge` → `gluetun` does not resolve (curl rc=6)

**Decision:** no `FIREWALL_INPUT_PORTS`.

## Q3 — Image tags / digests

- `ghcr.io/firecrawl/firecrawl`: no `v2.11.0` tag; per-commit semver tags exist (`2.11.701` newest = `latest`, built from upstream commit `874a9ed`, 2026-11-06). Release page "v2.11.0" is outdated relative to images.
- `ghcr.io/firecrawl/playwright-service`, `ghcr.io/firecrawl/nuq-postgres`: only `latest` and `sha-*` tags.

**Decision (pins used in `compose.yaml`):**

| Image | Pin |
|---|---|
| firecrawl | `ghcr.io/firecrawl/firecrawl:2.11.701@sha256:3fe1263dbf79984af344475fb075c0a557e9c529146bd2619a3af6bea0f28904` |
| playwright-service | `ghcr.io/firecrawl/playwright-service:sha-37a85335cdd6@sha256:eacaf2c256a6ff7fd1869e470d2969e97a037ff6c75ac01d38784d138a33f8eb` |
| nuq-postgres | `ghcr.io/firecrawl/nuq-postgres:sha-a7a63b4bfabf@sha256:d719b36160eac2fcbe16dc7e7360ddb9c82c40ea5da183d07bf4a755c6a0b2ae` |
| redis | `redis:8.10.3-alpine` (what `redis:alpine` resolved to) |
| rabbitmq | `rabbitmq:3.13.7-management` |
| gluetun | `qmcgaw/gluetun:v3.41.3` |
| test probe | `curlimages/curl:8.11.1` |

Upstream compose also starts `foundationdb` + `foundationdb-init` unconditionally; they are only used with `NUQ_BACKEND=fdb` → **omitted**. Upstream `nuq-postgres` has no volume → **we add one**.

## Q4 — Internal credentials

- Redis: `REDIS_URL` / `REDIS_RATE_LIMIT_URL` accept `redis://:<password>@redis:6379`; server `redis-server --requirepass`.
- RabbitMQ: api reads `NUQ_RABBITMQ_URL` (`amqp://user:pass@rabbitmq:5672`); broker reads `RABBITMQ_DEFAULT_USER` / `RABBITMQ_DEFAULT_PASS`.
- Postgres: `POSTGRES_PASSWORD` shared by api and nuq-postgres.

**Decision:** `.env` keeps `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_PASSWORD`; compose builds the URLs. Passwords must be URL-safe → `validate.sh` rejects characters outside `[A-Za-z0-9._~-]` (to add in Task 3).

## Q5 — Gluetun control server

- Auth: env `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE='{"auth":"apikey","apikey":"<key>"}'`; header `X-API-Key: <key>`. Without key → `401 Unauthorized`.
- `GET http://127.0.0.1:8000/v1/publicip/ip` → JSON with `public_ip`, `country`, `city`.
- `GET /v1/vpn/status` → `{"status":"running"}`; `PUT /v1/vpn/status {"status":"stopped"|"running"}` → `{"outcome":"stopped"|"running"}`.
- Port 8000 is reachable only inside the netns (not published).

## Q6 — Which engine runs / egress IP seen by target

- `POST /v2/scrape` `{"url":"https://api.ipify.org","formats":["markdown"]}` → markdown `46.x.x.x` (VPN, Amsterdam). Host IP `186.x.x.x` not present in response. Same with `"waitFor":1000`.
- Both requests used the **playwright** engine (api log: `Scraping via playwright... deemed successful`). Self-host selects playwright first when `PLAYWRIGHT_MICROSERVICE_URL` is set; no public parameter forces `fetch`.

**Decision:** tests do not try to force engines. Raw (non-browser) egress paths are proven at network level by `netns_probe` (curl inside the same netns as `api`), which covers every Node HTTP client because they share the namespace. `test-firecrawl.sh` checks `scrape_default` and `scrape_waitfor` instead of `scrape_fetch` / `scrape_playwright`.

## Kill switch (preview of Task 5)

VPN stopped via control server:

| Probe from netns | Result |
|---|---|
| `https://api.ipify.org` | rc=6 (DNS fails) |
| `http://8.8.8.8/` (raw IP) | rc=28 timeout |
| `http://169.254.169.254/` | rc=28 |
| `http://100.100.100.100/` (Tailscale range) | rc=28 |
| `http://192.168.65.7/` (Docker Desktop host) | rc=28 |
| `http://host.docker.internal/` | rc=28 |
| Firecrawl scrape `example.com` | `success:false`, `SCRAPE_DNS_RESOLUTION_ERROR` |

VPN restarted → new exit IP `212.x.x.x`, Redis `PING` → `+PONG` from netns, scrape `example.com` → success.

Note: `telnet://redis:6379` with empty stdin times out even when connected → tests must send `PING` and expect `+PONG`.

## IPv6

Netns has only `::1`; `curl -6 https://api6.ipify.org` → rc=7. No IPv6 egress.

## Q7 — Healthchecks / binaries

| Service | Binaries | Healthcheck |
|---|---|---|
| gluetun | built-in | image HEALTHCHECK `/gluetun-entrypoint healthcheck` |
| api | `curl`, `node` | `curl -fsS http://localhost:3002/v0/health/liveness` (200) |
| playwright | `node` only | `node -e "fetch('http://localhost:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"` (200) |
| redis | `redis-cli` | `redis-cli -a $REDIS_PASSWORD --no-auth-warning ping` |
| rabbitmq | `rabbitmq-diagnostics` | `rabbitmq-diagnostics -q check_running` |
| nuq-postgres | `pg_isready` | `pg_isready -U postgres -d postgres` |

Ports in shared netns: 3000, 3002, 3004, 3005, 8000 — no conflicts observed.

## Gluetun restart — limitation (a)+(b) verified

| Action | api reachable after? |
|---|---|
| `docker restart <gluetun>` (outside compose, same as daemon auto-restart) | **No** — api has no network (fail-closed) |
| then `docker compose up -d` | **No** — compose does not recreate dependents |
| then `docker compose restart api playwright` | **Yes** (200) |
| `docker compose restart gluetun` (compose-managed) | **Yes** — `depends_on.restart: true` restarted api/playwright |

**Ruling for spec §5 / plan Task 6:** (b) covers only compose-managed restarts (`docker compose restart gluetun`, `up` with recreate). Documented recovery command = `docker compose restart api playwright`. `test-recovery.sh` asserts: after `docker restart` → API unreachable (fail-closed); after `docker compose restart api playwright` → recovers.
