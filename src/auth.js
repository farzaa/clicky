// Auth module — OIDC flow, token exchange, and expiry tracking.

/** @type {number|null} */
let refreshTimer = null;

/** @type {string|null} */
let currentToken = null;

/**
 * Get the stored token, or null if not found.
 * @returns {Promise<string|null>}
 */
export async function getToken() {
  if (currentToken) return currentToken;
  if (!window.__TAURI__) return localStorage.getItem("companion_token");

  const stored = await window.__TAURI__.core.invoke("keyring_read", { key: "openbao_token" });
  if (stored) currentToken = stored;
  return stored;
}

/**
 * Check if we have a valid token. Tries to use the stored token.
 * Returns the token if valid, null otherwise.
 * @returns {Promise<string|null>}
 */
export async function checkAuth() {
  const token = await getToken();
  if (!token) return null;

  const expiresAt = localStorage.getItem("token_expires_at");
  if (expiresAt && Date.now() > parseInt(expiresAt, 10)) {
    await clearToken();
    return null;
  }

  return token;
}

/**
 * Run the interactive OIDC flow:
 * 1. Open browser to Authentik
 * 2. Get auth code via localhost callback
 * 3. Exchange code for OIDC id_token
 * 4. Exchange id_token for OpenBao token via Sewa
 * 5. Store token and schedule expiry handling
 *
 * @returns {Promise<string>} The OpenBao token
 */
export async function authenticate() {
  const authentikUrl = localStorage.getItem("authentik_url") || "https://auth.1-800-goobsquire.lol";
  const sewaUrl = localStorage.getItem("sewa_url") || "wss://sewa-prod.1-800-goobsquire.lol";
  const clientId = "sewa-companion";
  const redirectPath = "/callback";

  const authorizeUrl = `${authentikUrl}/application/o/authorize/?`;

  // Step 1: OIDC flow — opens browser, waits for callback
  const result = await window.__TAURI__.core.invoke("start_oidc_flow", {
    authorizeUrl,
    clientId,
    redirectPath,
  });

  // Step 2: Exchange auth code for OIDC tokens with Authentik
  const httpSewaUrl = sewaUrl.replace(/^wss:/, "https:").replace(/^ws:/, "http:");
  const tokenResponse = await fetch(`${authentikUrl}/application/o/token/`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: result.code,
      redirect_uri: `http://127.0.0.1:${result.port || 0}${redirectPath}`,
      client_id: clientId,
    }),
  });

  if (!tokenResponse.ok) {
    throw new Error(`Authentik token exchange failed: ${tokenResponse.status}`);
  }

  const tokenData = await tokenResponse.json();
  const idToken = tokenData.id_token;

  if (!idToken) {
    throw new Error("No id_token in Authentik response");
  }

  // Step 3: Exchange id_token for OpenBao token via Sewa
  const sewaResponse = await fetch(`${httpSewaUrl}/api/companion/token`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ oidc_token: idToken }),
  });

  if (!sewaResponse.ok) {
    const err = await sewaResponse.json().catch(() => ({}));
    throw new Error(`Sewa token exchange failed: ${err.error || sewaResponse.status}`);
  }

  const sewaData = await sewaResponse.json();
  const openbaoToken = sewaData.token;
  const expiresIn = sewaData.expires_in;

  // Step 4: Store token
  await storeToken(openbaoToken, expiresIn);

  return openbaoToken;
}

async function storeToken(token, expiresIn) {
  currentToken = token;

  if (window.__TAURI__) {
    await window.__TAURI__.core.invoke("keyring_store", {
      key: "openbao_token",
      value: token,
    });
  } else {
    localStorage.setItem("companion_token", token);
  }

  const expiresAt = Date.now() + expiresIn * 1000;
  localStorage.setItem("token_expires_at", String(expiresAt));

  scheduleTokenExpiry(expiresIn);
}

export function scheduleTokenExpiry(expiresIn, onExpired = () => {}) {
  if (refreshTimer) clearTimeout(refreshTimer);
  const refreshInMs = Math.max((expiresIn - 60) * 1000, 10_000);
  refreshTimer = setTimeout(async () => {
    try {
      await clearToken();
      onExpired();
      console.warn("[auth] Token expired; re-authentication is required before the next reconnect.");
    } catch (err) {
      console.error("[auth] Failed to clear expired auth state:", err);
      currentToken = null;
    }
  }, refreshInMs);

  return refreshTimer;
}

export async function clearToken() {
  currentToken = null;
  if (refreshTimer) {
    clearTimeout(refreshTimer);
    refreshTimer = null;
  }
  localStorage.removeItem("token_expires_at");

  if (window.__TAURI__) {
    await window.__TAURI__.core.invoke("keyring_delete", { key: "openbao_token" });
  } else {
    localStorage.removeItem("companion_token");
  }
}

export async function initAuth(onExpired) {
  const token = await checkAuth();
  if (token) {
    const expiresAt = localStorage.getItem("token_expires_at");
    if (expiresAt) {
      const remainingSec = Math.floor((parseInt(expiresAt, 10) - Date.now()) / 1000);
      if (remainingSec > 60) {
        scheduleTokenExpiry(remainingSec, onExpired);
      }
    }
    return token;
  }
  return null;
}
