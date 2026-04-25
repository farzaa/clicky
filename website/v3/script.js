const navToggle = document.querySelector(".nav-toggle");
const primaryNav = document.querySelector(".primary-nav");

if (navToggle && primaryNav) {
  primaryNav.id = "primary-nav-mobile";
  navToggle.addEventListener("click", () => {
    const open = navToggle.getAttribute("aria-expanded") !== "true";
    navToggle.setAttribute("aria-expanded", String(open));
    primaryNav.classList.toggle("is-open", open);
  });
  primaryNav.addEventListener("click", (event) => {
    if (event.target instanceof HTMLAnchorElement) {
      navToggle.setAttribute("aria-expanded", "false");
      primaryNav.classList.remove("is-open");
    }
  });
}


const voiceButtons = document.querySelectorAll(".voice-button");
let currentVoiceAudio = null;
let currentVoiceButton = null;

const stopCurrentVoice = () => {
  if (currentVoiceAudio) {
    currentVoiceAudio.pause();
    currentVoiceAudio.currentTime = 0;
  }
  if (currentVoiceButton) {
    currentVoiceButton.classList.remove("is-playing", "is-loading");
  }
  currentVoiceAudio = null;
  currentVoiceButton = null;
};

voiceButtons.forEach((button) => {
  const src = button.getAttribute("data-voice");
  if (!src) return;

  button.addEventListener("click", () => {
    if (currentVoiceButton === button) {
      stopCurrentVoice();
      return;
    }

    stopCurrentVoice();

    const audio = new Audio(src);
    currentVoiceAudio = audio;
    currentVoiceButton = button;
    button.classList.add("is-loading");

    audio.addEventListener("playing", () => {
      button.classList.remove("is-loading");
      button.classList.add("is-playing");
    });
    audio.addEventListener("ended", () => {
      if (currentVoiceButton === button) stopCurrentVoice();
    });
    audio.addEventListener("error", () => {
      if (currentVoiceButton === button) stopCurrentVoice();
    });

    audio.play().catch(() => {
      if (currentVoiceButton === button) stopCurrentVoice();
    });
  });
});

const newsletter = document.querySelector(".footer-sub");
if (newsletter) {
  newsletter.addEventListener("submit", (event) => {
    event.preventDefault();
    const btn = newsletter.querySelector("button");
    if (btn) btn.textContent = "Thanks! ♡";
  });
}
