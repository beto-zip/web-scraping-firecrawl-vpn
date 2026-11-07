# Example client

Stands in for OpenClaw (or any consumer) during local testing. It joins the stack's
`edge` network and calls the Firecrawl API at `http://gluetun:3002` (the API lives in
Gluetun's network namespace, so the hostname is `gluetun`).

```bash
docker compose up -d                                      # main stack first
docker compose -f examples/client/compose.yaml run --rm client https://example.com
```

To connect your own app, attach its container to the same network:

```yaml
networks:
  edge:
    external: true
    name: firecrawl-edge   # EDGE_NETWORK_NAME in .env
```

and point it at `FIRECRAWL_API_URL=http://gluetun:3002`.

Containers on `edge` are trusted: the API has no authentication and every port in the
scraping namespace is reachable from this network. See `docs/security.md`.
