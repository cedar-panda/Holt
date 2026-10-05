/**
 * Holt PWA — LLM API 統一調用層
 * 支持 OpenRouter / xAI / Gemini / OpenAI 兼容中轉站。
 * 各 provider 保留自己的原生 payload 與 cache 協議。
 */

import { getSetting } from "./db.js";
import {
  buildPromptCachePlan,
  cacheThresholdForModel,
  createStructuredPrompt,
  estimateTokens,
  getPromptCachingEnabled,
  hashText,
  liveStateEnvelope,
} from "./prompt-cache.js";

// ═══ Provider 定義 ═══

const PROVIDERS = {
  openrouter: {
    label: "OpenRouter",
    endpoint: "https://openrouter.ai/api/v1/chat/completions",
    modelsEndpoint: "https://openrouter.ai/api/v1/models",
    keyPlaceholder: "sk-or-v1-…",
  },
  grok: {
    label: "Grok (x.ai)",
    endpoint: "https://api.x.ai/v1/chat/completions",
    modelsEndpoint: "https://api.x.ai/v1/models",
    keyPlaceholder: "xai-…",
  },
  gemini: {
    label: "Google Gemini",
    endpoint: "https://generativelanguage.googleapis.com/v1beta",
    modelsEndpoint: "https://generativelanguage.googleapis.com/v1beta/models",
    keyPlaceholder: "AIza…",
    defaultModel: "gemini-2.5-flash",
  },
  custom: {
    label: "自訂中轉站",
    endpoint: "",          // 由用戶設定
    modelsEndpoint: "",
    keyPlaceholder: "sk-…",
  },
};

// ═══ 讀取當前 provider 設定 ═══

function normalizeCustomEndpoint(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";
  let url;
  try { url = new URL(raw); } catch { throw new Error("自訂中轉站 URL 格式無效"); }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password || url.hash) {
    throw new Error("自訂中轉站只接受不含帳密與片段的 HTTPS URL");
  }
  url.pathname = url.pathname
    .replace(/\/+$/, "")
    .replace(/\/(?:chat\/completions|models)$/, "");
  url.search = "";
  return url.toString().replace(/\/+$/, "");
}

function isUsablePwaModelId(value) {
  return String(value || "").trim().length > 0;
}

function isLegacyPwaDefaultModel(value) {
  return /^anthropic\/claude-sonnet-4$/i.test(String(value || "").trim());
}

function compactApiErrorBody(body) {
  const text = String(body || "").trim();
  if (!text) return "";
  const sanitize = (value) => String(value || "")
    .replace(/[<>]/g, "")
    .replace(/[\x00-\x1f\x7f]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 280);
  try {
    const json = JSON.parse(text);
    const detail = json?.error?.message || json?.error?.detail || json?.message || json?.detail;
    if (detail) return sanitize(detail);
  } catch {}
  return sanitize(text.replace(/<[^>]*>/g, " "));
}

function apiHttpError(operation, status, body = "") {
  const reason = compactApiErrorBody(body);
  const statusHint = status === 403
    ? "中轉站拒絕此請求，常見原因是金鑰權限、模型白名單、來源網域或上游帳戶限制"
    : status === 401
      ? "API Key 無效或已失效"
      : status === 429
        ? "請求過多或額度不足"
        : "請檢查來源設定與模型是否可用";
  return new Error(`${operation}（HTTP ${status}）：${reason || statusHint}${reason ? `；${statusHint}` : ""}`);
}

function timedSignal(externalSignal, timeoutMs = 45000) {
  const controller = new AbortController();
  let timedOut = false;
  const timeoutId = setTimeout(() => {
    timedOut = true;
    controller.abort(new DOMException("請求逾時", "TimeoutError"));
  }, timeoutMs);
  const onAbort = () => controller.abort(externalSignal?.reason || new DOMException("已取消", "AbortError"));
  if (externalSignal?.aborted) onAbort();
  else externalSignal?.addEventListener("abort", onAbort, { once: true });
  return {
    signal: controller.signal,
    timedOut: () => timedOut,
    cleanup() {
      clearTimeout(timeoutId);
      externalSignal?.removeEventListener("abort", onAbort);
    },
  };
}

function timeoutError(error, request) {
  return request.timedOut() ? new Error("API 請求逾時，請檢查網路或中轉站狀態") : error;
}

