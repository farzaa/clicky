// Sewa Companion — main orchestrator
// Wires auth, voice, screenshot, settings, reconnection, and chat together.

import { initAuth, getToken, authenticate, checkAuth, clearToken } from "./auth.js";
import {
  configure as configureVoice,
  startListening,
  stopListening,
  handleVoiceEvent,
  joinVoiceChannel,
  leaveVoiceChannel,
  stopTts,
} from "./voice.js";
import { init as initSettings, toggleSettings, updateAuthStatus } from "./settings.js";

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/** @type {WebSocket|null} */
let socket = null;
/** @type {string|null} */
let chatJoinRef = null;
let msgRef = 0;

/** @type {number|null} */
let heartbeatInterval = null;
let missedHeartbeats = 0;

let reconnectDelay = 1000;
const MAX_RECONNECT_DELAY = 30000;
/** @type {number|null} */
let reconnectTimer = null;

/** @type {Array<string>} */
const messageQueue = [];
const MAX_QUEUED = 10;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function nextRef() {
  return String(++msgRef);
}

function setStatus(state) {
  const dot = document.querySelector(".status-dot");
  const text = document.getElementById("status-text");
  const voiceIndicator = document.getElementById("voice-indicator");

  if (dot) dot.className = `status-dot ${state}`;
  if (text) text.textContent = state.charAt(0).toUpperCase() + state.slice(1);

  // Show voice indicator only when listening or processing
  if (voiceIndicator) {
    if (state === "listening" || state === "processing") {
      voiceIndicator.classList.remove("hidden");
      voiceIndicator.className = `voice-indicator ${state}`;
    } else {
      voiceIndicator.classList.add("hidden");
    }
  }
}

function addMessage(msg) {
  const container = document.getElementById("messages");
  if (!container) return;

  const el = document.createElement("div");
  el.className = `message ${msg.role || "system"}`;
  el.innerHTML = `
    <div>${escapeHtml(msg.content || "")}</div>
    <div class="source">${escapeHtml(msg.source || "")}</div>
  `;
  container.appendChild(el);
  container.scrollTop = container.scrollHeight;
}

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

// ---------------------------------------------------------------------------
// Pointer overlay
// ---------------------------------------------------------------------------

function handlePointerEvent(payload) {
  if (!window.__TAURI__ || !payload || !payload.instructions) return;

  // Group instructions by target screen
  const byScreen = new Map();
  for (const instr of payload.instructions) {
    if (instr.type === "chain" && instr.steps) {
      const screen = instr.steps[0]?.screen ?? 0;
      if (!byScreen.has(screen)) byScreen.set(screen, []);
      byScreen.get(screen).push(instr);
    } else {
      const screen = instr.screen ?? 0;
      if (!byScreen.has(screen)) byScreen.set(screen, []);
      byScreen.get(screen).push(instr);
    }
  }

  for (const [screen, instructions] of byScreen) {
    window.__TAURI__.core.invoke("show_overlay", { screen });
    window.__TAURI__.event.emitTo(`overlay-${screen}`, "pointer-instructions", {
      instructions,
    });
  }
}

// ---------------------------------------------------------------------------
// Screenshot capture + upload
// ---------------------------------------------------------------------------

async function captureAndUploadScreenshot() {
  if (!window.__TAURI__) return;

  try {
    const quality = parseInt(localStorage.getItem("screenshot_quality") || "80", 10);
    const imageData = await window.__TAURI__.core.invoke("capture_screenshot", {
      quality,
    });

    if (!imageData) return;

    const token = await getToken();
    if (!token) return;

    const sewaUrl = localStorage.getItem("sewa_url") || "wss://sewa-prod.1-800-goobsquire.lol";
    const httpUrl = sewaUrl.replace(/^wss:/, "https:").replace(/^ws:/, "http:");

    // imageData is a base64-encoded JPEG — decode to bytes for raw upload
    const binary = atob(imageData);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }

    await fetch(`${httpUrl}/api/companion/screen`, {
      method: "POST",
      headers: {
        "Content-Type": "image/jpeg",
        Authorization: `Bearer ${token}`,
      },
      body: bytes,
    });
  } catch (err) {
    console.error("[main] Screenshot capture/upload failed:", err);
  }
}

