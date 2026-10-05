/**
 * Holt PWA — 角色列表 + 編輯頁
 */

import { $, state, toast, registerTabHandler } from "./app.js";
import {
  listCharacters, getCharacter, newCharacter, saveCharacter, deleteCharacter,
  listTimelineEntries, listTimelineEntriesForCharacter, deleteTimelineEntry,
  getSetting, setSetting,
} from "./db.js";
import { renderHomeContent } from "./ui-home.js";
import { openAvatarCropper } from "./avatar-cropper.js";

// ═══ DOM refs ═══

const charCarousel = $("#charCarousel");
const charDots = $("#charDots");
const charResources = $("#charResources");
const charTimelinePanel = $("#charTimelinePanel");
const charSelfNotesPanel = $("#charSelfNotesPanel");
const charEmpty = $("#charEmpty");
const charCarouselWrap = $("#charCarouselWrap");
const newCharBtnNav = $("#newCharBtnNav");
const exportCharBtn = $("#exportCharBtn");

const charModal = $("#charModal");
const charModalTitle = $("#charModalTitle");
const charCancelBtn = $("#charCancelBtn");
const charSaveBtn = $("#charSaveBtn");
const charExtrasToggle = $("#charExtrasToggle");
const charExtras = $("#charExtras");
const charExtrasIcon = $("#charExtrasIcon");
const charDeleteBtn = $("#charDeleteBtn");
const charShareBtn = $("#charShareBtn");
const charAvatarUpload = $("#charAvatarUpload");
const charAvatarInput = $("#charAvatarInput");
const charAvatarPreview = $("#charAvatarPreview");

let charEditAvatarData = null;

// ═══ Tab registration ═══

registerTabHandler(3, renderCharList);

// ═══ Character list (carousel) ═══

