# Troubleshooting

## `validate.sh` says the file has CRLF line endings

The `.env` was saved with Windows line endings. Convert it: `dos2unix .env` or `sed -i 's/\r$//' .env`.

## `docker compose up` fails with "dependency failed to start: ... gluetun ... is unhealthy"

```bash
docker compose logs gluetun | tail -50
```

- `the country specified is not valid`: fix `SERVER_COUNTRIES` (the log lists valid names).
- `i/o timeout` or repeated `restarting VPN because it failed to pass the healthcheck`: wrong or revoked
  WireGuard key, or UDP 51820 blocked by your network. Generate a new key ([protonvpn.md](protonvpn.md)).
- `/dev/net/tun: no such file`: enable TUN on the host ([installation.md](installation.md)).

## API stopped answering after Gluetun restarted

Whenever Gluetun restarts (crash, `docker restart`, daemon restart or `docker compose restart gluetun`),
`api` and `playwright` lose their network namespace. They stay offline (no leak) until restarted:

```bash
docker compose restart api playwright
```

If Gluetun was **recreated** (for example after changing its configuration) and `api` shows
`Exited (128)`, run `docker compose up -d`.

## Port 3002 already in use

`validate.sh` warns about it. Change `FIRECRAWL_PORT` in `.env`, or stop the other service.

## Network `172.30.0.0/24` collides with an existing network

Change the subnet in `compose.yaml` (`networks.backend` and `FIREWALL_OUTBOUND_SUBNETS`) and in
`config/gluetun/post-rules.txt` (see ADR-3 in [architecture.md](architecture.md)).

## A site blocks the scrape or shows a CAPTCHA

Some sites block VPN/datacenter IPs. Try another `SERVER_COUNTRIES`/`SERVER_CITIES`. Evasion is out of scope.

## Scrape returns `SCRAPE_DNS_RESOLUTION_ERROR` for every URL

The tunnel is probably down. Check `docker compose ps` and `docker compose logs gluetun`.

## Tests

- `scripts/run-tests.sh` writes the full redacted report to `reports/`.
- `scripts/test-killswitch.sh` stops the tunnel temporarily and always restarts it on exit, including
  on Ctrl-C. If it was killed with `SIGKILL`, run `docker compose restart gluetun`.
