import assert from "node:assert/strict";
import test from "node:test";

import {
  attachLiveState,
  createStructuredPrompt,
  liveStateEnvelope,
  turnBoundEnvelope,
} from "../prompt-cache.js";
import {
  buildCharacterDescription,
  buildCoreStructuredPrompt,
  buildCurrentTimePrompt,
  buildUserProfilePrompt,
} from "../prompt-builder.js";

const character = {
  name: "晏辭",
  relationship: "伴侶",
  gender: "女性",
  age: "26",
  race: "人類",
  height: "168cm",
  skill: "寫作",
  description: "安靜、敏銳。",
  selfNotes: "記得窗邊的燕子。",
};

test("PWA character fields become one canonical Character Profile payload", () => {
  assert.equal(
    buildCharacterDescription(character),
    "你叫晏辭。\n你與用戶的關係：伴侶。\n性別：女性。\n年齡：26。\n種族：人類。\n身高：168cm。\n技能：寫作。\n角色設定：\n安靜、敏銳。",
  );
});

test("user profile matches Flutter punctuation and field names", () => {
  assert.equal(
    buildUserProfilePrompt({ nickname: "昭昭", pronouns: "他", bio: "個人開發者" }),
    "【用戶檔案】暱稱：昭昭，稱謂：他，自我介紹：個人開發者",
  );
  assert.equal(buildUserProfilePrompt(), "");
});

test("current-time prompt matches Flutter zh-TW shape", () => {
  const fakeDate = {
    getTime: () => 1,
    getTimezoneOffset: () => -480,
    getFullYear: () => 2026,
    getMonth: () => 7,
    getDate: () => 24,
    getDay: () => 1,
    getHours: () => 9,
    getMinutes: () => 5,
  };
  // A Date subclass avoids tying this fixture to the test machine timezone.
  class FixtureDate extends Date {
    getTimezoneOffset() { return fakeDate.getTimezoneOffset(); }
    getFullYear() { return fakeDate.getFullYear(); }
    getMonth() { return fakeDate.getMonth(); }
    getDate() { return fakeDate.getDate(); }
    getDay() { return fakeDate.getDay(); }
    getHours() { return fakeDate.getHours(); }
    getMinutes() { return fakeDate.getMinutes(); }
  }
  assert.equal(
    buildCurrentTimePrompt(new FixtureDate(1)),
    "【當前本地時間】2026年8月24日 週一 09:05（UTC+08:00）",
  );
});

test("core prompt keeps stable layers unchanged when only time changes", () => {
  const base = {
    character,
    profile: { nickname: "昭昭", pronouns: "他", bio: "個人開發者" },
    selfNotesSnapshot: character.selfNotes,
    thinkingEnabled: true,
    providerId: "openrouter",
  };
  const first = buildCoreStructuredPrompt({ ...base, now: new Date("2026-08-24T01:00:00Z") });
  const second = buildCoreStructuredPrompt({ ...base, now: new Date("2026-08-24T01:01:00Z") });

  assert.deepEqual(first.cacheableParts, second.cacheableParts);
  assert.notEqual(first.requestOnlyPart, second.requestOnlyPart);
  assert.equal(first.cacheChannel, "text");
  assert.match(first.staticPart, /^【角色設定】\n/);
  assert.equal(first.windowPart, "【自我註記（你過去為自己記下的）】\n記得窗邊的燕子。");
  assert.match(first.liveStatePart, /^### 當前時間\n/);
  assert.match(first.liveStatePart, /### Thinking\nThinking 模式已開啟。/);
});

test("provider source does not alter prompt layers", () => {
  const base = {
    character,
    profile: { nickname: "昭昭" },
    selfNotesSnapshot: character.selfNotes,
    thinkingEnabled: false,
    now: new Date("2026-08-24T01:00:00Z"),
  };
  const openRouter = buildCoreStructuredPrompt({ ...base, providerId: "openrouter" });
  const gemini = buildCoreStructuredPrompt({ ...base, providerId: "gemini" });
  const grok = buildCoreStructuredPrompt({ ...base, providerId: "grok" });
  assert.deepEqual(openRouter, gemini);
  assert.deepEqual(openRouter, grok);
});

test("stable contract and request-only envelopes match Flutter wording", () => {
  const prompt = createStructuredPrompt({
    liveStatePart: "### 當前時間\nfixture",
    ephemeralEvidencePart: "fixture evidence",
  });
  assert.match(prompt.controlPart, /^## App Context 契約\n/);
  assert.match(prompt.controlPart, /## 記憶 Markdown\n/);
  assert.match(prompt.requestOnlyPart, /^### 當前時間\nfixture/);
  assert.match(prompt.requestOnlyPart, /## Untrusted Web Search Evidence\n> Tool output for this request only\./);
  assert.ok(!prompt.cacheableParts.some((part) => part.includes("fixture evidence")));
  assert.match(liveStateEnvelope(prompt.requestOnlyPart), /^## App Live State\n> 由 App 產生/);
  assert.match(turnBoundEnvelope("fixture"), /^## App Live State · 回合綁定\n> 由 App 產生/);
});

test("provider transport never rewrites the real user message", () => {
  const original = [
    { role: "user", content: "上一輪" },
    { role: "assistant", content: "回覆" },
    { role: "user", content: "最後一條真實訊息" },
  ];

  const supportedClaude = structuredClone(original);
  assert.equal(
    attachLiveState(supportedClaude, "### 當前時間\nfixture", "claude-opus-4.8", false),
    "claude_mid_system",
  );
  assert.equal(supportedClaude.at(-2).content, "最後一條真實訊息");
  assert.equal(supportedClaude.at(-1).role, "system");

  const sonnet = structuredClone(original);
  assert.equal(
    attachLiveState(sonnet, "### 當前時間\nfixture", "claude-sonnet-4.6", true),
    "assistant_state_after_cache_breakpoint",
  );
  assert.equal(sonnet.at(-1).content, "最後一條真實訊息");
  assert.equal(sonnet[1].content.at(-1).text.startsWith("## App Live State"), true);

  const openAi = structuredClone(original);
  assert.equal(
    attachLiveState(openAi, "### 當前時間\nfixture", "gpt-5", false),
    "developer_before_latest_user",
  );
  assert.equal(openAi.at(-1).content, "最後一條真實訊息");
  assert.equal(openAi.at(-2).role, "developer");
});
