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
