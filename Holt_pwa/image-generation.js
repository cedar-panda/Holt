/** Holt PWA — 多來源生圖。只使用 PWA 已支援的四個 API 來源。 */

import { getSetting } from "./db.js";
import { apiHttpError, fetchModels } from "./api.js";

const IMAGE_PROVIDERS = Object.freeze({
  openrouter: { label: "OpenRouter", defaultModel: "openai/gpt-5.4-image-2" },
  gemini: { label: "Gemini", defaultModel: "gemini-3.1-flash-image" },
  grok: { label: "Grok / xAI", defaultModel: "grok-imagine-image-2.0" },
  custom: { label: "API 中轉站", defaultModel: "gpt-image-1" },
});

const MAX_IMAGE_BYTES = 12 * 1024 * 1024;
const IMAGE_MODEL_HINT = /(image|imagen|imagine|flux|seedream|recraft|dall[ -]?e|stable-diffusion|wan2\.|z-image)/i;
const UNSUPPORTED_VECTOR_MODEL = /(?:^|[-/_.])(svg|vector)(?:$|[-/_.])/i;

function rasterImageModel(item) {
  const value = `${item?.id || ""} ${item?.name || ""}`;
  return !UNSUPPORTED_VECTOR_MODEL.test(value);
}

function imageRequestSignal(externalSignal, timeoutMs = 90000) {
  if (!externalSignal) return AbortSignal.timeout(timeoutMs);
  if (typeof AbortSignal.any === "function") return AbortSignal.any([externalSignal, AbortSignal.timeout(timeoutMs)]);
  return externalSignal;
}

function normalizeBaseUrl(value) {
  return String(value || "")
    .trim()
    .replace(/\/+$/, "")
    .replace(/\/(?:chat\/completions|images\/generations|images|models)$/i, "")
    .replace(/\/+$/, "");
}

function validatedHttpsBase(value) {
  const normalized = normalizeBaseUrl(value);
  let url;
  try { url = new URL(normalized); } catch { throw new Error("API 中轉站 Base URL 格式無效"); }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password || url.hash) {
    throw new Error("API 中轉站只接受不含帳密與片段的 HTTPS Base URL");
  }
  return normalized;
}

function imageEndpointForBase(value) {
  let base = validatedHttpsBase(value);
  if (!/\/v1$/i.test(base)) base += "/v1";
  return `${base}/images/generations`;
}

async function getImageGenerationConfig(overrides = {}) {
  const savedProvider = await getSetting("imageGenerationProvider");
  const requested = String(overrides.providerId ?? savedProvider ?? "openrouter");
  const providerId = IMAGE_PROVIDERS[requested] ? requested : "openrouter";
  const apiKey = String(overrides.apiKey ?? await getSetting(`apiKey_${providerId}`) ?? "").trim();
  const customEndpoint = String(overrides.customEndpoint ?? await getSetting("customEndpoint") ?? "").trim();
  const savedModel = await getSetting(`imageGenerationModel_${providerId}`);
  const model = String(overrides.model ?? savedModel ?? IMAGE_PROVIDERS[providerId].defaultModel).trim();
  return { providerId, apiKey, customEndpoint, model };
}

function assertConfigured(config) {
  if (!config.apiKey) throw new Error(`${IMAGE_PROVIDERS[config.providerId].label} 尚未設定 API Key`);
  if (!config.model) throw new Error("尚未選擇生圖模型");
  if (config.providerId === "custom") validatedHttpsBase(config.customEndpoint);
}

function bytesFromBase64(encoded) {
  let binary;
  try { binary = atob(String(encoded || "")); } catch { throw new Error("圖片 Base64 格式不可解析"); }
  if (!binary || binary.length > MAX_IMAGE_BYTES) throw new Error("圖片為空或超過 12 MB");
  return binary.length;
}

function dataUrlFromBase64(encoded, mimeType = "image/png") {
  const mime = String(mimeType || "image/png").toLowerCase().split(";")[0];
  if (!["image/png", "image/jpeg", "image/webp"].includes(mime)) {
    throw new Error("只支援 PNG、JPEG 或 WebP 圖片");
  }
  bytesFromBase64(encoded);
  return `data:${mime};base64,${encoded}`;
}

function isSafeImageUrl(raw) {
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || url.username || url.password) return false;
    const host = url.hostname.toLowerCase();
    return host !== "localhost" && host !== "127.0.0.1" && host !== "::1" && !/^10\./.test(host) && !/^192\.168\./.test(host);
  } catch { return false; }
}

async function persistRemoteImage(rawUrl, signal) {
  if (!isSafeImageUrl(rawUrl)) throw new Error("圖片下載網址不安全或格式無效");
  let response;
  try {
    response = await fetch(rawUrl, { signal });
  } catch (error) {
    if (error?.name === "AbortError") throw error;
    // 部分圖片 CDN 允許 <img> 顯示但不允許瀏覽器 JS 讀取；保留安全 HTTPS URL 作即時降級。
    return rawUrl;
  }
  if (!response.ok) throw apiHttpError("圖片下載失敗", response.status, await response.text().catch(() => ""));
  const blob = await response.blob();
  if (!blob.size || blob.size > MAX_IMAGE_BYTES) throw new Error("圖片為空或超過 12 MB");
  if (!["image/png", "image/jpeg", "image/webp"].includes(blob.type)) throw new Error("圖片格式不是 PNG、JPEG 或 WebP");
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error("無法保存生成圖片"));
    reader.readAsDataURL(blob);
  });
}

