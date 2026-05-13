// Public, non-secret runtime config for the Dot website.
window.DOT_CONFIG = {
  // Central identity service. Sign-in, /auth/me, /admin/* live here. Same
  // for every Vibe Research project.
  vibeIdBaseURL: "https://api.accounts.vibe-research.net",

  // Same central service also fronts Dot inference endpoints when needed.
  workerBaseURL: "https://api.accounts.vibe-research.net",

  // The latest macOS download. Replace once you cut a real release on GitHub.
  downloadDmgURL: "https://github.com/Clamepending/dot/releases/latest/download/Dot.dmg",

  githubURL: "https://github.com/Clamepending/dot",
};
