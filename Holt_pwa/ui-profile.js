/**
 * Holt PWA — 個人頁 + 主題工坊 + 備份
 */

import { $, $$, toast, switchTab, registerTabHandler } from "./app.js";
import {
  getSetting, setSetting,
  listCharacters, listConversations, getMessagesByConversation,
  saveCharacter, saveConversation, saveMessage,
} from "./db.js";
import { applyFontPreference, getFontOptions } from "./font-loader.js";
import { encryptHoltBackup, isEncryptedBackup, makePortableZip, readBackupDump } from "./backup-bundle.js";
import { renderHomeContent } from "./ui-home.js";
import { openAvatarCropper } from "./avatar-cropper.js";

// ═══ DOM refs ═══

const profileAvatar = $("#profileAvatar");
const profileAvatarBtn = $("#profileAvatarBtn");
const profileAvatarPicker = $("#profileAvatarPicker");
const profileDisplayName = $("#profileDisplayName");
const profileSaveBtn = $("#profileSaveBtn");
const profileFont = $("#profileFont");
const profileFontHint = $("#profileFontHint");
const exportDataBtn = $("#exportDataBtn");
const importDataBtn = $("#importDataBtn");
const profileThemeToggle = $("#profileThemeToggle");
const profileUsageBtn = $("#profileUsageBtn");
const profileIdentity = $("#profileIdentity");
const profileEditor = $("#profileEditor");
const profileEditorToggle = $("#profileEditorToggle");
const themeWorkshop = $("#themeWorkshop");
const themeWorkshopBtn = $("#themeWorkshopBtn");
const themeWorkshopClose = $("#themeWorkshopClose");
const themeWorkshopDone = $("#themeWorkshopDone");
const themePresetListLight = $("#themePresetListLight");
const themePresetListDark = $("#themePresetListDark");
const themePreview = $("#themePreview");
const themePreviewName = $("#themePreviewName");
const themePreviewSubtitle = $("#themePreviewSubtitle");
const themeBubbleOpacity = $("#themeBubbleOpacity");
const themeBubbleOpacityValue = $("#themeBubbleOpacityValue");
const themeBubbleRadius = $("#themeBubbleRadius");
const themeBubbleRadiusValue = $("#themeBubbleRadiusValue");

// ═══ Tab registration ═══

registerTabHandler(4, renderProfile);

// ═══ Theme presets ═══

