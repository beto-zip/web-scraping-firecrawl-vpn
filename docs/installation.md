# Installation

## Requirements

- Linux host with Docker Engine and Docker Compose v2 (Docker Desktop on Windows/macOS also works for testing).
- `/dev/net/tun` available on the host (`ls -l /dev/net/tun`). Most distributions have it; on some VPS
  providers the TUN device must be enabled in the control panel.
- A Proton VPN account and a WireGuard private key (see [protonvpn.md](protonvpn.md)).
- Memory: about 2.5 GB used at idle (measured), more while browsers render pages. `API_MEMORY=8G` and
  `PLAYWRIGHT_MEMORY=4G` are ceilings, not reservations.
- `curl` for the test scripts. `jq` is optional: the scripts fall back to the `ghcr.io/jqlang/jq` image.
- Architectures: amd64 and arm64 images are published for every pinned component.

## Install

```bash
git clone <repository-url> web-scraping-firecrawl-vpn
cd web-scraping-firecrawl-vpn

cp .env.example .env
# Fill WIREGUARD_PRIVATE_KEY and generate the other secrets, for example:
#   openssl rand -hex 24
nano .env

./scripts/validate.sh
docker compose up -d
docker compose ps        # all six services should become "healthy" (1-2 minutes)
./scripts/run-tests.sh   # full check; writes reports/report-<UTC>.txt
```

`./scripts/run-tests.sh --skip-recovery` skips the recovery suite, which restarts containers.

The API is then available at `http://127.0.0.1:3002` on the host and at `http://gluetun:3002` for
containers attached to the `edge` network (see [examples/client](../examples/client/README.md)).

```bash
curl -s -X POST http://127.0.0.1:3002/v2/scrape \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","formats":["markdown"]}'
```

## Updating

1. Pick new image digests (`docker buildx imagetools inspect ghcr.io/firecrawl/firecrawl:<version>`).
2. Edit the `image:` lines in `compose.yaml`.
3. `docker compose up -d` and run `./scripts/run-tests.sh`.

## Moving to another server

Copy the repository and your `.env` (securely, it contains secrets), then run the install steps.
Job data in Postgres/Redis is transient; volumes do not need to be migrated.

## Uninstall

```bash
docker compose down        # keeps volumes
docker compose down -v     # also deletes volumes (job data)
```
