import test from "node:test";
import assert from "node:assert/strict";

import { apiHttpError } from "../api.js";
import { filterConversationsByMessages, messageSearchText } from "../db.js";
import { IMAGE_PROVIDERS, imageGenerationAbilityPrompt, parseDrawIntent, rasterImageModel } from "../image-generation.js";
import { WEB_SEARCH_MODES, explicitWebSearchQuery, parseXaiSearch } from "../web-search.js";
import {
  buildCompanionAbilityPrompt,
  buildReplyStylePrompt,
  localWindowSummary,
  splitReplySegments,
  stripCompanionTags,
} from "../companion-features.js";

test("cross-window search matches text inside an older conversation", () => {
  const conversations = [{ id: "new", title: "今天" }, { id: "old", title: "兩年前" }];
  const messages = [{ conversationId: "old", content: "埋在早期窗口的月桂關鍵詞" }];
  assert.deepEqual(filterConversationsByMessages(conversations, messages, "月桂").map((item) => item.id), ["old"]);
  assert.equal(messageSearchText({ content: [{ type: "text", text: "Vision 文字" }, { type: "image_url" }] }), "vision 文字");
});

test("web search only starts for an explicit visible request", () => {
  assert.equal(explicitWebSearchQuery("幫我上網查一下今天的新聞"), "幫我上網查一下今天的新聞");
  assert.equal(explicitWebSearchQuery("我們聊聊昨天的事"), "");
});

test("draw protocol hides complete and streaming control tags", () => {
  assert.deepEqual(parseDrawIntent("前文 <draw>cinematic portrait</draw> 後文"), { prompt: "cinematic portrait", visibleText: "前文  後文" });
  assert.equal(parseDrawIntent("正在準備 <draw>cinematic").visibleText, "正在準備");
  assert.match(imageGenerationAbilityPrompt(), /一次至多一張/);
});

test("PWA feature sources stay limited to its four configured providers", () => {
  assert.deepEqual(Object.keys(IMAGE_PROVIDERS), ["openrouter", "gemini", "grok", "custom"]);
  assert.deepEqual(Object.keys(WEB_SEARCH_MODES), ["auto", "openrouter", "gemini", "grok", "custom"]);
});

test("xAI citations include the documented top-level citation list", () => {
  const parsed = parseXaiSearch({ output_text: "答案", citations: ["https://example.com/source"] });
  assert.equal(parsed.answer, "答案");
  assert.deepEqual(parsed.sources, [{ url: "https://example.com/source", title: "example.com" }]);
});

test("image catalog rejects vector-only models that the PWA cannot persist safely", () => {
  assert.equal(rasterImageModel({ id: "recraft/vector-svg" }), false);
  assert.equal(rasterImageModel({ id: "x-ai/grok-imagine-image-2.0" }), true);
});

test("HTTP 403 exposes a safe upstream reason and relay guidance", () => {
  const error = apiHttpError("中轉站請求失敗", 403, '{"error":{"message":"<b>model not allowed</b>"}}');
  assert.match(error.message, /model not allowed/);
  assert.match(error.message, /模型白名單/);
  assert.doesNotMatch(error.message, /[<>]/);
});

test("companion tags stay hidden while visible reply text remains", () => {
  const raw = '在這裡。<memo>[重要事件] 小禾回來了 @回來</memo><emo>安全感|70,20|55|重逢</emo><transfer amount="30"/>[sticker:wave]';
  assert.equal(stripCompanionTags(raw), "在這裡。");
});

test("reply splitting creates at most four durable bubble segments", () => {
  assert.deepEqual(splitReplySegments("第一段。\n\n第二段。\n\n第三段。\n\n第四段。\n\n第五段。", true), ["第一段。", "第二段。", "第三段。", "第四段。 第五段。"]);
  assert.deepEqual(splitReplySegments("不拆", false), ["不拆"]);
});

test("local window summary excludes media and keeps speaker identity", () => {
  const messages = [
    { role: "user", content: [{ type: "text", text: "很早以前的內容" }, { type: "image_url", image_url: { url: "data:image/png;base64,AAA" } }] },
    { role: "assistant", content: "我記得。<home>晚點見</home>" },
  ];
  const summary = localWindowSummary(messages, 2);
  assert.match(summary, /用戶：很早以前的內容/);
  assert.match(summary, /角色：我記得/);
  assert.doesNotMatch(summary, /base64|<home>/);
});

test("companion prompt only advertises executors enabled in PWA", () => {
  const settings = { memory: true, emotion: true, bioClock: true, timeline: true, homeNote: true, whisper: true, scratch: true, transfer: true, stickers: true };
  const prompt = buildCompanionAbilityPrompt({ settings, userName: "小禾", characterName: "林澈", stickerIds: ["wave"] });
  assert.match(prompt, /<memo>/);
  assert.match(prompt, /<scratch who="char"\/>/);
  assert.match(prompt, /\[sticker:ID\]/);
  assert.doesNotMatch(prompt, /shop_view|<call>/);
  assert.match(buildReplyStylePrompt({ splitReply: true, conciseReply: false, maxReplyLines: 6 }), /2～4 段/);
});