export const PWA_THEME_PRESETS = {
  ivory: {
    name: "象牙白", subtitle: "窗外透進來的一點天色", dark: false,
    bg: ["#faf9f6", "#f8f7f3", "#f6f4ef", "#fcfbf8"], ai: "#fbfaf7", user: "#cbd7ea",
    ink: "#2e3038", soft: "#525960", faint: "#878f9a", accent: "#5d7492", light: "#a0b0c4",
    nav: "rgba(248,244,242,.90)", inactive: "#908898",
  },
  dawn: {
    name: "晨光", subtitle: "清晨透進紗簾的光", dark: false,
    bg: ["#f2ddd0", "#ecd4dc", "#e0d4e4", "#d8dce8"], ai: "#faf6f3", user: "#efe4ec",
    ink: "#484050", soft: "#787080", faint: "#9a909d", accent: "#9680b4", light: "#bca8d0",
    nav: "rgba(248,244,242,.90)", inactive: "#908898",
  },
  midnight: {
    name: "深夜書房", subtitle: "同一個房間入了夜", dark: true,
    bg: ["#2a2028", "#252030", "#1e2530", "#1c2628"], ai: "#423a4a", user: "#2e3542",
    ink: "#e8e0d8", soft: "#918c88", faint: "#746e70", accent: "#b8855c", light: "#c49570",
    nav: "rgba(18,16,22,.92)", inactive: "#a09898",
  },
  taro: {
    name: "紫芋泥", subtitle: "半融化的紫芋冰", dark: true,
    bg: ["#1e1a2a", "#221e30", "#261e34", "#1c1828"], ai: "#4a3550", user: "#352848",
    ink: "#e8dce6", soft: "#a898a8", faint: "#7e6e80", accent: "#c48db8", light: "#d4a8c8",
    nav: "rgba(16,14,22,.92)", inactive: "#a090a8",
  },
  salt: {
    name: "海鹽", subtitle: "退潮後的礁石", dark: true,
    bg: ["#1a2028", "#1e2430", "#202a30", "#182228"], ai: "#354550", user: "#2a3848",
    ink: "#d8e4e8", soft: "#8a9ca4", faint: "#687a82", accent: "#7eb8c4", light: "#90c8d0",
    nav: "rgba(12,18,24,.92)", inactive: "#80a0aa",
  },
  berry: {
    name: "覆盆子", subtitle: "果醬沉在杯底", dark: true,
    bg: ["#22181e", "#281c24", "#301e26", "#201620"], ai: "#503848", user: "#3a2838",
    ink: "#eedce0", soft: "#b08890", faint: "#886068", accent: "#d4869a", light: "#e0a0b0",
    nav: "rgba(18,12,16,.92)", inactive: "#b0888e",
  },
  yogurt: {
    name: "藍莓優格", subtitle: "攪拌到一半的紫藍", dark: true,
    bg: ["#1a1e22", "#1e2228", "#242830", "#181c24"], ai: "#3a4050", user: "#2e3448",
    ink: "#dce0e8", soft: "#8890a0", faint: "#666e80", accent: "#a0b0c8", light: "#b0bcd0",
    nav: "rgba(12,14,20,.92)", inactive: "#8890a8",
  },
  brulee: {
    name: "焦糖布蕾", subtitle: "糖面剛裂開的那刻", dark: true,
    bg: ["#201a1a", "#261e1e", "#2c2020", "#1e1818"], ai: "#4a3830", user: "#382a28",
    ink: "#eee4dc", soft: "#b09888", faint: "#887060", accent: "#c8a080", light: "#d4b898",
    nav: "rgba(16,12,12,.92)", inactive: "#b09888",
  },
  matcha: {
    name: "抹茶慕斯", subtitle: "粉打到起泡的綠", dark: true,
    bg: ["#181e20", "#1c2424", "#1e2828", "#161c1e"], ai: "#304540", user: "#263838",
    ink: "#d4e4dc", soft: "#889c92", faint: "#687a72", accent: "#88c4a0", light: "#98d0b0",
    nav: "rgba(10,16,14,.92)", inactive: "#80a898",
  },
  mist: {
    name: "霧紫", subtitle: "凌晨四點的霧", dark: true,
    bg: ["#2a2035", "#28203a", "#242040", "#202838"], ai: "#4b385b", user: "#333a58",
    ink: "#d8d0e0", soft: "#938ca9", faint: "#716a82", accent: "#a080c0", light: "#b090d0",
    nav: "rgba(22,18,34,.92)", inactive: "#9a90b0",
  },
  bloom: {
    name: "花信", subtitle: "淡紫裡的粉玫瑰", dark: false,
    bg: ["#dcc9e7", "#d6c2e2", "#d1bcdd", "#e0ceea"], ai: "#f9f4f5", user: "#efe4f8",
    ink: "#483848", soft: "#806878", faint: "#a08c9c", accent: "#ad4963", light: "#d48c9e",
    nav: "rgba(248,242,246,.90)", inactive: "#9b8490",
  },
  iced: {
    name: "冬夜", subtitle: "清冷透亮的神經碎片", dark: true,
    bg: ["#161a22", "#1a1e28", "#141820", "#181c24"], ai: "#323a46", user: "#2a2e4e",
    ink: "#d0d8e0", soft: "#8994a0", faint: "#68727e", accent: "#68a8d8", light: "#80b8e0",
    nav: "rgba(10,14,20,.92)", inactive: "#8ca0b0",
  },
  nightlamp: {
    name: "夜燈", subtitle: "小屋熄燈後剩的那一盞", dark: true,
    bg: ["#1a1721", "#1e1a26", "#221d2b", "#1c1823"], ai: "#3f354e", user: "#2e2c48",
    ink: "#efeaf2", soft: "#a89caf", faint: "#766a7c", accent: "#f2c96d", light: "#f7d98d",
    nav: "rgba(14,12,20,.92)", inactive: "#a098b0",
  },
  tipsy: {
    name: "微醺", subtitle: "一杯之後的體溫", dark: true,
    bg: ["#2a1d20", "#2e1f23", "#261a1e", "#301f24"], ai: "#4f353d", user: "#3a2c42",
    ink: "#eedfdc", soft: "#b08c88", faint: "#80686a", accent: "#e8a08a", light: "#f0b09a",
    nav: "rgba(22,14,16,.92)", inactive: "#b0969a",
  },
  snow: {
    name: "初雪", subtitle: "世界安靜下來的那一刻", dark: false,
    bg: ["#eae6ea", "#e4e0e6", "#dedce4", "#eeeaee"], ai: "#f6f4f6", user: "#e6e2ec",
    ink: "#3e4046", soft: "#737780", faint: "#999da8", accent: "#6878a0", light: "#8898b8",
    nav: "rgba(247,245,248,.90)", inactive: "#888c9a",
  },
  latte: {
    name: "卡布奇諾", subtitle: "奶泡上的一圈拉花", dark: false,
    bg: ["#f2eae0", "#e0d2c4", "#d4c4b4", "#ede2d8"], ai: "#faf6f0", user: "#ede0d2",
    ink: "#484040", soft: "#786860", faint: "#9a887d", accent: "#8c6e5e", light: "#b09080",
    nav: "rgba(249,244,238,.90)", inactive: "#93847a",
  },
  blush: {
    name: "玫瑰露", subtitle: "一滴暈開在指尖", dark: false,
    bg: ["#fae8ec", "#f5e2e8", "#f0dde4", "#fcf2f4"], ai: "#fdf8f8", user: "#f8ecf0",
    ink: "#4c3840", soft: "#80606c", faint: "#aa8c98", accent: "#c07888", light: "#e0a8b8",
    nav: "rgba(252,244,246,.90)", inactive: "#9e7f89",
  },
  soda: {
    name: "薄荷氣泡", subtitle: "氣泡正在往上竄", dark: false,
    bg: ["#d4ece8", "#c8e4e2", "#bededd", "#daf0ec"], ai: "#f8fcfb", user: "#dcf0ea",
    ink: "#364442", soft: "#5f7f7a", faint: "#8aa9a3", accent: "#388880", light: "#5aaaa0",
    nav: "rgba(241,250,248,.90)", inactive: "#72918b",
  },
  neon: {
    name: "霓虹雨", subtitle: "雨夜霓虹落在傘面上", dark: true,
    bg: ["#12101e", "#151226", "#0e0c18", "#171430"], ai: "#342b5b", user: "#152f3a",
    ink: "#edebf8", soft: "#9b94b4", faint: "#6e6886", accent: "#00e5d4", light: "#55f0e2",
    nav: "rgba(8,6,16,.92)", inactive: "#9690b8",
  },
  neonberry: {
    name: "霓虹莓果", subtitle: "深夜裡螢光粉的裙擺", dark: true,
    bg: ["#1a1a28", "#201e30", "#281e34", "#181828"], ai: "#3a2840", user: "#482040",
    ink: "#e8dce8", soft: "#a898b0", faint: "#7e6e88", accent: "#ff6b9d", light: "#ff8ab4",
    nav: "rgba(14,14,22,.92)", inactive: "#a088a8",
  },
  mintshock: {
    name: "薄荷電流", subtitle: "碰到舌尖那一秒", dark: true,
    bg: ["#181e22", "#1c2428", "#202a2e", "#161c20"], ai: "#1e3830", user: "#1a3028",
    ink: "#d4e4dc", soft: "#88a098", faint: "#688078", accent: "#00e5a0", light: "#40f0b8",
    nav: "rgba(12,16,18,.92)", inactive: "#78a898",
  },
  tangerine: {
    name: "焦橘夜燈", subtitle: "柑橘皮燃起來的味道", dark: true,
    bg: ["#1e1a20", "#241e26", "#2a2028", "#1c1820"], ai: "#3a2820", user: "#382418",
    ink: "#e8dcd4", soft: "#b0988a", faint: "#887868", accent: "#ff9f43", light: "#ffb86c",
    nav: "rgba(16,14,16,.92)", inactive: "#b09880",
  },
  ultraviolet: {
    name: "電紫星塵", subtitle: "頻率太高肉眼接不住", dark: true,
    bg: ["#14141e", "#1a1828", "#201e30", "#12121c"], ai: "#2a2448", user: "#241e40",
    ink: "#d8d0e8", soft: "#9890b0", faint: "#706890", accent: "#7c5cff", light: "#9880ff",
    nav: "rgba(10,10,16,.92)", inactive: "#8878b0",
  },
  crackedice: {
    name: "冰裂藍", subtitle: "裂開的地方在發光", dark: true,
    bg: ["#1a1e1e", "#1e2426", "#202a2c", "#181c1c"], ai: "#1e3440", user: "#182c38",
    ink: "#d0e0e8", soft: "#88a0a8", faint: "#688088", accent: "#00d4ff", light: "#40e0ff",
    nav: "rgba(12,14,14,.92)", inactive: "#78a0b0",
  },
  hotcherry: {
    name: "烈酒紅", subtitle: "吞下去的時候燒喉嚨", dark: true,
    bg: ["#1c1818", "#221c1c", "#2a2020", "#1a1616"], ai: "#3a2020", user: "#381818",
    ink: "#e8d8d8", soft: "#b08888", faint: "#886060", accent: "#ff4757", light: "#ff6b78",
    nav: "rgba(14,12,12,.92)", inactive: "#b08080",
  },
};

