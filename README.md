# web-scraping-firecrawl-vpn

[Português](README.pt-BR.md)

Self-hosted [Firecrawl](https://github.com/firecrawl/firecrawl) whose **only** way to the internet is a
Proton VPN WireGuard tunnel managed by [Gluetun](https://github.com/qdm12/gluetun). If the tunnel drops,
scraping stops instead of leaking your server's IP.

> Community project. **Not official** and not affiliated with Firecrawl, Proton or Gluetun.

## Features

- Firecrawl API (scrape, crawl) on `127.0.0.1:3002` and on a private Docker network for your apps.
- Fail-closed by network design: the API and browser share Gluetun's network namespace, so no HTTP
  client can bypass the tunnel ([why not a proxy?](docs/architecture.md#adr-1-shared-network-namespace-b1-instead-of-an-explicit-proxy)).
- Private destinations (host, LAN, Tailscale, cloud metadata) blocked from the scraping side.
- DNS over TLS through the tunnel, no IPv6 egress.
- Exit country/city selectable in `.env`; new exit IP on demand with `scripts/rotate-ip.sh`, no restarts.
- Host routes and existing VPNs such as Tailscale are untouched.
- Test scripts that prove all of the above and write a redacted report.

## Quick start

```bash
cp .env.example .env      # fill WIREGUARD_PRIVATE_KEY and the passwords
./scripts/validate.sh
docker compose up -d
./scripts/run-tests.sh
```

Full guide: [docs/installation.md](docs/installation.md). Proton key: [docs/protonvpn.md](docs/protonvpn.md).

```bash
curl -s -X POST http://127.0.0.1:3002/v2/scrape \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","formats":["markdown"]}'
```

Other containers (for example an AI agent platform such as OpenClaw) join the `firecrawl-edge` network and call
`http://gluetun:3002`. See [examples/client](examples/client/README.md).

## Tests

| Script | Proves |
|---|---|
| `scripts/validate.sh` | `.env` is complete and safe before deploy |
| `scripts/test-firecrawl.sh` | Scrape and crawl work |
| `scripts/test-vpn.sh` | Target sites see the VPN IP, never the host IP; DNS and IPv6 do not leak |
| `scripts/test-killswitch.sh` | With the tunnel stopped nothing leaves; private destinations blocked |
| `scripts/test-rotation.sh` | Rotation changes the exit IP; in-flight scrapes never leak; no restarts |
| `scripts/test-recovery.sh` | Data persists; behavior after Gluetun restarts |
| `scripts/run-tests.sh` | Runs everything, writes `reports/report-<UTC>.txt` (secrets and IPs masked) |

CI checks scripts, compose config and secrets. It cannot run the VPN tests (no credentials).

## Documentation

- [Architecture and decisions](docs/architecture.md)
- [Installation](docs/installation.md)
- [Proton VPN](docs/protonvpn.md)
- [Security](docs/security.md)
- [Troubleshooting](docs/troubleshooting.md)

## License

MIT for the files in this repository ([LICENSE](LICENSE)). The stack runs third-party images under their own
licenses: Firecrawl (AGPL-3.0), Gluetun (MIT), Redis, RabbitMQ (MPL-2.0), PostgreSQL. No third-party source
code is included in this repository.