async function getProviderConfig(overrides = {}) {
  const rawSavedProviderId = (await getSetting("provider")) || "openrouter";
  const savedProviderId = PROVIDERS[rawSavedProviderId] ? rawSavedProviderId : "openrouter";
  const requestedProviderId = overrides.providerId || savedProviderId;
  const providerId = PROVIDERS[requestedProviderId] ? requestedProviderId : "openrouter";
  const provider = PROVIDERS[providerId] || PROVIDERS.openrouter;
  const savedApiKey = (await getSetting(`apiKey_${providerId}`)) || "";
  const apiKey = String(overrides.apiKey ?? savedApiKey).trim();
  const providerModel = (await getSetting(`model_${providerId}`)) || "";
  const legacyModel = (await getSetting("model")) || "";
  // 忽略空白模型 ID
  const usableProviderModel = isUsablePwaModelId(providerModel) ? providerModel : "";
  const usableLegacyModel = isUsablePwaModelId(legacyModel) ? legacyModel : "";
  // The old `model` key belonged to whichever provider was selected when it
  // was saved. Do not leak that model into another provider after switching.
  const savedModel = usableProviderModel || (providerId === savedProviderId ? usableLegacyModel : "");
  const model = String(
    overrides.model ?? (savedModel || provider.defaultModel || ""),
  ).trim();
  const savedCustomEndpoint = (await getSetting("customEndpoint")) || "";
  const customEndpoint = String(overrides.customEndpoint ?? savedCustomEndpoint).trim();

  let endpoint = provider.endpoint;
  if (providerId === "custom" && customEndpoint) {
    endpoint = normalizeCustomEndpoint(customEndpoint);
    if (!endpoint.endsWith("/chat/completions")) {
      endpoint += "/chat/completions";
    }
  }

  return { providerId, provider, apiKey, model, endpoint, customEndpoint };
}

// ═══ 模型列表 ═══