let activeThemeId = "ivory";
let bubbleOpacity = 100;
let bubbleRadius = 18;

// ═══ Theme engine ═══

function applyBubbleTuning() {
  document.documentElement.style.setProperty("--bubble-opacity", `${bubbleOpacity}%`);
  document.documentElement.style.setProperty("--bubble-radius", `${bubbleRadius}px`);
  if (themeBubbleOpacity) themeBubbleOpacity.value = String(bubbleOpacity);
  if (themeBubbleOpacityValue) themeBubbleOpacityValue.textContent = `${bubbleOpacity}%`;
  if (themeBubbleRadius) themeBubbleRadius.value = String(bubbleRadius);
  if (themeBubbleRadiusValue) themeBubbleRadiusValue.textContent = String(bubbleRadius);
}

export function getActiveThemePreset() {
  return PWA_THEME_PRESETS[activeThemeId] || PWA_THEME_PRESETS.ivory;
}

function applyThemePreset(id, { persist = true, render = true } = {}) {
  const preset = PWA_THEME_PRESETS[id] || PWA_THEME_PRESETS.ivory;
  activeThemeId = preset === PWA_THEME_PRESETS[id] ? id : "ivory";
  const root = document.documentElement;
  ["bg-1", "bg-2", "bg-3", "bg-4"].forEach((key, index) => root.style.setProperty(`--${key}`, preset.bg[index]));
  root.style.setProperty("--ai-bubble", preset.ai);
  root.style.setProperty("--user-bubble", preset.user);
  root.style.setProperty("--ink", preset.ink);
  root.style.setProperty("--ink-soft", preset.soft);
  root.style.setProperty("--ink-faint", preset.faint);
  root.style.setProperty("--accent", preset.accent);
  root.style.setProperty("--accent-light", preset.light);
  root.style.setProperty("--accent-soft", `${preset.accent}24`);
  root.style.setProperty("--ambient-a", preset.dark ? `${preset.accent}24` : "rgba(203, 215, 234, 0.34)");
  root.style.setProperty("--ambient-b", preset.dark ? `${preset.light}18` : "rgba(234, 213, 220, 0.38)");
  root.classList.toggle("theme-is-dark", preset.dark);
  root.style.setProperty("--nav-bg", preset.nav);
  root.style.setProperty("--nav-inactive", preset.inactive);
  root.style.setProperty("--glass-input", preset.dark ? "rgba(24,20,28,.72)" : "rgba(255,255,255,.72)");
  root.style.setProperty("--glass-white", preset.dark ? "rgba(0,0,0,.20)" : "rgba(255,255,255,.82)");
  root.style.setProperty("--glass-border", preset.dark ? "rgba(255,255,255,.12)" : "rgba(255,255,255,.56)");
  root.style.setProperty("--line", `${preset.accent}29`);
  root.style.setProperty("--nav-border", preset.dark ? "rgba(255,255,255,.08)" : "rgba(255,255,255,.5)");
  root.style.setProperty("--nav-shadow-a", preset.dark ? "rgba(0,0,0,.35)" : "rgba(0,0,0,.10)");
  root.style.setProperty("--nav-shadow-b", preset.dark ? "rgba(0,0,0,.20)" : "rgba(0,0,0,.05)");
  root.style.colorScheme = preset.dark ? "dark" : "light";
  if (profileThemeToggle) {
    profileThemeToggle.setAttribute("aria-pressed", String(preset.dark));
    profileThemeToggle.innerHTML = preset.dark
      ? '<svg class="line-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 15.5A8.5 8.5 0 0 1 8.5 4 8.5 8.5 0 1 0 20 15.5Z"/></svg>'
      : '<svg class="line-icon" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M4.93 4.93l1.42 1.42m11.3 11.3 1.42 1.42M2 12h2m16 0h2M4.93 19.07l1.42-1.42m11.3-11.3 1.42-1.42"/></svg>';
  }
  applyBubbleTuning();
  window.dispatchEvent(new CustomEvent("holt:themechange", { detail: { preset, id: activeThemeId } }));
  if (persist) void setSetting("themePreset", activeThemeId);
  if (render) renderThemeWorkshop();
  else {
    syncThemePresetSelection();
    updateThemePreview();
  }
}

