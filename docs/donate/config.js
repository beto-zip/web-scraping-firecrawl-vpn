/*
 * PUBLIC website configuration (not a secret store).
 * All fields below are intentionally empty.
 *
 * Keep stage: "preview" until issue #10 release prerequisites are met.
 * To activate later, set stage: "live" AND configure real receiving accounts.
 * NEVER add private wallet keys, seed phrases, API tokens or passwords here.
 *
 * Each PayPal URL must be a real payment link that matches its displayed USD
 * amount and frequency. "Monthly" / "Yearly" require genuine subscription
 * links, not a generic PayPal.Me link.
 */
window.DONATION_CONFIG = Object.freeze({
  stage: "preview", // "preview" | "live"
  wallets: {
    btc: { address: "", network: "Bitcoin (BTC)" },
    xmr: { address: "", network: "Monero (XMR)" },
    eth: { address: "", network: "Ethereum Mainnet (ETH)" }
  },
  paypal: {
    once: { "5": "", "10": "", "25": "", "50": "" },
    monthly: { "5": "", "10": "", "25": "", "50": "" },
    yearly: { "5": "", "10": "", "25": "", "50": "" }
  }
});
