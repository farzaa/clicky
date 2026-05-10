// Public, non-secret runtime config for the Dot website.
// Update before deploying to production.
window.DOT_CONFIG = {
  // The Cloudflare Worker base URL. Same origin is fine if you host the site
  // behind the same Worker — separate subdomain is recommended.
  workerBaseURL: "https://api.dot.vibe-research.net",

  // The latest macOS download. Replace once you cut a real release on GitHub.
  // Until then, friends can only run dev builds via the install script in the repo.
  downloadDmgURL: "https://github.com/Clamepending/dot/releases/latest/download/Dot.dmg",

  // Where to send users from the "Open Source" link.
  githubURL: "https://github.com/Clamepending/dot",
};