let ignoreThemeScroll = 0;

function syncThemePresetSelection() {
  ignoreThemeScroll++;
  [themePresetListLight, themePresetListDark].forEach((list) => list?.querySelectorAll("[data-theme-id]").forEach((button) => {
    const selected = button.dataset.themeId === activeThemeId;
    button.classList.toggle("is-selected", selected);
    button.setAttribute("aria-pressed", String(selected));
  }));
  setTimeout(() => ignoreThemeScroll--, 100);
}

function renderThemeRail(list, entries) {
  if (!list) return;
  list.innerHTML = entries.map(([id, preset]) => `
    <button class="theme-preset ${id === activeThemeId ? "is-selected" : ""}" style="--swatch-accent:${preset.accent}" data-theme-id="${id}" type="button" role="listitem" aria-pressed="${id === activeThemeId}" aria-label="${preset.name}：${preset.subtitle}">
      <span class="theme-preset-swatch" style="--swatch-a:${preset.bg[0]};--swatch-b:${preset.bg[3]}"></span>
    </button>`).join("");
}

let themeScrollTimer;

function handleThemeRailScroll(list) {
  if (ignoreThemeScroll) return;
  const cards = [...list.querySelectorAll("[data-theme-id]")];
  if (!cards.length) return;
  const center = list.getBoundingClientRect().left + list.clientWidth / 2;
  const nearest = cards.reduce((best, card) => {
    const distance = Math.abs(card.getBoundingClientRect().left + card.offsetWidth / 2 - center);
    return distance < best.distance ? { card, distance } : best;
  }, { card: cards[0], distance: Infinity }).card;
  if (nearest.dataset.themeId !== activeThemeId) applyThemePreset(nearest.dataset.themeId, { persist: false, render: false });
  clearTimeout(themeScrollTimer);
  themeScrollTimer = window.setTimeout(() => setSetting("themePreset", activeThemeId), 160);
}

