/**
 * Holt PWA — 字體按需載入
 * 預設不觸碰網路；只有使用者選擇外部字體後才背景載入。
 */

const FONT_OPTIONS = Object.freeze({
  system: {
    label: "Holt 內建字體",
    stack: "var(--font-system)",
  },
  wenkai: {
    label: "落霞文楷",
    family: "LXGW WenKai TC",
    stack: '"LXGW WenKai TC", var(--font-system)',
    stylesheet: "https://cdn.jsdelivr.net/npm/lxgw-wenkai-tc-webfont@1.7.0/style.css",
  },
  lora: {
    label: "Lora",
    family: "Lora",
    stack: '"Lora", var(--font-system)',
    stylesheet: "https://fonts.googleapis.com/css2?family=Lora:wght@400;700&display=swap",
  },
});

const pendingLoads = new Map();

function setFontStack(option) {
  document.documentElement.style.setProperty("--font", option.stack);
}

function loadStylesheet(id, option) {
  if (!option.stylesheet) return Promise.resolve();
  if (pendingLoads.has(id)) return pendingLoads.get(id);

  const promise = new Promise((resolve, reject) => {
    const existing = document.querySelector(`link[data-holt-font="${id}"]`);
    if (existing) {
      resolve();
      return;
    }

    const link = document.createElement("link");
    link.rel = "stylesheet";
    link.href = option.stylesheet;
    link.dataset.holtFont = id;
    link.onload = () => resolve();
    link.onerror = () => reject(new Error(`字體載入失敗：${option.label}`));
    document.head.appendChild(link);
  });

  pendingLoads.set(id, promise);
  return promise;
}

/** 先立刻套用 fallback，再非阻塞地抓取選用字體。 */
async function applyFontPreference(id = "system") {
  const option = FONT_OPTIONS[id] || FONT_OPTIONS.system;
  setFontStack(option);

  if (!option.stylesheet) return { id: "system", loaded: true };

  try {
    await loadStylesheet(id, option);
    if (document.fonts && option.family) {
      await document.fonts.load(`16px "${option.family}"`);
    }
    return { id, loaded: true };
  } catch {
    return { id, loaded: false };
  }
}

function getFontOptions() {
  return FONT_OPTIONS;
}

export { applyFontPreference, getFontOptions };
