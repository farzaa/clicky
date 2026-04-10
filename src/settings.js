// Settings module — persistence, device enumeration, hotkey recording, Tauri bindings

const DEFAULTS = {
  sewa_url: "wss://sewa-prod.1-800-goobsquire.lol",
  authentik_url: "https://auth.1-800-goobsquire.lol",
  screenshot_quality: "80",
  overlay_dismiss_timeout: "5",
  auto_capture: "true",
  animation_speed: "normal",
  audio_input: "",
  audio_output: "",
};

let reauthenticateCallback = null;

// ---------------------------------------------------------------------------
// Persistence helpers
// ---------------------------------------------------------------------------

function getSetting(key) {
  return localStorage.getItem(key) ?? DEFAULTS[key] ?? "";
}

function setSetting(key, value) {
  localStorage.setItem(key, value);
}

// ---------------------------------------------------------------------------
// Initialise all form fields from localStorage
// ---------------------------------------------------------------------------

function loadSettings() {
  const sewaUrl = document.getElementById("setting-sewa-url");
  const authentikUrl = document.getElementById("setting-authentik-url");
  const qualitySlider = document.getElementById("setting-screenshot-quality");
  const dismissSlider = document.getElementById("setting-dismiss-timeout");
  const autoCapture = document.getElementById("setting-auto-capture");

  if (sewaUrl) sewaUrl.value = getSetting("sewa_url");
  if (authentikUrl) authentikUrl.value = getSetting("authentik_url");
  if (qualitySlider) {
    qualitySlider.value = getSetting("screenshot_quality");
    updateQualityDisplay(qualitySlider.value);
  }
  if (dismissSlider) {
    dismissSlider.value = getSetting("overlay_dismiss_timeout");
    updateDismissDisplay(dismissSlider.value);
  }
  if (autoCapture) {
    autoCapture.checked = getSetting("auto_capture") !== "false";
  }

  // Animation speed buttons
  const savedSpeed = getSetting("animation_speed");
  document.querySelectorAll(".speed-btn").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.speed === savedSpeed);
  });
}

// ---------------------------------------------------------------------------
// Device enumeration
// ---------------------------------------------------------------------------

async function populateDevices() {
  const inputSelect = document.getElementById("setting-audio-input");
  const outputSelect = document.getElementById("setting-audio-output");
  if (!inputSelect || !outputSelect) return;

  try {
    // Request permission so labels are populated
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    stream.getTracks().forEach((t) => t.stop());
  } catch {
    // Permission denied — enumerate anyway, labels may be empty
  }

  let devices = [];
  try {
    devices = await navigator.mediaDevices.enumerateDevices();
  } catch {
    return;
  }

  const savedInput = getSetting("audio_input");
  const savedOutput = getSetting("audio_output");

  inputSelect.innerHTML = "";
  outputSelect.innerHTML = "";

  const addOption = (select, device, saved) => {
    const opt = document.createElement("option");
    opt.value = device.deviceId;
    opt.textContent = device.label || `Device ${device.deviceId.slice(0, 8)}`;
    if (device.deviceId === saved) opt.selected = true;
    select.appendChild(opt);
  };

  devices.forEach((d) => {
    if (d.kind === "audioinput") addOption(inputSelect, d, savedInput);
    if (d.kind === "audiooutput") addOption(outputSelect, d, savedOutput);
  });
}

// ---------------------------------------------------------------------------
// Slider display helpers
// ---------------------------------------------------------------------------

function updateQualityDisplay(value) {
  const span = document.getElementById("quality-value");
  if (span) span.textContent = (parseInt(value, 10) / 100).toFixed(2);
}

function updateDismissDisplay(value) {
  const span = document.getElementById("dismiss-value");
  if (span) span.textContent = `${value}s`;
}

// ---------------------------------------------------------------------------
// Autostart (Tauri)
// ---------------------------------------------------------------------------

