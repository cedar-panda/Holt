/**
 * Holt PWA — IndexedDB 存儲層
 * 對話、角色卡、設定、表情包，全部本地不上傳。
 */

const DB_NAME = "holt_pwa";
const DB_VERSION = 3;

let _db = null;

function openDB() {
  if (_db) return Promise.resolve(_db);
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = (e) => {
      const db = e.target.result;

      // 角色卡
      if (!db.objectStoreNames.contains("characters")) {
        const cs = db.createObjectStore("characters", { keyPath: "id" });
        cs.createIndex("by_updated", "updatedAt");
      }

      // 對話
      if (!db.objectStoreNames.contains("conversations")) {
        const cv = db.createObjectStore("conversations", { keyPath: "id" });
        cv.createIndex("by_char", "characterId");
        cv.createIndex("by_updated", "updatedAt");
      }

      // 消息
      if (!db.objectStoreNames.contains("messages")) {
        const ms = db.createObjectStore("messages", { keyPath: "id" });
        ms.createIndex("by_conv", "conversationId");
        ms.createIndex("by_conv_time", ["conversationId", "createdAt"]);
      }

      // 設定（key-value）
      if (!db.objectStoreNames.contains("settings")) {
        db.createObjectStore("settings", { keyPath: "key" });
      }

      // 表情包
      if (!db.objectStoreNames.contains("stickers")) {
        const st = db.createObjectStore("stickers", { keyPath: "id" });
        st.createIndex("by_pack", "packId");
      }

      // 時間線（狀態 + 事件）
      if (!db.objectStoreNames.contains("timeline")) {
        const tl = db.createObjectStore("timeline", { keyPath: "id" });
        tl.createIndex("by_char", "characterId");
        tl.createIndex("by_char_date", ["characterId", "date"]);
      }

      // 用量記錄
      if (!db.objectStoreNames.contains("usage_logs")) {
        const ul = db.createObjectStore("usage_logs", { keyPath: "id", autoIncrement: true });
        ul.createIndex("by_timestamp", "timestamp");
      }
    };
    req.onsuccess = (e) => { _db = e.target.result; resolve(_db); };
    req.onerror = (e) => reject(e.target.error);
  });
}

// ═══ 通用 CRUD ═══

async function _put(store, data) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, "readwrite");
    tx.objectStore(store).put(data);
    tx.oncomplete = () => resolve(data);
    tx.onerror = (e) => reject(e.target.error);
  });
}

async function _get(store, key) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, "readonly");
    const req = tx.objectStore(store).get(key);
    req.onsuccess = () => resolve(req.result ?? null);
    req.onerror = (e) => reject(e.target.error);
  });
}

async function _getAll(store, indexName, query) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, "readonly");
    const src = indexName ? tx.objectStore(store).index(indexName) : tx.objectStore(store);
    const req = query !== undefined ? src.getAll(query) : src.getAll();
    req.onsuccess = () => resolve(req.result);
    req.onerror = (e) => reject(e.target.error);
  });
}

async function _del(store, key) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, "readwrite");
    tx.objectStore(store).delete(key);
    tx.oncomplete = () => resolve();
    tx.onerror = (e) => reject(e.target.error);
  });
}

// ═══ 設定 ═══

async function getSetting(key) {
  const row = await _get("settings", key);
  return row ? row.value : null;
}

async function setSetting(key, value) {
  return _put("settings", { key, value });
}

// ═══ 角色卡 ═══

