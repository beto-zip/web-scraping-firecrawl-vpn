# Architecture

## Goal

Run self-hosted [Firecrawl](https://github.com/firecrawl/firecrawl) so that **every** outbound
scraping connection leaves through a Proton VPN WireGuard tunnel managed by
[Gluetun](https://github.com/qdm12/gluetun), and **nothing** leaves when the tunnel is down
(fail-closed). Motivation: protect the server's public IP and scrape content from other countries.

## Layout

```text
            127.0.0.1:3002 (host)
                   │
┌──────────── netns gluetun ────────────┐
│ gluetun (WireGuard, firewall, DNS)    │
│ api :3002 + workers (3004/3005)       │──► tun0 ──► Proton VPN ──► internet
│ playwright :3000 (localhost)          │
└──────┬─────────────────────┬──────────┘
       │ backend             │ edge (API consumers: OpenClaw, examples/client)
       │ internal, 172.30.0.0/24
  redis   rabbitmq   nuq-postgres
```

| Service | Network | Role |
|---|---|---|
| `gluetun` | `backend`, `edge` | WireGuard tunnel, firewall kill switch, DNS over TLS, publishes the API port |
| `api` | `network_mode: service:gluetun` | Firecrawl API + workers |
| `playwright` | `network_mode: service:gluetun` | Headless browser, reached at `localhost:3000` |
| `redis`, `rabbitmq`, `nuq-postgres` | `backend` only | Queues and job storage; no internet access |

Images are pinned by digest in `compose.yaml` (see [spike-notes.md](spike-notes.md) for how they were chosen).

## How fail-closed works

1. `api` and `playwright` have no network interface of their own: they share Gluetun's namespace.
2. Gluetun's firewall default policy is `DROP`. It accepts only: loopback, established/related
   traffic, the WireGuard handshake to the selected server, everything on `tun0`, and the
   `backend` subnet (`FIREWALL_OUTBOUND_SUBNETS`).
3. Gluetun also accepts its own interface subnets by default. `config/gluetun/post-rules.txt`
   drops **new** connections to private ranges (`10/8`, `172.16/12`, `192.168/16`, `100.64/10`,
   `169.254/16`) outside the tunnel, except the backend subnet. This blocks the host (edge gateway),
   other edge containers, the LAN, Tailscale addresses and cloud metadata.
4. `api` and `playwright` run without Linux capabilities, so they cannot open raw/packet sockets
   that would skip the firewall. Both networks are IPv4-only (`enable_ipv6: false`).
5. When the tunnel stops, only loopback and the backend remain reachable: scrapes fail with DNS or
   connection errors. No configuration in Firecrawl is involved, so no HTTP client can bypass it.

All network changes live inside the container namespace: host routes and Tailscale are untouched.

Evidence: `scripts/test-killswitch.sh` and `scripts/test-vpn.sh` (see [installation.md](installation.md)).

## Decisions (ADRs)

### ADR-1: Shared network namespace (B1) instead of an explicit proxy

**Status:** accepted.

Firecrawl reads `PROXY_SERVER` only in two places (Firecrawl v2.11.0 source):
`apps/api/src/scraper/scrapeURL/engines/utils/safeFetch.ts` and `apps/playwright-service-ts/api.ts`.
About 15 other call sites (crawler robots/sitemap, wikipedia engine, file downloads, search, youtube,
webhooks, telemetry) make requests without it. In addition, `safeFetch` destroys connections whose
remote address is private unless `ALLOW_LOCAL_WEBHOOKS=true`, and a proxy inside Docker has a private
address.

An explicit proxy would therefore either leak the host IP or, if the containers had no other route,
break crawling, downloads and search. Sharing Gluetun's namespace covers every code path.

Rejected alternatives:

| Option | Reason |
|---|---|
| Gluetun HTTP proxy or [WireProxy](https://github.com/pufferffish/wireproxy) | Proxy coverage gaps above. WireProxy also lacks a Proton server list, country selection and failover. |
| Gluetun as a routed gateway (`ip route` in each container) | Requires `NET_ADMIN` in Firecrawl containers; fragile. |
| LinuxServer WireGuard in a shared namespace | Kill switch must be hand-written with `iptables`; no server list, VPN health check or public-IP endpoint; same restart limitation. |

### ADR-2: Internal-only databases in v1

`nuq-postgres` is a custom image (Postgres 17 + `pg_cron` in `shared_preload_libraries` + `nuq.sql`
schema), so a generic external Postgres does not work. External Postgres/Redis modes are planned for v1.1.

### ADR-3: Fixed backend subnet

`172.30.0.0/24` appears in `compose.yaml` (network + `FIREWALL_OUTBOUND_SUBNETS`) and in
`config/gluetun/post-rules.txt`, which Gluetun reads as a static file. If it collides with a network on
your host, change all three places.

### ADR-4: Protection of the API is network-based

Self-hosted Firecrawl has no API authentication unless a Supabase-style schema is provisioned. v1 binds
the API to `127.0.0.1` and exposes it to containers only through the `edge` network. See [security.md](security.md).

## Known limitations

- **Any Gluetun restart** (crash, `docker restart`, daemon restart, `docker compose restart gluetun`):
  `api` and `playwright` lose their namespace and have no network (fail-closed). Recover with
  `docker compose restart api playwright`. After Gluetun is **recreated**, use `docker compose up -d`.
  `depends_on.restart: true` was tried and removed: compose restarted the dependents before Gluetun was
  back, leaving them on a dead namespace (see [spike-notes.md](spike-notes.md)). An optional autoheal
  sidecar is on the roadmap.
- **No engine selection:** self-hosted Firecrawl picks the playwright engine first; requests cannot
  force the plain fetch engine. All engines share the namespace, so egress guarantees are identical.
- **VPN IPs get blocked** by some sites. This is inherent to scraping through a VPN.
- **Edge is a trust boundary:** containers on `edge` can reach every port in the scraping namespace.
- **Image updates are manual:** bump the digests in `compose.yaml` and rerun `scripts/run-tests.sh`.
