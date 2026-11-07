"use strict";

/* Static, browser-only donation interface. No payment details are collected. */
(() => {
  const config = window.DONATION_CONFIG || {};
  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];

  const dictionaries = {
    pt: {
      eyebrow: "COMUNIDADE OPEN SOURCE",
      title: "Ajude a manter o projeto em movimento.",
      lead: "Este software é gratuito. O apoio da comunidade poderá ajudar com infraestrutura, testes e documentação, sem mudar o acesso livre ao código.",
      previewNotice: "Prévia de interface. As doações não estão habilitadas. Esta página não solicita nem recebe pagamentos.",
      supportOptions: "FORMAS DE APOIO",
      selectMethod: "Selecione uma criptomoeda",
      selectedNetwork: "REDE SELECIONADA",
      onchain: "On-chain",
      publicAddress: "Endereço público para recebimento",
      qrTitle: "QR Code",
      qrPending: "Disponível quando a carteira oficial for configurada.",
      qrReady: "Escaneie para copiar o endereço público desta rede.",
      qrUnavailable: "O QR Code não carregou. Confira e copie o endereço exibido.",
      networkWarning: "Confira a rede e o endereço antes de enviar. Transações em blockchain podem ser irreversíveis.",
      whySupport: "Por que apoiar?",
      whyBody: "Este projeto é mantido de forma independente. Eventuais contribuições voluntárias serão destinadas a custos de manutenção, documentação e testes.",
      benefitOne: "Código aberto e gratuito",
      benefitTwo: "Sem obrigação de contribuir",
      benefitThree: "Sem privilégios ou suporte garantido",
      otherSupport: "Outras formas de apoiar",
      starsIssues: "Stars, issues e contribuições no GitHub",
      statusExplanation: "As doações permanecem em planejamento até a validação da implantação e uma versão estável.",
      viewRoadmap: "Ver planejamento →",
      notAffiliated: "Projeto independente. Não afiliado à Firecrawl ou Proton VPN.",
      addressPending: "Ainda não configurado",
      copyAddress: "Copiar endereço",
      copied: "Endereço copiado para a área de transferência.",
      copyError: "Não foi possível copiar. Selecione o endereço manualmente.",
      active: "Ativo",
      preview: "Prévia"
    },
    en: {
      eyebrow: "OPEN SOURCE COMMUNITY",
      title: "Keep this project moving forward.",
      lead: "This software is free. Community support may help cover infrastructure, testing and documentation while keeping the code freely accessible.",
      previewNotice: "Interface preview. Donations are not enabled. This page does not request or receive payments.",
      supportOptions: "SUPPORT OPTIONS",
      selectMethod: "Select a cryptocurrency",
      selectedNetwork: "SELECTED NETWORK",
      onchain: "On-chain",
      publicAddress: "Public receiving address",
      qrTitle: "QR code",
      qrPending: "Available after an official wallet is configured.",
      qrReady: "Scan to copy the public receiving address for this network.",
      qrUnavailable: "The QR code failed to load. Verify and copy the displayed address.",
      networkWarning: "Verify the network and receiving address before sending. Blockchain transactions may be irreversible.",
      whySupport: "Why support?",
      whyBody: "This project is maintained independently. Any voluntary contributions will go toward maintenance, documentation and testing costs.",
      benefitOne: "Free and open-source code",
      benefitTwo: "No contribution is required",
      benefitThree: "No privileges or guaranteed support",
      otherSupport: "Other ways to help",
      starsIssues: "Stars, issues and contributions on GitHub",
      statusExplanation: "Donations remain a future plan until deployment validation and a stable release.",
      viewRoadmap: "See roadmap →",
      notAffiliated: "Independent community project. Not affiliated with Firecrawl or Proton VPN.",
      addressPending: "Not configured yet",
      copyAddress: "Copy address",
      copied: "Address copied to clipboard.",
      copyError: "Unable to copy. Please select the address manually.",
      active: "Active",
      preview: "Preview"
    }
  };

  const methods = ["btc", "xmr", "eth"];
  const state = {
    language: (navigator.language || "").toLowerCase().startsWith("pt") ? "pt" : "en",
    method: "btc"
  };
  const anyWalletConfigured = ["btc", "xmr", "eth"].some((coin) =>
    !!String(config.wallets?.[coin]?.address || "").trim()
  );
  const isLive = config.stage === "live" && anyWalletConfigured;

  function dictionary() {
    return dictionaries[state.language];
  }

  function changeLanguage() {
    document.documentElement.lang = state.language === "pt" ? "pt-BR" : "en";
    document.title = state.language === "pt"
      ? "Apoie o projeto · Firecrawl over Proton VPN"
      : "Support the project · Firecrawl over Proton VPN";
    $$("[data-i18n]").forEach((element) => {
      const translation = dictionary()[element.dataset.i18n];
      if (translation !== undefined) element.textContent = translation;
    });
    $("#languageButton").textContent = state.language === "pt" ? "EN" : "PT";
    $("#languageButton").setAttribute("aria-label", state.language === "pt" ? "Change language to English" : "Mudar idioma para português");
    $("#walletAddress").placeholder = dictionary().addressPending;
    $("#copyAddress").setAttribute("aria-label", dictionary().copyAddress);
    $("#copyAddress").title = dictionary().copyAddress;
    $("#stageBadge").textContent = isLive ? dictionary().active : dictionary().preview;
    $("#stageBadge").classList.toggle("live", isLive);
    $("#previewNotice").hidden = isLive;
    $("#copyFeedback").textContent = "";
    render();
  }

  function render() {
    $(".method").forEach((button) => {
      const selected = button.dataset.method === state.method;
      button.classList.toggle("active", selected);
      button.setAttribute("aria-pressed", String(selected));
    });
    renderCrypto();
  }

  function renderCrypto() {
    const wallet = config.wallets?.[state.method] || {};
    const address = typeof wallet.address === "string" ? wallet.address.trim() : "";
    const enabled = isLive && address.length > 0;
    const fallbackNames = { btc: "Bitcoin (BTC)", xmr: "Monero (XMR)", eth: "Ethereum Mainnet (ETH)" };

    $("#networkName").textContent = wallet.network || fallbackNames[state.method];
    $("#walletAddress").value = enabled ? address : "";
    $("#copyAddress").disabled = !enabled;

    const qrNode = $("#qrCode");
    qrNode.replaceChildren();
    $("#qrDescription").textContent = dictionary().qrPending;

    if (enabled && typeof window.QRCode === "function") {
      try {
        new window.QRCode(qrNode, {
          text: address,
          width: 160,
          height: 160,
          colorDark: "#172440",
          colorLight: "#ffffff",
          correctLevel: window.QRCode.CorrectLevel.M
        });
        $("#qrDescription").textContent = dictionary().qrReady;
        return;
      } catch {
        // Address copying remains available even if QR rendering fails.
      }
    }
    const placeholder = document.createElement("span");
    placeholder.className = "qr-placeholder";
    placeholder.setAttribute("aria-hidden", "true");
    placeholder.textContent = "▦";
    qrNode.appendChild(placeholder);
    if (enabled) $("#qrDescription").textContent = dictionary().qrUnavailable;
  }

  $(".method").forEach((button) => button.addEventListener("click", () => {
    if (!methods.includes(button.dataset.method)) return;
    state.method = button.dataset.method;
    $("#copyFeedback").textContent = "";
    render();
  }));

  $("#copyAddress").addEventListener("click", async () => {
    const address = $("#walletAddress").value;
    if (!isLive || !address) return;
    try {
      await navigator.clipboard.writeText(address);
      $("#copyFeedback").textContent = dictionary().copied;
    } catch {
      $("#walletAddress").select();
      $("#copyFeedback").textContent = dictionary().copyError;
    }
  });

  $("#languageButton").addEventListener("click", () => {
    state.language = state.language === "pt" ? "en" : "pt";
    changeLanguage();
  });

  $("#currentYear").textContent = new Date().getFullYear();
  changeLanguage();
})();