async function fetchModels(overrides = {}) {
  const { providerId, provider, apiKey, customEndpoint } = await getProviderConfig(overrides);
  const modelsUrl = providerId === "custom"
    ? `${normalizeCustomEndpoint(customEndpoint)}/models`
    : provider.modelsEndpoint;

  if (!apiKey) throw new Error("請先輸入 API Key");
  if (providerId === "custom" && !normalizeCustomEndpoint(customEndpoint)) {
    throw new Error("請先輸入自訂端點 URL");
  }

  const res = await fetch(modelsUrl, {
    headers: providerId === "gemini"
      ? { "x-goog-api-key": apiKey }
      : { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) throw apiHttpError("模型列表請求失敗", res.status, await res.text().catch(() => ""));

  const data = await res.json();
  const rawModels = providerId === "gemini"
    ? (data.models || []).filter((m) => (m.supportedGenerationMethods || []).includes("generateContent"))
    : (data.data || []);
  const models = rawModels
    .map((m) => providerId === "gemini"
      ? ({ id: String(m.name || "").replace(/^models\//, ""), name: m.displayName || m.name || "" })
      : ({ id: m.id || "", name: m.name || m.id || "" }))
    .filter((m) => m.id)
    .sort((a, b) => a.name.localeCompare(b.name));
  return models;
}

// ═══ Gemini 原生協議與 Context Cache ═══

const GEMINI_CACHE_TTL_MS = 60 * 60 * 1000;
const geminiCacheEntries = new Map();

function normalizeGeminiModel(model) {
  const value = String(model || "gemini-2.5-flash").trim();
  return value.replace(/^models\//, "").split("/").pop() || "gemini-2.5-flash";
}

function geminiPartFromContent(block) {
  if (!block || typeof block !== "object") return null;
  if (block.type === "text") return { text: String(block.text || "") };
  if (block.type !== "image_url") return null;
  const url = block.image_url?.url || "";
  const match = String(url).match(/^data:([^;]+);base64,(.+)$/s);
  if (match) {
    return { inlineData: { mimeType: match[1], data: match[2] } };
  }
  return url ? { fileData: { fileUri: url } } : null;
}

function geminiContents(messages) {
  const contents = messages.map((message) => {
    const raw = message.content;
    const blocks = Array.isArray(raw)
      ? raw.map(geminiPartFromContent).filter(Boolean)
      : [{ text: String(raw ?? "") }];
    return {
      role: message.role === "assistant" ? "model" : "user",
      parts: blocks.length ? blocks : [{ text: "" }],
    };
  });
  if (!contents.length) contents.push({ role: "user", parts: [{ text: "（開始對話）" }] });
  return contents;
}

function geminiTextParts(prompt) {
  return prompt.cacheableParts
    .filter(Boolean)
    .map((text) => ({ text }));
}

async function ensureGeminiCache({ apiKey, model, prompt, signal }) {
  if (!(await getPromptCachingEnabled())) return { name: "", status: "disabled" };
  const stableText = prompt.cacheableParts.join("\n\n");
  const threshold = cacheThresholdForModel("gemini", model);
  const staticTokens = estimateTokens(stableText);
  if (staticTokens < threshold) {
    return { name: "", status: "below_threshold", staticTokens, threshold };
  }

  const cacheKey = await hashText(`${apiKey}\u0000${model}\u0000${stableText}`);
  const now = Date.now();
  const existing = geminiCacheEntries.get(cacheKey);
  if (existing && existing.expiresAt > now) {
    return { ...existing, status: "hit", staticTokens, threshold };
  }
  geminiCacheEntries.delete(cacheKey);

  try {
    const res = await fetch("https://generativelanguage.googleapis.com/v1beta/cachedContents", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": apiKey },
      body: JSON.stringify({
        model: `models/${normalizeGeminiModel(model)}`,
        systemInstruction: { parts: geminiTextParts(prompt) },
        ttl: "3600s",
      }),
      signal,
    });
    if (!res.ok) return { name: "", status: "create_failed", staticTokens, threshold };
    const data = await res.json();
    if (!data.name) return { name: "", status: "create_failed", staticTokens, threshold };
    const entry = { name: data.name, expiresAt: now + GEMINI_CACHE_TTL_MS };
    geminiCacheEntries.set(cacheKey, entry);
    return { ...entry, status: "created", staticTokens, threshold };
  } catch (error) {
    if (error?.name === "AbortError") throw error;
    return { name: "", status: "create_failed", staticTokens, threshold };
  }
}

async function buildGeminiRequest({ apiKey, model, messages, opts, stream }) {
  const prompt = opts.structuredPrompt || createStructuredPrompt({ staticPart: opts.systemPrompt || "" });
  const contents = geminiContents(messages);
  const liveState = liveStateEnvelope(prompt.requestOnlyPart);
  const latestUser = [...contents].map((message, index) => ({ message, index }))
    .reverse().find(({ message }) => message.role === "user")?.index ?? -1;
  let liveAttached = false;
  if (liveState && latestUser >= 0) {
    for (let i = latestUser - 1; i >= 0; i -= 1) {
      if (contents[i].role !== "model") continue;
      contents[i].parts.push({ text: liveState });
      liveAttached = true;
      break;
    }
  }

  const cache = await ensureGeminiCache({ apiKey, model, prompt, signal: opts.signal });
  const useCachedContent = Boolean(cache.name) && (!liveState || liveAttached);
  const body = {
    contents,
    generationConfig: { maxOutputTokens: 4096 },
    ...(useCachedContent
      ? { cachedContent: cache.name }
      : {
          systemInstruction: {
            parts: [
              ...geminiTextParts(prompt),
              ...(liveState && !liveAttached ? [{ text: liveState }] : []),
            ],
          },
        }),
  };
  return {
    body,
    plan: {
      cacheMode: useCachedContent ? "gemini_cachedContents" : "none",
      cacheStatus: cache.status,
      cacheName: cache.name || "",
      cacheEnabled: useCachedContent,
      liveStateTransport: liveAttached ? "gemini_model_state" : "gemini_system_instruction_fallback",
      stream,
    },
  };
}

function extractGeminiText(data) {
  const parts = data?.candidates?.[0]?.content?.parts || [];
  return parts
    .filter((part) => part && part.thought !== true && typeof part.text === "string")
    .map((part) => part.text)
    .join("");
}

function openAiMessageText(content) {
  if (Array.isArray(content)) {
    return content.map((part) => typeof part === "string" ? part : part?.text || "").join("");
  }
  return String(content || "");
}

function processGeminiEvent(data, opts, state) {
  if (data.usageMetadata) opts.onUsage?.(data.usageMetadata);
  const parts = data.candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) return;
  for (const part of parts) {
    if (part?.thought === true && typeof part?.text === "string" && part.text) {
      opts.onThinkingDelta?.(part.text);
      continue;
    }
    if (typeof part?.text !== "string" || !part.text) continue;
    state.fullText += part.text;
    opts.onDelta?.(part.text);
  }
}

async function streamGemini(messages, opts, config) {
  const model = normalizeGeminiModel(config.model);
  const { body, plan } = await buildGeminiRequest({
    apiKey: config.apiKey,
    model,
    messages,
    opts,
    stream: true,
  });
  opts.onPlan?.(plan);
  const request = timedSignal(opts.signal);
  let res;
  try {
    res = await fetch(`${config.provider.endpoint}/models/${model}:streamGenerateContent?alt=sse`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": config.apiKey },
      body: JSON.stringify(body),
      signal: request.signal,
    });
  } catch (error) {
    request.cleanup();
    throw timeoutError(error, request);
  }
  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    request.cleanup();
    throw apiHttpError("Gemini API 錯誤", res.status, errText);
  }

  if (!res.body) {
    request.cleanup();
    throw new Error("Gemini 未返回可讀取的串流內容");
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const state = { fullText: "" };
  const consume = (line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed === "data: [DONE]" || !trimmed.startsWith("data: ")) return;
    let data;
    try { data = JSON.parse(trimmed.slice(6)); } catch { return; }
    if (data?.error) {
      throw new Error(`Gemini 串流錯誤：${compactApiErrorBody(JSON.stringify(data)) || "未知錯誤"}`);
    }
    processGeminiEvent(data, opts, state);
  };
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";
      lines.forEach(consume);
    }
  } catch (error) {
    throw timeoutError(error, request);
  } finally {
    request.cleanup();
  }
  if (buffer) consume(buffer);
  if (!state.fullText.trim()) throw new Error("Gemini 返回空白回覆，請確認模型可用性");
  opts.onDone?.(state.fullText);
  return state.fullText;
}