// ---------------------------------------------------------------------------
// WebSocket connection
// ---------------------------------------------------------------------------

async function connect() {
  // Clean up any pending reconnect
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  // Ensure we have a token
  let token = await getToken();
  if (!token) {
    try {
      token = await authenticate();
    } catch (err) {
      console.error("[main] Auth failed during connect:", err);
      setStatus("disconnected");
      updateAuthStatus("unauthenticated");
      scheduleReconnect();
      return;
    }
  }

  const sewaUrl = localStorage.getItem("sewa_url") || "wss://sewa-prod.1-800-goobsquire.lol";
  const url = `${sewaUrl}/socket/companion/websocket?token=${encodeURIComponent(token)}&vsn=2.0.0`;

  setStatus("connecting");

  // Close existing socket if any
  if (socket) {
    try {
      socket.onclose = null; // Prevent reconnect from old socket
      socket.close();
    } catch {
      // ignore
    }
  }

  socket = new WebSocket(url);

  socket.onopen = () => {
    // Join companion:chat channel
    chatJoinRef = nextRef();
    const joinMsg = [chatJoinRef, nextRef(), "companion:chat", "phx_join", {}];
    socket.send(JSON.stringify(joinMsg));

    // Join voice channel so it is ready for push-to-talk
    joinVoiceChannel(socket, nextRef);

    startHeartbeat();
  };

  socket.onmessage = (event) => {
    const [joinRef, _ref, topic, eventName, payload] = JSON.parse(event.data);

    // --- Chat channel join reply ---
    if (eventName === "phx_reply" && joinRef === chatJoinRef && topic === "companion:chat") {
      if (payload.status === "ok") {
        setStatus("connected");
        reconnectDelay = 1000; // Reset backoff on successful join
        updateAuthStatus("authenticated");

        // Render any messages from join response (history)
        const messages = payload.response?.messages || [];
        messages.forEach(addMessage);

        // Flush queued messages
        flushMessageQueue();
      } else if (payload.response?.reason === "unauthorized" || payload.status === "error") {
        handleAuthFailure();
      } else {
        setStatus("disconnected");
        scheduleReconnect();
      }
      return;
    }

    // --- Heartbeat reply resets missed count ---
    if (eventName === "phx_reply" && topic === "phoenix") {
      missedHeartbeats = 0;
      return;
    }

    // --- Chat events ---
    if (topic === "companion:chat") {
      if (eventName === "new_message") {
        addMessage(payload);
      } else if (eventName === "pointer") {
        handlePointerEvent(payload);
      }
      return;
    }

    // --- Voice events ---
    if (topic === "companion:voice") {
      if (eventName === "phx_reply") {
        if (payload.status !== "ok") {
          console.error("[voice] Channel join failed:", payload.response);
        }
        return;
      }
      handleVoiceEvent(eventName, payload);
      return;
    }
  };

  socket.onclose = (event) => {
    setStatus("disconnected");
    stopHeartbeat();

    // Code 4001 or 4003 typically indicate auth rejection
    if (event.code === 4001 || event.code === 4003) {
      handleAuthFailure();
    } else {
      scheduleReconnect();
    }
  };

  socket.onerror = () => {
    // onclose will fire after onerror — reconnect happens there
    setStatus("disconnected");
  };
}

// ---------------------------------------------------------------------------
// Heartbeat
// ---------------------------------------------------------------------------

function startHeartbeat() {
  stopHeartbeat();
  missedHeartbeats = 0;

  heartbeatInterval = setInterval(() => {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;

    if (missedHeartbeats >= 2) {
      // Two missed heartbeats — force reconnect
      console.warn("[main] Missed 2 heartbeats, reconnecting");
      stopHeartbeat();
      socket.close();
      return;
    }

    socket.send(JSON.stringify([null, nextRef(), "phoenix", "heartbeat", {}]));
    missedHeartbeats++;
  }, 30000);
}

function stopHeartbeat() {
  if (heartbeatInterval) {
    clearInterval(heartbeatInterval);
    heartbeatInterval = null;
  }
}

// ---------------------------------------------------------------------------
// Reconnection — exponential backoff
// ---------------------------------------------------------------------------

