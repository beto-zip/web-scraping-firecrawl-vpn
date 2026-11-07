# Security

## What is protected

| Threat | Protection | Verified by |
|---|---|---|
| Scrape traffic leaving with the host IP | `api`/`playwright` share Gluetun's namespace; firewall default `DROP`, only `tun0` + backend allowed | `test-vpn.sh` (`scrape_*_sees_vpn_ip`, `egress_not_host`) |
| Tunnel down → direct egress | Same firewall; nothing but loopback and backend is reachable | `test-killswitch.sh` (`direct_egress_blocked`, `scrape_fails_when_down`) |
| DNS leaks | Resolver is Gluetun (`127.0.0.1`), upstream DNS over TLS through the tunnel | `test-vpn.sh` (`dns_via_gluetun`) |
| IPv6 leaks | No IPv6 in the namespace | `test-vpn.sh` (`ipv6_no_leak`) |
| SSRF to host, LAN, Tailscale, cloud metadata | `config/gluetun/post-rules.txt` drops new connections to private ranges outside the tunnel | `test-killswitch.sh` (`private_host_gateway_blocked*`, `metadata_blocked`, `tailscale_range_blocked`) |
| SSRF to the databases | Firecrawl API and playwright-service reject private targets; Redis, RabbitMQ and Postgres require passwords | `test-killswitch.sh` (`api_refuses_private_target`) |
| Databases reaching the internet | `backend` network is `internal: true` | compose definition |
| Secrets in logs/reports | Scripts never print secrets; `run-tests.sh` passes output through a redaction filter and masks IPs | manual check in Task 6 of the plan |

## Residual risks

- **No API authentication.** Anyone who can reach the API can scrape through your VPN.
  - Keep `API_BIND_ADDRESS=127.0.0.1`. `validate.sh` refuses other values unless you pass `--allow-public-bind`.
  - Only attach trusted containers to the `edge` network.
- **Edge is a trust boundary.** Containers on `edge` can reach every port of the scraping namespace:
  `3000` (playwright service, which also rejects private targets), `3004`/`3005` (workers) and `8000`
  (Gluetun control server, protected by `GLUETUN_CONTROL_API_KEY`). Gluetun cannot filter input ports
  per interface.
- **Backend reachable from the scraping namespace.** Required for queues; mitigated by passwords and by
  Firecrawl's private-address checks.
- **Admin routes** are protected by `BULL_AUTH_KEY` (required). Never publish an `ADMIN_INTERNAL_PORT`.
- **Upstream images** are pinned by digest but not audited by this project.

## Secrets

`.env` holds every secret and is git-ignored. Use URL-safe values (`openssl rand -hex 24`).
CI runs gitleaks on every push. Report a vulnerability privately to the maintainer instead of opening a public issue.
