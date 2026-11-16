// With reduced motion requested, stop the demo videos on their poster frame and hand control to the viewer.
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

function applyMotionPreference() {
  for (const video of document.querySelectorAll("video[data-demo]")) {
    if (reducedMotion.matches) {
      video.removeAttribute("autoplay");
      video.pause();
      video.controls = true;
    } else {
      video.controls = false;
      video.play().catch(() => {
        // Autoplay can be refused by the browser; fall back to user-started playback.
        video.controls = true;
      });
    }
  }
}

applyMotionPreference();
reducedMotion.addEventListener("change", applyMotionPreference);

// Remember the language the reader picked, so the root page stops redirecting by browser language (worker/index.js).
const languageMenu = document.querySelector("details.lang");
for (const link of document.querySelectorAll(".lang a[data-lang]")) {
  link.addEventListener("click", () => {
    document.cookie = `lang=${link.dataset.lang}; path=/; max-age=31536000; samesite=lax`;
  });
}
document.addEventListener("click", (event) => {
  if (languageMenu?.open && !languageMenu.contains(event.target)) languageMenu.open = false;
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && languageMenu?.open) {
    languageMenu.open = false;
    languageMenu.querySelector("summary").focus();
  }
});