function bindThemeRail(list) {
  list?.addEventListener("click", (event) => {
    const button = event.target.closest("[data-theme-id]");
    if (button) applyThemePreset(button.dataset.themeId);
  });
  list?.addEventListener("scroll", () => handleThemeRailScroll(list), { passive: true });
}

function scrollActiveThemeIntoView() {
  requestAnimationFrame(() => {
    const selected = themePresetListLight?.querySelector(".is-selected") || themePresetListDark?.querySelector(".is-selected");
    selected?.scrollIntoView({ behavior: "auto", block: "nearest", inline: "center" });
  });
}

function updateThemePreview() {
  if (!themePreview) return;
  const preset = PWA_THEME_PRESETS[activeThemeId];
  themePreview.style.setProperty("--preview-a", preset.bg[0]);
  themePreview.style.setProperty("--preview-b", preset.bg[3]);
  themePreview.style.setProperty("--preview-ai", preset.ai);
  themePreview.style.setProperty("--preview-user", preset.user);
  if (themePreviewName) themePreviewName.textContent = preset.name;
  if (themePreviewSubtitle) themePreviewSubtitle.textContent = preset.subtitle;
}

function renderThemeWorkshop() {
  ignoreThemeScroll++;
  const lightPresets = Object.entries(PWA_THEME_PRESETS).filter(([, preset]) => !preset.dark);
  const darkPresets = Object.entries(PWA_THEME_PRESETS).filter(([, preset]) => preset.dark);
  renderThemeRail(themePresetListLight, lightPresets);
  renderThemeRail(themePresetListDark, darkPresets);
  const inactiveRail = PWA_THEME_PRESETS[activeThemeId]?.dark ? themePresetListLight : themePresetListDark;
  if (inactiveRail) inactiveRail.scrollLeft = 0;
  updateThemePreview();
  setTimeout(() => ignoreThemeScroll--, 100);
}

