/**
 * Holt PWA — 首頁 + 對話
 */

import { $, $$, state, toast, formatMarkdown, compactImageToDataUrl, pillNav, registerTabHandler } from "./app.js";
import {
  getSetting, setSetting,
  listCharacters, getCharacter,
  newConversation, saveConversation, getConversation, deleteConversation, listConversations,
  toggleStarConversation, updateConversationTitle, searchConversations,
  newMessage, saveMessage, deleteMessage, getMessagesByConversation,
  getStarredModels, getStarredModelProviders, saveStarredModels, toggleStarModel, isModelStarred,
  getThinkingChainEnabled, setThinkingChainEnabled,
  saveSticker, listStickers,
  listFeatureRecords, getBalance, applyBalanceDeltas,
  logUsage,
} from "./db.js";
import { getProviderConfig, streamChat, fetchModels, isUsablePwaModelId } from "./api.js";
import { buildCoreStructuredPrompt } from "./prompt-builder.js";
import { explicitWebSearchQuery, searchWeb, webSearchEvidence, WEB_SEARCH_MODES } from "./web-search.js";
import { generateImage, getImageGenerationConfig, imageGenerationAbilityPrompt, parseDrawIntent } from "./image-generation.js";
import {
  getCompanionSettings, setCompanionSettings,
  prepareCompanionContext, processCompanionReply, stripCompanionTags, splitReplySegments,
  toggleSavedText, saveAudioResource, resolveMemoryLinkProposal,
  createScratchCard,
} from "./companion-features.js";
import { getActiveThemePreset, PWA_THEME_PRESETS } from "./ui-profile.js";

// ═══ DOM refs ═══

const homeView = $("#homeView");
const chatView = $("#chatView");
const homeGreeting = $("#homeGreeting");
const homeShellBalanceValue = $("#homeShellBalanceValue");
const homeCarousel = $("#homeCarousel");
const homeCarouselPrev = $("#homeCarouselPrev");
const homeCarouselNext = $("#homeCarouselNext");
const homeHistoryBtn = $("#homeHistoryBtn");
const homeLiveStage = $("#homeLiveStage");
const homeHeartbeatVal = $("#homeHeartbeatVal");
const homeBpmValue = $("#homeBpmValue");
const homeEcgDock = $("#homeEcgDock");
const homeEcgCanvas = $("#homeEcgCanvas");
const homePulsingDot = $("#homePulsingDot");

const historyModal = $("#historyModal");
const historyCloseBtn = $("#historyCloseBtn");
const historyNewConvBtn = $("#historyNewConvBtn");
const historySearchInput = $("#historySearchInput");
const historySearchClear = $("#historySearchClear");
const historyList = $("#historyList");

const chatBackBtn = $("#chatBackBtn");
const chatName = $("#chatName");
const chatModelBtn = $("#chatModelBtn");
const chatModelPickerModal = $("#chatModelPickerModal");
const chatThinkingToggle = $("#chatThinkingToggle");
const chatConciseReplyToggle = $("#chatConciseReplyToggle");
const chatSplitReplyToggle = $("#chatSplitReplyToggle");
const chatReplyLinesInput = $("#chatReplyLinesInput");
const chatModelSearchInput = $("#chatModelSearchInput");
const chatModelPickerList = $("#chatModelPickerList");
const chatCustomModelInput = $("#chatCustomModelInput");
const chatCustomModelApply = $("#chatCustomModelApply");

let chatModelCatalog = null;
let chatModelCatalogProvider = "";
let chatModelRenderVersion = 0;
let historySearchTimer = null;
let historyRenderVersion = 0;

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;",
  })[character]);
}

function safeDisplayImageUrl(value) {
  const raw = String(value || "");
  if (/^data:image\/(?:png|jpeg|webp);base64,/i.test(raw)) return raw;
  try {
    const url = new URL(raw);
    return url.protocol === "https:" && !url.username && !url.password ? url.toString() : "";
  } catch { return ""; }
}

function safeExternalUrl(value) {
  try {
    const url = new URL(String(value || ""));
    return url.protocol === "https:" && !url.username && !url.password ? url.toString() : "";
  } catch { return ""; }
}

const messageList = $("#messageList");
const emptyState = $("#emptyState");
const messageInput = $("#messageInput");
const sendButton = $("#sendButton");
const sendLeaf = $("#sendLeaf");
const addButton = $("#addButton");
const composerShell = $("#composerShell");
const actionPanel = $("#actionPanel");
const imagePicker = $("#imagePicker");
const stickerPicker = $("#stickerPicker");
const audioPicker = $("#audioPicker");

// ═══ ECG Waveform Animator (v3 – Flutter-matched) ═══
//
// 像素級復刻 Flutter _EcgPainter：
//  • 分段式 P-QRS-T 波形（與 Flutter if/else 邏輯一致）
//  • 固定 waveLen = w * 0.32（不依賴 BPM）
//  • 立方衰減尾跡 t³（Flutter brightness() 函數）
//  • 三層光暈：寬光暈(blur 25) → 窄光暈(blur 8) → 主線(1.5px)
//  • 掃描頭：亮點(blur 4, r=3) + 暈圈(blur 20, r=12)
//  • 光點：40px RadialGradient + boxShadow，sin 脈衝

class EcgAnimator {
  constructor({ canvas, pulsingDot, dock }) {
    this.canvas = canvas;
    this.ctx = canvas?.getContext("2d", { alpha: true });
    this.pulsingDot = pulsingDot;
    this.dock = dock;

    this.animId = null;
    this.startTime = null;
    this.duration = 4000; // 4s cycle (matches Flutter AnimationController)
    this.running = false;
    this.colors = null;

    this.dpr = window.devicePixelRatio || 1;
    this.width = 0;
    this.height = 0;

    // ── Perf: wave LUT (piecewise, matches Flutter) ──
    this._waveLutSize = 1024;
    this._waveLut = null;

    // ── Perf: pulsing-dot throttle ──
    this._lastDotScale = -1;
    this._lastDotOpacity = -1;

    this.resizeObserver = null;
    this.reduceMotionQuery = window.matchMedia?.("(prefers-reduced-motion: reduce)") || null;
    this.reduceMotion = Boolean(this.reduceMotionQuery?.matches);
    this.init();
  }

  init() {
    if (!this.canvas || !this.ctx) return;

    this._buildWaveLut();
    this.updateColors();

    window.addEventListener("holt:themechange", () => {
      this.updateColors();
    });

    this.reduceMotionQuery?.addEventListener?.("change", (event) => {
      this.reduceMotion = event.matches;
      if (this.reduceMotion) {
        this.stop();
        this.start();
      } else if (state.currentTab === 2 && !state.currentConvId) {
        this.start();
      }
    });

    document.addEventListener("visibilitychange", () => {
      if (document.hidden) {
        this.stop();
      } else if (state.currentTab === 2 && !state.currentConvId) {
        this.start();
      }
    });

    if (window.ResizeObserver && this.dock) {
      this.resizeObserver = new ResizeObserver(() => {
        this.resize();
      });
      this.resizeObserver.observe(this.dock);
    } else {
      window.addEventListener("resize", () => this.resize());
    }

    this.resize();
  }

  // ── Wave LUT: piecewise P-QRS-T matching Flutter _EcgPainter.waveY ──

  _buildWaveLut() {
    const N = this._waveLutSize;
    const lut = new Float64Array(N);
    const PI = Math.PI;
    for (let i = 0; i < N; i++) {
      const t = i / N;
      let y = 0;
      if (t < 0.30) {
        y = 0; // 平線
      } else if (t < 0.38) {
        // P波（小圓弧）
        const p = (t - 0.30) / 0.08;
        y = -12 * Math.sin(p * PI);
      } else if (t < 0.42) {
        y = 0; // 短平線
      } else if (t < 0.46) {
        // Q 下降
        const p = (t - 0.42) / 0.04;
        y = 10 * p;
      } else if (t < 0.52) {
        // R 主峰（上衝）
        const p = (t - 0.46) / 0.06;
        y = 10 - 60 * Math.sin(p * PI);
      } else if (t < 0.56) {
        // S 下谷
        const p = (t - 0.52) / 0.04;
        y = 15 * (1 - p);
      } else if (t < 0.62) {
        y = 0; // 短平線
      } else if (t < 0.75) {
        // T波
        const p = (t - 0.62) / 0.13;
        y = -18 * Math.sin(p * PI);
      } else {
        y = 0; // 平線
      }
      lut[i] = y;
    }
    this._waveLut = lut;
  }

  // ── LUT sampled wave query ──

  _waveY(x, waveLen) {
    let t = (x % waveLen) / waveLen;
    if (t < 0) t += 1;
    const idx = (t * this._waveLutSize) & (this._waveLutSize - 1);
    return this._waveLut[idx];
  }

  // ── Flutter-matched cubic brightness: 離掃描頭越近越亮 ──

  _brightness(x, headX, trailLen) {
    const dist = headX - x;
    if (dist < 0 || dist > trailLen) return 0;
    const t = 1.0 - (dist / trailLen);
    return t * t * t; // 立方曲線，與 Flutter 一致
  }

  // ── Colour helpers ──

