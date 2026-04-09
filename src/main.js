// Sewa Companion — Phoenix channel client (chat + pointer overlay dispatch)

/** @type {WebSocket | null} */
let socket = null;
/** @type {string | null} */
let channelJoinRef = null;
let msgRef = 0;
/** @type {number|null} */
let heartbeatInterval = null;

function nextRef() {
  return String(++msgRef);
}

function setStatus(state) {
  const dot = document.querySelector(".status-dot");
  const text = document.getElementById("status-text");
  dot.className = `status-dot ${state}`;
  text.textContent = state.charAt(0).toUpperCase() + state.slice(1);
}

function addMessage(msg) {
  const container = document.getElementById("messages");
  const el = document.createElement("div");
  el.className = `message ${msg.role}`;
  el.innerHTML = `
    <div>${escapeHtml(msg.content)}</div>
    <div class="source">${msg.source || ""}</div>
  `;
  container.appendChild(el);
  container.scrollTop = container.scrollHeight;
}

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

function handlePointerEvent(payload) {
  if (!window.__TAURI__ || !payload || !payload.instructions) return;

  // Group instructions by target screen
  const byScreen = new Map();
  for (const instr of payload.instructions) {
    if (instr.type === "chain" && instr.steps) {
      // Chain targets the screen of its first step
      const screen = instr.steps[0]?.screen ?? 0;
      if (!byScreen.has(screen)) byScreen.set(screen, []);
      byScreen.get(screen).push(instr);
    } else {
      const screen = instr.screen ?? 0;
      if (!byScreen.has(screen)) byScreen.set(screen, []);
      byScreen.get(screen).push(instr);
    }
  }

  // Show each overlay and emit only its instructions
  for (const [screen, instructions] of byScreen) {
    window.__TAURI__.core.invoke("show_overlay", { screen });
    window.__TAURI__.event.emitTo(`overlay-${screen}`, "pointer-instructions", { instructions });
  }
}

function connect() {
  const sewaUrl = localStorage.getItem("sewa_url") || "wss://sewa-prod.1-800-goobsquire.lol";
  const token = localStorage.getItem("companion_token") || "";
  const url = `${sewaUrl}/socket/companion/websocket?token=${encodeURIComponent(token)}&vsn=2.0.0`;

  setStatus("connecting");
  socket = new WebSocket(url);

  socket.onopen = () => {
    channelJoinRef = nextRef();
    const joinMsg = [channelJoinRef, nextRef(), "companion:chat", "phx_join", {}];
    socket.send(JSON.stringify(joinMsg));
  };

  socket.onmessage = (event) => {
    const [joinRef, ref, topic, eventName, payload] = JSON.parse(event.data);

    if (eventName === "phx_reply" && joinRef === channelJoinRef) {
      if (payload.status === "ok") {
        setStatus("connected");
        const messages = payload.response?.messages || [];
        messages.forEach(addMessage);
      } else {
        setStatus("disconnected");
      }
    }

    if (eventName === "new_message" && topic === "companion:chat") {
      addMessage(payload);
    }

    if (eventName === "pointer" && topic === "companion:chat") {
      handlePointerEvent(payload);
    }
  };

  socket.onclose = () => {
    setStatus("disconnected");
    setTimeout(connect, 3000);
  };

  socket.onerror = () => {
    setStatus("disconnected");
  };

  // Heartbeat every 30 seconds (clear previous on reconnect)
  if (heartbeatInterval) clearInterval(heartbeatInterval);
  heartbeatInterval = setInterval(() => {
    if (socket?.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify([null, nextRef(), "phoenix", "heartbeat", {}]));
    }
  }, 30000);
}

function sendMessage(content) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;

  const ref = nextRef();
  const msg = [channelJoinRef, ref, "companion:chat", "new_message", {
    content,
    role: "user"
  }];
  socket.send(JSON.stringify(msg));
}

document.getElementById("chat-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const input = document.getElementById("chat-input");
  const content = input.value.trim();
  if (!content) return;

  sendMessage(content);
  input.value = "";
});

connect();