async function decodeImageResponse(response, providerId, signal) {
  if (!response.ok) throw apiHttpError(`${IMAGE_PROVIDERS[providerId].label} 生圖失敗`, response.status, await response.text().catch(() => ""));
  const data = await response.json();
  if (providerId === "gemini") {
    for (const part of data?.candidates?.[0]?.content?.parts || []) {
      const inline = part?.inlineData || part?.inline_data;
      if (inline?.data) return dataUrlFromBase64(inline.data, inline.mimeType || inline.mime_type);
    }
    throw new Error("Gemini 模型未返回圖片");
  }
  const first = data?.data?.[0];
  if (first?.b64_json) return dataUrlFromBase64(first.b64_json, first.media_type || first.mime_type);
  if (first?.url) return persistRemoteImage(first.url, signal);
  throw new Error(`${IMAGE_PROVIDERS[providerId].label} 模型未返回可解析圖片`);
}

async function generateImage(prompt, options = {}) {
  const cleanPrompt = String(prompt || "").trim();
  if (!cleanPrompt) throw new Error("空白生圖描述");
  const config = await getImageGenerationConfig(options);
  assertConfigured(config);
  const signal = options.signal;
  let endpoint;
  let headers;
  let body;
  if (config.providerId === "gemini") {
    endpoint = `https://generativelanguage.googleapis.com/v1/models/${encodeURIComponent(config.model.replace(/^models\//, ""))}:generateContent`;
    headers = { "Content-Type": "application/json", "x-goog-api-key": config.apiKey };
    body = { contents: [{ parts: [{ text: cleanPrompt }] }], generationConfig: { responseModalities: ["IMAGE"] } };
  } else {
    endpoint = config.providerId === "openrouter"
      ? "https://openrouter.ai/api/v1/images"
      : config.providerId === "grok"
        ? "https://api.x.ai/v1/images/generations"
        : imageEndpointForBase(config.customEndpoint);
    headers = { "Content-Type": "application/json", Authorization: `Bearer ${config.apiKey}` };
    body = { model: config.model, prompt: cleanPrompt, n: 1, ...(["grok", "custom"].includes(config.providerId) ? { response_format: "b64_json" } : {}) };
  }
  const response = await fetch(endpoint, { method: "POST", headers, body: JSON.stringify(body), signal: imageRequestSignal(signal) });
  return decodeImageResponse(response, config.providerId, signal);
}

async function fetchImageModels(overrides = {}) {
  const config = await getImageGenerationConfig(overrides);
  assertConfigured({ ...config, model: config.model || "pending" });
  if (config.providerId === "openrouter") {
    const response = await fetch("https://openrouter.ai/api/v1/images/models", { headers: { Authorization: `Bearer ${config.apiKey}` }, signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw apiHttpError("無法取得 OpenRouter 生圖模型", response.status, await response.text().catch(() => ""));
    return (await response.json()).data?.map((item) => ({ id: item.id, name: item.name || item.id })).filter((item) => item.id && rasterImageModel(item)) || [];
  }
  if (config.providerId === "grok") {
    const response = await fetch("https://api.x.ai/v1/image-generation-models", { headers: { Authorization: `Bearer ${config.apiKey}` }, signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw apiHttpError("無法取得 xAI 生圖模型", response.status, await response.text().catch(() => ""));
    return (await response.json()).models?.map((item) => ({ id: item.id, name: item.name || item.id })).filter((item) => item.id) || [];
  }
  const models = await fetchModels({ providerId: config.providerId, apiKey: config.apiKey, customEndpoint: config.customEndpoint });
  return models.filter((model) => IMAGE_MODEL_HINT.test(model.id));
}

function parseDrawIntent(text) {
  const source = String(text || "");
  const match = source.match(/<draw>([\s\S]{1,4000}?)<\/draw>/i);
  const openIndex = source.search(/<draw>/i);
  return {
    prompt: match?.[1]?.trim() || "",
    visibleText: match
      ? source.replace(/<draw>[\s\S]*?<\/draw>/gi, "").trim()
      : (openIndex >= 0 ? source.slice(0, openIndex).trim() : source),
  };
}

function imageGenerationAbilityPrompt() {
  return "■ 畫畫\n  <draw>英文圖像描述，寫清主體、風格、光線、構圖</draw>\n  僅在對方要求時使用。對方給出完整描述時，完全使用對方的 prompt。\n  一次至多一張。";
}

export {
  IMAGE_PROVIDERS,
  getImageGenerationConfig,
  rasterImageModel,
  fetchImageModels,
  generateImage,
  parseDrawIntent,
  imageGenerationAbilityPrompt,
};