  hexToRgb(hex) {
    if (!hex) return { r: 93, g: 116, b: 146 };
    hex = hex.replace(/^#/, "");
    if (hex.length === 3) hex = hex.split("").map((c) => c + c).join("");
    const num = parseInt(hex, 16);
    return {
      r: (num >> 16) & 255,
      g: (num >> 8) & 255,
      b: num & 255,
    };
  }

  lerpRgb(c1, c2, t) {
    return {
      r: Math.round(c1.r + (c2.r - c1.r) * t),
      g: Math.round(c1.g + (c2.g - c1.g) * t),
      b: Math.round(c1.b + (c2.b - c1.b) * t),
    };
  }

  updateColors() {
    const rootStyle = getComputedStyle(document.documentElement);
    let preset = null;
    try {
      preset = getActiveThemePreset();
    } catch {
      preset = PWA_THEME_PRESETS?.ivory;
    }

    const isDark = document.documentElement.classList.contains("theme-is-dark") || Boolean(preset?.dark);
    const accentHex = rootStyle.getPropertyValue("--accent").trim() || preset?.accent || "#5d7492";
    const lightHex = rootStyle.getPropertyValue("--accent-light").trim() || preset?.light || "#a0b0c4";

    const accent = this.hexToRgb(accentHex);
    const accentLight = this.hexToRgb(lightHex);
    const white = { r: 255, g: 255, b: 255 };

    // Matches Flutter AppTheme getters:
    const lineRgb = isDark ? this.lerpRgb(accentLight, white, 0.65) : this.lerpRgb(accentLight, white, 0.3);
    const headRgb = isDark ? white : this.lerpRgb(accentLight, white, 0.55);
    const glowRgb = isDark ? accent : accentLight;

    this.colors = {
      // Flutter: color (ecgGlow)
      glowRgb,
      // Flutter: lineColor (ecgLine)
      lineRgb,
      // Flutter: headColor (ecgHead)
      headRgb,
      headColor: `rgb(${headRgb.r},${headRgb.g},${headRgb.b})`,
      // accent for pulsing dot
      accentRgb: accent,
    };
  }

  resize() {
    if (!this.canvas) return;
    const rect = this.dock ? this.dock.getBoundingClientRect() : this.canvas.getBoundingClientRect();
    if (!rect.width || !rect.height) return;

    this.dpr = window.devicePixelRatio || 1;
    this.width = rect.width;
    this.height = rect.height;

    this.canvas.width = Math.round(this.width * this.dpr);
    this.canvas.height = Math.round(this.height * this.dpr);
    this.canvas.style.width = `${this.width}px`;
    this.canvas.style.height = `${this.height}px`;

    this.ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.resize();
    if (this.reduceMotion) {
      this.draw(0.58);
      return;
    }
    const loop = (time) => {
      if (!this.running) return;
      try {
        if (!this.startTime) this.startTime = time;
        const elapsed = time - this.startTime;
        const progress = (elapsed % this.duration) / this.duration;
        this.draw(progress);
      } catch (err) {
        console.error("ECG draw error:", err);
      }
      this.animId = requestAnimationFrame(loop);
    };
    this.animId = requestAnimationFrame(loop);
  }

  stop() {
    this.running = false;
    if (this.animId) {
      cancelAnimationFrame(this.animId);
      this.animId = null;
    }
    if (this.ctx && this.width && this.height) {
      this.ctx.clearRect(0, 0, this.width, this.height);
    }
    if (this.pulsingDot) {
      this.pulsingDot.style.transform = "scale(1)";
      this.pulsingDot.style.opacity = "0.35";
    }
    this._lastDotScale = -1;
    this._lastDotOpacity = -1;
  }

  draw(progress) {
    const ctx = this.ctx;
    const w = this.width;
    const h = this.height;
    if (!ctx || w <= 0 || h <= 0) return;

    ctx.clearRect(0, 0, w, h);

    if (!this.colors) this.updateColors();
    const colors = this.colors;
    const midY = h / 2;

    // Flutter: waveLen = w * 0.32（固定比例，不依賴 BPM）
    const waveLen = w * 0.32;

    // 掃描頭位置（與 Flutter 一致）
    const headX = progress * w * 1.8 - w * 0.2;
    const trailLen = w * 0.7;

    const step = 2.0;

    // ── 光點：Flutter sin 脈衝（與 _buildPulsingDot 一致）──
    if (this.pulsingDot) {
      const beat = this.reduceMotion ? 0 : Math.sin(progress * 2 * Math.PI * 2);
      const absBeat = Math.abs(beat);
      const scale = 1.0 + absBeat * 0.4;
      const opacity = 0.35 + absBeat * 0.35;
      if (Math.abs(scale - this._lastDotScale) > 0.002 ||
          Math.abs(opacity - this._lastDotOpacity) > 0.002) {
        this.pulsingDot.style.transform = `scale(${scale.toFixed(3)})`;
        this.pulsingDot.style.opacity = opacity.toFixed(3);
        this._lastDotScale = scale;
        this._lastDotOpacity = opacity;
      }
    }

    // ── 第一層：寬光暈（Flutter: MaskFilter.blur(normal, 25), r=8, alpha=b*0.25）──
    const gR = colors.glowRgb.r;
    const gG = colors.glowRgb.g;
    const gB = colors.glowRgb.b;

    for (let x = 0; x < w; x += step * 2) {
      const b = this._brightness(x, headX, trailLen);
      if (b < 0.02) continue;
      const y = this._waveY(x, waveLen);

      ctx.save();
      ctx.fillStyle = `rgba(${gR},${gG},${gB},${(b * 0.25).toFixed(3)})`;
      ctx.shadowColor = `rgba(${gR},${gG},${gB},${(b * 0.25).toFixed(3)})`;
      ctx.shadowBlur = 25;
      ctx.beginPath();
      ctx.arc(x, midY + y, 8, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    // ── 第二層：窄光暈（Flutter: MaskFilter.blur(normal, 8), r=3, alpha=b*0.4）──
    for (let x = 0; x < w; x += step) {
      const b = this._brightness(x, headX, trailLen);
      if (b < 0.03) continue;
      const y = this._waveY(x, waveLen);

      ctx.save();
      ctx.fillStyle = `rgba(${gR},${gG},${gB},${(b * 0.4).toFixed(3)})`;
      ctx.shadowColor = `rgba(${gR},${gG},${gB},${(b * 0.4).toFixed(3)})`;
      ctx.shadowBlur = 8;
      ctx.beginPath();
      ctx.arc(x, midY + y, 3, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    // ── 第三層：主線條（Flutter: strokeWidth=1.5, lineColor alpha 0.9）──
    const lR = colors.lineRgb.r;
    const lG = colors.lineRgb.g;
    const lB = colors.lineRgb.b;

    let linePath = null;
    let lastB = 0;
    for (let x = 0; x < w; x += step) {
      const b = this._brightness(x, headX, trailLen);
      if (b < 0.03) {
        if (linePath && lastB >= 0.03) {
          ctx.save();
          ctx.strokeStyle = `rgba(${lR},${lG},${lB},0.9)`;
          ctx.lineWidth = 1.5;
          ctx.lineCap = "round";
          ctx.lineJoin = "round";
          ctx.stroke(linePath);
          ctx.restore();
          linePath = null;
        }
        lastB = b;
        continue;
      }
      const y = this._waveY(x, waveLen);
      if (!linePath) {
        linePath = new Path2D();
        linePath.moveTo(x, midY + y);
      } else {
        linePath.lineTo(x, midY + y);
      }
      lastB = b;
    }
    if (linePath) {
      ctx.save();
      ctx.strokeStyle = `rgba(${lR},${lG},${lB},0.9)`;
      ctx.lineWidth = 1.5;
      ctx.lineCap = "round";
      ctx.stroke(linePath);
      ctx.restore();
    }

    // ── 掃描頭（Flutter: 亮點 blur 4 r=3 + 暈圈 blur 20 r=12）──
    if (headX > 0 && headX < w) {
      const hy = midY + this._waveY(headX, waveLen);

      // 頭部額外光暈
      ctx.save();
      ctx.fillStyle = `rgba(${gR},${gG},${gB},0.5)`;
      ctx.shadowColor = `rgba(${gR},${gG},${gB},0.5)`;
      ctx.shadowBlur = 20;
      ctx.beginPath();
      ctx.arc(headX, hy, 12, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();

      // 頭部亮點
      ctx.save();
      ctx.fillStyle = colors.headColor;
      ctx.shadowColor = colors.headColor;
      ctx.shadowBlur = 4;
      ctx.beginPath();
      ctx.arc(headX, hy, 3, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }
  }
}

let ecgAnimator = null;
function getEcgAnimator() {
  if (!ecgAnimator && homeEcgCanvas) {
    ecgAnimator = new EcgAnimator({
      canvas: homeEcgCanvas,
      pulsingDot: homePulsingDot,
      dock: homeEcgDock,
    });
  }
  return ecgAnimator;
}

// ═══ Tab registration ═══

registerTabHandler(2, initHome);

// ═══ Home tab ═══

async function initHome() {
  if (!state.currentConvId) {
    homeView.removeAttribute("hidden");
    chatView.setAttribute("hidden", "");
  }
  await renderHomeContent();
  if (state.selectedCharId) getEcgAnimator()?.start();
}

export async function renderHomeContent() {
  const chars = await listCharacters();
  if (homeShellBalanceValue) homeShellBalanceValue.textContent = String(await getBalance("_user"));

  if (!state.selectedCharId) {
    state.selectedCharId = await getSetting("activeCharacterId");
  }

  const hour = new Date().getHours();
  let greet = "晚安";
  if (hour >= 5 && hour < 12) greet = "早安";
  else if (hour >= 12 && hour < 18) greet = "午安";

  homeGreeting.innerHTML = `
    <h2>${greet}</h2>
  `;

  homeCarousel.innerHTML = "";
  if (!chars.length) {
    homeLiveStage?.setAttribute("hidden", "");
    getEcgAnimator()?.stop();
    homeCarousel.classList.add("is-empty");
    homeCarouselPrev?.setAttribute("hidden", "");
    homeCarouselNext?.setAttribute("hidden", "");
    homeCarousel.innerHTML = `
      <button class="home-empty-character-entry" type="button" aria-label="新增角色">
        <span class="home-empty-character-mark" aria-hidden="true">✦</span>
        <span>還沒有角色</span>
      </button>
    `;
    homeCarousel.querySelector(".home-empty-character-entry")?.addEventListener("click", () => {
      document.querySelector("#newCharBtnNav")?.click();
    });
    return;
  }

  homeLiveStage?.removeAttribute("hidden");
  homeCarousel.classList.remove("is-empty");
  // Flutter PageView: viewportFraction=0.72，外層寬度為螢幕寬度減 28、最多 380px。
  const carouselWidth = Math.min(window.innerWidth - 28, 380);
  const cardWidth = carouselWidth * 0.72;
  homeCarousel.style.width = `${carouselWidth}px`;
  homeCarousel.style.setProperty("--carousel-card-width", `${cardWidth}px`);
  homeCarousel.style.maxWidth = "100%";

  const leadingSpacer = document.createElement("span");
  leadingSpacer.className = "carousel-spacer";
  homeCarousel.appendChild(leadingSpacer);

  const cards = [];
  const homeNotesByCharacter = new Map(await Promise.all(chars.map(async (character) => {
    const notes = await listFeatureRecords(character.id, "home_note");
    return [character.id, notes[0]?.value?.text || ""];
  })));
  // Online dwell: 選中角色 800ms 後顯示在線（與 Flutter _onlineDwellReady 行為一致）
  let onlineDwellTimer = null;
  let onlineDwellReady = false;

  chars.forEach((c, index) => {
    const card = document.createElement("div");
    card.className = "carousel-card";
    card.dataset.index = String(index);
    card.setAttribute("role", "option");
    card.setAttribute("aria-label", c.name || "未命名");

    const avatarSrc = c.avatarDataUrl || "";
    const sig = homeNotesByCharacter.get(c.id) || c.signature || "ta還沒有想說的～";
    const safeName = escapeHtml(c.name || "未命名");
    const safeSig = escapeHtml(sig);

    card.innerHTML = `
      <div class="carousel-card-inner">
        <div class="carousel-avatar">
          ${avatarSrc
            ? `<img src="${escapeHtml(avatarSrc)}" alt="" draggable="false"/>`
            : `<svg viewBox="0 0 24 24" width="27" height="27" fill="currentColor" aria-hidden="true"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>`
          }
        </div>
        <div class="carousel-card-text">
          <span class="carousel-name">${safeName}<span class="carousel-card-online-dot" aria-hidden="true"></span></span>
          <span class="carousel-signature">${safeSig}</span>
        </div>
      </div>
      <div class="carousel-card-online-label" aria-hidden="true">對方已上線</div>
    `;
    card.addEventListener("click", () => selectCarouselIndex(index, true));
    homeCarousel.appendChild(card);
    cards.push(card);
  });

  const trailingSpacer = document.createElement("span");
  trailingSpacer.className = "carousel-spacer";
  homeCarousel.appendChild(trailingSpacer);

  let selectedIndex = chars.findIndex((c) => c.id === state.selectedCharId);
  if (selectedIndex < 0) {
    selectedIndex = 0;
    state.selectedCharId = chars[0].id;
  }

  const updateCarousel = (selectedIdx, pagePosition = selectedIdx) => {
    cards.forEach((card, index) => {
      const isSel = index === selectedIdx;
      card.classList.toggle("is-selected", isSel);
      card.setAttribute("aria-selected", String(isSel));

      // Flutter AnimatedBuilder: neighboring cards reveal only while swiping;
      // at rest the selected card is the sole visible card.
      const diff = Math.abs(pagePosition - index);
      const scale = Math.max(0.84, Math.min(1, 1 - diff * 0.12));
      const swipeReveal = Math.max(0, Math.min(1, Math.abs(pagePosition - selectedIdx) / 0.25));
      const opacity = diff < 0.5
        ? 1
        : Math.max(0, Math.min(1, 1 - diff * 0.38)) * swipeReveal;
      card.style.transform = `scale(${scale})`;
      card.style.opacity = opacity.toFixed(3);

      // Online indicator: only selected card, after dwell
      const isOnline = isSel && onlineDwellReady && diff < 0.5;
      card.classList.toggle("is-online", isOnline);
    });
  };

  let settleTimer;
  homeCarousel.onscroll = () => {
    const leadingWidth = leadingSpacer.getBoundingClientRect().width;
    const pagePosition = (homeCarousel.scrollLeft + homeCarousel.clientWidth / 2 - leadingWidth - cardWidth / 2) / cardWidth;
    updateCarousel(selectedIndex, pagePosition);
    clearTimeout(settleTimer);
    settleTimer = setTimeout(() => {
      const nextIndex = Math.max(0, Math.min(chars.length - 1, Math.round(pagePosition)));
      if (nextIndex !== selectedIndex) selectCarouselIndex(nextIndex, false);
      else updateCarousel(selectedIndex, selectedIndex);
    }, 90);
  };

  async function updateHeartbeatDisplay() {
    if (!homeHeartbeatVal || !homeBpmValue) return;
    const hb = (state.selectedCharId ? await getSetting(`heartbeat_${state.selectedCharId}`) : null) || await getSetting("legacy_heartbeat");
    if (hb) {
      homeBpmValue.textContent = String(hb);
      homeHeartbeatVal.removeAttribute("hidden");
    } else {
      homeHeartbeatVal.setAttribute("hidden", "");
    }
  }

  const selectCarouselIndex = (index, animate) => {
    const clamped = Math.max(0, Math.min(chars.length - 1, index));
    state.selectedCharId = chars[clamped].id;
    void setSetting("activeCharacterId", state.selectedCharId);

    // Online dwell: 切換角色時重置，800ms 後顯示在線
    clearTimeout(onlineDwellTimer);
    onlineDwellReady = false;
    onlineDwellTimer = setTimeout(() => {
      onlineDwellReady = true;
      updateCarousel(clamped);
    }, 800);

    updateCarousel(clamped);
    homeCarouselPrev?.toggleAttribute("hidden", clamped <= 0);
    homeCarouselNext?.toggleAttribute("hidden", clamped >= chars.length - 1);

    // 滾動讓選中卡片居中
    const card = cards[clamped];
    if (card) {
      const containerW = homeCarousel.offsetWidth;
      const scrollTarget = card.offsetLeft - (containerW - cardWidth) / 2;
      homeCarousel.scrollTo({
        left: Math.max(0, scrollTarget),
        behavior: animate ? "smooth" : "auto",
      });
    }
    void updateHeartbeatDisplay();
  };

  // 點擊選中，不需要 scroll 自動選中
  updateCarousel(selectedIndex);
  homeCarouselPrev.toggleAttribute("hidden", selectedIndex <= 0);
  homeCarouselNext.toggleAttribute("hidden", selectedIndex >= chars.length - 1);
  void updateHeartbeatDisplay();
  requestAnimationFrame(() => selectCarouselIndex(selectedIndex, false));
  getEcgAnimator()?.start();
}

homeCarouselPrev?.addEventListener("click", () => {
  const cards = homeCarousel.querySelectorAll(".carousel-card");
  const selected = [...cards].findIndex((card) => card.classList.contains("is-selected"));
  if (selected > 0) cards[selected - 1]?.click();
});

homeCarouselNext?.addEventListener("click", () => {
  const cards = homeCarousel.querySelectorAll(".carousel-card");
  const selected = [...cards].findIndex((card) => card.classList.contains("is-selected"));
  if (selected >= 0 && selected < cards.length - 1) cards[selected + 1]?.click();
});

// ═══ Conversation History Modal ═══

homeHistoryBtn?.addEventListener("click", openHistoryModal);
historyCloseBtn?.addEventListener("click", closeHistoryModal);

historyModal?.addEventListener("click", (e) => {
  if (e.target === historyModal) closeHistoryModal();
});

historySearchInput?.addEventListener("input", () => {
  const hasVal = Boolean(historySearchInput.value);
  if (historySearchClear) {
    if (hasVal) historySearchClear.removeAttribute("hidden");
    else historySearchClear.setAttribute("hidden", "");
  }
  clearTimeout(historySearchTimer);
  historySearchTimer = window.setTimeout(() => void renderHistoryList(), 180);
});

historySearchClear?.addEventListener("click", () => {
  if (historySearchInput) {
    historySearchInput.value = "";
    historySearchInput.focus();
  }
  historySearchClear.setAttribute("hidden", "");
  clearTimeout(historySearchTimer);
  void renderHistoryList();
});

historyNewConvBtn?.addEventListener("click", async () => {
  if (!state.selectedCharId) { toast("先選一個角色"); return; }
  closeHistoryModal();
  const char = await getCharacter(state.selectedCharId);
  const conv = newConversation(state.selectedCharId, char?.name || "新對話");
  await saveConversation(conv);
  await enterChat(state.selectedCharId, conv.id);
});

async function openHistoryModal() {
  if (!state.selectedCharId) {
    toast("先選一個角色");
    return;
  }
  if (historySearchInput) historySearchInput.value = "";
  if (historySearchClear) historySearchClear.setAttribute("hidden", "");
  historyModal?.removeAttribute("hidden");
  await renderHistoryList();
}

function closeHistoryModal() {
  historyModal?.setAttribute("hidden", "");
}

async function renderHistoryList() {
  if (!state.selectedCharId || !historyList) return;
  const version = ++historyRenderVersion;
  const query = historySearchInput?.value?.trim() || "";
  const convs = query
    ? await searchConversations(query, state.selectedCharId)
    : await listConversations(state.selectedCharId);
  if (version !== historyRenderVersion) return;

  historyList.innerHTML = "";
  if (!convs.length) {
    historyList.innerHTML = `<div class="history-empty">${query ? "找不到符合的歷史對話" : "還沒有歷史對話"}</div>`;
    return;
  }

  convs.forEach((conv) => {
    const item = document.createElement("div");
    item.className = "history-item";
    item.setAttribute("role", "listitem");

    const dateStr = conv.updatedAt
      ? conv.updatedAt.substring(0, 16).replace("T", " ")
      : "";

    item.innerHTML = `
      <div class="history-item-main" role="button" tabindex="0">
        <div class="history-item-title-row">
          ${conv.isStarred ? '<span class="history-star-badge" aria-label="已加星">★</span>' : ""}
          <span class="history-item-title">${escapeHtml(conv.title || "新對話")}</span>
        </div>
        <span class="history-item-date">${escapeHtml(dateStr)}</span>
      </div>
      <div class="history-item-actions">
        <button class="history-action-btn" data-action="rename" type="button" aria-label="重命名" title="重命名">
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M12 20h9"></path>
            <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"></path>
          </svg>
        </button>
        <button class="history-action-btn ${conv.isStarred ? "is-starred" : ""}" data-action="star" type="button" aria-label="${conv.isStarred ? "取消星標" : "加星標"}" title="${conv.isStarred ? "取消星標" : "加星標"}">
          <svg viewBox="0 0 24 24" width="15" height="15" fill="${conv.isStarred ? "currentColor" : "none"}" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon>
          </svg>
        </button>
        <button class="history-action-btn is-delete" data-action="delete" type="button" aria-label="刪除對話" title="刪除對話">
          <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <polyline points="3 6 5 6 21 6"></polyline>
            <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
          </svg>
        </button>
      </div>
    `;

    item.querySelector(".history-item-main")?.addEventListener("click", async () => {
      closeHistoryModal();
      await enterChat(state.selectedCharId, conv.id);
    });

    item.querySelector(".history-item-main")?.addEventListener("keydown", async (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        closeHistoryModal();
        await enterChat(state.selectedCharId, conv.id);
      }
    });

    item.querySelector('[data-action="rename"]')?.addEventListener("click", async (e) => {
      e.stopPropagation();
      const newTitle = window.prompt("重命名對話：", conv.title || "");
      if (newTitle !== null && newTitle.trim()) {
        await updateConversationTitle(conv.id, newTitle.trim());
        await renderHistoryList();
      }
    });

    item.querySelector('[data-action="star"]')?.addEventListener("click", async (e) => {
      e.stopPropagation();
      await toggleStarConversation(conv.id, !conv.isStarred);
      await renderHistoryList();
    });

    item.querySelector('[data-action="delete"]')?.addEventListener("click", async (e) => {
      e.stopPropagation();
      if (window.confirm("確認刪除這段對話？")) {
        await deleteConversation(conv.id);
        await renderHistoryList();
        toast("已刪除對話");
      }
    });

    historyList.appendChild(item);
  });
}

// ═══ Enter chat & ECG Dock ═══

homeEcgDock?.addEventListener("click", async () => {
  if (!state.selectedCharId) { toast("先選一個角色"); return; }
  await enterChat(state.selectedCharId);
});

homeEcgDock?.addEventListener("keydown", async (e) => {
  if (e.key === "Enter" || e.key === " ") {
    e.preventDefault();
    if (!state.selectedCharId) { toast("先選一個角色"); return; }
    await enterChat(state.selectedCharId);
  }
});

$$(".pill-nav-item").forEach((btn) => {
  btn.addEventListener("click", () => {
    const idx = parseInt(btn.dataset.tab, 10);
    if (idx !== 2) {
      getEcgAnimator()?.stop();
    }
  });
});

async function enterChat(charId, specificConvId = null) {
  const char = await getCharacter(charId);
  if (!char) { toast("角色不存在"); return; }

  getEcgAnimator()?.stop();

  let conv = null;
  if (specificConvId) {
    conv = await getConversation(specificConvId);
  }
  if (!conv) {
    const convs = await listConversations(charId);
    conv = convs[0];
  }
  if (!conv) {
    conv = newConversation(charId, char.name || "新對話");
    await saveConversation(conv);
  }

  state.currentConvId = conv.id;
  state.selectedCharId = charId;

  chatName.textContent = char.name || "對話";
  messageInput.placeholder = char.whisperModelText || char.whisperUserText || "我在……";
  const cfg = await getProviderConfig();
  chatModelBtn.textContent = (cfg.model || "未設定模型") + " ⌄";

  homeView.setAttribute("hidden", "");
  chatView.removeAttribute("hidden");
  pillNav.style.display = "none";
  loadSendLeaf();

  await renderMessages();
  scrollToBottom();
}

let sendLeafLoadStarted = false;
function loadSendLeaf() {
  if (sendLeafLoadStarted || !sendLeaf) return;
  const source = sendLeaf.dataset.src;
  if (!source) return;
  sendLeafLoadStarted = true;
  sendLeaf.src = source;
}

chatBackBtn.addEventListener("click", () => {
  if (state.isStreaming) {
    state.abortController?.abort();
    state.isStreaming = false;
    sendButton.classList.remove("is-streaming");
  }
  state.currentConvId = null;
  chatView.setAttribute("hidden", "");
  homeView.removeAttribute("hidden");
  pillNav.style.display = "";
  renderHomeContent();
  getEcgAnimator()?.start();
});

// ═══ Chat AppBar Model Picker ═══

chatModelBtn?.addEventListener("click", (e) => {
  e.stopPropagation();
  toggleChatModelPicker();
});

document.addEventListener("click", (e) => {
  if (chatModelPickerModal && !chatModelPickerModal.hasAttribute("hidden") && !chatModelPickerModal.contains(e.target) && e.target !== chatModelBtn) {
    closeChatModelPicker();
  }
});

async function toggleChatModelPicker() {
  if (!chatModelPickerModal) return;
  if (chatModelPickerModal.hasAttribute("hidden")) {
    await openChatModelPicker();
  } else {
    closeChatModelPicker();
  }
}

async function openChatModelPicker() {
  if (!chatModelPickerModal) return;
  chatModelPickerModal.removeAttribute("hidden");
  if (chatThinkingToggle) {
    chatThinkingToggle.checked = await getThinkingChainEnabled();
  }
  const companionSettings = await getCompanionSettings();
  if (chatConciseReplyToggle) chatConciseReplyToggle.checked = companionSettings.conciseReply;
  if (chatSplitReplyToggle) chatSplitReplyToggle.checked = companionSettings.splitReply;
  if (chatReplyLinesInput) chatReplyLinesInput.value = String(companionSettings.maxReplyLines);
  if (chatModelSearchInput) chatModelSearchInput.value = "";
  if (chatCustomModelInput) chatCustomModelInput.value = "";
  chatModelCatalog = null;
  chatModelCatalogProvider = "";
  await renderChatModelList();
}

function closeChatModelPicker() {
  chatModelPickerModal?.setAttribute("hidden", "");
}

chatThinkingToggle?.addEventListener("change", async (e) => {
  const enabled = e.target.checked;
  await setThinkingChainEnabled(enabled);
  toast(enabled ? "已開啟思考鏈 (Reasoning)" : "已關閉思考鏈");
});

chatConciseReplyToggle?.addEventListener("change", async (event) => {
  await setCompanionSettings({ conciseReply: event.target.checked });
  toast(event.target.checked ? "已使用精簡回覆" : "已關閉精簡回覆");
});

chatSplitReplyToggle?.addEventListener("change", async (event) => {
  await setCompanionSettings({ splitReply: event.target.checked });
  toast(event.target.checked ? "已開啟拆分回覆" : "已關閉拆分回覆");
});

chatReplyLinesInput?.addEventListener("change", async (event) => {
  const value = Math.max(2, Math.min(20, Number(event.target.value) || 8));
  event.target.value = String(value);
  await setCompanionSettings({ maxReplyLines: value });
});

chatReplyLinesInput?.addEventListener("input", async (event) => {
  const value = Number(event.target.value);
  if (!Number.isFinite(value) || value < 2 || value > 20) return;
  await setCompanionSettings({ maxReplyLines: value });
});

chatModelSearchInput?.addEventListener("input", () => {
  void renderChatModelList();
});

chatCustomModelApply?.addEventListener("click", async () => {
  const customModel = chatCustomModelInput?.value?.trim();
  if (!customModel) { toast("請輸入模型 ID"); return; }
  const cfg = await getProviderConfig();
  await setSetting(`model_${cfg.providerId}`, customModel);
  await setSetting("model", customModel);
  chatModelBtn.textContent = customModel + " ⌄";
  closeChatModelPicker();
  toast(`已切換至模型：${customModel}`);
});

async function renderChatModelList() {
  if (!chatModelPickerList) return;
  const renderVersion = ++chatModelRenderVersion;
  const cfg = await getProviderConfig();
  const currentModel = cfg.model || "";
  const query = chatModelSearchInput?.value?.trim().toLowerCase() || "";
  const [allStarred, starredProviders] = await Promise.all([getStarredModels(), getStarredModelProviders()]);
  const starred = allStarred.filter((model) => isUsablePwaModelId(model) && starredProviders[model] === cfg.providerId);

  let fetched = chatModelCatalogProvider === cfg.providerId && chatModelCatalog
    ? chatModelCatalog
    : null;
  if (!fetched) {
    try {
      fetched = await fetchModels();
    } catch {
      fetched = [];
    }
    if (renderVersion !== chatModelRenderVersion) return;
    chatModelCatalog = fetched;
    chatModelCatalogProvider = cfg.providerId;
  }

  if (renderVersion !== chatModelRenderVersion) return;

  const allModelIds = Array.from(new Set([
    ...starred,
    ...fetched.map((m) => m.id).filter(isUsablePwaModelId),
    ...(isUsablePwaModelId(currentModel) ? [currentModel] : []),
  ])).filter(Boolean);

  let filtered = allModelIds;
  if (query) {
    filtered = allModelIds.filter((id) => id.toLowerCase().includes(query));
  }

  // Starred models first
  filtered.sort((a, b) => {
    const aStar = starred.includes(a);
    const bStar = starred.includes(b);
    if (aStar !== bStar) return aStar ? -1 : 1;
    return a.localeCompare(b);
  });

  chatModelPickerList.innerHTML = "";
  if (!filtered.length) {
    chatModelPickerList.innerHTML = `<div style="text-align:center;padding:18px;font-size:12px;color:var(--ink-faint);">找不到模型</div>`;
    return;
  }

  filtered.forEach((modelId) => {
    const isActive = modelId === currentModel;
    const isStarred = starred.includes(modelId);

    const row = document.createElement("div");
    row.className = `model-picker-row ${isActive ? "is-active" : ""}`;
    row.setAttribute("role", "button");
    row.setAttribute("tabindex", "0");

    row.innerHTML = `
      <div class="model-row-left">
        ${isActive ? '<span class="model-row-dot" aria-label="當前模型"></span>' : '<span style="width:6px;"></span>'}
        <span class="model-row-name" title="${escapeHtml(modelId)}">${escapeHtml(modelId)}</span>
      </div>
      <button class="model-star-btn ${isStarred ? "is-starred" : ""}" type="button" aria-label="${isStarred ? "取消星標" : "加星標"}">
        ${isStarred ? "★" : "☆"}
      </button>
    `;

    // Row click selects model
    row.querySelector(".model-row-left")?.addEventListener("click", async () => {
      await setSetting(`model_${cfg.providerId}`, modelId);
      await setSetting("model", modelId);
      chatModelBtn.textContent = modelId + " ⌄";
      closeChatModelPicker();
      toast(`已切換模型：${modelId}`);
    });

    // Star click toggles favorite
    row.querySelector(".model-star-btn")?.addEventListener("click", async (e) => {
      e.stopPropagation();
      await toggleStarModel(modelId, cfg.providerId);
      await renderChatModelList();
    });

    chatModelPickerList.appendChild(row);
  });
}

// ═══ Message Context Parser (Thinking, Memory, Emotion) ═══

function parseMessageContext(rawText, thinkingFallback = "", memoryFallback = "", emotionFallback = "") {
  if (typeof rawText !== "string") {
    return {
      cleanText: rawText,
      thinking: thinkingFallback,
      memoryLog: memoryFallback,
      emotionLog: emotionFallback,
    };
  }

  let text = rawText;
  let thinking = thinkingFallback || "";
  let memoryLog = memoryFallback || "";
  let emotionLog = emotionFallback || "";

  // 1. Extract <think>...</think>
  const thinkMatch = text.match(/<think>([\s\S]*?)(?:<\/think>|$)/i);
  if (thinkMatch) {
    thinking = (thinking ? thinking + "\n" : "") + thinkMatch[1].trim();
    text = text.replace(/<think>[\s\S]*?(?:<\/think>|$)/gi, "");
  }

  // 2. Extract <memory>...</memory>
  const memMatch = text.match(/<memory>([\s\S]*?)(?:<\/memory>|$)/i);
  if (memMatch) {
    memoryLog = (memoryLog ? memoryLog + "\n" : "") + memMatch[1].trim();
    text = text.replace(/<memory>[\s\S]*?(?:<\/memory>|$)/gi, "");
  }

  // 3. Extract <emo>...</emo> or <emotion>...</emotion>
  const emoMatch = text.match(/<(?:emo|emotion)>([\s\S]*?)(?:<\/(?:emo|emotion)>|$)/i);
  if (emoMatch) {
    emotionLog = (emotionLog ? emotionLog + "\n" : "") + emoMatch[1].trim();
    text = text.replace(/<(?:emo|emotion)>[\s\S]*?(?:<\/(?:emo|emotion)>|$)/gi, "");
  }

  // 4. Extract lines starting with "情緒座標：" or "[emotion: ...]"
  const lines = text.split("\n");
  const keepLines = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("情緒座標：") || trimmed.startsWith("情緒座標:") || /^\[emotion:.*?\]$/i.test(trimmed)) {
      emotionLog = (emotionLog ? emotionLog + "\n" : "") + trimmed;
    } else if (trimmed.startsWith("記憶：") || trimmed.startsWith("記憶:")) {
      memoryLog = (memoryLog ? memoryLog + "\n" : "") + trimmed;
    } else {
      keepLines.push(line);
    }
  }
  text = keepLines.join("\n").trim();

  return {
    cleanText: text,
    thinking: thinking.trim(),
    memoryLog: memoryLog.trim(),
    emotionLog: emotionLog.trim(),
  };
}

// ═══ Messages ═══

async function renderMessages() {
  const msgs = state.currentConvId ? await getMessagesByConversation(state.currentConvId) : [];
  messageList.innerHTML = "";

  if (!msgs.length) {
    messageList.appendChild(emptyState.cloneNode(true));
    return;
  }

  emptyState.setAttribute("hidden", "");

  for (const m of msgs) {
    if (m.role === "system") continue;
    appendMessageBubble(m);
  }
}

function appendTextBubbles(container, text, segments = []) {
  const values = Array.isArray(segments) && segments.length ? segments : [text];
  const stack = values.length > 1 ? document.createElement("div") : container;
  if (values.length > 1) stack.className = "message-segment-stack";
  for (const value of values.filter((item) => String(item || "").trim())) {
    const bubble = document.createElement("div");
    bubble.className = "message-bubble";
    bubble.innerHTML = formatMarkdown(value);
    stack.appendChild(bubble);
  }
  if (values.length > 1) container.appendChild(stack);
}

async function appendStickerContent(container, stickerId) {
  if (!stickerId) return;
  const sticker = (await listStickers()).find((item) => item.id === stickerId);
  const src = safeDisplayImageUrl(sticker?.dataUrl || sticker?.imageDataUrl || "");
  if (!src || !container.isConnected) return;
  const image = document.createElement("img");
  image.className = "chat-sticker-image";
  image.src = src;
  image.alt = sticker?.name ? `表情包：${sticker.name}` : "表情包";
  container.appendChild(image);
}

function appendAudioContent(container, msg) {
  if (!/^data:audio\/[a-z0-9.+-]+;base64,/i.test(String(msg.audioDataUrl || ""))) return;
  const card = document.createElement("div");
  card.className = "chat-audio-card";
  const audio = document.createElement("audio");
  audio.controls = true;
  audio.preload = "metadata";
  audio.src = msg.audioDataUrl;
  audio.setAttribute("aria-label", msg.audioName || "聲音");
  card.appendChild(audio);
  container.appendChild(card);
}

function toolCardStatus(card) {
  if (card.status === "accepted") return "已接受";
  if (card.status === "declined") return "已退還";
  if (card.status === "insufficient") return "貝殼不足";
  if (card.status === "revealed") return (card.prizes || []).map((prize) => prize.coins > 0 ? `+${prize.coins} 貝殼` : prize.label).join(" → ");
  return "";
}

function appendToolCard(container, msg, tool, index) {
  const card = document.createElement("section");
  card.className = `chat-tool-card ${["accepted", "declined", "insufficient", "revealed"].includes(tool.status) ? "is-resolved" : ""}`;
  if (tool.type === "scratch") {
    const status = toolCardStatus(tool);
    card.innerHTML = `<strong>刮刮樂</strong><div>${status || "一張還沒刮開的刮刮卡"}</div>`;
    if (tool.status === "ready") {
      const actions = document.createElement("div"); actions.className = "chat-tool-card-actions";
      const reveal = document.createElement("button"); reveal.type = "button"; reveal.textContent = "刮開";
      reveal.addEventListener("click", async () => {
        reveal.disabled = true;
        const total = (tool.prizes || []).reduce((sum, prize) => sum + Number(prize.coins || 0), 0);
        if (total > 0) await applyBalanceDeltas({ [tool.who === "user" ? "_user" : state.selectedCharId]: total });
        tool.status = "revealed";
        msg.toolCards[index] = tool;
        await saveMessage(msg);
        await renderMessages();
      });
      actions.appendChild(reveal); card.appendChild(actions);
    }
  } else if (tool.type === "transfer") {
    const direction = tool.direction === "charToUser" ? "角色轉給你" : "你轉給角色";
    card.innerHTML = `<strong>轉帳 ${Number(tool.amount || 0)} 貝殼</strong><div>${toolCardStatus(tool) || direction}</div>`;
    if (tool.status === "pending" && tool.direction === "charToUser") {
      const actions = document.createElement("div"); actions.className = "chat-tool-card-actions";
      for (const [label, accepted] of [["接受", true], ["退還", false]]) {
        const button = document.createElement("button"); button.type = "button"; button.textContent = label;
        button.addEventListener("click", async () => {
          [...actions.children].forEach((item) => { item.disabled = true; });
          if (accepted) {
            try {
              await applyBalanceDeltas({ [state.selectedCharId]: -tool.amount, _user: tool.amount });
              tool.status = "accepted";
            } catch { tool.status = "insufficient"; }
          } else tool.status = "declined";
          msg.toolCards[index] = tool; await saveMessage(msg); await renderMessages();
        });
        actions.appendChild(button);
      }
      card.appendChild(actions);
    }
  } else if (tool.type === "memory_link") {
    card.innerHTML = `<strong>記憶關聯</strong><div>${tool.status === "accepted" ? "已建立關聯" : tool.status === "declined" ? "已忽略" : "模型發現幾段記憶可能有關聯"}</div>`;
    if (tool.status === "pending") {
      const actions = document.createElement("div"); actions.className = "chat-tool-card-actions";
      for (const [label, accepted] of [["確認", true], ["略過", false]]) {
        const button = document.createElement("button"); button.type = "button"; button.textContent = label;
        button.addEventListener("click", async () => {
          [...actions.children].forEach((item) => { item.disabled = true; });
          await resolveMemoryLinkProposal(tool.proposalId, accepted);
          tool.status = accepted ? "accepted" : "declined"; msg.toolCards[index] = tool; await saveMessage(msg); await renderMessages();
        }); actions.appendChild(button);
      }
      card.appendChild(actions);
    }
  }
  container.appendChild(card);
}

async function appendMessageActions(container, msg) {
  if (msg.role !== "assistant" && !msg.audioDataUrl) return;
  const actions = document.createElement("div");
  actions.className = "message-actions";
  if (msg.role === "assistant") {
    const copy = document.createElement("button");
    copy.type = "button"; copy.className = "message-action-btn"; copy.textContent = "⧉"; copy.setAttribute("aria-label", "複製訊息");
    copy.addEventListener("click", async () => { await navigator.clipboard.writeText(stripCompanionTags(msg.content)); toast("已複製"); });
    const save = document.createElement("button");
    save.type = "button"; save.className = "message-action-btn"; save.textContent = "☆"; save.setAttribute("aria-label", "收藏文字訊息");
    const saved = await listFeatureRecords(state.selectedCharId, "saved_text");
    let active = saved.some((record) => record.value?.messageId === msg.id);
    save.classList.toggle("is-active", active); save.textContent = active ? "★" : "☆";
    save.addEventListener("click", async () => {
      active = await toggleSavedText(msg, state.selectedCharId, state.currentConvId);
      save.classList.toggle("is-active", active); save.textContent = active ? "★" : "☆";
      toast(active ? "已收藏文字" : "已取消收藏");
    });
    actions.append(copy, save);
  }
  if (msg.audioDataUrl) {
    const voice = document.createElement("button");
    voice.type = "button"; voice.className = "message-action-btn"; voice.textContent = "♫"; voice.setAttribute("aria-label", "收藏聲音");
    voice.addEventListener("click", async () => { await saveAudioResource({ characterId: state.selectedCharId, messageId: msg.id, conversationId: state.currentConvId, name: msg.audioName || "語音", dataUrl: msg.audioDataUrl, mimeType: msg.audioMime }); voice.classList.add("is-active"); toast("已收藏聲音"); });
    const download = document.createElement("a"); download.className = "message-action-btn"; download.textContent = "↓"; download.setAttribute("aria-label", "下載聲音"); download.href = msg.audioDataUrl; download.download = msg.audioName || "holt-voice.webm";
    actions.append(voice, download);
  }
  container.appendChild(actions);
}

function appendMessageBubble(msg) {
  messageList.querySelector(".empty-state")?.remove();
  const div = document.createElement("div");
  div.className = `message ${msg.role === "user" ? "user" : "assistant"}`;
  div.id = `msg-${msg.id}`;

  if (msg.role === "assistant") {
    if (msg.webSearchTrace) div.appendChild(buildWebSearchTraceCard(msg.webSearchTrace));
    const { cleanText, thinking, memoryLog, emotionLog } = parseMessageContext(
      typeof msg.content === "string" ? stripCompanionTags(msg.content) : "",
      msg.thinking || "",
      msg.memoryLog || "",
      msg.emotionLog || ""
    );

    if (thinking || memoryLog || emotionLog) {
      const thinkingCard = document.createElement("div");
      thinkingCard.className = "chat-thinking-card is-collapsed";
      thinkingCard.innerHTML = `
        <div class="thinking-header" role="button" tabindex="0" aria-label="展開或折疊思考過程">
          <span class="thinking-label-text">Thinking</span>
          <span class="thinking-toggle-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
              <polyline points="9 18 15 12 9 6"></polyline>
            </svg>
          </span>
        </div>
        <div class="thinking-body">
          ${thinking ? `<div class="thinking-text">${formatMarkdown(thinking)}</div>` : ""}
          ${memoryLog ? `
            <div class="memory-branch">
              <div class="branch-header">
                <span>Memory</span>
              </div>
              <div class="branch-body">${formatMarkdown(memoryLog)}</div>
            </div>` : ""}
          ${emotionLog ? `
            <div class="emotion-branch">
              <div class="branch-header">
                <span>Mood</span>
              </div>
              <div class="branch-body">${formatMarkdown(emotionLog)}</div>
            </div>` : ""}
        </div>
      `;

      thinkingCard.querySelector(".thinking-header")?.addEventListener("click", () => {
        thinkingCard.classList.toggle("is-collapsed");
      });
      div.appendChild(thinkingCard);
    }

    if (cleanText || (!msg.toolCards?.length && !msg.stickerId && !msg.audioDataUrl)) {
      appendTextBubbles(div, cleanText || "···", msg.segments);
    }
    if (msg.generatedImageDataUrl || msg.generatedImageStatus || msg.generatedImageError) {
      div.appendChild(buildGeneratedImageCard(msg));
    }
  } else {
    const bubble = document.createElement("div");
    bubble.className = "message-bubble";
    if (typeof msg.content === "string") {
      bubble.innerHTML = formatMarkdown(stripCompanionTags(msg.content));
    } else if (Array.isArray(msg.content)) {
      for (const part of msg.content) {
        if (part.type === "text") {
          const p = document.createElement("p");
          p.innerHTML = formatMarkdown(stripCompanionTags(part.text));
          bubble.appendChild(p);
        } else if (part.type === "image_url") {
          const img = document.createElement("img");
          img.className = "bubble-image";
          const safeUrl = safeDisplayImageUrl(part.image_url?.url);
          if (safeUrl) {
            img.src = safeUrl;
            bubble.appendChild(img);
          }
        }
      }
    }
    if (bubble.textContent.trim() || bubble.querySelector("img")) div.appendChild(bubble);
    if (msg.deliveryStatus === "failed") {
      const failure = document.createElement("div");
      failure.className = "message-delivery-error";
      const reason = document.createElement("span");
      reason.textContent = msg.deliveryError || "回覆失敗";
      const retry = document.createElement("button");
      retry.type = "button";
      retry.className = "message-retry-btn";
      retry.textContent = "重試";
      retry.addEventListener("click", () => retryUserMessage(msg));
      failure.append(reason, retry);
      div.style.flexDirection = "column";
      div.style.alignItems = "flex-end";
      div.appendChild(failure);
    }
  }

  appendAudioContent(div, msg);
  for (const [index, tool] of (msg.toolCards || []).entries()) appendToolCard(div, msg, tool, index);
  const stickerSlot = msg.stickerId ? document.createElement("div") : null;
  if (stickerSlot) div.appendChild(stickerSlot);

  messageList.appendChild(div);
  if (stickerSlot) void appendStickerContent(stickerSlot, msg.stickerId);
  void appendMessageActions(div, msg);
}

async function markUserMessageFailed(message, error) {
  if (!message) return;
  message.deliveryStatus = "failed";
  message.deliveryError = String(error?.message || "回覆失敗").slice(0, 280);
  await saveMessage(message);
}

async function retryUserMessage(message) {
  if (state.isStreaming) { toast("請先等待目前請求完成"); return; }
  await deleteMessage(message.id);
  state.pendingStickerId = message.stickerId || null;
  state.pendingTransferAmount = message.transferCard?.status === "pending" ? message.transferCard.amount : null;
  if (typeof message.content === "string") {
    messageInput.value = message.content;
  } else if (Array.isArray(message.content)) {
    const textPart = message.content.find((part) => part?.type === "text");
    const imagePart = message.content.find((part) => part?.type === "image_url");
    messageInput.value = textPart?.text || "";
    const dataUrl = String(imagePart?.image_url?.url || "");
    const match = dataUrl.match(/^data:([^;]+);base64,(.+)$/s);
    if (match) {
      state.pendingImageMime = match[1];
      state.pendingImageBase64 = match[2];
      showImagePreview(dataUrl);
    }
  }
  await renderMessages();
  await sendMessage();
}

function buildWebSearchTraceCard(trace) {
  const card = document.createElement("section");
  card.className = `web-search-trace ${trace.error ? "has-error" : ""}`;
  const sourceCount = trace.sources?.length || 0;
  card.innerHTML = `<div class="web-search-trace-header"><span class="web-search-pulse" aria-hidden="true"></span><strong>Web Search</strong><small>${trace.error ? "搜尋失敗" : `${WEB_SEARCH_MODES[trace.providerId] || trace.providerId} · ${sourceCount} 個來源`}</small></div>`;
  if (trace.error) {
    const error = document.createElement("p"); error.textContent = trace.error; card.appendChild(error);
  } else if (sourceCount) {
    const list = document.createElement("div"); list.className = "web-search-source-list";
    for (const source of trace.sources) {
      const safeUrl = safeExternalUrl(source.url);
      if (!safeUrl) continue;
      const link = document.createElement("a"); link.href = safeUrl; link.target = "_blank"; link.rel = "noopener noreferrer"; link.textContent = source.title || new URL(safeUrl).hostname; list.appendChild(link);
    }
    card.appendChild(list);
  }
  return card;
}

function buildGeneratedImageCard(msg) {
  const card = document.createElement("figure");
  card.className = `generated-image-card ${msg.generatedImageStatus === "generating" ? "is-generating" : ""}`;
  if (msg.generatedImageDataUrl) {
    const safeUrl = safeDisplayImageUrl(msg.generatedImageDataUrl);
    if (safeUrl) {
      const image = document.createElement("img"); image.src = safeUrl; image.alt = msg.generatedImagePrompt ? `生成圖片：${msg.generatedImagePrompt}` : "生成圖片"; image.loading = "lazy"; card.appendChild(image);
    } else {
      const status = document.createElement("div"); status.className = "generated-image-status"; status.textContent = "圖片來源無效或不安全"; card.appendChild(status);
    }
  } else {
    const status = document.createElement("div"); status.className = "generated-image-status"; status.textContent = msg.generatedImageError ? `生圖失敗：${msg.generatedImageError}` : "正在生成圖片…"; card.appendChild(status);
  }
  return card;
}

function scrollToBottom() {
  requestAnimationFrame(() => {
    messageList.scrollTop = messageList.scrollHeight;
  });
}

async function getSelfNotesWindowSnapshot(character) {
  const notes = String(character?.selfNotes || "").trim();
  if (!notes || !state.currentConvId) return "";
  const conversation = await getConversation(state.currentConvId);
  if (!conversation) return notes;
  if (typeof conversation.promptSelfNotesSnapshot === "string") {
    return conversation.promptSelfNotesSnapshot;
  }
  conversation.promptSelfNotesSnapshot = notes;
  await saveConversation(conversation);
  return notes;
}

// ═══ Sending messages ═══

async function sendMessage() {
  const text = messageInput.value.trim();
  if (!text && !state.pendingImageBase64) return;
  if (!state.currentConvId) return;
  if (state.isStreaming) {
    state.abortController?.abort();
    state.isStreaming = false;
    sendButton.classList.remove("is-streaming");
    return;
  }

  state.abortController = new AbortController();
  state.isStreaming = true;
  sendButton.classList.add("is-streaming");
  let userMsg = null;

  try {
  const userExtras = {};
  if (state.pendingStickerId) userExtras.stickerId = state.pendingStickerId;
  if (state.pendingTransferAmount) {
    userExtras.transferCard = { type: "transfer", direction: "userToChar", amount: state.pendingTransferAmount, status: "pending" };
    userExtras.toolCards = [userExtras.transferCard];
  }
  if (state.pendingImageBase64) {
    userMsg = newMessage(state.currentConvId, "user", [
      ...(text ? [{ type: "text", text }] : []),
      { type: "image_url", image_url: { url: `data:${state.pendingImageMime};base64,${state.pendingImageBase64}` } },
    ], userExtras);
    clearImagePreview();
  } else {
    userMsg = newMessage(state.currentConvId, "user", text, userExtras);
  }
  state.pendingStickerId = null;
  state.pendingTransferAmount = null;

  await saveMessage(userMsg);
  appendMessageBubble(userMsg);
  scrollToBottom();

  messageInput.value = "";
  messageInput.style.height = "auto";

  const allMsgs = await getMessagesByConversation(state.currentConvId);
  const context = allMsgs.slice(-40).map((m) => ({
    role: m.role,
    content: m.content,
  }));

  const char = await getCharacter(state.selectedCharId);
  const [userName, userPronoun, userBio, thinkingEnabled, providerCfg, webSearchEnabled, imageConfig] = await Promise.all([
    getSetting("userName"),
    getSetting("userPronoun"),
    getSetting("userBio"),
    getThinkingChainEnabled(),
    getProviderConfig(),
    getSetting("webSearchEnabled"),
    getImageGenerationConfig(),
  ]);
  let webSearchTrace = null;
  let ephemeralEvidencePart = "";
  const searchQuery = webSearchEnabled === true ? explicitWebSearchQuery(text) : "";
  if (searchQuery) {
    toast("正在搜尋網路…");
    try {
      const result = await searchWeb(searchQuery, { currentProvider: providerCfg.providerId, signal: state.abortController.signal });
      webSearchTrace = { providerId: result.providerId, query: result.query, sources: result.sources || [] };
      ephemeralEvidencePart = webSearchEvidence(result);
    } catch (error) {
      if (error.name === "AbortError") throw error;
      webSearchTrace = { providerId: providerCfg.providerId, query: searchQuery, sources: [], error: error.message };
    }
  }
  const selfNotesSnapshot = await getSelfNotesWindowSnapshot(char);
  const conversation = await getConversation(state.currentConvId);
  const companion = await prepareCompanionContext({
    character: char || {},
    conversation,
    messages: allMsgs,
    userText: text,
    userName: userName || "對方",
  });
  const structuredPrompt = buildCoreStructuredPrompt({
    character: char || {},
    profile: { nickname: userName, pronouns: userPronoun, bio: userBio },
    selfNotesSnapshot,
    thinkingEnabled,
    providerId: providerCfg.providerId,
    controlInstructions: [
      imageConfig.apiKey && imageConfig.model ? imageGenerationAbilityPrompt() : "",
      companion.controlInstructions,
    ].filter(Boolean).join("\n\n"),
    ephemeralEvidencePart,
    windowSummary: companion.windowSummary,
    companionWindowParts: companion.windowParts,
    companionLiveParts: companion.liveParts,
    now: new Date(),
  });

  const assistantMsg = newMessage(state.currentConvId, "assistant", "", webSearchTrace ? { webSearchTrace } : {});
  const div = document.createElement("div");
  div.className = "message assistant";
  div.id = `msg-${assistantMsg.id}`;

  if (webSearchTrace) div.appendChild(buildWebSearchTraceCard(webSearchTrace));

  const thinkingCard = document.createElement("div");
  thinkingCard.className = "chat-thinking-card is-streaming";
  thinkingCard.style.display = "none";
  thinkingCard.innerHTML = `
    <div class="thinking-header" role="button" tabindex="0" aria-label="展開或折疊思考過程">
      <span class="thinking-label-text">Thinking…</span>
      <span class="thinking-toggle-icon" aria-hidden="true">
        <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="9 18 15 12 9 6"></polyline>
        </svg>
      </span>
    </div>
    <div class="thinking-body">
      <div class="thinking-text"></div>
    </div>
  `;
  thinkingCard.querySelector(".thinking-header")?.addEventListener("click", () => {
    thinkingCard.classList.toggle("is-collapsed");
  });
  div.appendChild(thinkingCard);

  const bubble = document.createElement("div");
  bubble.className = "message-bubble";
  bubble.innerHTML = '<span class="typing-indicator">···</span>';
  div.appendChild(bubble);
  messageList.appendChild(div);
  scrollToBottom();

  let fullText = "";
  let streamThinking = "";
  try {
    await streamChat(context, {
      systemPrompt: structuredPrompt.staticPart,
      structuredPrompt,
      conversationId: state.currentConvId,
      signal: state.abortController.signal,
      onThinkingDelta(delta) {
        streamThinking += delta;
        thinkingCard.style.display = "block";
        const thEl = thinkingCard.querySelector(".thinking-text");
        if (thEl) thEl.innerHTML = formatMarkdown(streamThinking);
        scrollToBottom();
      },
      onDelta(delta) {
        fullText += delta;
        const drawIntent = parseDrawIntent(fullText);
        const parsed = parseMessageContext(stripCompanionTags(drawIntent.visibleText), streamThinking);
        if (parsed.thinking) {
          thinkingCard.style.display = "block";
          const thEl = thinkingCard.querySelector(".thinking-text");
          if (thEl) thEl.innerHTML = formatMarkdown(parsed.thinking);
        }
        bubble.innerHTML = formatMarkdown(parsed.cleanText || "···");
        scrollToBottom();
      },
      onDone() {
        const drawIntent = parseDrawIntent(fullText);
        const parsed = parseMessageContext(stripCompanionTags(drawIntent.visibleText), streamThinking);
        assistantMsg.content = parsed.cleanText || drawIntent.visibleText || (drawIntent.prompt ? "我來畫。" : fullText);
        if (parsed.thinking) assistantMsg.thinking = parsed.thinking;
        if (parsed.memoryLog) assistantMsg.memoryLog = parsed.memoryLog;
        if (parsed.emotionLog) assistantMsg.emotionLog = parsed.emotionLog;
        thinkingCard.classList.remove("is-streaming");
        const lbl = thinkingCard.querySelector(".thinking-label-text");
        if (lbl) lbl.textContent = "Thinking";
      },
      onUsage(u) {
        if (!u) return;
        /* 各 provider 格式不同，統一解析 */
        const prompt = u.prompt_tokens ?? u.input_tokens ?? u.promptTokenCount ?? u.totalTokenCount ?? 0;
        const completion = u.completion_tokens ?? u.output_tokens ?? u.candidatesTokenCount ?? 0;
        const cacheHit = u.cache_read_input_tokens ?? u.prompt_tokens_details?.cached_tokens ?? u.cachedContentTokenCount ?? 0;
        const cacheCreation = u.cache_creation_input_tokens ?? 0;
        logUsage({
          provider: providerCfg.providerId,
          model: providerCfg.model,
          characterId: state.selectedCharId || "default",
          promptTokens: prompt,
          completionTokens: completion,
          cacheHitTokens: cacheHit,
          cacheCreationTokens: cacheCreation,
        });
      },
    });
    const drawIntent = parseDrawIntent(fullText);
    const companionResult = await processCompanionReply(drawIntent.visibleText, {
      settings: companion.settings,
      characterId: state.selectedCharId,
      conversationId: state.currentConvId,
      conversation,
      assistantMessageId: assistantMsg.id,
    });
    const parsed = parseMessageContext(companionResult.cleanText, streamThinking);
    assistantMsg.content = parsed.cleanText || (drawIntent.prompt ? "我來畫。" : companionResult.cleanText);
    assistantMsg.memoryLog = [...companionResult.memoryLog, parsed.memoryLog].filter(Boolean).join("\n");
    assistantMsg.emotionLog = [...companionResult.emotionLog, ...companionResult.clockLog, parsed.emotionLog].filter(Boolean).join("\n");
    assistantMsg.toolCards = [...(companionResult.toolCards || [])];
    if (companionResult.memoryLinkProposal) assistantMsg.toolCards.push({ type: "memory_link", proposalId: companionResult.memoryLinkProposal.id, status: "pending" });
    if (companionResult.stickerId) assistantMsg.stickerId = companionResult.stickerId;
    assistantMsg.segments = splitReplySegments(assistantMsg.content, companion.settings.splitReply);
    if (companionResult.whisperText) messageInput.placeholder = companionResult.whisperText;
    if (drawIntent.prompt) {
      assistantMsg.generatedImagePrompt = drawIntent.prompt;
      assistantMsg.generatedImageStatus = "generating";
      bubble.innerHTML = formatMarkdown(assistantMsg.content);
      const imageCard = buildGeneratedImageCard(assistantMsg);
      div.appendChild(imageCard);
      await saveMessage(assistantMsg);
      scrollToBottom();
      try {
        assistantMsg.generatedImageDataUrl = await generateImage(drawIntent.prompt, { signal: state.abortController.signal });
        assistantMsg.generatedImageStatus = "done";
      } catch (imageError) {
        assistantMsg.generatedImageStatus = "failed";
        assistantMsg.generatedImageError = imageError.message;
      }
      imageCard.replaceWith(buildGeneratedImageCard(assistantMsg));
    }
    await saveMessage(assistantMsg);
    await renderMessages();
  } catch (err) {
    if (err.name === "AbortError") {
      const parsed = parseMessageContext(stripCompanionTags(fullText), streamThinking);
      bubble.innerHTML = formatMarkdown(parsed.cleanText || fullText) + '<br><span class="stream-cancelled">（已停止）</span>';
      assistantMsg.content = parsed.cleanText || fullText;
      if (parsed.thinking) assistantMsg.thinking = parsed.thinking;
      if (fullText) saveMessage(assistantMsg);
    } else {
      await markUserMessageFailed(userMsg, err);
      div.remove();
      await renderMessages();
    }
  } finally {
    state.isStreaming = false;
    sendButton.classList.remove("is-streaming");
    scrollToBottom();
  }
  } catch (error) {
    if (error.name !== "AbortError") {
      await markUserMessageFailed(userMsg, error);
      await renderMessages();
      toast("傳送失敗：" + error.message, 5000);
    }
  } finally {
    state.isStreaming = false;
    sendButton.classList.remove("is-streaming");
  }
}

sendButton.addEventListener("click", sendMessage);
messageInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    sendMessage();
  }
});

messageInput.addEventListener("input", () => {
  messageInput.style.height = "auto";
  messageInput.style.height = Math.min(messageInput.scrollHeight, 124) + "px";
});

// ═══ Action panel / image ═══

addButton.addEventListener("click", () => {
  const isOpen = composerShell.classList.toggle("is-open");
  addButton.setAttribute("aria-expanded", isOpen);
  actionPanel.setAttribute("aria-hidden", !isOpen);
});

$$(".action-tile").forEach((tile) => {
  tile.addEventListener("click", async () => {
    const action = tile.dataset.action;
    if (action === "image") imagePicker.click();
    if (action === "draw") openManualImageDialog();
    if (action === "sticker") await openStickerDialog();
    if (action === "transfer") await openTransferDialog();
    if (action === "scratch") await createUserScratchCard();
    if (action === "audio") audioPicker.click();
    composerShell.classList.remove("is-open");
    actionPanel.setAttribute("aria-hidden", "true");
    addButton.setAttribute("aria-expanded", "false");
  });
});

async function openStickerDialog() {
  if (!state.selectedCharId || state.isStreaming) return;
  const stickers = (await listStickers()).filter((item) => !item.characterId || item.characterId === state.selectedCharId);
  const backdrop = document.createElement("div");
  backdrop.className = "manual-image-backdrop";
  backdrop.innerHTML = `<section class="manual-image-dialog" role="dialog" aria-modal="true" aria-labelledby="stickerDialogTitle"><h2 id="stickerDialogTitle">表情包</h2><p>選一張傳送，或加入本機表情包。</p><div class="sticker-dialog-grid">${stickers.map((sticker) => `<button class="sticker-dialog-item" type="button" data-id="${escapeHtml(sticker.id)}"><img src="${escapeHtml(safeDisplayImageUrl(sticker.dataUrl || sticker.imageDataUrl || ""))}" alt="${escapeHtml(sticker.name || "表情包")}"></button>`).join("")}</div><div class="manual-image-actions"><button class="btn-plain" type="button" data-action="close">取消</button><button class="btn-primary" type="button" data-action="upload">加入表情包</button></div></section>`;
  document.body.appendChild(backdrop);
  const close = () => backdrop.remove();
  backdrop.querySelector('[data-action="close"]').addEventListener("click", close);
  backdrop.querySelector('[data-action="upload"]').addEventListener("click", () => { close(); stickerPicker.click(); });
  backdrop.addEventListener("click", (event) => { if (event.target === backdrop) close(); });
  backdrop.querySelectorAll(".sticker-dialog-item").forEach((button) => button.addEventListener("click", async () => {
    state.pendingStickerId = button.dataset.id;
    messageInput.value = `[sticker:${button.dataset.id}]`;
    close();
    await sendMessage();
  }));
}

async function openTransferDialog() {
  if (!state.selectedCharId || state.isStreaming) return;
  const balance = await getBalance("_user");
  const raw = window.prompt(`轉給角色多少貝殼？目前餘額 ${balance}`);
  if (raw === null) return;
  const amount = Math.max(0, Math.min(1000000, Number(String(raw).trim())));
  if (!Number.isInteger(amount) || amount <= 0) { toast("請輸入有效的整數金額"); return; }
  if (amount > balance) { toast("貝殼不夠了"); return; }
  state.pendingTransferAmount = amount;
  messageInput.value = `[transfer:${amount}]`;
  await sendMessage();
}

async function createUserScratchCard() {
  if (!state.currentConvId || !state.selectedCharId || state.isStreaming) return;
  try {
    await applyBalanceDeltas({ _user: -30 });
  } catch { toast("貝殼不夠了"); return; }
  const message = newMessage(state.currentConvId, "user", "", { toolCards: [createScratchCard("user")] });
  await saveMessage(message);
  appendMessageBubble(message);
  scrollToBottom();
}

stickerPicker.addEventListener("change", async () => {
  const file = stickerPicker.files[0];
  if (!file) return;
  if (!file.type.startsWith("image/") || file.size > 8 * 1024 * 1024) { toast("表情包需為 8 MB 內的圖片"); stickerPicker.value = ""; return; }
  try {
    const dataUrl = await compactImageToDataUrl(file, 512);
    await saveSticker({ id: crypto.randomUUID(), characterId: state.selectedCharId, packId: "local", name: file.name.replace(/\.[^.]+$/, "").slice(0, 60) || "表情包", dataUrl, createdAt: new Date().toISOString() });
    toast("已加入表情包");
  } catch (error) { toast("表情包處理失敗：" + error.message); }
  finally { stickerPicker.value = ""; }
});

audioPicker.addEventListener("change", async () => {
  const file = audioPicker.files[0];
  if (!file) return;
  if (!file.type.startsWith("audio/") || file.size > 20 * 1024 * 1024) { toast("聲音需為 20 MB 內的音訊檔"); audioPicker.value = ""; return; }
  try {
    const dataUrl = await new Promise((resolve, reject) => { const reader = new FileReader(); reader.onload = () => resolve(reader.result); reader.onerror = reject; reader.readAsDataURL(file); });
    const message = newMessage(state.currentConvId, "user", `聲音：${file.name}`, { audioDataUrl: dataUrl, audioName: file.name, audioMime: file.type });
    await saveMessage(message); appendMessageBubble(message); scrollToBottom();
  } catch (error) { toast("聲音讀取失敗：" + error.message); }
  finally { audioPicker.value = ""; }
});

function openManualImageDialog() {
  if (state.isStreaming) { toast("請先等待目前請求完成"); return; }
  const backdrop = document.createElement("div");
  backdrop.className = "manual-image-backdrop";
  backdrop.innerHTML = `
    <section class="manual-image-dialog" role="dialog" aria-modal="true" aria-labelledby="manualImageTitle">
      <h2 id="manualImageTitle">生成圖片</h2>
      <p>直接使用「API 設定」中選擇的生圖來源與模型。</p>
      <textarea class="field-input" maxlength="4000" placeholder="描述主體、風格、光線與構圖"></textarea>
      <div class="manual-image-actions"><button class="btn-plain" type="button" data-action="cancel">取消</button><button class="btn-primary" type="button" data-action="generate">生成</button></div>
    </section>`;
  document.body.appendChild(backdrop);
  const input = backdrop.querySelector("textarea");
  const close = () => backdrop.remove();
  backdrop.querySelector('[data-action="cancel"]').addEventListener("click", close);
  backdrop.addEventListener("click", (event) => { if (event.target === backdrop) close(); });
  backdrop.addEventListener("keydown", (event) => { if (event.key === "Escape") close(); });
  backdrop.querySelector('[data-action="generate"]').addEventListener("click", async () => {
    const prompt = input.value.trim();
    if (!prompt) { toast("請先輸入生圖描述"); return; }
    close();
    await generateImageDirectly(prompt);
  });
  input.focus();
}

async function generateImageDirectly(prompt) {
  if (!state.currentConvId || state.isStreaming) return;
  state.abortController = new AbortController();
  state.isStreaming = true;
  sendButton.classList.add("is-streaming");
  const userMsg = newMessage(state.currentConvId, "user", `請生成圖片：${prompt}`);
  const assistantMsg = newMessage(state.currentConvId, "assistant", "我來畫。", {
    generatedImagePrompt: prompt,
    generatedImageStatus: "generating",
  });
  try {
    await saveMessage(userMsg);
    appendMessageBubble(userMsg);
    await saveMessage(assistantMsg);
    appendMessageBubble(assistantMsg);
    scrollToBottom();
    assistantMsg.generatedImageDataUrl = await generateImage(prompt, { signal: state.abortController.signal });
    assistantMsg.generatedImageStatus = "done";
  } catch (error) {
    assistantMsg.generatedImageStatus = "failed";
    assistantMsg.generatedImageError = error.name === "TimeoutError" ? "生圖請求逾時" : error.message;
  } finally {
    await saveMessage(assistantMsg);
    await renderMessages();
    state.isStreaming = false;
    sendButton.classList.remove("is-streaming");
    scrollToBottom();
  }
}

imagePicker.addEventListener("change", async () => {
  const file = imagePicker.files[0];
  if (!file) return;
  if (!file.type.startsWith("image/")) {
    toast("只接受圖片檔案");
    imagePicker.value = "";
    return;
  }
  if (file.size > 12 * 1024 * 1024) {
    toast("圖片不可超過 12 MB");
    imagePicker.value = "";
    return;
  }
  try {
    const dataUrl = await compactImageToDataUrl(file, 1600);
    state.pendingImageBase64 = dataUrl.split(",")[1];
    state.pendingImageMime = dataUrl.slice(5, dataUrl.indexOf(";")) || "image/webp";
    showImagePreview(dataUrl);
  } catch (error) {
    toast("圖片處理失敗：" + error.message);
  } finally {
    imagePicker.value = "";
  }
});

function showImagePreview(dataUrl) {
  let preview = $(".image-preview");
  if (!preview) {
    preview = document.createElement("div");
    preview.className = "image-preview";
    composerShell.insertBefore(preview, composerShell.firstChild);
  }
  preview.innerHTML = `<img src="${dataUrl}" alt=""><button class="image-preview-remove" type="button">✕</button>`;
  preview.querySelector(".image-preview-remove").addEventListener("click", clearImagePreview);
}

function clearImagePreview() {
  state.pendingImageBase64 = null;
  state.pendingImageMime = null;
  $(".image-preview")?.remove();
}