async function renderCharList() {
  const chars = await listCharacters();
  if (!state.selectedCharId) {
    state.selectedCharId = await getSetting("activeCharacterId");
  }
  charCarousel.innerHTML = '<div class="char-carousel-spacer"></div>';
  charDots.innerHTML = "";

  if (!chars.length) {
    charCarousel.innerHTML = "";
    charCarouselWrap.setAttribute("hidden", "");
    charDots.setAttribute("hidden", "");
    charResources.setAttribute("hidden", "");
    charTimelinePanel.setAttribute("hidden", "");
    charSelfNotesPanel.setAttribute("hidden", "");
    charEmpty.removeAttribute("hidden");
    return;
  }

  charEmpty.setAttribute("hidden", "");
  charCarouselWrap.removeAttribute("hidden");
  charDots.removeAttribute("hidden");
  charResources.removeAttribute("hidden");

  if (!state.selectedCharId || !chars.find(c => c.id === state.selectedCharId)) {
    state.selectedCharId = chars[0].id;
  }

  let activeIndex = chars.findIndex(c => c.id === state.selectedCharId);
  if (activeIndex < 0) activeIndex = 0;

  chars.forEach((c, i) => {
    const isActive = c.id === state.selectedCharId;
    const card = document.createElement("div");
    const isCurrent = i === activeIndex;
    card.className = "char-page-card" + (isActive ? " is-active" : "") + (!isCurrent ? " is-side" : "");
    card.dataset.charId = c.id;

    const sub = [c.gender, c.relationship].filter(Boolean).join(" · ");
    const avatarHtml = c.avatarDataUrl
      ? `<img src="${esc(c.avatarDataUrl)}" alt="" loading="lazy" decoding="async">`
      : `<span class="avatar-fallback">${esc((c.name || "?")[0])}</span>`;

    const actionHtml = isActive
      ? `<div class="char-online-pill"><span class="char-online-dot"></span><span>在線</span></div>`
      : `<button type="button" class="char-use-btn">交流</button>`;

    card.innerHTML = `
      <div class="char-card-top">
        <div class="char-card-avatar${isActive ? " is-active" : ""}">${avatarHtml}</div>
        <div class="char-card-meta">
          <strong>${esc(c.name || "未命名")}</strong>
          ${sub ? `<span class="char-card-sub">${esc(sub)}</span>` : ""}
        </div>
        <div class="char-card-action">${actionHtml}</div>
      </div>
      <div class="char-card-desc">${esc(c.description || "")}</div>
    `;

    // In-place update instead of full rebuild → no jank
    const useBtn = card.querySelector(".char-use-btn");
    if (useBtn) {
      useBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        selectCharacter(c.id);
      });
    }

    card.addEventListener("click", () => openCharModal(c));

    let pressTimer;
    card.addEventListener("touchstart", () => {
      pressTimer = setTimeout(() => {
        if (confirm(`確定刪除「${c.name}」？`)) {
          deleteCharacter(c.id).then(() => {
            if (state.selectedCharId === c.id) state.selectedCharId = null;
            renderCharList();
            toast("已刪除");
          });
        }
      }, 600);
    }, { passive: true });
    card.addEventListener("touchend", () => clearTimeout(pressTimer));
    card.addEventListener("touchmove", () => clearTimeout(pressTimer));

    charCarousel.appendChild(card);

    const dot = document.createElement("span");
    dot.className = "char-dot" + (i === activeIndex ? " is-active" : "");
    charDots.appendChild(dot);
  });

  // Trailing spacer
  const endSpacer = document.createElement("div");
  endSpacer.className = "char-carousel-spacer";
  charCarousel.appendChild(endSpacer);

  // Scroll to active card (+1 because of leading spacer)
  requestAnimationFrame(() => {
    const activeCard = charCarousel.children[activeIndex + 1];
    if (activeCard) {
      activeCard.scrollIntoView({ inline: "center", behavior: "instant" });
    }
  });

  // Scroll-snap observer → update dots + side scale
  let scrollTimeout;
  charCarousel.onscroll = () => {
    clearTimeout(scrollTimeout);
    scrollTimeout = setTimeout(() => {
      const cards = [...charCarousel.querySelectorAll(".char-page-card")];
      const wrapRect = charCarousel.getBoundingClientRect();
      const center = wrapRect.left + wrapRect.width / 2;
      let closest = 0;
      let minDist = Infinity;
      cards.forEach((el, i) => {
        const r = el.getBoundingClientRect();
        const d = Math.abs(r.left + r.width / 2 - center);
        if (d < minDist) { minDist = d; closest = i; }
      });
      [...charDots.children].forEach((dot, i) => {
        dot.classList.toggle("is-active", i === closest);
      });
      cards.forEach((el, i) => {
        el.classList.toggle("is-side", i !== closest);
      });
    }, 60);
  };

  renderCharResources();
  renderTimeline();
  renderSelfNotes();
}

// ═══ In-place character selection (no DOM rebuild → no jank) ═══

function selectCharacter(charId) {
  state.selectedCharId = charId;
  void setSetting("activeCharacterId", charId);
  const cards = charCarousel.querySelectorAll(".char-page-card");
  cards.forEach((card) => {
    const isActive = card.dataset.charId === charId;
    card.classList.toggle("is-active", isActive);
    // Swap action button in-place
    const actionEl = card.querySelector(".char-card-action");
    if (isActive) {
      actionEl.innerHTML = `<div class="char-online-pill"><span class="char-online-dot"></span><span>在線</span></div>`;
    } else {
      actionEl.innerHTML = `<button type="button" class="char-use-btn">交流</button>`;
      actionEl.querySelector(".char-use-btn").addEventListener("click", (e) => {
        e.stopPropagation();
        selectCharacter(card.dataset.charId);
      });
    }
    // Update avatar ring
    card.querySelector(".char-card-avatar")?.classList.toggle("is-active", isActive);
  });
  // Refresh panels for the newly selected character
  renderTimeline();
  renderSelfNotes();
}

