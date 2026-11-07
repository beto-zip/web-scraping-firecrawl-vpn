# web-scraping-firecrawl-vpn — Design Spec v1.0

**Data:** 2026-11-06
**Status:** Aprovado em brainstorming, aguardando revisão da spec escrita
**Repositório:** `web-scraping-firecrawl-vpn` (projeto comunitário, **não oficial**, sem afiliação com Firecrawl ou Proton)

---

## 1. Objetivo

Distribuição Docker Compose self-hosted do Firecrawl cujo **único caminho de saída para a internet** é um túnel WireGuard da Proton VPN gerenciado pelo Gluetun.

**Motivação do usuário:**
1. Proteger o IP público do servidor (vazamento = falha grave).
2. Acessar conteúdo de outros países para scraping.

**Consequência de design:** isolamento deve ser **fail-closed por construção de rede**, não por configuração de proxy em clientes.

### Critérios de sucesso (v1)

1. `docker compose up -d` sobe a stack completa.
2. Scrape funciona via API (engine fetch e playwright) e crawl simples funciona.
3. IP de saída observado pelo site alvo = IP da VPN ≠ IP do host.
4. Com túnel parado, scrape externo falha (sem vazamento).
5. Destinos privados (LAN do host, `169.254.169.254`, `100.64.0.0/10`) inalcançáveis a partir dos containers de scraping.
6. Tailscale e rotas do host intocados (validado no servidor real).
7. Dados persistem após `down`/`up`.
8. Nenhum segredo no repositório; testes produzem relatório mascarado.
9. Terceiros conseguem instalar seguindo a documentação.

### Fora do escopo v1

- PostgreSQL/Redis **externos** (v1.1). Motivo: `nuq-postgres` é imagem customizada (Postgres 17 + `pg_cron` em `shared_preload_libraries` + schema `nuq.sql`); usuário não tem bancos para reusar.
- `setup.sh` interativo, `backup.sh`/`restore.sh` (v1.1; Postgres guarda só fila de jobs transitória).
- Proxy explícito como modo alternativo, `VPN_ENABLED=false`, OpenVPN, múltiplos túneis, rotação de IP, dashboard, Kubernetes, evasão de CAPTCHA/fingerprinting.
- Autenticação de API por usuário (self-host Firecrawl não tem auth sem schema Supabase). Proteção v1 é por rede.
- Docs completos em pt-BR (só README bilíngue na v1).

---

## 2. Pesquisa técnica (Fase 1) — achados

| # | Achado | Fonte | Impacto |
|---|---|---|---|
| 1 | Firecrawl v2.11.0 exige `api` (inclui workers via harness), `playwright-service`, `redis`, `rabbitmq`, `nuq-postgres`. FoundationDB só com `NUQ_BACKEND=fdb` (experimental). | `docker-compose.yaml`, `SELF_HOST.md` | Spec original omitia RabbitMQ e natureza customizada do Postgres. |
| 2 | `PROXY_SERVER` usado **somente** em `apps/api/src/scraper/scrapeURL/engines/utils/safeFetch.ts` e `apps/playwright-service-ts/api.ts`. | Código v2.11.0 | ~15 outros call sites (crawler robots/sitemap, wikipedia, downloadFile, ddgsearch, youtube, webhook, posthog) fazem requisições sem proxy. Estratégia proxy = vazamento ou quebra funcional. |
| 3 | `safeFetch` destrói conexões cujo `remoteAddress` é privado, salvo `ALLOW_LOCAL_WEBHOOKS=true`. Com proxy em IP Docker privado, a conexão ao proxy seria morta. | Código v2.11.0 | Reforça rejeição de proxy explícito. |
| 4 | API self-host sem auth por padrão. `BULL_AUTH_KEY` protege rotas admin. `ADMIN_INTERNAL_PORT` nunca deve ser publicado. | `SELF_HOST.md` | Proteção por bind loopback + rede privada. |
| 5 | Imagens oficiais do Firecrawl no ghcr referenciadas como `:latest`. | `docker-compose.yaml` | Fixar por digest (ou build de tag git). |
| 6 | Gluetun v3.41.3 atual. v3.41.0: DNS reescrito (DoT/DoH, `DNS_UPSTREAM_RESOLVER_TYPE`), resolução de nomes locais via resolvers privados detectados no start, proteção DNS rebinding sempre ativa. | Releases Gluetun | Resolução de nomes Docker no netns precisa ser validada (spike). |
| 7 | Gluetun Proton WireGuard: `VPN_SERVICE_PROVIDER=protonvpn`, `VPN_TYPE=wireguard`, `WIREGUARD_PRIVATE_KEY` (vale para todos servidores), filtros `SERVER_COUNTRIES`/`SERVER_CITIES`. Plano do usuário: **pago**. | gluetun-wiki protonvpn.md | Sem `FREE_ONLY`. |
| 8 | Licenças: Firecrawl AGPL-3.0, Gluetun MIT. | Repositórios | Repo contém só compose/scripts/docs → MIT viável se nenhum código AGPL for copiado. |

