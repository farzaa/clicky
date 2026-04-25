/* Account / receipt pages
 *
 * Personalize the success page based on URL parameters. Stripe gives
 * us `?session_id=…` for free; the worker (worker/src/index.ts) is
 * also configured to append `&theme=<id>` and/or `&credits=<n>` via
 * its `success_url` query so we can render the right copy without
 * round-tripping to the API.
 *
 * Falls back gracefully — if the URL has nothing, we keep the default
 * "You're in." with Jade as the messenger.
 */
(function () {
  "use strict";

  const SENSEI = {
    jade: {
      name: "Jade",
      kana: "ジェイド",
      portrait: "/assets/characters/jade-card.png",
      headline: "Welcome to the desk.",
      themeKana: "ありがとう",
    },
    sakura: {
      name: "Sakura",
      kana: "さくら",
      portrait: "/assets/characters/sakura-card.png",
      headline: "Sakura is yours.",
      themeKana: "やった！",
    },
    akane: {
      name: "Akane",
      kana: "あかね",
      portrait: "/assets/characters/teacher-card.png",
      headline: "Akane is yours.",
      themeKana: "ありがとう",
    },
    oliver: {
      name: "Oliver",
      kana: "オリバー",
      portrait: "/assets/characters/oliver-card.png",
      headline: "Oliver is yours.",
      themeKana: "よろしく",
    },
    scooter: {
      name: "Scooter",
      kana: "スクーター",
      portrait: "/assets/characters/scooter-card.png",
      headline: "Scooter is yours.",
      themeKana: "ありがとう",
    },
  };

  function $(sel) { return document.querySelector(sel); }
  function setText(node, value) { if (node) node.textContent = value; }

  const params = new URLSearchParams(location.search);
  const themeID = (params.get("theme") || "").toLowerCase();
  const creditsRaw = params.get("credits");
  const credits = creditsRaw ? parseInt(creditsRaw, 10) : null;

  const receipt = $(".receipt");
  if (!receipt) return;

  // Default messenger is Jade — she's the launch starter so any
  // generic credits purchase still has a familiar face attached.
  let messenger = SENSEI.jade;
  let stampLabelEN = "PAID";
  let stampLabelJP = "承";
  let headline = "You're in.";
  let kana = "ありがとう";
  let bodyHTML = `
    <p>
      Your purchase is complete. Open the app and you'll find it
      waiting for you on the home screen.
    </p>
  `;

  if (themeID && SENSEI[themeID]) {
    // Theme purchase — the unlocked sensei is the messenger so the
    // page reads like she's introducing herself to the user.
    messenger = SENSEI[themeID];
    headline = messenger.headline;
    kana = messenger.themeKana;
    stampLabelEN = "UNLOCKED";
    stampLabelJP = "解";
    bodyHTML = `
      <p>
        Welcome, sensei <em>${messenger.name}</em> is yours forever — no
        subscription, no expiry. Open the app and pick her from the
        teachers tab to switch.
      </p>
    `;
    receipt.dataset.theme = themeID;
  } else if (credits && credits > 0) {
    // Credits top-up — keep Jade as the messenger (she's the host)
    // but lead with the number.
    headline = `${credits.toLocaleString()} credits added.`;
    kana = "チャージ完了";
    stampLabelEN = "CREDITED";
    stampLabelJP = "充";
    bodyHTML = `
      <p>
        Your wallet now has <em>${credits.toLocaleString()} more
        credits</em> to spend on guidance. Open the app and ask away —
        the new balance is already live.
      </p>
    `;
    receipt.dataset.theme = "jade";
  } else {
    receipt.dataset.theme = "jade";
  }

  // Apply
  const portrait = $("[data-portrait]");
  if (portrait) {
    portrait.src = messenger.portrait;
    portrait.alt = `${messenger.name}, your AI Sensei 3000 teacher`;
  }
  const portraitCaption = $("[data-portrait-caption]");
  if (portraitCaption) {
    portraitCaption.innerHTML =
      `${messenger.name} <span aria-hidden="true">✿</span> ${messenger.kana}`;
  }
  setText($("[data-from-name]"), messenger.name);
  setText($("[data-headline]"), headline);
  setText($("[data-kana]"), kana);

  const body = $("[data-body]");
  if (body) body.innerHTML = bodyHTML;

  const stamp = $("[data-stamp]");
  if (stamp) {
    const lines = stamp.querySelectorAll(".receipt-stamp-line");
    if (lines[0]) lines[0].textContent = stampLabelJP;
    if (lines[1]) lines[1].textContent = stampLabelEN;
  }

  // Auto-attempt the deep link after a beat. If the user has the
  // desktop app installed, this brings it to the front (and Safari
  // happily ignores it when it's not registered). The visible CTA
  // stays as the explicit fallback.
  if (themeID || credits) {
    setTimeout(() => {
      try { window.location.href = "aisensei3000://account"; } catch (_) {}
    }, 1200);
  }
})();
