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

const revealTargets = document.querySelectorAll(
  ".hero-copy, .hero-polaroid, .section-header, .moment, .roster-card, .step, .shop-copy, .sticker-sheet, .letter, .footer-board"
);

revealTargets.forEach((el) => el.setAttribute("data-reveal", ""));

if ("IntersectionObserver" in window) {
  const io = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry, i) => {
        if (entry.isIntersecting) {
          const delay = Math.min(i, 5) * 60;
          setTimeout(() => entry.target.classList.add("is-visible"), delay);
          io.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.15, rootMargin: "0px 0px -8% 0px" }
  );
  revealTargets.forEach((el) => io.observe(el));
} else {
  revealTargets.forEach((el) => el.classList.add("is-visible"));
}

const newsletter = document.querySelector(".footer-sub");
if (newsletter) {
  newsletter.addEventListener("submit", (event) => {
    event.preventDefault();
    const btn = newsletter.querySelector("button");
    if (btn) btn.textContent = "Thanks! ♡";
  });
}
