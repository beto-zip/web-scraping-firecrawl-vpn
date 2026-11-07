# Donation page prototype / Protótipo da página de apoio

This folder contains a **cryptocurrency-only** static GitHub Pages donation interface for **Bitcoin (BTC), Monero (XMR), and Ethereum (ETH)**. It is independent of the Docker/VPN runtime. **A public Bitcoin address is configured**; Monero and Ethereum remain unconfigured, and the interface is locked in preview mode.

> **Do not activate donations yet.** [Issue #10](https://github.com/beto-zip/web-scraping-firecrawl-vpn/issues/10) requires real deployment validation ([#6](https://github.com/beto-zip/web-scraping-firecrawl-vpn/issues/6)), resolution of material security/maintenance gaps, and a stable public release before publishing a donation call to action.

## Files

- `index.html`: accessible cryptocurrency selector with PT-BR/EN labels.
- `styles.css`: responsive layout with no CSS framework.
- `app.js`: browser-only wallet selection, QR rendering and address copy.
- `config.js`: **public** Bitcoin receiving address, an optional BTC payment-message label, empty XMR/ETH addresses and an explicit `stage` flag.

There is **no backend and no custody of funds**. Users send funds directly to a public wallet address with their own wallet app. Private keys and seed phrases are never required on this site.

## Preview locally

From the repository root:

```sh
python3 -m http.server 8000 --directory docs
```

Open `http://localhost:8000/donate/`. By design, wallet addresses, QR codes and the copy button remain disabled while `stage: "preview"`, even if receiving addresses are filled. The preview notice stays visible.

QRCode.js 1.0.0 (MIT) is loaded using a version-pinned Cloudflare CDN script with SRI. QR codes are generated **in the visitor's browser**, not by calling a third-party QR code generation service. When enabled, Bitcoin uses the BIP21 URI `bitcoin:bc1qnsv4070t2vxrxvlzfmdm82r8l7g8cyk2hzhztc?message=git` in the QR code, but the copy button uses the raw receiving address only. With the QR dependency unavailable, copying the configured public address will still work in live mode.

## Future activation (only after issue #10 prerequisites)

1. Complete the deployment validation and stable-release prerequisites. Decide how funds will be reported and who controls the receiving accounts.
2. Create **dedicated receiving addresses** for BTC, XMR and ETH as needed. Do not use a single wallet address across incompatible blockchains.
3. Keep the supplied BTC public receiving address current and add **only public receiving addresses** for any other supported networks in `config.js`; never commit seed phrases, private keys, API tokens, or credentials.
4. Independently verify the displayed address and associated network for every enabled coin. Check address validity and recipient control. Perform authorized low-value test payments before release.
5. Change `stage: "preview"` to `stage: "live"` only after review and the issue #10 release gate.
6. Enable GitHub Pages in **Settings → Pages → Build and deployment → Deploy from a branch → main → /docs → Save**, and confirm the published site at `https://beto-zip.github.io/web-scraping-firecrawl-vpn/donate/`. The URL is not active until Pages is configured and deployed.

## Security / scope

- Supported coins: Bitcoin **mainnet**, Monero **mainnet** and Ethereum **mainnet**. Do not use mismatched networks or token-specific contracts.
- The QR encodes the **public address** only, without requesting permissions or funds.
- Copying an address requires a secure context; GitHub Pages provides HTTPS.
- Contributions are entirely voluntary and confer no service SLA, priority, guaranteed access or security warranty.
- Not a payment processor or checkout service; **no fiat payments, PayPal, credit cards or subscriptions** are offered.
- Keep both README languages aligned.

**Status: prototype only. No donations are requested or accepted through this interface.**