---

## 3. Arquitetura

### 3.1 Decisão: B1 — scraping compartilha netns do Gluetun

```text
            127.0.0.1:3002 (host)
                   │
┌──────────── netns gluetun ────────────┐
│ gluetun (wg0, firewall kill switch)   │
│ api :3002 + workers                   │──► wg0 ──► Proton ──► internet
│ playwright :3000 (localhost)          │
└──────┬─────────────────────┬──────────┘
       │ rede "backend"      │ rede "edge" (clientes: OpenClaw, cliente simulado)
       │ internal: true      │
  redis   rabbitmq   nuq-postgres
```

- `api` e `playwright` usam `network_mode: service:gluetun`. Toda saída passa pelo firewall do Gluetun, que permite apenas `wg0` + subnets em `FIREWALL_OUTBOUND_SUBNETS` (apenas a subnet `backend`).
- Independe de clientes HTTP honrarem proxy — cobre todos os call sites do achado 2.
- Alterações de rede ficam dentro do namespace do container: rotas do host e Tailscale não são tocados.
- Proteção SSRF de rede: LAN do host, metadata cloud e Tailscale bloqueados pelo firewall.

### 3.2 Alternativas rejeitadas (registrar como ADR em `docs/architecture.md`)

| Alternativa | Motivo da rejeição |
|---|---|
| A — Proxy explícito (Gluetun HTTP proxy ou WireProxy) | Achados 2 e 3: vazamento ou quebra de crawl/PDF/busca. WireProxy também sem lista de servidores Proton/seleção de país/failover. |
| B2 — Gluetun como gateway via `ip route` em cada container | Exige `NET_ADMIN` nos containers Firecrawl; frágil e menos seguro. |
| LinuxServer WireGuard em netns | Kill switch próprio via `iptables` `PostUp` (mais código a manter/testar), sem lista de servidores, healthcheck VPN ou IP público consultável. Mesmo problema de restart do netns. |

### 3.3 Serviços

| Serviço | Imagem | Rede | Papel |
|---|---|---|---|
| `gluetun` | `qmcgaw/gluetun:v3.41.3` | `backend`, `edge` | Túnel, firewall, DNS, publica porta API, control server (auth, não publicado) |
| `api` | Firecrawl v2.11.0 (digest fixo) | `service:gluetun` | API + workers, porta 3002 |
| `playwright` | Firecrawl playwright-service v2.11.0 (digest fixo) | `service:gluetun` | Navegador; `PLAYWRIGHT_MICROSERVICE_URL=http://localhost:3000/scrape` |
| `redis` | `redis` alpine, versão fixa | `backend` | Fila / rate limit; **com senha** |
| `rabbitmq` | `rabbitmq` management, versão fixa | `backend` | Fila NuQ; **credenciais não padrão** |
| `nuq-postgres` | Firecrawl nuq-postgres v2.11.0 (digest fixo) | `backend` | Jobs (pg_cron) |

- `api`/`playwright`: `depends_on: { gluetun: { condition: service_healthy, restart: true } }`.
- Porta publicada **no serviço gluetun**: `${API_BIND_ADDRESS:-127.0.0.1}:${FIRECRAWL_PORT:-3002}:3002`.
- Portas usadas dentro do netns compartilhado (sem conflito a confirmar no spike): 3002 (api), 3004/3005 (workers), 3000 (playwright), 8000 (control server Gluetun). Proxy HTTP e Shadowsocks do Gluetun desligados.
- Volumes nomeados (sem bind em diretórios do host).
- Logs `json-file` com `max-size`/`max-file`.
- Healthchecks nos 6 serviços; `restart: unless-stopped`.
- Limites de recursos configuráveis via `.env` (padrões do compose upstream).
- Nenhum `network_mode: host`; nenhuma porta de banco publicada.