function newCharacter(overrides = {}) {
  const now = new Date().toISOString();
  return {
    id: crypto.randomUUID(),
    name: "",
    gender: "",
    relationship: "",
    description: "",
    race: "",
    skill: "",
    age: "",
    height: "",
    avatarDataUrl: "",       // PWA 用 base64 data URL 而非文件路徑
    selfNotes: "",
    ttsVoiceId: "",
    drawAnchorUser: "",
    drawAnchorChar: "",
    drawStyle: "",
    bioClockJson: "",
    whisperUserText: "",
    whisperModelText: "",
    whisperSource: "default",
    whisperModelOverride: true,
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

const saveCharacter = (c) => _put("characters", { ...c, updatedAt: new Date().toISOString() });
const getCharacter = (id) => _get("characters", id);
const deleteCharacter = (id) => _del("characters", id);
async function listCharacters() {
  const all = await _getAll("characters");
  return all.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
}

// ═══ 對話 ═══

function newConversation(characterId, title = "", overrides = {}) {
  const now = new Date().toISOString();
  return {
    id: crypto.randomUUID(),
    characterId,
    title: title || "新對話",
    isStarred: false,
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

const saveConversation = (c) => _put("conversations", { ...c, updatedAt: new Date().toISOString() });
const getConversation = (id) => _get("conversations", id);
const deleteConversation = async (id) => {
  // 刪對話時連消息一起清
  const msgs = await getMessagesByConversation(id);
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["conversations", "messages"], "readwrite");
    tx.objectStore("conversations").delete(id);
    const ms = tx.objectStore("messages");
    for (const m of msgs) ms.delete(m.id);
    tx.oncomplete = () => resolve();
    tx.onerror = (e) => reject(e.target.error);
  });
};

async function toggleStarConversation(id, isStarred) {
  const conv = await getConversation(id);
  if (!conv) return null;
  conv.isStarred = isStarred !== undefined ? Boolean(isStarred) : !conv.isStarred;
  await saveConversation(conv);
  return conv;
}

async function updateConversationTitle(id, title) {
  const conv = await getConversation(id);
  if (!conv) return null;
  conv.title = title;
  await saveConversation(conv);
  return conv;
}

async function listConversations(characterId) {
  const all = characterId
    ? await _getAll("conversations", "by_char", characterId)
    : await _getAll("conversations");
  return all.sort((a, b) => {
    if (Boolean(b.isStarred) !== Boolean(a.isStarred)) {
      return b.isStarred ? 1 : -1;
    }
    return (b.updatedAt || "").localeCompare(a.updatedAt || "");
  });
}

async function searchConversations(query, characterId) {
  const all = await listConversations(characterId);
  const q = (query || "").trim().toLowerCase();
  if (!q) return all;
  return all.filter((c) => (c.title || "").toLowerCase().includes(q));
}

// ═══ 消息 ═══

function newMessage(conversationId, role, content, extra = {}) {
  return {
    id: crypto.randomUUID(),
    conversationId,
    role,          // "user" | "assistant" | "system"
    content,       // string 或 array (vision 多部件)
    createdAt: new Date().toISOString(),
    ...extra,
  };
}

const saveMessage = (m) => _put("messages", m);

async function getMessagesByConversation(conversationId) {
  const all = await _getAll("messages", "by_conv", conversationId);
  return all.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
}

async function deleteMessage(id) { return _del("messages", id); }

// 更新消息內容（流式追加完成後寫回）
async function updateMessageContent(id, content) {
  const msg = await _get("messages", id);
  if (msg) { msg.content = content; await _put("messages", msg); }
}

// ═══ 表情包 ═══

const saveSticker = (s) => _put("stickers", s);
const deleteSticker = (id) => _del("stickers", id);
async function listStickers(packId) {
  return packId
    ? _getAll("stickers", "by_pack", packId)
    : _getAll("stickers");
}

// ═══ 時間線 ═══

function newTimelineEntry(characterId, type, value, key = "") {
  return {
    id: crypto.randomUUID(),
    characterId,
    type,       // "state" | "event"
    key,        // 狀態名（僅 type=state）
    value,
    date: new Date().toISOString(),
  };
}

const saveTimelineEntry = (e) => _put("timeline", e);
const deleteTimelineEntry = (id) => _del("timeline", id);

async function listTimelineEntries(characterId, year, month) {
  const all = await _getAll("timeline", "by_char", characterId);
  const filtered = all.filter((e) => {
    const d = new Date(e.date);
    return d.getFullYear() === year && d.getMonth() + 1 === month;
  });
  return filtered.sort((a, b) => a.date.localeCompare(b.date));
}

// ═══ 用量記錄 ═══

const MODEL_PRICES = {
  opus:    { input: 15.0,  output: 75.0 },
  sonnet:  { input: 3.0,   output: 15.0 },
  haiku:   { input: 0.25,  output: 1.25 },
  "gpt-4o":{ input: 2.5,   output: 10.0 },
  "gpt-4": { input: 30.0,  output: 60.0 },
  "gemini-flash": { input: 0.075, output: 0.3 },
  "gemini-pro":   { input: 1.25,  output: 5.0 },
  deepseek: { input: 0.27,  output: 1.1 },
  qwen:     { input: 0.3,   output: 0.6 },
  "mistral-large": { input: 2.0, output: 6.0 },
};

function _getModelPrices(model) {
  const m = model.toLowerCase();
  for (const [key, prices] of Object.entries(MODEL_PRICES)) {
    if (m.includes(key)) return prices;
  }
  return { input: 1.0, output: 3.0 };
}

function estimateCost(model, prompt, completion, cacheHit = 0, cacheCreation = 0) {
  const p = _getModelPrices(model);
  let normalInput = prompt - cacheHit - cacheCreation;
  if (normalInput < 0) normalInput = 0;
  const inputCost = (normalInput * p.input + cacheHit * p.input * 0.1 + cacheCreation * p.input * 2.0) / 1_000_000;
  const outputCost = completion * p.output / 1_000_000;
  return inputCost + outputCost;
}

async function logUsage({ provider, model, characterId = "default", promptTokens = 0, completionTokens = 0, cacheHitTokens = 0, cacheCreationTokens = 0, actualCost = null }) {
  if (promptTokens === 0 && completionTokens === 0) return;
  const cost = actualCost ?? estimateCost(model, promptTokens, completionTokens, cacheHitTokens, cacheCreationTokens);
  const entry = {
    timestamp: new Date().toISOString(),
    provider, model, characterId,
    promptTokens, completionTokens,
    cacheHitTokens, cacheCreationTokens,
    estimatedCost: cost,
  };
  return _put("usage_logs", entry);
}

async function getUsageSummary(from, to) {
  const all = await _getUsageInRange(from, to);
  let totalPrompt = 0, totalCompletion = 0, totalCacheHit = 0, totalCost = 0;
  for (const r of all) {
    totalPrompt += r.promptTokens || 0;
    totalCompletion += r.completionTokens || 0;
    totalCacheHit += r.cacheHitTokens || 0;
    totalCost += r.estimatedCost || 0;
  }
  return { totalPrompt, totalCompletion, totalCacheHit, totalCost, totalRequests: all.length };
}

async function getDailyUsage(from, to) {
  const all = await _getUsageInRange(from, to);
  const byDate = {};
  for (const r of all) {
    const date = r.timestamp.substring(0, 10);
    if (!byDate[date]) byDate[date] = { date, prompt: 0, completion: 0, cacheHit: 0, cost: 0 };
    byDate[date].prompt += r.promptTokens || 0;
    byDate[date].completion += r.completionTokens || 0;
    byDate[date].cacheHit += r.cacheHitTokens || 0;
    byDate[date].cost += r.estimatedCost || 0;
  }
  return Object.values(byDate).sort((a, b) => a.date.localeCompare(b.date));
}

async function getUsageByModel(from, to) {
  const all = await _getUsageInRange(from, to);
  const byModel = {};
  for (const r of all) {
    const m = r.model || "?";
    if (!byModel[m]) byModel[m] = { model: m, totalTokens: 0, cost: 0, requests: 0 };
    byModel[m].totalTokens += (r.promptTokens || 0) + (r.completionTokens || 0);
    byModel[m].cost += r.estimatedCost || 0;
    byModel[m].requests += 1;
  }
  return Object.values(byModel).sort((a, b) => b.cost - a.cost);
}

async function _getUsageInRange(from, to) {
  const db = await openDB();
  const fromStr = from.toISOString();
  const toStr = to.toISOString();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("usage_logs", "readonly");
    const idx = tx.objectStore("usage_logs").index("by_timestamp");
    const range = IDBKeyRange.bound(fromStr, toStr, false, true);
    const req = idx.getAll(range);
    req.onsuccess = () => resolve(req.result);
    req.onerror = (e) => reject(e.target.error);
  });
}

