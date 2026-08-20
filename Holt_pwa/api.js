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
  return String(value || "")
    .trim()
    .replace(/\/+$/, "")
    .replace(/\/(?:chat\/completions|models)$/, "");
}

function isUsablePwaModelId(value) {
  return String(value || "").trim().length > 0;
}

function isLegacyPwaDefaultModel(value) {
  return /^anthropic\/claude-sonnet-4$/i.test(String(value || "").trim());
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
  const savedModel = usableProviderModel || usableLegacyModel;
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
  if (!res.ok) throw new Error(`模型列表請求失敗：${res.status}`);

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
  const liveState = prompt.requestOnlyPart.trim();
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
  const res = await fetch(`${config.provider.endpoint}/models/${model}:streamGenerateContent?alt=sse`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": config.apiKey },
    body: JSON.stringify(body),
    signal: opts.signal,
  });
  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    throw new Error(`Gemini API 錯誤 ${res.status}：${errText.slice(0, 300)}`);
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const state = { fullText: "" };
  const consume = (line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed === "data: [DONE]" || !trimmed.startsWith("data: ")) return;
    try { processGeminiEvent(JSON.parse(trimmed.slice(6)), opts, state); } catch {}
  };
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";
    lines.forEach(consume);
  }
  if (buffer) consume(buffer);
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
  const res = await fetch(`${config.provider.endpoint}/models/${model}:generateContent`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": config.apiKey },
    body: JSON.stringify(body),
    signal: opts.signal,
  });
  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    throw new Error(`Gemini API 錯誤 ${res.status}：${errText.slice(0, 300)}`);
  }
  const data = await res.json();
  opts.onUsage?.(data.usageMetadata);
  return extractGeminiText(data);
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

  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
      ...plan.headers,
    },
    body: JSON.stringify(body),
    signal: opts.signal,
  });

  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    throw new Error(`API 錯誤 ${res.status}：${errText.slice(0, 300)}`);
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let fullText = "";
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed === "data: [DONE]") continue;
      if (!trimmed.startsWith("data: ")) continue;

      try {
        const json = JSON.parse(trimmed.slice(6));
        const delta = json.choices?.[0]?.delta;
        const reasoning = delta?.reasoning_content || delta?.reasoning || delta?.thought;
        if (reasoning) {
          opts.onThinkingDelta?.(reasoning);
        }
        if (delta?.content) {
          fullText += delta.content;
          opts.onDelta?.(delta.content);
        }
        if (json.usage) opts.onUsage?.(json.usage);
      } catch {
        // 跳過格式不正確的行
      }
    }
  }

  opts.onDone?.(fullText);
  return fullText;
}

// ═══ 非流式（備用）═══

async function chat(messages, opts = {}) {
  const config = await getProviderConfig();
  const { providerId, apiKey, model, endpoint } = config;
  if (!apiKey) throw new Error("尚未設定 API Key");
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

  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
      ...plan.headers,
    },
    body: JSON.stringify(body),
    signal: opts.signal,
  });

  if (!res.ok) {
    const errText = await res.text().catch(() => "");
    throw new Error(`API 錯誤 ${res.status}：${errText.slice(0, 300)}`);
  }

  const data = await res.json();
  return data.choices?.[0]?.message?.content || "";
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
  streamChat,
  chat,
  buildVisionMessage,
};
