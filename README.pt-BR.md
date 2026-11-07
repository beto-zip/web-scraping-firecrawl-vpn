# web-scraping-firecrawl-vpn

[English](README.md)

[Firecrawl](https://github.com/firecrawl/firecrawl) self-hosted cuja **única** saída para a internet é um
túnel WireGuard da Proton VPN gerenciado pelo [Gluetun](https://github.com/qdm12/gluetun). Se o túnel cair,
o scraping para em vez de vazar o IP do servidor.

> Projeto comunitário. **Não oficial** e sem afiliação com Firecrawl, Proton ou Gluetun.

## Recursos

- API do Firecrawl (scrape, crawl) em `127.0.0.1:3002` e numa rede Docker privada para suas aplicações.
- Fail-closed por construção de rede: API e navegador compartilham o namespace de rede do Gluetun, então
  nenhum cliente HTTP consegue contornar o túnel ([por que não proxy?](docs/architecture.md#adr-1-shared-network-namespace-b1-instead-of-an-explicit-proxy)).
- Destinos privados (host, LAN, Tailscale, metadata de nuvem) bloqueados a partir do scraping.
- DNS sobre TLS pelo túnel, sem saída IPv6.
- País/cidade de saída configuráveis no `.env`; novo IP de saída sob demanda com `scripts/rotate-ip.sh`, sem reinícios.
- Rotas do host e VPNs existentes, como Tailscale, não são alteradas.
- Scripts de teste que comprovam tudo isso e geram relatório com dados mascarados.

## Início rápido

```bash
cp .env.example .env      # preencha WIREGUARD_PRIVATE_KEY e as senhas
./scripts/validate.sh
docker compose up -d
./scripts/run-tests.sh
```

Guia completo (em inglês): [docs/installation.md](docs/installation.md). Chave Proton: [docs/protonvpn.md](docs/protonvpn.md).

```bash
curl -s -X POST http://127.0.0.1:3002/v2/scrape \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com","formats":["markdown"]}'
```

Outros containers (por exemplo, uma plataforma de agentes de IA como o OpenClaw) entram na rede `firecrawl-edge` e chamam
`http://gluetun:3002`. Veja [examples/client](examples/client/README.md).

## Testes

| Script | Comprova |
|---|---|
| `scripts/validate.sh` | `.env` completo e seguro antes do deploy |
| `scripts/test-firecrawl.sh` | Scrape e crawl funcionam |
| `scripts/test-vpn.sh` | Sites veem o IP da VPN, nunca o do host; sem vazamento de DNS e IPv6 |
| `scripts/test-killswitch.sh` | Com o túnel parado nada sai; destinos privados bloqueados |
| `scripts/test-rotation.sh` | A rotação troca o IP de saída; scrapes em andamento não vazam; sem reinícios |
| `scripts/test-recovery.sh` | Dados persistem; comportamento após reinício do Gluetun |
| `scripts/run-tests.sh` | Roda tudo e grava `reports/report-<UTC>.txt` (segredos e IPs mascarados) |

O CI valida scripts, configuração do compose e segredos. Os testes de VPN não rodam no CI (sem credenciais).

## Documentação (em inglês)

- [Arquitetura e decisões](docs/architecture.md)
- [Instalação](docs/installation.md)
- [Proton VPN](docs/protonvpn.md)
- [Segurança](docs/security.md)
- [Troubleshooting](docs/troubleshooting.md)

## Licença

MIT para os arquivos deste repositório ([LICENSE](LICENSE)). A stack executa imagens de terceiros sob suas
próprias licenças: Firecrawl (AGPL-3.0), Gluetun (MIT), Redis, RabbitMQ (MPL-2.0), PostgreSQL. Nenhum código-fonte
de terceiros está incluído neste repositório.
