(function runPwaSplash() {
  const splash = document.getElementById("pwaSplash");
  if (!splash) {
    document.documentElement.classList.add("holt-splash-done");
    return;
  }

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const startedAt = performance.now();
  // The last spark ends at 3.25s (1.5s delay + 250ms stagger + 1.5s run).
  // Keep a small buffer so the splash never starts leaving mid-animation.
  const entranceDuration = reduceMotion ? 0 : 3400;
  const fallbackReady = 8000;
  let hasExited = false;
  let hasCssReady = document.documentElement.classList.contains("holt-css-ready");
  let hasAppReady = false;
  let hasEntranceFinished = reduceMotion;

  function finishSplash() {
    document.documentElement.classList.add("holt-splash-done");
    splash.remove();
  }

  function tryExitSplash() {
    if (hasExited || !hasCssReady || !hasAppReady || !hasEntranceFinished) return;
    hasExited = true;
    if (reduceMotion) {
      finishSplash();
      return;
    }
    splash.classList.add("is-exiting");
    window.setTimeout(finishSplash, 500);
  }

  window.setTimeout(() => {
    hasEntranceFinished = true;
    tryExitSplash();
  }, entranceDuration);

  window.addEventListener("holt:css-ready", () => {
    hasCssReady = true;
    tryExitSplash();
  }, { once: true });
  window.addEventListener("holt:pwa-ready", () => {
    hasAppReady = true;
    tryExitSplash();
  }, { once: true });
  // If a stylesheet/module/browser feature fails, never strand the splash.
  window.setTimeout(() => {
    hasCssReady = true;
    hasAppReady = true;
    hasEntranceFinished = true;
    document.documentElement.classList.add("holt-css-ready");
    tryExitSplash();
  }, fallbackReady);
})();
