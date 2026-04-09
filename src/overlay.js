// src/overlay.js — Sewa Companion pointer overlay rendering

const pointer = document.getElementById("pointer");
const bubble = document.getElementById("bubble");
const regionMask = document.getElementById("region-mask");
const regionLabel = document.getElementById("region-label");

/** @type {number|null} */
let dismissTimer = null;
/** @type {number|null} */
let chainTimer = null;
/** @type {number} */
let chainIndex = 0;
/** @type {Array|null} */
let chainSteps = null;
/** @type {function|null} */
let chainOnDone = null;

// -- Rendering --------------------------------------------------------

function showPointer(x, y) {
  pointer.style.left = x + "px";
  pointer.style.top = y + "px";
  pointer.classList.remove("hidden");
  pointer.classList.add("visible");
}

function showBubble(x, y, label, stepText) {
  bubble.style.left = x + "px";
  bubble.style.top = y + "px";
  bubble.innerHTML = (stepText ? `<span class="step-indicator">${stepText}</span>` : "") + escapeHtml(label);
  bubble.classList.remove("hidden");
  bubble.classList.add("visible");
}

function showRegion(x, y, w, h, label) {
  // Clip-path polygon: full screen with rectangular cutout
  const right = x + w;
  const bottom = y + h;
  regionMask.style.clipPath =
    `polygon(0% 0%, 0% 100%, ${x}px 100%, ${x}px ${y}px, ${right}px ${y}px, ${right}px ${bottom}px, ${x}px ${bottom}px, ${x}px 100%, 100% 100%, 100% 0%)`;
  regionMask.classList.remove("hidden");
  regionMask.classList.add("visible");

  // Position label above the region, or below if near top edge
  const labelY = y > 40 ? y - 36 : bottom + 8;
  regionLabel.style.left = x + "px";
  regionLabel.style.top = labelY + "px";
  regionLabel.textContent = label;
  regionLabel.classList.remove("hidden");
  regionLabel.classList.add("visible");
}

function clearAll() {
  if (dismissTimer) { clearTimeout(dismissTimer); dismissTimer = null; }
  if (chainTimer) { clearTimeout(chainTimer); chainTimer = null; }
  chainSteps = null;
  chainIndex = 0;
  chainOnDone = null;

  pointer.classList.remove("visible");
  pointer.classList.add("hidden");
  bubble.classList.remove("visible");
  bubble.classList.add("hidden");
  regionMask.classList.remove("visible");
  regionMask.classList.add("hidden");
  regionMask.style.clipPath = "";
  regionLabel.classList.remove("visible");
  regionLabel.classList.add("hidden");
}

function fadeAndHide() {
  pointer.classList.add("fade-out");
  bubble.classList.add("fade-out");
  regionMask.classList.add("fade-out");
  regionLabel.classList.add("fade-out");

  setTimeout(() => {
    clearAll();
    pointer.classList.remove("fade-out");
    bubble.classList.remove("fade-out");
    regionMask.classList.remove("fade-out");
    regionLabel.classList.remove("fade-out");
  }, 500);
}

// -- Instruction dispatch ---------------------------------------------

function handleInstructions(instructions) {
  clearAll();

  if (!instructions || instructions.length === 0) return;

  // Render instructions sequentially
  renderSequence(instructions, 0);
}

function renderSequence(instructions, index) {
  if (index >= instructions.length) {
    return;
  }

  const instr = instructions[index];

  if (instr.type === "chain") {
    renderChain(instr.steps, () => renderSequence(instructions, index + 1));
  } else if (instr.type === "point") {
    renderPoint(instr, () => renderSequence(instructions, index + 1));
  } else if (instr.type === "region") {
    renderRegionInstr(instr, () => renderSequence(instructions, index + 1));
  }
}

function renderPoint(instr, onDone) {
  clearRegion();
  showPointer(instr.x, instr.y);
  showBubble(instr.x, instr.y, instr.label, null);

  const duration = 1000 + instr.label.length * 50 + 2000;
  dismissTimer = setTimeout(() => {
    fadeAndHide();
    setTimeout(() => { if (onDone) onDone(); }, 600);
  }, duration);
}

function renderRegionInstr(instr, onDone) {
  clearPointer();
  showRegion(instr.x, instr.y, instr.w, instr.h, instr.label);

  const duration = 1000 + instr.label.length * 50 + 2000;
  dismissTimer = setTimeout(() => {
    fadeAndHide();
    setTimeout(() => { if (onDone) onDone(); }, 600);
  }, duration);
}

function clearPointer() {
  pointer.classList.remove("visible");
  pointer.classList.add("hidden");
  bubble.classList.remove("visible");
  bubble.classList.add("hidden");
}

function clearRegion() {
  regionMask.classList.remove("visible");
  regionMask.classList.add("hidden");
  regionMask.style.clipPath = "";
  regionLabel.classList.remove("visible");
  regionLabel.classList.add("hidden");
}

// -- Chain rendering --------------------------------------------------

function renderChain(steps, onDone) {
  if (!steps || steps.length === 0) { if (onDone) onDone(); return; }

  chainSteps = steps;
  chainIndex = 0;
  chainOnDone = onDone;

  renderChainStep();
}

function renderChainStep() {
  if (chainIndex >= chainSteps.length) {
    const done = chainOnDone;
    chainOnDone = null;
    // Hold last step for 2 seconds, then fade
    dismissTimer = setTimeout(() => {
      fadeAndHide();
      setTimeout(() => { chainSteps = null; chainIndex = 0; if (done) done(); }, 600);
    }, 2000);
    return;
  }

  const step = chainSteps[chainIndex];
  const stepText = `${chainIndex + 1}/${chainSteps.length}`;

  clearRegion();
  showPointer(step.x, step.y);
  showBubble(step.x, step.y, step.label, stepText);

  const delay = 1000 + step.label.length * 50;
  chainTimer = setTimeout(() => {
    chainIndex++;
    renderChainStep();
  }, delay);
}

function advanceChain() {
  if (!chainSteps) return;
  if (chainTimer) { clearTimeout(chainTimer); chainTimer = null; }
  chainIndex++;
  renderChainStep();
}

// -- Utilities --------------------------------------------------------

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  return div.innerHTML;
}

// -- Tauri event listeners --------------------------------------------

if (window.__TAURI__) {
  window.__TAURI__.event.listen("pointer-instructions", (event) => {
    const payload = event.payload;
    if (payload && payload.instructions) {
      handleInstructions(payload.instructions);
    }
  });

  window.__TAURI__.event.listen("pointer-dismissed", () => {
    clearAll();
  });

  // Chain advance via global shortcut (Space / Right Arrow).
  // Overlay is click-through so document.keydown never fires —
  // Rust registers global shortcuts and forwards as this event.
  window.__TAURI__.event.listen("pointer-advance", () => {
    advanceChain();
  });
}