// ═══ 星標模型與思考鏈 ═══

async function getStarredModels() {
  const models = await getSetting("starredModels");
  return Array.isArray(models) ? models : [];
}

async function saveStarredModels(models) {
  await setSetting("starredModels", Array.isArray(models) ? models : []);
}

async function getStarredModelProviders() {
  const map = await getSetting("starredModelProviders");
  return (map && typeof map === "object") ? map : {};
}

async function toggleStarModel(modelId, provider = "") {
  if (!modelId) return [];
  const current = await getStarredModels();
  const set = new Set(current);
  const providers = await getStarredModelProviders();
  if (set.has(modelId)) {
    set.delete(modelId);
    delete providers[modelId];
  } else {
    set.add(modelId);
    if (provider) providers[modelId] = provider;
  }
  const next = Array.from(set);
  await saveStarredModels(next);
  await setSetting("starredModelProviders", providers);
  return next;
}

async function isModelStarred(modelId) {
  if (!modelId) return false;
  const current = await getStarredModels();
  return current.includes(modelId);
}

async function getThinkingChainEnabled() {
  return (await getSetting("thinkingChain")) === true;
}

async function setThinkingChainEnabled(enabled) {
  await setSetting("thinkingChain", Boolean(enabled));
}

// ═══ Export ═══

export {
  openDB,
  getSetting, setSetting,
  newCharacter, saveCharacter, getCharacter, deleteCharacter, listCharacters,
  newConversation, saveConversation, getConversation, deleteConversation, listConversations, toggleStarConversation, updateConversationTitle, searchConversations,
  newMessage, saveMessage, getMessagesByConversation, deleteMessage, updateMessageContent,
  getStarredModels, saveStarredModels, toggleStarModel, isModelStarred, getStarredModelProviders,
  getThinkingChainEnabled, setThinkingChainEnabled,
  saveSticker, deleteSticker, listStickers,
  newTimelineEntry, saveTimelineEntry, deleteTimelineEntry, listTimelineEntries,
  logUsage, getUsageSummary, getDailyUsage, getUsageByModel, estimateCost,
};
