/** Holt PWA — API、網搜、生圖與收藏模型設定。 */

import { $, toast, registerTabHandler } from "./app.js";
import { getSetting, setSetting, getStarredModels, getStarredModelProviders, toggleStarModel } from "./db.js";
import { PROVIDERS, fetchModels, getProviderConfig, testProviderConnection, isUsablePwaModelId, isLegacyPwaDefaultModel } from "./api.js";
import { getPromptCachingEnabled, setPromptCachingEnabled } from "./prompt-cache.js";
import { IMAGE_PROVIDERS, fetchImageModels } from "./image-generation.js";
import { WEB_SEARCH_MODES, favoriteSearchModels, resolveWebSearchConfig } from "./web-search.js";
import { openFavoriteModelsDialog } from "./favorite-models-dialog.js";

const apiPageContent = $("#apiPageContent");
let renderVersion = 0;

registerTabHandler(0, renderApiSettings);

function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;",
  })[character]);
}

function selectedValue(selector, fallback = "") {
  return apiPageContent.querySelector(selector)?.value?.trim() || fallback;
}

function modelOption(model, label = model) {
  return `<option value="${esc(model)}">${esc(label)}</option>`;
}

async function savedChatModel(providerId) {
  const providerModel = await getSetting(`model_${providerId}`);
  const legacyModel = await getSetting("model");
  const legacyProvider = await getSetting("provider") || "openrouter";
  return (isUsablePwaModelId(providerModel) && !isLegacyPwaDefaultModel(providerModel) ? providerModel : "") ||
    (providerId === legacyProvider && isUsablePwaModelId(legacyModel) && !isLegacyPwaDefaultModel(legacyModel) ? legacyModel : "") || PROVIDERS[providerId]?.defaultModel || "";
}