async function loadAutostartState() {
  const checkbox = document.getElementById("setting-autostart");
  if (!checkbox) return;

  try {
    const enabled = await window.__TAURI__?.core.invoke("get_autostart_enabled");
    checkbox.checked = !!enabled;
  } catch {
    checkbox.checked = false;
  }
}

async function setAutostart(enabled) {
  try {
    await window.__TAURI__?.core.invoke("set_autostart_enabled", { enabled });
  } catch {
    // Not available in non-Tauri context — ignore
  }
}

// ---------------------------------------------------------------------------
// Event binding
// ---------------------------------------------------------------------------

function bindEvents() {
  // Close button
  document.getElementById("settings-close")?.addEventListener("click", () => {
    toggleSettings(false);
  });

  // Re-authenticate button
  document.getElementById("btn-reauth")?.addEventListener("click", () => {
    if (typeof reauthenticateCallback === "function") reauthenticateCallback();
  });

  // URL fields — persist on change
  document.getElementById("setting-sewa-url")?.addEventListener("change", (e) => {
    setSetting("sewa_url", e.target.value.trim());
  });

  document.getElementById("setting-authentik-url")?.addEventListener("change", (e) => {
    setSetting("authentik_url", e.target.value.trim());
  });

  // Screenshot quality slider
  const qualitySlider = document.getElementById("setting-screenshot-quality");
  qualitySlider?.addEventListener("input", (e) => {
    updateQualityDisplay(e.target.value);
    setSetting("screenshot_quality", e.target.value);
  });

  // Dismiss timeout slider
  const dismissSlider = document.getElementById("setting-dismiss-timeout");
  dismissSlider?.addEventListener("input", (e) => {
    updateDismissDisplay(e.target.value);
    setSetting("overlay_dismiss_timeout", e.target.value);
  });

  // Auto-capture toggle
  document.getElementById("setting-auto-capture")?.addEventListener("change", (e) => {
    setSetting("auto_capture", e.target.checked ? "true" : "false");
  });

  // Autostart toggle
  document.getElementById("setting-autostart")?.addEventListener("change", (e) => {
    setAutostart(e.target.checked);
  });

  // Animation speed buttons
  document.querySelectorAll(".speed-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".speed-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      setSetting("animation_speed", btn.dataset.speed);
    });
  });

  // Audio device selects — persist on change
  document.getElementById("setting-audio-input")?.addEventListener("change", (e) => {
    setSetting("audio_input", e.target.value);
  });

  document.getElementById("setting-audio-output")?.addEventListener("change", (e) => {
    setSetting("audio_output", e.target.value);
  });
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Show or hide the settings panel.
 * @param {boolean} [show] — pass true/false to force, omit to toggle
 */
export function toggleSettings(show) {
  const panel = document.getElementById("settings-panel");
  if (!panel) return;

  const shouldShow = typeof show === "boolean" ? show : panel.classList.contains("hidden");
  panel.classList.toggle("hidden", !shouldShow);
}

/**
 * Update the authentication status display in the settings panel.
 * @param {"authenticated"|"unauthenticated"} status
 * @param {string} [user] — display name / email when authenticated
 */
export function updateAuthStatus(status, user) {
  const el = document.getElementById("auth-status");
  if (!el) return;

  el.className = `auth-status ${status}`;
  if (status === "authenticated" && user) {
    el.textContent = `Signed in as ${user}`;
  } else if (status === "authenticated") {
    el.textContent = "Authenticated";
  } else {
    el.textContent = "Not authenticated";
  }
}

/**
 * Initialise the settings module.
 * Must be called after the settings HTML fragment has been injected into the DOM.
 *
 * @param {{ onReauthenticate?: () => void }} [opts]
 */
export async function init(opts = {}) {
  reauthenticateCallback = opts.onReauthenticate ?? null;

  loadSettings();
  bindEvents();
  await populateDevices();
  await loadAutostartState();
}