function scheduleReconnect() {
  if (reconnectTimer) return; // Already scheduled

  console.log(`[main] Reconnecting in ${reconnectDelay}ms`);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, reconnectDelay);

  // Exponential backoff with cap
  reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY);
}

async function handleAuthFailure() {
  console.warn("[main] Auth failure — clearing token and re-authenticating");
  await clearToken();
  updateAuthStatus("unauthenticated");

  try {
    await authenticate();
    updateAuthStatus("authenticated");
    reconnectDelay = 1000;
    connect();
  } catch (err) {
    console.error("[main] Re-auth failed:", err);
    scheduleReconnect();
  }
}

// ---------------------------------------------------------------------------
// Message send + queue
// ---------------------------------------------------------------------------

function sendMessage(content) {
  if (!content) return;

  if (!socket || socket.readyState !== WebSocket.OPEN || !chatJoinRef) {
    // Queue the message for when we reconnect
    if (messageQueue.length < MAX_QUEUED) {
      messageQueue.push(content);
    }
    return;
  }

  const msg = [chatJoinRef, nextRef(), "companion:chat", "new_message", {
    content,
    role: "user",
  }];
  socket.send(JSON.stringify(msg));
}

function flushMessageQueue() {
  while (messageQueue.length > 0) {
    const content = messageQueue.shift();
    sendMessage(content);
  }
}

// ---------------------------------------------------------------------------
// Hotkey handlers (voice + screenshot)
// ---------------------------------------------------------------------------

async function onHotkeyDown() {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;

  // Auto-capture screenshot if enabled
  const autoCapture = localStorage.getItem("auto_capture") !== "false";
  if (autoCapture) {
    captureAndUploadScreenshot();
  }

  startListening(socket, nextRef);
}

function onHotkeyUp() {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  stopListening(socket, nextRef);
}

// ---------------------------------------------------------------------------
// Settings HTML loader
// ---------------------------------------------------------------------------

async function loadSettingsHtml() {
  try {
    const resp = await fetch("settings.html");
    const html = await resp.text();
    const container = document.getElementById("settings-container");
    if (container) container.innerHTML = html;
  } catch (err) {
    console.error("[main] Failed to load settings.html:", err);
  }
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

async function init() {
  // 1. Load settings HTML fragment into DOM
  await loadSettingsHtml();

  // 2. Initialise settings module (binds events, populates devices, etc.)
  await initSettings({
    onReauthenticate: async () => {
      await clearToken();
      try {
        await authenticate();
        updateAuthStatus("authenticated");
        // Reconnect with new token
        connect();
      } catch (err) {
        console.error("[main] Re-auth from settings failed:", err);
        updateAuthStatus("unauthenticated");
      }
    },
  });

  // 3. Gear icon toggles settings panel
  document.getElementById("settings-toggle")?.addEventListener("click", () => {
    toggleSettings();
  });

  // 4. Chat form submission
  document.getElementById("chat-form")?.addEventListener("submit", (e) => {
    e.preventDefault();
    const input = document.getElementById("chat-input");
    const content = input?.value.trim();
    if (!content) return;
    sendMessage(content);
    input.value = "";
  });

  // 5. Configure voice callbacks
  configureVoice({
    onStatusChange: (status) => setStatus(status),
    onTranscript: (text, isFinal) => {
      if (isFinal) {
        addMessage({ role: "user", content: text, source: "voice" });
      }
    },
    onResponse: (text) => {
      addMessage({ role: "assistant", content: text, source: "voice" });
    },
    onError: (message) => {
      console.error("[voice]", message);
      addMessage({ role: "system", content: `Voice error: ${message}` });
    },
  });

  // 6. Listen for Tauri events
  if (window.__TAURI__) {
    window.__TAURI__.event.listen("hotkey-down", () => onHotkeyDown());
    window.__TAURI__.event.listen("hotkey-up", () => onHotkeyUp());
    window.__TAURI__.event.listen("toggle-settings", () => toggleSettings());
    window.__TAURI__.event.listen("manual-screenshot", () => captureAndUploadScreenshot());
  }

  // 7. Auth + connect
  const token = await initAuth();
  if (token) {
    updateAuthStatus("authenticated");
  }
  connect();
}

init();