async function renderApiSettings() {
  const thisRender = ++renderVersion;
  const rawProvider = await getSetting("provider") || "openrouter";
  const providerId = PROVIDERS[rawProvider] ? rawProvider : "openrouter";
  const [apiKey, model, customEndpoint, promptCachingEnabled, starred, starredProviders] = await Promise.all([
    getSetting(`apiKey_${providerId}`).then((value) => value || ""), savedChatModel(providerId),
    getSetting("customEndpoint").then((value) => value || ""), getPromptCachingEnabled(), getStarredModels(), getStarredModelProviders(),
  ]);
  if (thisRender !== renderVersion) return;
  const imageProviderSaved = await getSetting("imageGenerationProvider") || "openrouter";
  const imageProvider = IMAGE_PROVIDERS[imageProviderSaved] ? imageProviderSaved : "openrouter";
  const imageModel = await getSetting(`imageGenerationModel_${imageProvider}`) || IMAGE_PROVIDERS[imageProvider].defaultModel;
  const webEnabled = await getSetting("webSearchEnabled") === true;
  const webModeSaved = await getSetting("webSearchMode") || "auto";
  const webMode = WEB_SEARCH_MODES[webModeSaved] ? webModeSaved : "auto";
  const webMaxResults = Math.max(1, Math.min(8, Number(await getSetting("webSearchMaxResults")) || 5));
  const resolvedSearch = await resolveWebSearchConfig({ mode: webMode, currentProvider: providerId });
  const activeSearchProvider = webMode === "auto" ? resolvedSearch.providerId : webMode;
  const searchModels = await favoriteSearchModels(activeSearchProvider);
  const selectedSearchModel = await getSetting(`webSearchModel_${activeSearchProvider}`) || "";
  const visibleStarred = starred.filter((item) => isUsablePwaModelId(item) && starredProviders[item] === providerId);
  const cacheDescription = providerId === "gemini"
    ? "Gemini 使用 Google cachedContents；達到模型門檻後建立 1 小時內容快取。"
    : "Claude／相容中轉站使用顯式快取；Grok 使用供應商的隱式前綴快取。其他模型維持普通請求。";

  apiPageContent.innerHTML = `
    <section class="settings-block" aria-labelledby="providerSettingsTitle">
      <h2 class="settings-block-title" id="providerSettingsTitle">API 設定</h2>
      <div class="settings-section"><p class="field-label">來源</p><div class="radio-group">${Object.entries(PROVIDERS).map(([id, provider]) => `<label class="radio-option"><input type="radio" name="provider" value="${id}" ${id === providerId ? "checked" : ""}>${esc(provider.label)}</label>`).join("")}</div></div>
      <div class="settings-section" id="customEndpointSection" ${providerId !== "custom" ? "hidden" : ""}><label class="field-label" for="customEndpointInput">自訂端點 URL</label><input class="field-input" id="customEndpointInput" type="url" value="${esc(customEndpoint)}" placeholder="https://your-relay.com/v1"></div>
      <div class="settings-section"><label class="field-label" for="apiKeyInput">API Key</label><div class="settings-key-row"><input class="field-input" id="apiKeyInput" type="password" value="${esc(apiKey)}" placeholder="${esc(PROVIDERS[providerId]?.keyPlaceholder || "sk-…")}"><button class="settings-eye btn-plain" id="toggleKeyVis" type="button" aria-label="顯示 API Key" aria-pressed="false"></button></div><p class="settings-hint">Key 僅儲存在此瀏覽器，不會寫入備份；請只在可信裝置使用。</p></div>
      <div class="settings-section model-settings-section">
        <div class="model-section-header"><button type="button" class="model-section-toggle btn-plain" id="modelSectionToggle" aria-expanded="true"><span>模型</span><span class="model-section-chevron" aria-hidden="true">⌄</span></button><button type="button" class="favorite-models-entry btn-plain" id="favoriteModelsBtn"><span aria-hidden="true">☆</span> 收藏模型</button></div>
        <div id="modelSectionBody">
          ${visibleStarred.length ? `<div class="starred-models-chips">${visibleStarred.map((item) => `<button type="button" class="starred-model-chip btn-plain" data-model="${esc(item)}">★ ${esc(item.split("/").pop())}</button>`).join("")}</div>` : ""}
          <div class="settings-model-row"><input class="field-input" id="modelInput" list="modelList" type="text" value="${esc(model)}" placeholder="輸入模型 ID"><datalist id="modelList"></datalist><button class="btn-plain compact-action" id="fetchModelsBtn" type="button">拉取列表</button></div>
          <p class="settings-hint">填入模型 ID，或拉取列表後點擊星標收藏。</p><div id="fetchedModelsContainer" class="fetched-models-container" hidden></div>
        </div>
      </div>
      <div class="settings-section cache-settings"><label class="cache-toggle-row"><input id="promptCachingInput" type="checkbox" ${promptCachingEnabled ? "checked" : ""}><span><strong>提示詞快取</strong><small>沿用 Holt 原生的穩定前綴、滾動斷點與 request-only 狀態分層。</small></span></label><p class="settings-hint">${cacheDescription}</p></div>
    </section>
    <section class="settings-block" aria-labelledby="webSearchSettingsTitle"><div class="settings-glass-card">
      <label class="settings-feature-toggle"><span><strong id="webSearchSettingsTitle">原生網搜</strong><small>只有明確要求搜尋時才會連線；證據只注入當次回合。</small></span><input id="webSearchEnabledInput" type="checkbox" ${webEnabled ? "checked" : ""}></label><div class="settings-card-divider"></div>
      <div class="settings-feature-body" id="webSearchBody" ${webEnabled ? "" : "aria-disabled=\"true\""}><label class="field-label" for="webSearchModeInput">來源</label><select class="field-input field-select" id="webSearchModeInput">${Object.entries(WEB_SEARCH_MODES).map(([id, label]) => `<option value="${id}" ${id === webMode ? "selected" : ""}>${esc(label)}</option>`).join("")}</select>
        <p class="settings-status-line" id="webSearchStatus"><span class="status-dot ${resolvedSearch.ready ? "is-ready" : ""}"></span>${webMode === "auto" ? `自動將使用 ${esc(WEB_SEARCH_MODES[resolvedSearch.providerId])}` : esc(WEB_SEARCH_MODES[activeSearchProvider])}${resolvedSearch.ready ? " · 已就緒" : " · 設定未完整"}</p>
        <label class="field-label" for="webSearchModelInput">搜尋模型</label><select class="field-input field-select" id="webSearchModelInput"><option value="">${searchModels.length ? `自動 · ${esc(resolvedSearch.model || "目前模型")}` : "尚無此來源的收藏模型"}</option>${searchModels.map((item) => `<option value="${esc(item)}" ${item === selectedSearchModel ? "selected" : ""}>${esc(item)}</option>`).join("")}</select><p class="settings-hint">請先在上方替此來源模型加星標，再於此選擇；中轉站需返回 url_citation。</p>
        <label class="settings-range-label" for="webSearchMaxResults"><span>最多來源數</span><output>${webMaxResults}</output></label><input id="webSearchMaxResults" class="settings-range" type="range" min="1" max="8" step="1" value="${webMaxResults}">
      </div></div></section>
    <section class="settings-block" aria-labelledby="imageSettingsTitle"><div class="settings-glass-card"><h2 class="feature-card-title" id="imageSettingsTitle">生成圖片</h2><p class="feature-card-subtitle">生圖來源與模型獨立於聊天模型，沿用該來源 API 憑證。</p><label class="field-label" for="imageProviderInput">生圖來源</label><select class="field-input field-select" id="imageProviderInput">${Object.entries(IMAGE_PROVIDERS).map(([id, provider]) => `<option value="${id}" ${id === imageProvider ? "selected" : ""}>${esc(provider.label)}</option>`).join("")}</select><label class="field-label image-model-label" for="imageModelInput">生圖模型</label><div class="settings-model-row"><input class="field-input" id="imageModelInput" list="imageModelList" value="${esc(imageModel)}"><datalist id="imageModelList"></datalist><button class="btn-plain icon-action" id="fetchImageModelsBtn" type="button" aria-label="重新整理生圖模型">↻</button></div><p class="settings-hint">PWA 支援 OpenRouter、Gemini、xAI 與 HTTPS OpenAI 相容中轉站；只顯示疑似生圖模型。</p></div></section>
    <div class="settings-section settings-actions"><button class="btn-secondary" id="testConnectionBtn" type="button" title="會送出一次最小聊天請求，可能計入供應商用量">測試連線</button><button class="btn-primary" id="saveSettingsBtn" type="button">儲存設定</button></div>`;
  bindSettingsEvents();
}

