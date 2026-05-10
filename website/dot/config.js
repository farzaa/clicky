// Public, non-secret runtime config for the Dot website.
window.DOT_CONFIG = {
  // Central identity service. Sign-in, /auth/me, /admin/* live here. Same
  // for every Vibe Research project.
  vibeIdBaseURL: "https://api.accounts.vibe-research.net",

  // Per-project inference proxy. Currently only the macOS app talks to this
  // directly; kept here in case the website later needs to call /chat or /tts.
  workerBaseURL: "https://api.dot.vibe-research.net",

  // The latest macOS download. Replace once you cut a real release on GitHub.
  downloadDmgURL: "https://github.com/Clamepending/dot/releases/latest/download/Dot.dmg",

  githubURL: "https://github.com/Clamepending/dot",
};