function setProfileEditorOpen(open) {
  profileEditor?.toggleAttribute("hidden", !open);
  profileEditorToggle?.setAttribute("aria-expanded", String(open));
  profileIdentity?.setAttribute("aria-expanded", String(open));
}

function openThemeWorkshop() {
  renderThemeWorkshop();
  applyBubbleTuning();
  themeWorkshop?.removeAttribute("hidden");
  scrollActiveThemeIntoView();
}

function closeThemeWorkshop() {
  themeWorkshop?.setAttribute("hidden", "");
}

// ═══ Event bindings ═══

profileThemeToggle?.addEventListener("click", () => {
  applyThemePreset(PWA_THEME_PRESETS[activeThemeId]?.dark ? "ivory" : "midnight");
});
profileUsageBtn?.addEventListener("click", () => switchTab(1));
profileIdentity?.addEventListener("click", () => setProfileEditorOpen(profileEditor?.hasAttribute("hidden")));
themeWorkshopBtn?.addEventListener("click", openThemeWorkshop);
themeWorkshopClose?.addEventListener("click", closeThemeWorkshop);
bindThemeRail(themePresetListLight);
bindThemeRail(themePresetListDark);
themeBubbleOpacity?.addEventListener("input", () => {
  bubbleOpacity = Number(themeBubbleOpacity.value);
  applyBubbleTuning();
  void setSetting("bubbleOpacity", bubbleOpacity);
});
themeBubbleRadius?.addEventListener("input", () => {
  bubbleRadius = Number(themeBubbleRadius.value);
  applyBubbleTuning();
  void setSetting("bubbleRadius", bubbleRadius);
});

// ═══ Profile rendering ═══

