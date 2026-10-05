/**
 * Holt PWA — IndexedDB 存儲層
 * 對話、角色卡、設定與本機索引的 IndexedDB 存儲層。
 */

const DB_NAME = "holt_pwa";
const DB_VERSION = 5;

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

      // 跨窗口搜尋只讀取純文字投影，避免每次搜尋載入 Base64 圖片。
      if (!db.objectStoreNames.contains("message_search")) {
        const search = db.createObjectStore("message_search", { keyPath: "id" });
        search.createIndex("by_conv", "conversationId");
        if (db.objectStoreNames.contains("messages")) {
          const source = e.target.transaction.objectStore("messages");
          source.openCursor().onsuccess = (event) => {
            const cursor = event.target.result;
            if (!cursor) return;
            const message = cursor.value;
            search.put(searchProjection(message));
            cursor.continue();
          };
        }
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

      // PWA companion features: memories, summaries, emotion points,
      // bio-clock habits, notes, balances, saved text and audio resources.
      // A typed store keeps these features independently queryable without
      // multiplying stores for every optional module.
      if (!db.objectStoreNames.contains("feature_records")) {
        const features = db.createObjectStore("feature_records", { keyPath: "id" });
        features.createIndex("by_char", "characterId");
        features.createIndex("by_char_kind", ["characterId", "kind"]);
        features.createIndex("by_kind", "kind");
      }

      // 用量記錄
      if (!db.objectStoreNames.contains("usage_logs")) {
        const ul = db.createObjectStore("usage_logs", { keyPath: "id", autoIncrement: true });
        ul.createIndex("by_timestamp", "timestamp");
      }
    };
    req.onsuccess = (e) => {
      _db = e.target.result;
      _db.onversionchange = () => {
        _db?.close();
        _db = null;
        globalThis.dispatchEvent?.(new Event("holt:db-versionchange"));
      };
      resolve(_db);
    };
    req.onerror = (e) => reject(e.target.error);
    req.onblocked = () => reject(new Error("資料庫正在其他 Holt 視窗使用，請關閉舊視窗後重新載入"));
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
async function deleteCharacter(id) {
  const conversations = await _getAll("conversations", "by_char", id);
  const messages = (await Promise.all(conversations.map((conversation) =>
    _getAll("messages", "by_conv", conversation.id)
  ))).flat();
  const timeline = await _getAll("timeline", "by_char", id);
  const featureRecords = await _getAll("feature_records", "by_char", id);
  const stickers = (await _getAll("stickers")).filter((sticker) => sticker.characterId === id);
  const usageLogs = (await _getAll("usage_logs")).filter((entry) => entry.characterId === id);
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["characters", "conversations", "messages", "message_search", "stickers", "timeline", "feature_records", "usage_logs"], "readwrite");
    tx.objectStore("characters").delete(id);
    for (const conversation of conversations) tx.objectStore("conversations").delete(conversation.id);
    for (const message of messages) {
      tx.objectStore("messages").delete(message.id);
      tx.objectStore("message_search").delete(message.id);
    }
    for (const entry of timeline) tx.objectStore("timeline").delete(entry.id);
    for (const entry of featureRecords) tx.objectStore("feature_records").delete(entry.id);
    for (const sticker of stickers) tx.objectStore("stickers").delete(sticker.id);
    for (const entry of usageLogs) tx.objectStore("usage_logs").delete(entry.id);
    tx.oncomplete = () => resolve();
    tx.onerror = (event) => reject(event.target.error);
    tx.onabort = () => reject(tx.error || new Error("刪除角色失敗"));
  });
}
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
    const tx = db.transaction(["conversations", "messages", "message_search"], "readwrite");
    tx.objectStore("conversations").delete(id);
    const ms = tx.objectStore("messages");
    const search = tx.objectStore("message_search");
    for (const m of msgs) {
      ms.delete(m.id);
      search.delete(m.id);
    }
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
  const q = normalizeSearchText(query);
  if (!q) return all;
  const projections = await _getAll("message_search");
  return filterConversationsByMessages(all, projections, q);
}

function filterConversationsByMessages(conversations, messages, query) {
  const q = normalizeSearchText(query);
  if (!q) return [...conversations];
  const conversationIds = new Set(conversations.map((conversation) => conversation.id));
  const matchedConversationIds = new Set();
  for (const message of messages) {
    if (!conversationIds.has(message.conversationId)) continue;
    const searchable = message.searchText ?? messageSearchText(message);
    if (normalizeSearchText(searchable).includes(q)) {
      matchedConversationIds.add(message.conversationId);
    }
  }
  return conversations.filter((conversation) =>
    normalizeSearchText(conversation.title).includes(q) ||
    matchedConversationIds.has(conversation.id)
  );
}

