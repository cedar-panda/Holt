const CACHE_NAME = "holt-pwa-shell-v90";
const APP_SHELL = [
  "./",
  "./index.html",
  "./home.html",
  "./settings.html",
  "./styles.css?v=90",
  "./splash.js?v=4",
  "./shell-ready.js?v=1",
  "./app.js?v=90",
  "./avatar-cropper.js",
  "./ui-home.js",
  "./ui-usage.js",
  "./ui-characters.js",
  "./ui-settings.js",
  "./ui-profile.js",
  "./backup-bundle.js",
  "./font-loader.js",
  "./db.js",
  "./api.js",
  "./prompt-cache.js",
  "./prompt-builder.js",
  "./companion-features.js",
  "./image-generation.js",
  "./web-search.js",
  "./favorite-models-dialog.js",
  "./manifest.webmanifest",
  "./privacy.html",
  "./assets/images/holt_logo.png",
  "./assets/images/app_icon.png",
  "./assets/images/send_leaf_optimized.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const requestUrl = new URL(event.request.url);

  // API 請求不走緩存
  if (requestUrl.origin !== self.location.origin) return;

  // 導航請求：網路優先，失敗時回退快取，確保始終載入最新 HTML
  if (event.request.mode === "navigate") {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          if (response.ok) {
            const copy = response.clone();
            event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.put("./index.html", copy)));
          }
          return response;
        })
        .catch(() => caches.match("./index.html"))
    );
    return;
  }

  // 靜態資源：網路優先嘗試，失敗時回退快取
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
