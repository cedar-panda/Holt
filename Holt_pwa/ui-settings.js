/**
 * Holt PWA — API 設定
 */

import { $, toast, registerTabHandler } from "./app.js";
import { getSetting, setSetting, getStarredModels, toggleStarModel, isModelStarred } from "./db.js";
import { PROVIDERS, fetchModels, isUsablePwaModelId, isLegacyPwaDefaultModel } from "./api.js";
import { getPromptCachingEnabled, setPromptCachingEnabled } from "./prompt-cache.js";

// ═══ DOM refs ═══

const apiPageContent = $("#apiPageContent");

// ═══ Tab registration ═══

registerTabHandler(0, renderApiSettings);

// ═══ API Settings ═══

async function renderApiSettings() {
  const savedProviderId = (await getSetting("provider")) || "openrouter";
  const providerId = PROVIDERS[savedProviderId] ? savedProviderId : "openrouter";
  const apiKey = (await getSetting(`apiKey_${providerId}`)) || "";
  const providerModel = (await getSetting(`model_${providerId}`)) || "";
  const legacyModel = (await getSetting("model")) || "";
  const model = (isUsablePwaModelId(providerModel) && !isLegacyPwaDefaultModel(providerModel) ? providerModel : "") || (
    isUsablePwaModelId(legacyModel) && !isLegacyPwaDefaultModel(legacyModel) ? legacyModel : ""
  ) || PROVIDERS[providerId]?.defaultModel || "";
  const customEndpoint = (await getSetting("customEndpoint")) || "";
  const promptCachingEnabled = await getPromptCachingEnabled();
  const starred = (await getStarredModels()).filter(isUsablePwaModelId);

  const cacheDescription = providerId === "gemini"
    ? "Gemini 使用 Google cachedContents；達到模型門檻後建立 1 小時內容快取。"
    : "Claude／支援 Anthropic 協議的中轉站使用 1 小時顯式快取；Grok 使用供應商的隱式前綴快取。其他模型會維持普通請求。";

  apiPageContent.innerHTML = `
    <div class="settings-section">
      <p class="field-label">Provider</p>
      <div class="radio-group">
        ${Object.entries(PROVIDERS).map(([key, p]) => `
          <label class="radio-option">
            <input type="radio" name="provider" value="${key}" ${key === providerId ? "checked" : ""}>
            ${p.label}
          </label>
        `).join("")}
      </div>
    </div>

    <div class="settings-section" id="customEndpointSection" ${providerId !== "custom" ? 'style="display:none"' : ""}>
      <label class="field-label">自訂端點 URL</label>
      <input class="field-input" id="customEndpointInput" type="url" value="${customEndpoint}" placeholder="https://your-relay.com/v1">
    </div>

    <div class="settings-section">
      <label class="field-label">API Key</label>
      <div class="settings-key-row">
        <input class="field-input" id="apiKeyInput" type="password" value="${apiKey}" placeholder="${PROVIDERS[providerId]?.keyPlaceholder || "sk-…"}">
        <button class="settings-eye btn-plain" id="toggleKeyVis" type="button" aria-label="顯示 API Key" aria-pressed="false"></button>
      </div>
    </div>

    <div class="settings-section">
      <label class="field-label">模型</label>
      ${starred.length ? `
        <div class="starred-models-chips" style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:8px;">
          ${starred.map((m) => `
            <button type="button" class="starred-model-chip btn-plain" data-model="${m}" style="padding:4px 8px;font-size:11px;border-radius:8px;background:color-mix(in srgb,var(--accent) 12%,transparent);color:var(--accent);">⭐ ${m.split("/").pop()}</button>
          `).join("")}
        </div>
      ` : ""}
      <div class="settings-model-row">
        <input class="field-input" id="modelInput" list="modelList" type="text" value="${model}" placeholder="輸入模型 ID">
        <datalist id="modelList"></datalist>
        <button class="btn-plain" id="fetchModelsBtn" type="button">拉取列表</button>
      </div>
      <p class="settings-hint">填入模型 ID，或點拉取列表選擇與星標收藏。</p>
      <div id="fetchedModelsContainer" style="margin-top:10px;display:none;max-height:220px;overflow-y:auto;border-radius:12px;background:color-mix(in srgb,var(--ink) 4%,transparent);padding:8px;"></div>
    </div>

    <div class="settings-section cache-settings">
      <label class="cache-toggle-row">
        <input id="promptCachingInput" type="checkbox" ${promptCachingEnabled ? "checked" : ""}>
        <span>
          <strong>提示詞快取</strong>
          <small>沿用 Holt 原生的穩定前綴、滾動斷點與 request-only 狀態分層。</small>
        </span>
      </label>
      <p class="settings-hint">${cacheDescription}</p>
    </div>

    <div class="settings-section settings-actions">
      <button class="btn-primary" id="saveSettingsBtn" type="button">儲存設定</button>
    </div>
  `;

  // Starred chip click
  apiPageContent.querySelectorAll(".starred-model-chip").forEach((chip) => {
    chip.addEventListener("click", () => {
      const m = chip.dataset.model;
      const modelInput = apiPageContent.querySelector("#modelInput");
      if (modelInput) modelInput.value = m;
      toast(`已填入模型：${m}`);
    });
  });

  // Provider radio change
  apiPageContent.querySelectorAll('input[name="provider"]').forEach((radio) => {
    radio.addEventListener("change", async () => {
      const custom = radio.value === "custom";
      const sec = apiPageContent.querySelector("#customEndpointSection");
      sec.style.display = custom ? "" : "none";
      const nextProvider = PROVIDERS[radio.value];
      const nextKey = (await getSetting(`apiKey_${radio.value}`)) || "";
      const nextProviderModel = (await getSetting(`model_${radio.value}`)) || "";
      const nextLegacyModel = (await getSetting("model")) || "";
      const nextModel = (isUsablePwaModelId(nextProviderModel) && !isLegacyPwaDefaultModel(nextProviderModel) ? nextProviderModel : "") || (
        isUsablePwaModelId(nextLegacyModel) && !isLegacyPwaDefaultModel(nextLegacyModel) ? nextLegacyModel : ""
      ) || nextProvider?.defaultModel || "";
      const keyInput = apiPageContent.querySelector("#apiKeyInput");
      const modelInput = apiPageContent.querySelector("#modelInput");
      keyInput.value = nextKey;
      keyInput.placeholder = nextProvider?.keyPlaceholder || "sk-…";
      modelInput.value = nextModel;
      modelInput.placeholder = "輸入模型 ID";
      const hint = apiPageContent.querySelector(".cache-settings .settings-hint");
      hint.textContent = radio.value === "gemini"
        ? "Gemini 使用 Google cachedContents；達到模型門檻後建立 1 小時內容快取。"
        : "Claude／支援 Anthropic 協議的中轉站使用 1 小時顯式快取；Grok 使用供應商的隱式前綴快取。其他模型會維持普通請求。";
    });
  });

  // Eye toggle
  const eyeOpenIcon = '<svg class="eye-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M2.5 12s3.3-5 9.5-5 9.5 5 9.5 5-3.3 5-9.5 5-9.5-5-9.5-5Z"></path><circle cx="12" cy="12" r="2.5"></circle></svg>';
  const eyeClosedIcon = '<svg class="eye-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 3l18 18"></path><path d="M10.6 6.9A10.7 10.7 0 0 1 12 7c6.2 0 9.5 5 9.5 5a16.3 16.3 0 0 1-3.1 3.2M6.2 6.8C3.8 8.2 2.5 12 2.5 12s3.3 5 9.5 5c1 0 1.9-.1 2.7-.4"></path><path d="M9.7 9.7a3.2 3.2 0 0 0 4.6 4.6"></path></svg>';
  const eyeButton = apiPageContent.querySelector("#toggleKeyVis");
  const updateEyeIcon = () => {
    const input = apiPageContent.querySelector("#apiKeyInput");
    const isVisible = input.type === "text";
    eyeButton.innerHTML = isVisible ? eyeClosedIcon : eyeOpenIcon;
    eyeButton.setAttribute("aria-label", isVisible ? "隱藏 API Key" : "顯示 API Key");
    eyeButton.setAttribute("aria-pressed", String(isVisible));
  };
  updateEyeIcon();
  eyeButton.addEventListener("click", () => {
    const input = apiPageContent.querySelector("#apiKeyInput");
    input.type = input.type === "password" ? "text" : "password";
    updateEyeIcon();
  });

  // Fetch models with star buttons
  apiPageContent.querySelector("#fetchModelsBtn").addEventListener("click", async () => {
    const btn = apiPageContent.querySelector("#fetchModelsBtn");
    btn.textContent = "載入中…";
    try {
      const providerId = apiPageContent.querySelector('input[name="provider"]:checked')?.value || "openrouter";
      const apiKey = apiPageContent.querySelector("#apiKeyInput")?.value.trim() || "";
      const customEndpoint = apiPageContent.querySelector("#customEndpointInput")?.value.trim() || "";
      const models = await fetchModels({ providerId, apiKey, customEndpoint });
      const dl = apiPageContent.querySelector("#modelList");
      dl.innerHTML = models.map((m) => `<option value="${m.id}">${m.name}</option>`).join("");

      const container = apiPageContent.querySelector("#fetchedModelsContainer");
      container.style.display = "block";
      const currentStarred = await getStarredModels();

      container.innerHTML = `
        <div style="font-size:11px;color:var(--ink-faint);margin-bottom:6px;display:flex;justify-content:space-between;">
          <span>共 ${models.length} 個模型（點擊填入，⭐ 加星收藏）</span>
        </div>
        ${models.map((m) => {
          const isStarred = currentStarred.includes(m.id);
          return `
            <div class="fetched-model-row" style="display:flex;align-items:center;justify-content:space-between;padding:5px 8px;border-radius:8px;margin-bottom:2px;cursor:pointer;">
              <span class="fetched-model-id" data-model="${m.id}" style="font-size:12px;color:var(--ink);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${m.name || m.id}</span>
              <button type="button" class="fetch-model-star-btn btn-plain" data-model="${m.id}" style="color:${isStarred ? "#f5a623" : "var(--ink-faint)"};font-size:14px;padding:2px 6px;">
                ${isStarred ? "★" : "☆"}
              </button>
            </div>
          `;
        }).join("")}
      `;

      container.querySelectorAll(".fetched-model-id").forEach((el) => {
        el.addEventListener("click", () => {
          const mid = el.dataset.model;
          apiPageContent.querySelector("#modelInput").value = mid;
          toast(`已選擇模型：${mid}`);
        });
      });

      container.querySelectorAll(".fetch-model-star-btn").forEach((sbtn) => {
        sbtn.addEventListener("click", async (e) => {
          e.stopPropagation();
          const mid = sbtn.dataset.model;
          const prov = apiPageContent.querySelector('input[name="provider"]:checked')?.value || "openrouter";
          const updated = await toggleStarModel(mid, prov);
          const nowStarred = updated.includes(mid);
          sbtn.textContent = nowStarred ? "★" : "☆";
          sbtn.style.color = nowStarred ? "#f5a623" : "var(--ink-faint)";
          toast(nowStarred ? `已加星收藏：${mid}` : `已取消星標：${mid}`);
        });
      });

      toast(`已載入 ${models.length} 個模型`);
    } catch (err) {
      toast("拉取失敗：" + err.message);
    } finally {
      btn.textContent = "拉取列表";
    }
  });

  // Prompt caching toggle
  apiPageContent.querySelector("#promptCachingInput").addEventListener("change", async (event) => {
    await setPromptCachingEnabled(event.target.checked);
    toast(event.target.checked ? "已開啟提示詞快取" : "已關閉提示詞快取");
  });

  // Save
  apiPageContent.querySelector("#saveSettingsBtn").addEventListener("click", async () => {
    const prov = apiPageContent.querySelector('input[name="provider"]:checked')?.value || "openrouter";
    const key = apiPageContent.querySelector("#apiKeyInput").value.trim();
    const mdl = apiPageContent.querySelector("#modelInput").value.trim();
    const ep = apiPageContent.querySelector("#customEndpointInput")?.value.trim() || "";

    await setSetting("provider", prov);
    await setSetting(`apiKey_${prov}`, key);
    await setSetting(`model_${prov}`, mdl);
    await setSetting("model", mdl);
    if (ep) await setSetting("customEndpoint", ep);

    toast("設定已儲存");
  });
}
