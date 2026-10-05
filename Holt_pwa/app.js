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
  pendingStickerId: null,
  pendingTransferAmount: null,
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

async function preparePersistentStorage() {
  if (!navigator.storage) return;
  try { await navigator.storage.persist?.(); } catch {}
  try {
    const { usage = 0, quota = 0 } = await navigator.storage.estimate?.() || {};
    if (quota > 0 && usage / quota >= 0.85) {
      toast("本機儲存空間已接近上限，建議匯出備份並清理圖片", 7000);
    }
  } catch {}
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
const replayOnboardingBtn = $("#replayOnboardingBtn");
const ONBOARDING_VERSION = 1;
let obStep = 0;

async function checkOnboarding() {
  const [done, version, savedStep] = await Promise.all([
    getSetting("onboardingDone"), getSetting("onboardingVersion"), getSetting("onboardingStep"),
  ]);
  if (done && version == null) {
    await setSetting("onboardingVersion", ONBOARDING_VERSION);
    return;
  }
  if (Number(version) >= ONBOARDING_VERSION) return;
  obStep = Math.max(0, Math.min($$(".ob-step").length - 1, Number(savedStep) || 0));
  renderOnboardingStep();
  onboarding.removeAttribute("hidden");
}

function renderOnboardingStep() {
  const steps = $$(".ob-step");
  const dots = $$(".ob-dot");
  steps.forEach((s, i) => s.classList.toggle("is-active", i === obStep));
  dots.forEach((d, i) => d.classList.toggle("is-active", i === obStep));
  nextOb.textContent = obStep === steps.length - 1 ? "開始" : "下一步";
}

nextOb.addEventListener("click", async () => {
  obStep++;
  if (obStep >= $$(".ob-step").length) { finishOnboarding(); return; }
  renderOnboardingStep();
  await setSetting("onboardingStep", obStep);
});

skipOb.addEventListener("click", finishOnboarding);

function finishOnboarding() {
  onboarding.setAttribute("hidden", "");
  void Promise.all([
    setSetting("onboardingDone", true),
    setSetting("onboardingVersion", ONBOARDING_VERSION),
    setSetting("onboardingStep", 0),
  ]);
}

replayOnboardingBtn?.addEventListener("click", () => {
  obStep = 0;
  renderOnboardingStep();
  onboarding.removeAttribute("hidden");
});

// ═══ Service Worker ═══

if ("serviceWorker" in navigator) {
  const hadServiceWorkerController = Boolean(navigator.serviceWorker.controller);
  navigator.serviceWorker.register("./service-worker.js").then((reg) => {
    reg.update().catch((error) => console.warn("Holt 更新檢查失敗", error));
  }).catch((error) => {
    console.warn("Holt 離線功能註冊失敗", error);
    toast("離線功能暫時無法啟用", 5000);
  });
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    toast(hadServiceWorkerController
      ? "新版本已準備好，重新開啟 Holt 後套用"
      : "離線功能已準備完成", 6000);
  });
}

window.addEventListener("holt:db-versionchange", () => {
  toast("資料庫已由另一個 Holt 視窗更新，請重新載入", 7000);
});
window.addEventListener("offline", () => toast("目前離線；既有內容仍可查看", 5000));
window.addEventListener("online", () => toast("網路已恢復"));

// ═══ Init ═══

(async function init() {
  try {
    await openDB();
    await preparePersistentStorage();
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
    await checkOnboarding();
  } catch (error) {
    console.error("Holt 啟動失敗", error);
    const fatal = $("#appFatal");
    const message = $("#appFatalMessage");
    if (message) message.textContent = error?.message || "未知錯誤";
    fatal?.removeAttribute("hidden");
  } finally {
    window.dispatchEvent(new Event("holt:pwa-ready"));
  }
})();

$("#appFatalRetry")?.addEventListener("click", () => window.location.reload());
