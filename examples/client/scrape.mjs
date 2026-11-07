// Minimal Firecrawl v2 client: scrape one URL and print its markdown.
// Exit code 0 on success, 1 on any failure.
const api = process.env.FIRECRAWL_API_URL ?? "http://gluetun:3002";
const url = process.argv[2];

if (!url) {
  console.error("usage: scrape.mjs <url>");
  process.exit(1);
}

try {
  const res = await fetch(`${api}/v2/scrape`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url, formats: ["markdown"] }),
    signal: AbortSignal.timeout(120_000),
  });
  const body = await res.json();
  if (!res.ok || body.success !== true) {
    console.error(`scrape failed (HTTP ${res.status}): ${body.error ?? JSON.stringify(body).slice(0, 300)}`);
    process.exit(1);
  }
  console.log(body.data.markdown);
} catch (err) {
  console.error(`request to ${api} failed: ${err.message}`);
  process.exit(1);
}
