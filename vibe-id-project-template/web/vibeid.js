// vibeid.js — drop-in JS SDK for vibe-id-powered web pages.
//
// Usage:
//   <script src="vibeid.js"></script>
//   <script>
//     VibeId.configure({
//       projectId: "myproject",
//       vibeIdBaseURL: "https://api.accounts.vibe-research.net",
//     });
//     // On page load, this restores any prior sign-in from localStorage,
//     // consumes a sign-in callback fragment if present, and returns the
//     // current state.
//     VibeId.bootstrap().then((state) => {
//       if (state.signedIn) renderSignedIn(state);
//       else renderSignedOut();
//     });
//
//     // Sign-in: redirects to vibe-id, comes back with #token=… in URL.
//     // bootstrap() picks that up automatically on the next load.
//     document.getElementById("signInButton").onclick = () => {
//       window.location.href = VibeId.signInUrl({ returnTo: window.location.href });
//     };
//
//     document.getElementById("signOutButton").onclick = async () => {
//       await VibeId.signOut();
//       location.reload();
//     };
//   </script>

(function (global) {
  "use strict";

  let configuredVibeIdBaseURL = "";
  let configuredProjectId = "";

  const TOKEN_STORAGE_KEY_PREFIX = "vibeId.installToken.";
  const EMAIL_STORAGE_KEY_PREFIX = "vibeId.email.";

  function configure(configObject) {
    configuredVibeIdBaseURL = (configObject.vibeIdBaseURL || "").replace(/\/$/, "");
    configuredProjectId = configObject.projectId || "";
  }

  function tokenStorageKey() { return TOKEN_STORAGE_KEY_PREFIX + configuredProjectId; }
  function emailStorageKey() { return EMAIL_STORAGE_KEY_PREFIX + configuredProjectId; }

  /** Build the URL the user's browser should navigate to for sign-in. */
  function signInUrl(options) {
    options = options || {};
    return configuredVibeIdBaseURL +
      "/auth/start?project=" + encodeURIComponent(configuredProjectId) +
      "&return_to=" + encodeURIComponent(options.returnTo || window.location.href);
  }

  /**
   * Pull token + email out of the URL fragment (set by /auth/callback)
   * on first arrival, then strip them so they don't sit in the address bar.
   * Idempotent — safe to call on every page load.
   */
  function consumeAuthCallbackFragmentIfPresent() {
    if (!window.location.hash) return;
    const fragmentParameters = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    const receivedToken = fragmentParameters.get("token");
    const receivedEmail = fragmentParameters.get("email");
    if (receivedToken) {
      localStorage.setItem(tokenStorageKey(), receivedToken);
      if (receivedEmail) localStorage.setItem(emailStorageKey(), receivedEmail);
      history.replaceState(null, "", window.location.pathname + window.location.search);
    }
  }

  /** Returns the current install token, or null if signed out. */
  function currentInstallToken() {
    return localStorage.getItem(tokenStorageKey());
  }

  /** Calls vibe-id /auth/me and returns the parsed payload, or null if 401. */
  async function fetchAccount() {
    const installToken = currentInstallToken();
    if (!installToken) return null;
    const response = await fetch(configuredVibeIdBaseURL + "/auth/me", {
      headers: { authorization: "Bearer " + installToken },
    });
    if (response.status === 401) {
      localStorage.removeItem(tokenStorageKey());
      return null;
    }
    if (!response.ok) {
      throw new Error("vibe-id /auth/me returned " + response.status);
    }
    return response.json();
  }

  /** Best-effort sign-out: revokes server-side, clears local. */
  async function signOut() {
    const installToken = currentInstallToken();
    if (installToken) {
      try {
        await fetch(configuredVibeIdBaseURL + "/auth/signout", {
          method: "POST",
          headers: { authorization: "Bearer " + installToken },
        });
      } catch (_ignored) { /* network failure is fine — clear locally anyway */ }
    }
    localStorage.removeItem(tokenStorageKey());
    localStorage.removeItem(emailStorageKey());
  }

  /**
   * One-call page bootstrap. Consumes any callback fragment, then either
   * fetches /auth/me or returns a signed-out marker.
   *
   * Returns: { signedIn: boolean, account?: AuthMeResponse, error?: string }
   */
  async function bootstrap() {
    if (!configuredVibeIdBaseURL || !configuredProjectId) {
      return { signedIn: false, error: "VibeId.configure({ vibeIdBaseURL, projectId }) not called" };
    }
    consumeAuthCallbackFragmentIfPresent();
    try {
      const account = await fetchAccount();
      if (account) return { signedIn: true, account };
      return { signedIn: false };
    } catch (error) {
      return { signedIn: false, error: error.message };
    }
  }

  global.VibeId = {
    configure,
    signInUrl,
    currentInstallToken,
    fetchAccount,
    signOut,
    bootstrap,
  };
})(typeof window !== "undefined" ? window : this);
