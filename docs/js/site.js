(() => {
  const nav = document.querySelector("[data-nav]");

  if (nav) {
    const setNavState = () => {
      nav.classList.toggle("is-scrolled", window.scrollY > 8);
    };
    setNavState();
    window.addEventListener("scroll", setNavState, { passive: true });
  }

  const items = document.querySelectorAll(".reveal");
  if (!items.length) return;

  // Content stays visible when scripting is off or the observer is missing.
  if (!("IntersectionObserver" in window)) return;

  document.documentElement.classList.add("js");

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("is-in");
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -40px 0px", threshold: 0.05 }
  );

  items.forEach((item) => observer.observe(item));
})();