### 3.4 Fallback de build

Se fixação por digest no ghcr for inviável, usar `build:` com contexto remoto `https://github.com/firecrawl/firecrawl.git#v2.11.0:apps/<app>` — sem copiar código AGPL para o repo.

---

## 4. Configuração (`.env.example`)

Somente variáveis efetivamente consumidas (repasse direto para Gluetun/Firecrawl ou interpolação no compose):

```dotenv
# REDE / ACESSO
API_BIND_ADDRESS=127.0.0.1
FIRECRAWL_PORT=3002
EDGE_NETWORK_NAME=firecrawl-edge

# VPN (Gluetun)
WIREGUARD_PRIVATE_KEY=
SERVER_COUNTRIES=Netherlands
SERVER_CITIES=

# FIRECRAWL
BULL_AUTH_KEY=
NUM_WORKERS_PER_QUEUE=8
CRAWL_CONCURRENT_REQUESTS=10
MAX_CONCURRENT_JOBS=5
BROWSER_POOL_SIZE=5
LOGGING_LEVEL=info
OPENAI_API_KEY=

# BANCOS (internos)
POSTGRES_PASSWORD=
REDIS_PASSWORD=
RABBITMQ_PASSWORD=

# GLUETUN CONTROL SERVER (usado pelos testes)
GLUETUN_CONTROL_API_KEY=
```

Nomes finais de variáveis de credenciais internas e do control server serão confirmados contra a versão fixada no spike; nenhuma variável fictícia.

**Removidas da proposta original:** `VPN_ENABLED`, `VPN_REQUIRED` (VPN é estrutural), `PROXY_*` (sem proxy no caminho), `POSTGRES_MODE`/`REDIS_MODE`/`REDIS_DB`/hosts externos (v1.1), `PROJECT_NAME`/`APP_ENV` (sem consumidor).

### 4.1 `validate.sh`

Rejeita antes do deploy:
- `WIREGUARD_PRIVATE_KEY` vazia ou não base64 de 32 bytes.
- Senhas internas vazias.
- `API_BIND_ADDRESS` não-loopback sem confirmação explícita (flag).
- `docker compose config` com erro.
- Ausência de `/dev/net/tun` no host (aviso).

Nunca imprime valores de segredos.

---

## 5. Fluxo de dados e falhas

```text
cliente ──► 127.0.0.1:3002 (host) | gluetun:3002 (rede edge)
          └► api ──► redis / rabbitmq / nuq-postgres  (backend, sem internet)
              └► worker ──► fetch | playwright (localhost:3000)
                          └► wg0 ──► Proton ──► alvo
```

| Situação | Comportamento esperado | Garantia |
|---|---|---|
| Túnel não sobe no boot | Gluetun `unhealthy`; api/playwright não iniciam | `depends_on: service_healthy` |
| Túnel cai em operação | Firewall bloqueia; scrape falha; Gluetun reconecta | `test-killswitch.sh` |
| Container Gluetun reinicia | api/playwright perdem netns (fail-closed, sem rede) | **Limitação aceita:** (a) documentada + comando `docker compose restart api playwright`; (b) `depends_on.restart: true` cobre `compose up`. Sidecar autoheal → roadmap. |
| DNS | Resolvido pelo Gluetun via túnel | `test-vpn.sh` |
| IPv6 | Bloqueado se túnel sem IPv6 | `test-vpn.sh` |
| SSRF LAN/host/Tailscale/metadata | Bloqueado pelo firewall | `test-killswitch.sh` |
| SSRF para `backend` | Alcançável | Mitigado: senhas Redis/RabbitMQ/Postgres não padrão |

---

## 6. Testes e evidências

Scripts rodam no host (local ou servidor), dependências: `docker`, `curl`, `jq`. `run-tests.sh` executa todos e emite relatório PASS/FAIL **mascarado** (IPs parciais como `189.x.x.x`, segredos nunca impressos) para o usuário colar na conversa.

