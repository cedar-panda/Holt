(() => {
  const markReady = () => {
    if (document.documentElement.classList.contains("holt-css-ready")) return;
    document.documentElement.classList.add("holt-css-ready");
    window.dispatchEvent(new Event("holt:css-ready"));
  };
  const stylesheet = document.getElementById("holtStylesheet");
  if (stylesheet?.sheet) markReady();
  else stylesheet?.addEventListener("load", markReady, { once: true });
  window.setTimeout(markReady, 8000);
})();