async function renderProfile() {
  const nick = (await getSetting("userName")) || "";
  const pronoun = (await getSetting("userPronoun")) || "";
  const bio = (await getSetting("userBio")) || "";
  const avatar = await getSetting("userAvatar");
  const fontChoice = (await getSetting("fontChoice")) || "system";

  profileDisplayName.textContent = nick || "未設定";
  $("#profileNick").value = nick;
  $("#profilePronoun").value = pronoun;
  $("#profileBio").value = bio;
  profileFont.innerHTML = Object.entries(getFontOptions())
    .map(([id, option]) => `<option value="${id}">${option.label}</option>`)
    .join("");
  profileFont.value = getFontOptions()[fontChoice] ? fontChoice : "system";

  if (avatar) {
    profileAvatar.innerHTML = `<img src="${avatar}" alt="">`;
  } else {
    profileAvatar.innerHTML = `<svg class="line-icon profile-avatar-default" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="3.2"/><path d="M5.5 20a6.5 6.5 0 0 1 13 0"/></svg>`;
  }
}

profileAvatarBtn.addEventListener("click", (event) => {
  event.stopPropagation();
  profileAvatarPicker.click();
});

profileAvatarPicker.addEventListener("change", async () => {
  const file = profileAvatarPicker.files[0];
  if (!file) return;
  try {
    const dataUrl = await openAvatarCropper(file, { title: "裁剪使用者頭像" });
    if (!dataUrl) return;
    await setSetting("userAvatar", dataUrl);
    profileAvatar.innerHTML = `<img src="${dataUrl}" alt="" decoding="async">`;
  } catch (err) {
    toast("頭像處理失敗：" + err.message);
  } finally {
    profileAvatarPicker.value = "";
  }
});

profileSaveBtn.addEventListener("click", async () => {
  await setSetting("userName", $("#profileNick").value.trim());
  await setSetting("userPronoun", $("#profilePronoun").value.trim());
  await setSetting("userBio", $("#profileBio").value.trim());
  profileDisplayName.textContent = $("#profileNick").value.trim() || "未設定";
  setProfileEditorOpen(false);
  toast("已儲存");
});

profileFont.addEventListener("change", async () => {
  const choice = profileFont.value;
  await setSetting("fontChoice", choice);
  profileFontHint.textContent = "字體載入中，先維持目前字體……";
  const result = await applyFontPreference(choice);
  profileFontHint.textContent = result.loaded
    ? "字體已套用；下次開啟會優先沿用瀏覽器快取。"
    : "外部字體暫時無法取得，已維持內建字體。";
});

// ═══ Backup ═══

const PROFILE_BACKUP_SETTINGS = [
  "provider", "model", "customEndpoint", "userName", "userPronoun", "userBio",
  "userAvatar", "fontChoice", "themePreset", "bubbleOpacity", "bubbleRadius",
  "onboardingDone", "promptCachingEnabled",
];

function askBackupPassword({ confirmation = false } = {}) {
  const password = window.prompt(confirmation ? "請設定 Holt 備份密碼（至少 8 個字元）" : "請輸入 Holt 備份密碼");
  if (password === null) return null;
  if (password.length < 8) {
    toast("備份密碼至少需要 8 個字元");
    return null;
  }
  if (confirmation) {
    const repeated = window.prompt("請再次輸入備份密碼確認");
    if (repeated === null) return null;
    if (repeated !== password) {
      toast("兩次輸入的備份密碼不一致");
      return null;
    }
  }
  return password;
}

async function collectPwaBackup() {
  const chars = await listCharacters();
  const allConvs = await listConversations();
  const allMsgs = [];
  for (const c of allConvs) {
    const msgs = await getMessagesByConversation(c.id);
    allMsgs.push(...msgs);
  }
  const settings = {};
  for (const key of PROFILE_BACKUP_SETTINGS) settings[key] = await getSetting(key);
  return {
    type: "holt_pwa_backup",
    version: 2,
    exportedAt: new Date().toISOString(),
    characters: chars,
    conversations: allConvs,
    messages: allMsgs,
    settings,
  };
}