async function chatGemini(messages, opts, config) {
  const model = normalizeGeminiModel(config.model);
  const { body, plan } = await buildGeminiRequest({
    apiKey: config.apiKey,
    model,
    messages,
    opts,
    stream: false,
  });
  opts.onPlan?.(plan);
  const request = timedSignal(opts.signal, 20000);
  let res;
  try {
    res = await fetch(`${config.provider.endpoint}/models/${model}:generateContent`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-goog-api-key": config.apiKey },
      body: JSON.stringify(body),
      signal: request.signal,
    });
  } catch (error) {
    request.cleanup();
    throw timeoutError(error, request);
  }
  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    request.cleanup();
    throw apiHttpError("Gemini API 錯誤", res.status, errText);
  }
  let data;
  try {
    data = await res.json();
  } finally {
    request.cleanup();
  }
  opts.onUsage?.(data.usageMetadata);
  const text = extractGeminiText(data);
  if (!text.trim()) throw new Error("Gemini 返回空白回覆");
  return text;
}

// ═══ 流式聊天 ═══

/**
 * @param {Array} messages — OpenAI 格式的 messages 陣列
 * @param {object} opts
 * @param {string} [opts.systemPrompt] — system prompt
 * @param {function} opts.onDelta — (text: string) => void 每個 token 回調
 * @param {function} [opts.onDone] — (fullText: string) => void 完成回調
 * @param {function} [opts.onError] — (error: Error) => void
 * @param {AbortSignal} [opts.signal] — 取消信號
 * @returns {Promise<string>} 完整回覆文字
 */
