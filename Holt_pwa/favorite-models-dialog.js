/** 收藏模型管理：刪除、長按拖動排序與鍵盤替代操作。 */

import { getStarredModels, getStarredModelProviders, removeStarredModel, saveStarredModels } from "./db.js";
import { PROVIDERS } from "./api.js";

const LONG_PRESS_MS = 360;

function providerLabel(providerId) {
  return PROVIDERS[providerId]?.label || providerId || "未記錄來源";
}

async function openFavoriteModelsDialog({ onChanged } = {}) {
  let favorites = await getStarredModels();
  let providers = await getStarredModelProviders();
  const backdrop = document.createElement("div");
  backdrop.className = "favorite-models-backdrop";
  backdrop.innerHTML = `
    <section class="favorite-models-dialog" role="dialog" aria-modal="true" aria-labelledby="favoriteModelsTitle">
      <header class="favorite-models-header">
        <h2 id="favoriteModelsTitle">收藏模型</h2>
        <button type="button" class="favorite-models-close btn-plain" aria-label="關閉收藏模型">×</button>
      </header>
      <p class="favorite-models-help">長按條目拖動，可調整對話框內的模型順序。</p>
      <div class="favorite-models-list" role="list"></div>
      <footer><button type="button" class="btn-primary favorite-models-done">完成</button></footer>
    </section>`;
  document.body.appendChild(backdrop);
  const dialog = backdrop.querySelector(".favorite-models-dialog");
  const list = backdrop.querySelector(".favorite-models-list");

  const persistOrder = async () => {
    favorites = await saveStarredModels(favorites);
    onChanged?.(favorites);
  };

  const move = async (from, to) => {
    if (from === to || from < 0 || to < 0 || from >= favorites.length || to >= favorites.length) return;
    const [model] = favorites.splice(from, 1);
    favorites.splice(to, 0, model);
    render();
    await persistOrder();
  };

  const installLongPressDrag = (row, model) => {
    let timer = 0;
    let dragging = false;
    const stop = async (event) => {
      clearTimeout(timer);
      if (!dragging) return;
      dragging = false;
      row.classList.remove("is-dragging");
      try { row.releasePointerCapture(event.pointerId); } catch {}
      favorites = [...list.querySelectorAll(".favorite-model-row")].map((item) => item.dataset.model);
      await persistOrder();
    };
    row.addEventListener("pointerdown", (event) => {
      if (event.target.closest("button")) return;
      timer = window.setTimeout(() => {
        dragging = true;
        row.classList.add("is-dragging");
        row.setPointerCapture(event.pointerId);
        navigator.vibrate?.(12);
      }, LONG_PRESS_MS);
    });
    row.addEventListener("pointermove", (event) => {
      if (!dragging) return;
      event.preventDefault();
      const target = document.elementFromPoint(event.clientX, event.clientY)?.closest(".favorite-model-row");
      if (!target || target === row || target.parentElement !== list) return;
      const rect = target.getBoundingClientRect();
      list.insertBefore(row, event.clientY < rect.top + rect.height / 2 ? target : target.nextSibling);
    });
    row.addEventListener("pointerup", stop);
    row.addEventListener("pointercancel", stop);
    row.addEventListener("lostpointercapture", (event) => stop(event));
    row.addEventListener("contextmenu", (event) => event.preventDefault());
  };

  function render() {
    if (!favorites.length) {
      list.innerHTML = '<p class="favorite-models-empty">尚未收藏模型，請先在模型列表點擊星標。</p>';
      return;
    }
    list.innerHTML = favorites.map((model, index) => `
      <article class="favorite-model-row" role="listitem" data-model="${escapeAttribute(model)}">
        <span class="favorite-model-drag" aria-hidden="true">⠿</span>
        <span class="favorite-model-copy"><strong>${escapeHtml(model)}</strong><small>${escapeHtml(providerLabel(providers[model]))}</small></span>
        <span class="favorite-model-move" aria-label="排序控制">
          <button type="button" class="btn-plain" data-move="up" aria-label="上移 ${escapeAttribute(model)}" ${index === 0 ? "disabled" : ""}>↑</button>
          <button type="button" class="btn-plain" data-move="down" aria-label="下移 ${escapeAttribute(model)}" ${index === favorites.length - 1 ? "disabled" : ""}>↓</button>
        </span>
        <button type="button" class="favorite-model-delete btn-plain" aria-label="刪除 ${escapeAttribute(model)}">刪除</button>
      </article>`).join("");
    list.querySelectorAll(".favorite-model-row").forEach((row) => {
      const model = row.dataset.model;
      installLongPressDrag(row, model);
      row.querySelector("[data-move=up]")?.addEventListener("click", () => move(favorites.indexOf(model), favorites.indexOf(model) - 1));
      row.querySelector("[data-move=down]")?.addEventListener("click", () => move(favorites.indexOf(model), favorites.indexOf(model) + 1));
      row.querySelector(".favorite-model-delete")?.addEventListener("click", async () => {
        favorites = await removeStarredModel(model);
        providers = await getStarredModelProviders();
        render();
        onChanged?.(favorites);
      });
    });
  }

  const close = () => {
    backdrop.classList.add("is-closing");
    window.setTimeout(() => backdrop.remove(), 150);
  };
  backdrop.querySelector(".favorite-models-close").addEventListener("click", close);
  backdrop.querySelector(".favorite-models-done").addEventListener("click", close);
  backdrop.addEventListener("click", (event) => { if (event.target === backdrop) close(); });
  backdrop.addEventListener("keydown", (event) => { if (event.key === "Escape") close(); });
  render();
  dialog.focus?.();
}

function escapeHtml(value) {
  const span = document.createElement("span");
  span.textContent = String(value || "");
  return span.innerHTML;
}

function escapeAttribute(value) {
  return escapeHtml(value).replace(/`/g, "&#96;");
}

export { openFavoriteModelsDialog };