function bindSettingsEvents() {
  apiPageContent.querySelectorAll(".starred-model-chip").forEach((chip) => chip.addEventListener("click", () => { apiPageContent.querySelector("#modelInput").value = chip.dataset.model; toast(`已填入模型：${chip.dataset.model}`); }));
  apiPageContent.querySelector("#favoriteModelsBtn").addEventListener("click", () => openFavoriteModelsDialog({ onChanged: () => renderApiSettings() }));
  apiPageContent.querySelector("#modelSectionToggle").addEventListener("click", (event) => { const body = apiPageContent.querySelector("#modelSectionBody"); const expanded = event.currentTarget.getAttribute("aria-expanded") === "true"; event.currentTarget.setAttribute("aria-expanded", String(!expanded)); body.hidden = expanded; });
  apiPageContent.querySelectorAll('input[name="provider"]').forEach((radio) => radio.addEventListener("change", async () => { const nextId = radio.value; apiPageContent.querySelector("#customEndpointSection").hidden = nextId !== "custom"; apiPageContent.querySelector("#apiKeyInput").value = await getSetting(`apiKey_${nextId}`) || ""; apiPageContent.querySelector("#apiKeyInput").placeholder = PROVIDERS[nextId]?.keyPlaceholder || "sk-…"; apiPageContent.querySelector("#modelInput").value = await savedChatModel(nextId); await refreshWebSearchPreview(); }));
  const eye = apiPageContent.querySelector("#toggleKeyVis");
  const updateEye = () => { const input = apiPageContent.querySelector("#apiKeyInput"); const visible = input.type === "text"; eye.textContent = visible ? "◉̸" : "◉"; eye.setAttribute("aria-label", visible ? "隱藏 API Key" : "顯示 API Key"); eye.setAttribute("aria-pressed", String(visible)); };
  updateEye(); eye.addEventListener("click", () => { const input = apiPageContent.querySelector("#apiKeyInput"); input.type = input.type === "password" ? "text" : "password"; updateEye(); });
  apiPageContent.querySelector("#fetchModelsBtn").addEventListener("click", fetchChatModelList);
  apiPageContent.querySelector("#promptCachingInput").addEventListener("change", async (event) => { await setPromptCachingEnabled(event.target.checked); toast(event.target.checked ? "已開啟提示詞快取" : "已關閉提示詞快取"); });
  apiPageContent.querySelector("#webSearchEnabledInput").addEventListener("change", (event) => apiPageContent.querySelector("#webSearchBody").toggleAttribute("aria-disabled", !event.target.checked));
  apiPageContent.querySelector("#webSearchModeInput").addEventListener("change", refreshWebSearchPreview);
  const range = apiPageContent.querySelector("#webSearchMaxResults"); range.addEventListener("input", () => { range.previousElementSibling.querySelector("output").textContent = range.value; });
  apiPageContent.querySelector("#imageProviderInput").addEventListener("change", async (event) => { const providerId = event.target.value; apiPageContent.querySelector("#imageModelInput").value = await getSetting(`imageGenerationModel_${providerId}`) || IMAGE_PROVIDERS[providerId].defaultModel; });
  apiPageContent.querySelector("#fetchImageModelsBtn").addEventListener("click", fetchImageModelList);
  apiPageContent.querySelector("#testConnectionBtn").addEventListener("click", testCurrentConnection);
  apiPageContent.querySelector("#saveSettingsBtn").addEventListener("click", () => saveSettings());
}