// ═══ Resource tabs ═══

function renderCharResources() {
  charResources.innerHTML = `
    <button class="char-resource-tab" data-res="voice">
      <div class="char-resource-icon">
        <svg class="line-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <rect x="4" y="2" width="16" height="20" rx="2"/><path d="M9 22v-4h6v4"/><path d="M8 6h.01M16 6h.01M12 6h.01M8 10h.01M16 10h.01M12 10h.01M8 14h.01M16 14h.01M12 14h.01"/>
        </svg>
      </div>
      <span class="char-resource-label">語音</span>
    </button>
    <button class="char-resource-tab" data-res="stickers">
      <div class="char-resource-icon">
        <svg class="line-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="10"/>
          <path d="M8 14s1.5 2 4 2 4-2 4-2"/>
          <line x1="9" y1="9" x2="9.01" y2="9"/>
          <line x1="15" y1="9" x2="15.01" y2="9"/>
        </svg>
      </div>
      <span class="char-resource-label">表情</span>
    </button>
    <button class="char-resource-tab" data-res="memory">
      <div class="char-resource-icon">
        <svg class="line-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="3"/><circle cx="12" cy="12" r="8" stroke-dasharray="4 3"/>
        </svg>
      </div>
      <span class="char-resource-label">記憶</span>
    </button>
    <button class="char-resource-tab" data-res="saved">
      <div class="char-resource-icon">
        <svg class="line-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"/>
        </svg>
      </div>
      <span class="char-resource-label">收藏</span>
    </button>
  `;
}

// ═══ Timeline panel ═══

let _timelineYear = new Date().getFullYear();
let _timelineMonth = new Date().getMonth() + 1;

async function renderTimeline() {
  if (!state.selectedCharId) { charTimelinePanel.setAttribute("hidden", ""); return; }
  const allNodes = await listTimelineEntriesForCharacter(state.selectedCharId);
  if (!allNodes.length) { charTimelinePanel.setAttribute("hidden", ""); return; }
  charTimelinePanel.removeAttribute("hidden");

  const monthLabel = `${_timelineYear}.${String(_timelineMonth).padStart(2, "0")}`;
  const nodes = await listTimelineEntries(state.selectedCharId, _timelineYear, _timelineMonth);

  // Layout constants (matching Flutter)
  const nodeWidth = 76;
  const lineGap = 20;
  const totalHeight = 150;

  let axisHtml;
  if (!nodes.length) {
    axisHtml = `<div class="timeline-empty">這個月還沒有足跡</div>`;
  } else {
    const totalWidth = nodes.length * (nodeWidth + lineGap) - lineGap + 8;
    let items = `<div class="timeline-line"></div>`;

    nodes.forEach((node, i) => {
      const isAbove = i % 2 === 0;
      const isState = node.type === "state";
      const left = i * (nodeWidth + lineGap);
      const cx = left + nodeWidth / 2;
      const d = new Date(node.date);
      const dateStr = `${d.getMonth() + 1}/${d.getDate()}`;
      const displayText = isState && node.key ? `${node.key}·${node.value}` : node.value;

      // Dot
      items += `<div class="timeline-dot ${isState ? "is-state" : "is-event"}" style="left:${cx}px"></div>`;

      // Stalk
      items += `<div class="timeline-stalk ${isAbove ? "is-above" : "is-below"}" style="left:${cx}px;transform:translateX(-50%)"></div>`;

      // Content
      items += `
        <div class="timeline-content ${isAbove ? "is-above" : "is-below"}" style="left:${left}px" data-idx="${i}">
          <span class="timeline-date">${dateStr}</span>
          <span class="timeline-text ${isState ? "is-state" : ""}">${esc(displayText)}</span>
        </div>`;
    });

    axisHtml = `<div class="timeline-axis-wrap"><div class="timeline-axis" style="width:${totalWidth}px">${items}</div></div>`;
  }

  charTimelinePanel.innerHTML = `
    <div class="timeline-header">
      <div class="timeline-header-left">
        <svg class="timeline-header-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>
        <span class="timeline-header-title">時間線</span>
      </div>
      <button class="timeline-month-btn" id="timelineMonthBtn" type="button">
        ${monthLabel}
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 15l5 5 5-5M7 9l5-5 5 5"/></svg>
      </button>
    </div>
    ${axisHtml}
  `;

  // Month picker
  charTimelinePanel.querySelector("#timelineMonthBtn")?.addEventListener("click", showMonthPicker);

  // Node detail tap
  charTimelinePanel.querySelectorAll(".timeline-content").forEach((el) => {
    el.addEventListener("click", () => {
      const idx = parseInt(el.dataset.idx, 10);
      if (nodes[idx]) showTimelineDetail(nodes[idx]);
    });
  });

  // Scroll to rightmost (newest)
  const wrap = charTimelinePanel.querySelector(".timeline-axis-wrap");
  if (wrap) requestAnimationFrame(() => { wrap.scrollLeft = wrap.scrollWidth; });
}