function normalizeImportedDump(dump) {
  if (dump?.type === "holt_pwa_backup") return dump;
  if (dump?.type === "holt_full_export") {
    const characters = (dump.characters || []).map((row) => ({
      id: String(row.id), name: row.name || "", gender: row.gender || "",
      relationship: row.relationship || "", description: row.description || "",
      race: row.race || "", skill: row.skill || "", age: row.age || "",
      height: row.height || "", avatarDataUrl: String(row.avatar_path || "").startsWith("data:") ? row.avatar_path : "",
      selfNotes: row.self_notes || "", ttsVoiceId: row.tts_voice_id || "",
      createdAt: row.created_at || new Date(0).toISOString(), updatedAt: row.updated_at || new Date(0).toISOString(),
    }));
    const conversations = (dump.conversations || []).map((row) => ({
      id: String(row.id), characterId: String(row.character_id || ""),
      title: row.title || "新對話", createdAt: row.created_at || new Date(0).toISOString(),
      updatedAt: row.updated_at || new Date(0).toISOString(),
    }));
    const messages = (dump.messages || []).map((row) => ({
      id: String(row.id), conversationId: String(row.conversation_id || ""),
      role: Number(row.is_user) ? "user" : "assistant", content: row.text || "",
      createdAt: row.created_at || new Date(0).toISOString(),
    }));
    return { type: "holt_pwa_backup", version: 2, characters, conversations, messages, settings: {} };
  }
  throw new Error("不是可辨識的 Holt 備份檔");
}

async function applyImportedDump(rawDump) {
  const dump = normalizeImportedDump(rawDump);
  for (const c of (dump.characters || [])) await saveCharacter(c);
  for (const c of (dump.conversations || [])) await saveConversation(c);
  for (const m of (dump.messages || [])) await saveMessage(m);
  if (dump.settings) {
    const supportedProviders = new Set(["openrouter", "grok", "gemini", "custom"]);
    const importedProvider = String(dump.settings.provider || "");
    const hasSupportedProvider = supportedProviders.has(importedProvider);
    for (const key of PROFILE_BACKUP_SETTINGS) {
      let value = dump.settings[key];
      if (key === "provider" && !hasSupportedProvider) {
        value = "openrouter";
      }
      if (key === "model" && !hasSupportedProvider) {
        value = "";
      }
      if (value != null) await setSetting(key, value);
    }
  }
}

// Data export
exportDataBtn.addEventListener("click", async () => {
  try {
    const password = askBackupPassword({ confirmation: true });
    if (!password) return;
    toast("正在加密備份……", 6000);
    const dump = await collectPwaBackup();
    const zip = makePortableZip(dump);
    const encrypted = await encryptHoltBackup(zip, password);
    const blob = new Blob([encrypted], { type: "application/octet-stream" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `holt_backup_${new Date().toISOString().slice(0, 10)}.holt.backup`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    toast("已匯出加密備份");
  } catch (err) { toast("匯出失敗：" + err.message); }
});

// Data import
importDataBtn.addEventListener("click", () => {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = ".json,.zip,.holt.zip,.backup,.holt.backup,application/json,application/zip,application/octet-stream";
  input.onchange = async () => {
    const file = input.files[0];
    if (!file) return;
    if (!confirm("匯入會覆蓋現有數據，確定？")) return;
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      const password = isEncryptedBackup(bytes) ? askBackupPassword() : "";
      if (isEncryptedBackup(bytes) && !password) return;
      const dump = await readBackupDump(bytes, password);
      await applyImportedDump(dump);
      toast("已匯入");
      await renderProfile();
      await renderHomeContent();
    } catch (err) { toast("匯入失敗：" + err.message); }
  };
  input.click();
});

// ═══ Theme init (called from app.js) ═══

export async function initTheme() {
  const savedTheme = await getSetting("themePreset");
  bubbleOpacity = Number(await getSetting("bubbleOpacity")) || 100;
  bubbleRadius = Number(await getSetting("bubbleRadius")) || 18;
  applyThemePreset(savedTheme || "ivory", { persist: false });
  // Font preference: non-blocking background load
  getSetting("fontChoice").then((choice) => {
    if (choice && choice !== "system") void applyFontPreference(choice);
  });
}