function currentDraft() {
  const providerId = apiPageContent.querySelector('input[name="provider"]:checked')?.value || "openrouter";
  return {
    providerId,
    apiKey: selectedValue("#apiKeyInput"),
    model: selectedValue("#modelInput"),
    customEndpoint: selectedValue("#customEndpointInput"),
  };
}

async function validateCurrentDraft() {
  const draft = currentDraft();
  if (!draft.apiKey) throw new Error("請先輸入 API Key");
  if (!draft.model) throw new Error("請先輸入或選擇模型 ID");
  const config = await getProviderConfig(draft);
  if (!config.endpoint) throw new Error("請先輸入 HTTPS 中轉站端點");
  return draft;
}

async function refreshWebSearchPreview() {
  const mode = selectedValue("#webSearchModeInput", "auto");
  const draft = currentDraft();
  let resolved;
  try {
    resolved = await resolveWebSearchConfig({ mode, currentProvider: draft.providerId, currentDraft: draft });
  } catch (error) {
    const status = apiPageContent.querySelector("#webSearchStatus");
    if (status) status.innerHTML = `<span class="status-dot"></span>設定未完整 · ${esc(error.message)}`;
    return;
  }
  const activeProvider = mode === "auto" ? resolved.providerId : mode;
  const status = apiPageContent.querySelector("#webSearchStatus");
  if (status) status.innerHTML = `<span class="status-dot ${resolved.ready ? "is-ready" : ""}"></span>${mode === "auto" ? `自動將使用 ${esc(WEB_SEARCH_MODES[resolved.providerId])}` : esc(WEB_SEARCH_MODES[activeProvider])}${resolved.ready ? " · 已就緒" : " · 設定未完整"}`;
  const select = apiPageContent.querySelector("#webSearchModelInput");
  if (!select) return;
  const previous = select.value;
  const models = await favoriteSearchModels(activeProvider);
  select.innerHTML = `<option value="">${models.length ? `自動 · ${esc(resolved.model || "目前模型")}` : "尚無此來源的收藏模型"}</option>${models.map((item) => `<option value="${esc(item)}">${esc(item)}</option>`).join("")}`;
  if (models.includes(previous)) select.value = previous;
}

async function testCurrentConnection() {
  const button = apiPageContent.querySelector("#testConnectionBtn");
  button.disabled = true;
  button.textContent = "測試中…";
  try {
    const draft = await validateCurrentDraft();
    await testProviderConnection(draft);
    toast("連線成功，模型可正常回覆");
  } catch (error) {
    toast(`連線失敗：${error.message}`, 6000);
  } finally {
    button.disabled = false;
    button.textContent = "測試連線";
  }
}