function showMonthPicker() {
  const now = new Date();
  const months = [];
  for (let i = 0; i < 12; i++) {
    const y = now.getFullYear();
    const m = now.getMonth() + 1 - i;
    const dt = new Date(y, m - 1);
    months.push({ year: dt.getFullYear(), month: dt.getMonth() + 1 });
  }

  const chips = months.map((m) => {
    const label = `${m.year}.${String(m.month).padStart(2, "0")}`;
    const isActive = m.year === _timelineYear && m.month === _timelineMonth;
    return `<button class="timeline-month-chip${isActive ? " is-active" : ""}" data-y="${m.year}" data-m="${m.month}" type="button">${label}</button>`;
  }).join("");

  const backdrop = document.createElement("div");
  backdrop.className = "timeline-month-picker";
  backdrop.innerHTML = `<div class="timeline-month-sheet"><div class="timeline-month-handle"></div><div class="timeline-month-grid">${chips}</div></div>`;
  document.body.appendChild(backdrop);

  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) { backdrop.remove(); return; }
    const chip = e.target.closest(".timeline-month-chip");
    if (chip) {
      _timelineYear = parseInt(chip.dataset.y, 10);
      _timelineMonth = parseInt(chip.dataset.m, 10);
      backdrop.remove();
      renderTimeline();
    }
  });
}

