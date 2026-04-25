const navigationToggle = document.querySelector(".nav-toggle");
const primaryNavigation = document.querySelector(".primary-navigation");

if (navigationToggle && primaryNavigation) {
  navigationToggle.addEventListener("click", () => {
    const shouldOpenNavigation = navigationToggle.getAttribute("aria-expanded") !== "true";
    navigationToggle.setAttribute("aria-expanded", String(shouldOpenNavigation));
    primaryNavigation.classList.toggle("is-open", shouldOpenNavigation);
  });

  primaryNavigation.addEventListener("click", (event) => {
    if (event.target instanceof HTMLAnchorElement) {
      navigationToggle.setAttribute("aria-expanded", "false");
      primaryNavigation.classList.remove("is-open");
    }
  });
}

const revealTargets = document.querySelectorAll("[data-reveal]");

if ("IntersectionObserver" in window) {
  const revealObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          revealObserver.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.18 }
  );

  revealTargets.forEach((target) => revealObserver.observe(target));
} else {
  revealTargets.forEach((target) => target.classList.add("is-visible"));
}

const newsletterForm = document.querySelector(".newsletter");

if (newsletterForm) {
  newsletterForm.addEventListener("submit", (event) => {
    event.preventDefault();
    newsletterForm.classList.add("is-submitted");
  });
}

const characterCarousel = document.querySelector("[data-character-carousel]");
const previousCharacterButton = document.querySelector("[data-carousel-previous]");
const nextCharacterButton = document.querySelector("[data-carousel-next]");

if (characterCarousel && previousCharacterButton && nextCharacterButton) {
  const getCharacterCarouselStepSize = () => {
    const firstCharacterCard = characterCarousel.querySelector(".character-card");
    const cardWidth = firstCharacterCard ? firstCharacterCard.getBoundingClientRect().width : characterCarousel.clientWidth;
    const computedCarouselStyle = window.getComputedStyle(characterCarousel);
    const carouselGap = Number.parseFloat(computedCarouselStyle.columnGap || computedCarouselStyle.gap) || 24;

    return cardWidth + carouselGap;
  };

  const scrollCharacterCarousel = (direction) => {
    const stepSize = getCharacterCarouselStepSize();
    const maxScrollLeft = characterCarousel.scrollWidth - characterCarousel.clientWidth;

    if (direction > 0 && characterCarousel.scrollLeft >= maxScrollLeft - 4) {
      characterCarousel.append(characterCarousel.firstElementChild);
    }

    if (direction < 0 && characterCarousel.scrollLeft <= 4) {
      characterCarousel.prepend(characterCarousel.lastElementChild);
      characterCarousel.scrollLeft += stepSize;
    }

    characterCarousel.scrollBy({
      left: direction * stepSize,
      behavior: "smooth",
    });
  };

  previousCharacterButton.addEventListener("click", () => scrollCharacterCarousel(-1));
  nextCharacterButton.addEventListener("click", () => scrollCharacterCarousel(1));
}
