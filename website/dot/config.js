// Public, non-secret runtime config for the Dot website.
// Update before deploying to production.
window.DOT_CONFIG = {
  // The Cloudflare Worker base URL. Same origin is fine if you host the site
  // behind the same Worker — separate subdomain is recommended.
  workerBaseURL: "https://api.dot.vibe-research.net",

  // The latest macOS download. Replace once you cut a real release.
  downloadDmgURL: "https://github.com/REPLACE_WITH_YOUR_GITHUB/dot/releases/latest/download/Dot.dmg",

  // Where to send users from the "Open Source" link.
  githubURL: "https://github.com/REPLACE_WITH_YOUR_GITHUB/dot",
};