async function fetchChatModelList() {
  const button = apiPageContent.querySelector("#fetchModelsBtn"); const container = apiPageContent.querySelector("#fetchedModelsContainer"); button.disabled = true; button.textContent = "載入中…";
  try {
    const providerId = apiPageContent.querySelector('input[name="provider"]:checked')?.value || "openrouter";
    const models = await fetchModels({ providerId, apiKey: selectedValue("#apiKeyInput"), customEndpoint: selectedValue("#customEndpointInput") }); const starred = await getStarredModels();
    apiPageContent.querySelector("#modelList").innerHTML = models.map((item) => modelOption(item.id, item.name)).join(""); container.hidden = false;
    container.innerHTML = `<p class="fetched-models-count">共 ${models.length} 個模型</p>${models.map((item) => `<div class="fetched-model-row"><button type="button" class="fetched-model-select btn-plain" data-model="${esc(item.id)}">${esc(item.name || item.id)}</button><button type="button" class="fetch-model-star-btn btn-plain ${starred.includes(item.id) ? "is-starred" : ""}" data-model="${esc(item.id)}" aria-label="收藏 ${esc(item.id)}">${starred.includes(item.id) ? "★" : "☆"}</button></div>`).join("")}`;
    container.querySelectorAll(".fetched-model-select").forEach((item) => item.addEventListener("click", () => { apiPageContent.querySelector("#modelInput").value = item.dataset.model; }));
    container.querySelectorAll(".fetch-model-star-btn").forEach((item) => item.addEventListener("click", async () => { const next = await toggleStarModel(item.dataset.model, providerId); const active = next.includes(item.dataset.model); item.classList.toggle("is-starred", active); item.textContent = active ? "★" : "☆"; }));
    toast(`已載入 ${models.length} 個模型`);
  } catch (error) { toast(`拉取失敗：${error.message}`); } finally { button.disabled = false; button.textContent = "拉取列表"; }
}

async function fetchImageModelList() {
  const button = apiPageContent.querySelector("#fetchImageModelsBtn"); button.disabled = true; button.textContent = "…";
  try {
    const providerId = selectedValue("#imageProviderInput", "openrouter"); const currentChatProvider = apiPageContent.querySelector('input[name="provider"]:checked')?.value;
    const apiKey = providerId === currentChatProvider ? selectedValue("#apiKeyInput") : await getSetting(`apiKey_${providerId}`) || "";
    const customEndpoint = providerId === "custom" ? selectedValue("#customEndpointInput") : await getSetting("customEndpoint") || "";
    const models = await fetchImageModels({ providerId, apiKey, customEndpoint, model: selectedValue("#imageModelInput", IMAGE_PROVIDERS[providerId].defaultModel) });
    apiPageContent.querySelector("#imageModelList").innerHTML = models.map((item) => modelOption(item.id, item.name)).join("");
    toast(models.length ? `已載入 ${models.length} 個生圖模型` : "未找到疑似生圖模型，可直接輸入模型 ID");
  } catch (error) { toast(`生圖模型拉取失敗：${error.message}`); } finally { button.disabled = false; button.textContent = "↻"; }
}

async function saveSettings({ quiet = false } = {}) {
  try {
    const draft = await validateCurrentDraft();
    const { providerId, apiKey, model, customEndpoint } = draft;
    const imageProvider = selectedValue("#imageProviderInput", "openrouter");
    const searchMode = selectedValue("#webSearchModeInput", "auto");
    await Promise.all([
      setSetting("provider", providerId), setSetting(`apiKey_${providerId}`, apiKey), setSetting(`model_${providerId}`, model), setSetting("model", model), setSetting("customEndpoint", customEndpoint),
      setSetting("imageGenerationProvider", imageProvider), setSetting(`imageGenerationModel_${imageProvider}`, selectedValue("#imageModelInput")),
    ]);
    const resolvedSearch = await resolveWebSearchConfig({ mode: searchMode, currentProvider: providerId });
    const activeSearchProvider = searchMode === "auto" ? resolvedSearch.providerId : searchMode;
    await Promise.all([
      setSetting("webSearchEnabled", apiPageContent.querySelector("#webSearchEnabledInput").checked), setSetting("webSearchMode", searchMode), setSetting("webSearchMaxResults", Number(selectedValue("#webSearchMaxResults", "5"))), setSetting(`webSearchModel_${activeSearchProvider}`, selectedValue("#webSearchModelInput")),
    ]);
    if (!quiet) toast("設定已儲存");
    return true;
  } catch (error) {
    if (!quiet) toast(`無法儲存：${error.message}`, 6000);
    return false;
  }
}