function normalizeSearchText(value) {
  return String(value ?? "").trim().toLocaleLowerCase();
}

function messageSearchText(message) {
  const content = message?.content;
  if (typeof content === "string") return normalizeSearchText(content);
  if (!Array.isArray(content)) return "";
  return normalizeSearchText(content
    .filter((part) => part?.type === "text")
    .map((part) => part.text || "")
    .join(" "));
}

function searchProjection(message) {
  return {
    id: message.id,
    conversationId: message.conversationId,
    searchText: messageSearchText(message),
  };
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

async function saveMessage(message) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["messages", "message_search", "conversations"], "readwrite");
    tx.objectStore("messages").put(message);
    tx.objectStore("message_search").put(searchProjection(message));
    const conversations = tx.objectStore("conversations");
    const request = conversations.get(message.conversationId);
    request.onsuccess = () => {
      if (!request.result) return;
      conversations.put({ ...request.result, updatedAt: new Date().toISOString() });
    };
    tx.oncomplete = () => resolve(message);
    tx.onerror = (event) => reject(event.target.error);
    tx.onabort = () => reject(tx.error || new Error("儲存訊息失敗"));
  });
}

async function getMessagesByConversation(conversationId) {
  const all = await _getAll("messages", "by_conv", conversationId);
  return all.sort((a, b) => a.createdAt.localeCompare(b.createdAt));
}

async function deleteMessage(id) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["messages", "message_search"], "readwrite");
    tx.objectStore("messages").delete(id);
    tx.objectStore("message_search").delete(id);
    tx.oncomplete = () => resolve();
    tx.onerror = (event) => reject(event.target.error);
  });
}

