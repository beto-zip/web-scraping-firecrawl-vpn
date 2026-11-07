# Donation page prototype / Protótipo da página de apoio

This folder contains a **static** GitHub Pages donation interface, inspired by the layout of a typical multi-method donation selector. It is independent of the Docker/VPN runtime. All payment destinations are intentionally blank and the page is locked in preview mode.

> **Do not switch it on yet.** [Issue #10](https://github.com/beto-zip/web-scraping-firecrawl-vpn/issues/10) requires real deployment validation ([#6](https://github.com/beto-zip/web-scraping-firecrawl-vpn/issues/6)), resolution of material security/maintenance gaps, and a stable public release before publishing a donation call to action.

## Files

- `index.html`: accessible page structure, Portuguese/English labels.
- `styles.css`: original responsive design, no CSS framework.
- `app.js`: browser-only method selector, copy button, QR rendering and PayPal links.
- `config.js`: **public** placeholders and a separate `stage` activation flag.

The page has **no payment backend**. Crypto receiving addresses are presented locally in the browser, and users follow official external PayPal links for payment. No private keys or credentials are needed or permitted in the repository.

## Test the prototype locally

From the repository root:

```sh
python3 -m http.server 8000 --directory docs
```

Open `http://localhost:8000/donate/`. By design: no real payment button, receiving wallet or QR code is enabled while `stage: "preview"`, even if a payment destination is filled in. The page shows a clear preview notice.

QR creation uses **QRCode.js 1.0.0** (MIT license) delivered through a version-pinned Cloudflare CDN script with SRI integrity. Wallet addresses are encoded into QR codes **inside the browser**, not sent to a third-party QR generation service. If the CDN is unreachable, users can still copy a configured wallet address in live mode.

## Publish on GitHub Pages (only after #10 prerequisites)

1. Complete and document the prerequisites in issue #10. Decide who owns payment accounts, tax/accounting implications, public contact, provider fees and how funds will be reported.
2. Verify the addresses and external links against the actual recipient account (and against the exact network). Have another maintainer independently verify the displayed destinations. Do not trust a screenshot for copying wallet addresses.
3. Set the public addresses in `config.js`. Set each PayPal URL for the **exact USD amount and frequency** shown. The monthly and yearly columns require genuine subscription links; a normal one-off PayPal.Me link does not create recurring billing.
4. Test each enabled method end to end **with an authorized low-value test transaction** and check the receiving destination. Leave unconfigured methods disabled.
5. Only then change `stage: "preview"` to `stage: "live"`, update the README links, and enable Pages in **Settings → Pages → Build and deployment → Deploy from a branch → main → /docs → Save**.
6. Check the published site at `https://beto-zip.github.io/web-scraping-firecrawl-vpn/donate/` and confirm that README links work. The URL will not be live until Pages is configured and deployed.

GitHub Pages needs an entry point at the root of the selected source folder, which is why `docs/index.html` is also included. Pages uses `/docs` for publishing, but regular repository documentation remains at `docs/*.md`.

## Safety and disclosure checklist

- Never add wallet **private** keys, mnemonics, OAuth tokens or API secrets in client-side files.
- Disable any unavailable method rather than providing fake addresses.
- Avoid copying the branding or payment details of the reference website.
- Explain that voluntary contributions confer **no support SLA, priority, access or security guarantee**.
- Do not describe PayPal links as monthly/yearly recurring plans without configuring actual recurring plans in PayPal.
- Keep English and Portuguese README disclosures in sync.

**Status:** prototype only. No contributions are requested or accepted through this interface.
