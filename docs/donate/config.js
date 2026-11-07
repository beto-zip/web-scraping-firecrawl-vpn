/*
 * PUBLIC website configuration (not a secret store).
 * Only a public Bitcoin receiving address has been supplied. Other networks remain empty.
 *
 * Keep stage: "preview" until issue #10 release prerequisites are met.
 * To activate later, set stage: "live" AND configure real receiving accounts.
 * NEVER add private wallet keys, seed phrases, API tokens or passwords here.
 *
 * The page accepts only direct cryptocurrency donations (BTC, XMR, ETH).
 */
window.DONATION_CONFIG = Object.freeze({
  stage: "preview", // "preview" | "live"
  wallets: {
    btc: { address: "bc1qnsv4070t2vxrxvlzfmdm82r8l7g8cyk2hzhztc", network: "Bitcoin (BTC)", message: "git" },
    xmr: { address: "", network: "Monero (XMR)" },
    eth: { address: "", network: "Ethereum Mainnet (ETH)" }
  }
});