// 更新消息內容（流式追加完成後寫回）
async function updateMessageContent(id, content) {
  const msg = await _get("messages", id);
  if (msg) { msg.content = content; await saveMessage(msg); }
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

const listTimelineEntriesForCharacter = (characterId) => _getAll("timeline", "by_char", characterId);
const listAllTimelineEntries = () => _getAll("timeline");

// ═══ 陪伴功能資料 ═══

function newFeatureRecord(characterId, kind, value = {}, overrides = {}) {
  const now = new Date().toISOString();
  return {
    id: crypto.randomUUID(),
    characterId: characterId || "default",
    kind,
    value,
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

const saveFeatureRecord = (record) => _put("feature_records", {
  ...record,
  updatedAt: new Date().toISOString(),
});
const getFeatureRecord = (id) => _get("feature_records", id);
const deleteFeatureRecord = (id) => _del("feature_records", id);
async function listFeatureRecords(characterId, kind = "") {
  const rows = kind
    ? await _getAll("feature_records", "by_char_kind", IDBKeyRange.only([characterId || "default", kind]))
    : await _getAll("feature_records", "by_char", characterId || "default");
  return rows.sort((a, b) => String(b.createdAt || "").localeCompare(String(a.createdAt || "")));
}
const listAllFeatureRecords = () => _getAll("feature_records");

async function applyBalanceDeltas(deltas, { defaultBalance = 800 } = {}) {
  const entries = Object.entries(deltas || {})
    .map(([accountId, delta]) => [String(accountId), Number(delta)])
    .filter(([accountId, delta]) => accountId && Number.isInteger(delta) && delta !== 0);
  if (!entries.length) return {};
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("feature_records", "readwrite");
    const store = tx.objectStore("feature_records");
    const next = {};
    let pending = entries.length;
    let rejected = false;
    for (const [accountId, delta] of entries) {
      const id = `balance:${accountId}`;
      const request = store.get(id);
      request.onerror = () => { rejected = true; tx.abort(); };
      request.onsuccess = () => {
        if (rejected) return;
        const current = Number(request.result?.value?.coins ?? defaultBalance);
        const balance = current + delta;
        if (!Number.isSafeInteger(balance) || balance < 0) {
          rejected = true;
          tx.abort();
          return;
        }
        next[accountId] = balance;
        store.put({
          id,
          characterId: accountId === "_user" ? "default" : accountId,
          kind: "balance",
          value: { coins: balance },
          createdAt: request.result?.createdAt || new Date().toISOString(),
          updatedAt: new Date().toISOString(),
        });
        pending -= 1;
      };
    }
    tx.oncomplete = () => resolve(next);
    tx.onerror = () => reject(tx.error || new Error("貝殼餘額更新失敗"));
    tx.onabort = () => reject(rejected ? new Error("貝殼餘額不足") : tx.error || new Error("貝殼餘額更新失敗"));
  });
}

async function getBalance(accountId, defaultBalance = 800) {
  const row = await getFeatureRecord(`balance:${accountId}`);
  const value = Number(row?.value?.coins ?? defaultBalance);
  return Number.isSafeInteger(value) && value >= 0 ? value : defaultBalance;
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

const listAllUsageLogs = () => _getAll("usage_logs");

// ═══ 備份還原與清除 ═══

const RESTORABLE_STORES = ["characters", "conversations", "messages", "message_search", "stickers", "timeline", "feature_records", "usage_logs"];

async function replacePwaData({ characters = [], conversations = [], messages = [], stickers = [], timeline = [], featureRecords = [], usageLogs = [], settings = {}, settingKeys = [] }) {
  const db = await openDB();
  return new Promise((resolve, reject) => {
    const tx = db.transaction([...RESTORABLE_STORES, "settings"], "readwrite");
    for (const storeName of RESTORABLE_STORES) tx.objectStore(storeName).clear();
    for (const row of characters) tx.objectStore("characters").put(row);
    for (const row of conversations) tx.objectStore("conversations").put(row);
    for (const row of messages) {
      tx.objectStore("messages").put(row);
      tx.objectStore("message_search").put(searchProjection(row));
    }
    for (const row of stickers) tx.objectStore("stickers").put(row);
    for (const row of timeline) tx.objectStore("timeline").put(row);
    for (const row of featureRecords) tx.objectStore("feature_records").put(row);
    for (const row of usageLogs) {
      const normalized = { ...row };
      if (normalized.id == null) delete normalized.id;
      tx.objectStore("usage_logs").put(normalized);
    }
    const settingStore = tx.objectStore("settings");
    for (const key of settingKeys) settingStore.delete(key);
    for (const [key, value] of Object.entries(settings)) settingStore.put({ key, value });
    tx.oncomplete = () => resolve();
    tx.onerror = (event) => reject(event.target.error);
    tx.onabort = () => reject(tx.error || new Error("匯入交易失敗"));
  });
}

async function clearAllPwaData() {
  const db = await openDB();
  const stores = Array.from(db.objectStoreNames);
  return new Promise((resolve, reject) => {
    const tx = db.transaction(stores, "readwrite");
    for (const storeName of stores) tx.objectStore(storeName).clear();
    tx.oncomplete = () => resolve();
    tx.onerror = (event) => reject(event.target.error);
    tx.onabort = () => reject(tx.error || new Error("清除本機資料失敗"));
  });
}

// ═══ 星標模型與思考鏈 ═══

async function getStarredModels() {
  const models = await getSetting("starredModels");
  return Array.isArray(models) ? models : [];
}

async function saveStarredModels(models) {
  const unique = [];
  const seen = new Set();
  for (const rawModel of Array.isArray(models) ? models : []) {
    const model = String(rawModel || "").trim();
    if (!model || seen.has(model)) continue;
    seen.add(model);
    unique.push(model);
  }
  await setSetting("starredModels", unique);
  return unique;
}

async function removeStarredModel(modelId) {
  const target = String(modelId || "").trim();
  const current = await getStarredModels();
  const next = current.filter((model) => model !== target);
  const providers = await getStarredModelProviders();
  delete providers[target];
  await saveStarredModels(next);
  await setSetting("starredModelProviders", providers);
  return next;
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
  normalizeSearchText, messageSearchText, filterConversationsByMessages,
  newMessage, saveMessage, getMessagesByConversation, deleteMessage, updateMessageContent,
  getStarredModels, saveStarredModels, removeStarredModel, toggleStarModel, isModelStarred, getStarredModelProviders,
  getThinkingChainEnabled, setThinkingChainEnabled,
  saveSticker, deleteSticker, listStickers,
  newTimelineEntry, saveTimelineEntry, deleteTimelineEntry, listTimelineEntries, listTimelineEntriesForCharacter, listAllTimelineEntries,
  newFeatureRecord, saveFeatureRecord, getFeatureRecord, deleteFeatureRecord, listFeatureRecords, listAllFeatureRecords,
  getBalance, applyBalanceDeltas,
  logUsage, getUsageSummary, getDailyUsage, getUsageByModel, listAllUsageLogs, estimateCost,
  replacePwaData, clearAllPwaData,
};
