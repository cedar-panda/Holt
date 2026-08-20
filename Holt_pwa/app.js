/**
 * Holt PWA — SPA 核心控制器
 * 狀態、工具函數、tab 導航、初始化
 * UI 邏輯在 ui-*.js 模組中
 */

import { openDB, getSetting, setSetting } from "./db.js";

// ═══ DOM helpers ═══
export const $ = (sel) => document.querySelector(sel);
export const $$ = (sel) => document.querySelectorAll(sel);

// ═══ Shared state ═══
export const state = {
  currentTab: 2,
  selectedCharId: null,
  currentConvId: null,
  abortController: null,
  isStreaming: false,
  pendingImageBase64: null,
  pendingImageMime: null,
  editingCharId: null,
};

// ═══ Toast ═══
const toastEl = $("#toast");
let toastTimer = null;
export function toast(msg, ms = 2600) {
  toastEl.textContent = msg;
  toastEl.classList.add("is-visible");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.remove("is-visible"), ms);
}

// ═══ Utilities ═══

export function formatMarkdown(text) {
  if (!text) return "";
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\*(.+?)\*/g, "<em>$1</em>")
    .replace(/`(.+?)`/g, "<code>$1</code>")
    .replace(/\n/g, "<br>");
}

export async function compactImageToDataUrl(file, maxSide = 256) {
  const objectUrl = URL.createObjectURL(file);
  try {
    const image = await new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = reject;
      img.src = objectUrl;
    });
    const scale = Math.min(1, maxSide / Math.max(image.naturalWidth, image.naturalHeight));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
    canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((resolve) => {
      canvas.toBlob((webp) => {
        if (webp) { resolve(webp); return; }
        canvas.toBlob(resolve, "image/jpeg", 0.82);
      }, "image/webp", 0.82);
    });
    if (!blob) throw new Error("無法壓縮圖片");
    return await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = reject;
      reader.readAsDataURL(blob);
    });
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}

// ═══ Tab navigation ═══

const tabPages = [$("#tabApi"), $("#tabUsage"), $("#tabHome"), $("#tabCharacters"), $("#tabProfile")];
const navItems = $$(".pill-nav-item");
export const pillNav = $("#pillNav");

const tabHandlers = {};
export function registerTabHandler(index, fn) { tabHandlers[index] = fn; }

export function switchTab(index) {
  state.currentTab = index;
  tabPages.forEach((p, i) => {
    if (i === index) p.removeAttribute("hidden");
    else p.setAttribute("hidden", "");
  });
  navItems.forEach((btn, i) => {
    btn.classList.toggle("is-active", i === index);
  });
  tabHandlers[index]?.();
}

navItems.forEach((btn) => {
  btn.addEventListener("click", () => {
    const idx = parseInt(btn.dataset.tab, 10);
    switchTab(idx);
  });
});

// ═══ Onboarding ═══

const onboarding = $("#onboarding");
const nextOb = $("#nextOb");
const skipOb = $("#skipOb");
let obStep = 0;

async function checkOnboarding() {
  const done = await getSetting("onboardingDone");
  if (done) return;
  onboarding.removeAttribute("hidden");
}

nextOb.addEventListener("click", () => {
  obStep++;
  const steps = $$(".ob-step");
  const dots = $$(".ob-dot");
  if (obStep >= steps.length) { finishOnboarding(); return; }
  steps.forEach((s, i) => s.classList.toggle("is-active", i === obStep));
  dots.forEach((d, i) => d.classList.toggle("is-active", i === obStep));
  if (obStep === steps.length - 1) nextOb.textContent = "開始";
});

skipOb.addEventListener("click", finishOnboarding);

function finishOnboarding() {
  onboarding.setAttribute("hidden", "");
  setSetting("onboardingDone", true);
}

// ═══ Service Worker ═══

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("./service-worker.js").then((reg) => {
    reg.update().catch(() => {});
  }).catch(() => {});
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    window.location.reload();
  });
}

// ═══ Init ═══

(async function init() {
  try {
    await openDB();
    // Dynamic imports ensure all app.js exports are live before UI modules evaluate
    await Promise.all([
      import("./ui-home.js"),
      import("./ui-usage.js"),
      import("./ui-characters.js"),
      import("./ui-settings.js"),
      import("./ui-profile.js"),
    ]);
    const { initTheme } = await import("./ui-profile.js");
    await initTheme();
    switchTab(2);
    checkOnboarding();
  } finally {
    window.dispatchEvent(new Event("holt:pwa-ready"));
  }
})();