| Script | Prova | Método |
|---|---|---|
| `test-firecrawl.sh` | Scrape funcional | Scrape `example.com` (fetch e playwright) + crawl 2 páginas via API |
| `test-vpn.sh` | Saída pela VPN | IP host vs IP Gluetun (control server) vs IP retornado por scrape Firecrawl de `api.ipify.org` → 2 últimos iguais e ≠ host; resolver DNS no netns; IPv6 |
| `test-killswitch.sh` | Fail-closed | Para túnel via control server → scrape falha + fetch direto do netns falha; destinos privados bloqueados; religa → scrape volta |
| `test-recovery.sh` | (a)+(b), persistência | Restart Gluetun → `compose up` recupera; `down`/`up` preserva volumes |

**CI (GitHub Actions, sem credenciais):** shellcheck, `docker compose config` com env de exemplo, gitleaks, yamllint. Testes VPN não rodam no CI (documentado).

**Cliente simulado:** `examples/client/` — container na rede `edge` chamando `http://gluetun:3002`, substitui OpenClaw até a validação no servidor.

---

## 7. Árvore de arquivos

```text
web-scraping-firecrawl-vpn/
├── compose.yaml
├── .env.example
├── .gitignore
├── LICENSE                      # MIT (sujeito à revisão final)
├── README.md
├── README.pt-BR.md
├── scripts/
│   ├── validate.sh
│   ├── test-firecrawl.sh
│   ├── test-vpn.sh
│   ├── test-killswitch.sh
│   ├── test-recovery.sh
│   ├── run-tests.sh
│   └── lib/common.sh            # helpers: mascaramento, PASS/FAIL, carregamento .env
├── examples/
│   └── client/
├── docs/
│   ├── architecture.md          # ADRs + limitações
│   ├── installation.md
│   ├── protonvpn.md
│   ├── security.md
│   ├── troubleshooting.md
│   └── superpowers/specs/       # esta spec
└── .github/workflows/validate.yml
```

`.gitignore`: `.env`, `.env.*`, `!.env.example`, `secrets/`, `*.key`, `*.conf` (WireGuard), `*.log`, `.claude/settings.local.json`.

---

## 8. Fases

| Fase | Onde | Saída / gate |
|---|---|---|
| 0. Spike | Local | Respostas: nomes Docker no netns (senão IPs fixos); porta publicada no Gluetun exige `FIREWALL_INPUT_PORTS`?; tags/digests ghcr; nomes de variáveis de credenciais internas. Código descartável. |
| 1. Stack up | Local | compose + `.env.example` + `validate.sh` + smoke scrape |
| 2. Testes | Local | 4 scripts + relatório com evidência real |
| 3. Docs + CI | Local | READMEs, docs, workflow, LICENSE |
| 4. Validação servidor | Servidor do usuário | Usuário roda `run-tests.sh`; confirma Tailscale e OpenClaw |
| 5. Publicação | GitHub | Somente com aprovação; revisão final de segredos e licenças |

Pré-requisitos locais: Docker Desktop iniciado (WSL2), chave WireGuard Proton (plano pago).

---

## 9. Riscos e limitações

1. **DNS no netns** — validação no spike; plano B IPs fixos na `backend`.
2. **Restart isolado do Gluetun** — limitação aceita (a)+(b).
3. **Atualização de imagens** — digest fixo exige atualização manual documentada.
4. **Bloqueio de IPs de VPN** por sites — limitação do conceito, documentada.
5. **Termos de uso Proton / uso responsável** — documentado; evasão fora de escopo.
6. **Licença** — MIT proposta; reavaliar se algum artefato AGPL for copiado.
7. **OpenClaw real** — só validado na Fase 4; cliente simulado até lá.
8. **Docker Desktop ≠ servidor Linux** — itens de Tailscale/rotas do host só validados na Fase 4.

---

## 10. Roadmap

- **v1.1:** Postgres/Redis externos, backup/restore, skill OpenClaw, exemplos n8n, `setup.sh`, docs pt-BR completos, sidecar autoheal opcional.
- **v1.2:** múltiplos túneis/gateways, failover, rotação controlada de IP.
- **v2.0:** dashboard opcional, API admin, métricas, outros provedores VPN.
