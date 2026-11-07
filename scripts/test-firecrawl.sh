#!/usr/bin/env bash
# Functional checks: API up, scrape works, small crawl completes.
# Usage: scripts/test-firecrawl.sh   (stack must be running; reads .env for FIRECRAWL_PORT)
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[[ -f "$FVPN_ROOT/.env" ]] && load_env "$FVPN_ROOT/.env"

API="$(api_url)"
report_init firecrawl

# POST JSON body to an API path; prints response body (empty on transport error).
api_post() { curl -s -m "${3:-120}" -X POST "$API$1" -H 'Content-Type: application/json' -d "$2" || true; }

scrape_check() {
  local name="$1" body="$2" resp ok
  resp="$(api_post /v2/scrape "$body")"
  ok="$(printf '%s' "$resp" | jqr -r 'if .success == true and .data.metadata.statusCode == 200 and ((.data.markdown // "") | length) > 0 then "yes" else "no" end' 2>/dev/null || echo no)"
  if [[ "$ok" == yes ]]; then pass "$name"; else fail "$name" "unexpected response: $(printf '%s' "$resp" | head -c 200)"; fi
}

if curl -sf -m 10 -o /dev/null "$API/v0/health/liveness"; then
  pass api_reachable
else
  fail api_reachable "no answer from $API/v0/health/liveness (is the stack up? docker compose ps)"
  report_summary || exit 1
fi

scrape_check scrape_default '{"url":"https://example.com","formats":["markdown"]}'
scrape_check scrape_waitfor '{"url":"https://example.com","formats":["markdown"],"waitFor":1000}'

crawl_id="$(api_post /v2/crawl '{"url":"https://example.com","limit":2}' 30 | jqr -r '.id // empty' 2>/dev/null || true)"
if [[ -z "$crawl_id" ]]; then
  fail crawl_small "crawl was not accepted"
else
  status="" count=0 waited=0
  while (( waited < 120 )); do
    resp="$(curl -s -m 30 "$API/v2/crawl/$crawl_id" || true)"
    status="$(printf '%s' "$resp" | jqr -r '.status // empty' 2>/dev/null || true)"
    [[ "$status" == completed || "$status" == failed ]] && break
    sleep 5
    waited=$((waited + 5))
  done
  count="$(printf '%s' "$resp" | jqr -r '(.data // []) | length' 2>/dev/null || echo 0)"
  if [[ "$status" == completed && "$count" -ge 1 ]]; then
    pass crawl_small "$count page(s)"
  else
    fail crawl_small "status=${status:-none} pages=$count after ${waited}s"
  fi
fi

report_summary