function showTimelineDetail(node) {
  const isState = node.type === "state";
  const d = new Date(node.date);
  const dateStr = `${d.getFullYear()}.${String(d.getMonth() + 1).padStart(2, "0")}.${String(d.getDate()).padStart(2, "0")}  ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

  const backdrop = document.createElement("div");
  backdrop.className = "timeline-detail-backdrop";
  backdrop.innerHTML = `
    <div class="timeline-detail-sheet">
      <div class="timeline-detail-header">
        <span class="timeline-detail-tag ${isState ? "is-state" : "is-event"}">${isState ? "狀態" : "事件"}</span>
        <span class="timeline-detail-date">${dateStr}</span>
        <button class="timeline-detail-delete" type="button" aria-label="刪除">
          <svg class="line-icon" viewBox="0 0 24 24" style="width:19px;height:19px"><path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>
        </button>
      </div>
      ${isState && node.key ? `<div class="timeline-detail-key">${esc(node.key)}</div>` : ""}
      <div class="timeline-detail-value">${esc(node.value)}</div>
    </div>
  `;
  document.body.appendChild(backdrop);

  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) backdrop.remove();
  });

  backdrop.querySelector(".timeline-detail-delete").addEventListener("click", async () => {
    if (!confirm("刪除此時間線項目？")) return;
    await deleteTimelineEntry(node.id);
    backdrop.remove();
    renderTimeline();
  });
}

// ═══ Self-Notes panel (偷偷記住你) ═══

async function renderSelfNotes() {
  if (!state.selectedCharId) { charSelfNotesPanel.setAttribute("hidden", ""); return; }
  const char = await getCharacter(state.selectedCharId);
  if (!char) { charSelfNotesPanel.setAttribute("hidden", ""); return; }
  charSelfNotesPanel.removeAttribute("hidden");

  const notes = parseSelfNotes(char.selfNotes || "");
  const hasNotes = notes.length > 0;
  const preview = hasNotes ? notes[notes.length - 1] : "還沒有偷偷記下的事";

  charSelfNotesPanel.innerHTML = `
    <div class="selfnotes-header">
      <span class="selfnotes-title">偷偷記住你</span>
      ${hasNotes ? `<span class="selfnotes-count">${notes.length}</span>` : ""}
    </div>
    <div class="selfnotes-preview selfnotes-ruled${hasNotes ? "" : ""}" id="selfNotesPreviewBtn">
      <span class="selfnotes-preview-text${hasNotes ? "" : " is-empty"}">${esc(preview)}</span>
    </div>
  `;

  if (hasNotes) {
    charSelfNotesPanel.querySelector("#selfNotesPreviewBtn").addEventListener("click", () => {
      showSelfNotesSheet(notes);
    });
  }
}

function parseSelfNotes(value) {
  return value
    .split("\n")
    .map((line) => line.trim().replace(/^[·•*\-]+\s*/, ""))
    .filter((line) => line.length > 0);
}

function showSelfNotesSheet(notes) {
  const items = notes.map((note) => `<div class="selfnotes-sheet-item">${esc(note)}</div>`).join(`<div class="selfnotes-sheet-sep"></div>`);

  const backdrop = document.createElement("div");
  backdrop.className = "selfnotes-sheet-backdrop";
  backdrop.innerHTML = `
    <div class="selfnotes-sheet">
      <div class="selfnotes-sheet-handle"></div>
      <div class="selfnotes-sheet-header">
        <span class="selfnotes-sheet-title">偷偷記住你</span>
        <button class="selfnotes-sheet-close" type="button" aria-label="關閉">×</button>
      </div>
      <div class="selfnotes-sheet-list">${items}</div>
    </div>
  `;
  document.body.appendChild(backdrop);

  backdrop.addEventListener("click", (e) => {
    if (e.target === backdrop) backdrop.remove();
  });
  backdrop.querySelector(".selfnotes-sheet-close").addEventListener("click", () => backdrop.remove());
}

// ═══ HTML escape helper ═══

function esc(str) {
  return String(str ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;",
  })[character]);
}

// ═══ Export current character (header button) ═══

exportCharBtn.addEventListener("click", async () => {
  if (!state.selectedCharId) { toast("先選一個角色"); return; }
  const c = await getCharacter(state.selectedCharId);
  if (!c) { toast("角色不存在"); return; }
  const exp = { yanci_character: 1 };
  for (const k of ["name","gender","relationship","description","race","skill","age","height"]) {
    if (c[k]) exp[k] = c[k];
  }
  const code = btoa(unescape(encodeURIComponent(JSON.stringify(exp))));
  try {
    await navigator.clipboard.writeText(code);
    toast("角色碼已複製");
  } catch {
    prompt("角色碼（手動複製）：", code);
  }
});

newCharBtnNav.addEventListener("click", () => openCharModal());

// ═══ Character edit page ═══

function openCharModal(char = null) {
  state.editingCharId = char?.id || null;
  charModalTitle.textContent = char ? "編輯角色" : "新角色";

  $("#charName").value = char?.name || "";
  $("#charGender").value = char?.gender || "";
  $("#charRelationship").value = char?.relationship || "";
  $("#charDesc").value = char?.description || "";
  $("#charAge").value = char?.age || "";
  $("#charRace").value = char?.race || "";
  $("#charSkill").value = char?.skill || "";
  $("#charHeight").value = char?.height || "";
  $("#charSelfNotes").value = char?.selfNotes || "";

  charEditAvatarData = char?.avatarDataUrl || null;
  if (charEditAvatarData) {
    charAvatarPreview.innerHTML = `<img src="${esc(charEditAvatarData)}" alt="">`;
  } else {
    charAvatarPreview.innerHTML = `
      <svg class="line-icon" viewBox="0 0 24 24" style="width:36px;height:36px;opacity:.3"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>
      <span class="char-avatar-hint">上傳圖片</span>`;
  }

  if (state.editingCharId) {
    charDeleteBtn.removeAttribute("hidden");
    charShareBtn.removeAttribute("hidden");
  } else {
    charDeleteBtn.setAttribute("hidden", "");
    charShareBtn.setAttribute("hidden", "");
  }

  const hasExtras = !!(char?.race || char?.skill || char?.age || char?.height);
  charExtras.toggleAttribute("hidden", !hasExtras);
  charExtrasIcon.textContent = hasExtras ? "☑" : "☐";

  const name = char?.name || "";
  charSaveBtn.textContent = name ? `準備好了，${name}` : "準備好了";

  charModal.removeAttribute("hidden");
}

// Avatar upload
charAvatarUpload.addEventListener("click", () => charAvatarInput.click());
charAvatarInput.addEventListener("change", async () => {
  const file = charAvatarInput.files[0];
  if (!file) return;
  try {
    const cropped = await openAvatarCropper(file, { title: "裁剪角色頭像" });
    if (!cropped) return;
    charEditAvatarData = cropped;
    charAvatarPreview.innerHTML = `<img src="${esc(charEditAvatarData)}" alt="">`;
  } catch (err) {
    toast("頭像裁剪失敗：" + err.message);
  } finally {
    charAvatarInput.value = "";
  }
});

// Extras toggle
charExtrasToggle.addEventListener("click", () => {
  const show = charExtras.hasAttribute("hidden");
  charExtras.toggleAttribute("hidden", !show);
  charExtrasIcon.textContent = show ? "☑" : "☐";
});

// Back / cancel
charCancelBtn.addEventListener("click", () => {
  charModal.setAttribute("hidden", "");
  state.editingCharId = null;
});

// Delete
charDeleteBtn.addEventListener("click", async () => {
  if (!state.editingCharId) return;
  const name = $("#charName").value || "此角色";
  if (!confirm(`確定刪除「${name}」？`)) return;
  await deleteCharacter(state.editingCharId);
  if (state.selectedCharId === state.editingCharId) state.selectedCharId = null;
  charModal.setAttribute("hidden", "");
  state.editingCharId = null;
  toast("已刪除");
  if (state.currentTab === 3) renderCharList();
});

// Save
charSaveBtn.addEventListener("click", async () => {
  try {
    let char;
    if (state.editingCharId) {
      char = await getCharacter(state.editingCharId);
      if (!char) { toast("角色不存在"); return; }
    } else {
      char = newCharacter();
    }

    char.name = $("#charName").value.trim();
    char.gender = $("#charGender").value.trim();
    char.relationship = $("#charRelationship").value.trim();
    char.description = $("#charDesc").value.trim();
    char.age = $("#charAge").value.trim();
    char.race = $("#charRace").value.trim();
    char.skill = $("#charSkill").value.trim();
    char.height = $("#charHeight").value.trim();
    char.selfNotes = $("#charSelfNotes").value.trim();
    if (charEditAvatarData) char.avatarDataUrl = charEditAvatarData;

    if (!char.name) { toast("名字不能空"); return; }

    await saveCharacter(char);
    charModal.setAttribute("hidden", "");
    state.editingCharId = null;
    toast("已儲存");

    if (state.currentTab === 3) renderCharList();
    if (state.currentTab === 2) renderHomeContent();
  } catch (err) {
    toast("儲存失敗：" + err.message);
    console.error("char save error:", err);
  }
});