async function streamChat(messages, opts = {}) {
  const config = await getProviderConfig();
  const { providerId, apiKey, model, endpoint } = config;

  if (!apiKey) throw new Error("尚未設定 API Key，請先到設定頁面填入。");
  if (!model) throw new Error("尚未選擇模型，請先到設定頁面填入模型 ID。");
  if (!endpoint) throw new Error("API 端點未設定完整。");
  if (providerId === "gemini") return streamGemini(messages, opts, config);

  const { body, plan } = await buildPromptCachePlan({
    providerId,
    model,
    messages,
    systemPrompt: opts.systemPrompt,
    structuredPrompt: opts.structuredPrompt,
    conversationId: opts.conversationId,
    stream: true,
  });
  opts.onPlan?.(plan);

  const request = timedSignal(opts.signal);
  let res;
  try {
    res = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
        ...plan.headers,
      },
      body: JSON.stringify(body),
      signal: request.signal,
    });
  } catch (error) {
    request.cleanup();
    throw timeoutError(error, request);
  }

  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    request.cleanup();
    throw apiHttpError("API 請求失敗", res.status, errText);
  }

  const contentType = String(res.headers.get("content-type") || "").toLowerCase();
  if (contentType.includes("application/json")) {
    let data;
    try {
      data = await res.json().catch(() => ({}));
    } finally {
      request.cleanup();
    }
    if (data?.error) throw new Error(`API 串流錯誤：${compactApiErrorBody(JSON.stringify(data)) || "未知錯誤"}`);
    const fallbackText = openAiMessageText(data?.choices?.[0]?.message?.content).trim();
    if (!fallbackText) throw new Error("API 返回空白回覆或不支援 SSE 串流");
    opts.onDelta?.(fallbackText);
    if (data.usage) opts.onUsage?.(data.usage);
    opts.onDone?.(fallbackText);
    return fallbackText;
  }
  if (!res.body) {
    request.cleanup();
    throw new Error("API 未返回可讀取的串流內容");
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let fullText = "";
  let buffer = "";

  const consumeLine = (line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed === "data: [DONE]" || !trimmed.startsWith("data:")) return;
    const payload = trimmed.slice(5).trim();
    if (!payload) return;
    let json;
    try { json = JSON.parse(payload); } catch { return; }
    if (json?.error) throw new Error(`API 串流錯誤：${compactApiErrorBody(JSON.stringify(json)) || "未知錯誤"}`);
    const delta = json.choices?.[0]?.delta;
    const reasoning = delta?.reasoning_content || delta?.reasoning || delta?.thought;
    if (reasoning) opts.onThinkingDelta?.(reasoning);
    const content = Array.isArray(delta?.content)
      ? delta.content.map((part) => part?.text || "").join("")
      : delta?.content;
    if (content) {
      fullText += content;
      opts.onDelta?.(content);
    }
    if (json.usage) opts.onUsage?.(json.usage);
  };

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";
      for (const line of lines) consumeLine(line);
    }
    if (buffer) consumeLine(buffer);
  } catch (error) {
    throw timeoutError(error, request);
  } finally {
    request.cleanup();
  }
  if (!fullText.trim()) {
    throw new Error("模型返回空白回覆，請確認模型支援 SSE 或更換模型");
  }

  opts.onDone?.(fullText);
  return fullText;
}

// ═══ 非流式（備用）═══

async function chat(messages, opts = {}) {
  const config = await getProviderConfig(opts.configOverrides || {});
  const { providerId, apiKey, model, endpoint } = config;
  if (!apiKey) throw new Error("尚未設定 API Key");
  if (!model) throw new Error("尚未選擇模型");
  if (!endpoint) throw new Error("API 端點未設定完整");
  if (providerId === "gemini") return chatGemini(messages, opts, config);

  const { body, plan } = await buildPromptCachePlan({
    providerId,
    model,
    messages,
    systemPrompt: opts.systemPrompt,
    structuredPrompt: opts.structuredPrompt,
    conversationId: opts.conversationId,
    stream: false,
  });
  opts.onPlan?.(plan);

  const request = timedSignal(opts.signal, 20000);
  let res;
  try {
    res = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
        ...plan.headers,
      },
      body: JSON.stringify(body),
      signal: request.signal,
    });
  } catch (error) {
    request.cleanup();
    throw timeoutError(error, request);
  }

  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    request.cleanup();
    throw apiHttpError("API 請求失敗", res.status, errText);
  }

  let data;
  try {
    data = await res.json();
  } finally {
    request.cleanup();
  }
  const text = openAiMessageText(data.choices?.[0]?.message?.content);
  if (!String(text).trim()) throw new Error("模型返回空白回覆");
  return text;
}

async function testProviderConnection(overrides = {}) {
  const reply = await chat([{ role: "user", content: "Reply with OK only." }], {
    configOverrides: overrides,
    systemPrompt: "This is a connection test. Reply with OK only.",
  });
  if (!String(reply || "").trim()) throw new Error("模型連線成功但返回空白內容");
  return String(reply).trim();
}

// ═══ 構建 vision 消息（圖片 + 文字）═══

function buildVisionMessage(text, imageBase64, mimeType = "image/png") {
  return {
    role: "user",
    content: [
      ...(text ? [{ type: "text", text }] : []),
      {
        type: "image_url",
        image_url: { url: `data:${mimeType};base64,${imageBase64}` },
      },
    ],
  };
}

export {
  PROVIDERS,
  getProviderConfig,
  fetchModels,
  isUsablePwaModelId,
  isLegacyPwaDefaultModel,
  apiHttpError,
  testProviderConnection,
  streamChat,
  chat,
  buildVisionMessage,
};
