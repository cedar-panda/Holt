import assert from "node:assert/strict";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const read = (name) => readFileSync(join(root, name), "utf8");

test("v90 static resource versions and app shell stay atomic", () => {
  const index = read("index.html");
  const worker = read("service-worker.js");
  assert.match(index, /styles\.css\?v=90/);
  assert.match(index, /app\.js\?v=90/);
  assert.match(worker, /holt-pwa-shell-v90/);
  assert.match(worker, /styles\.css\?v=90/);
  assert.match(worker, /app\.js\?v=90/);
  assert.match(worker, /\.\/companion-features\.js/);
  for (const asset of ["privacy.html", "shell-ready.js?v=1", "assets/images/app_icon.png", "assets/images/send_leaf_optimized.png"]) {
    assert.ok(worker.includes(`"./${asset}"`), `${asset} must be pre-cached`);
    assert.ok(existsSync(join(root, asset.split("?")[0])), `${asset} must exist`);
  }
  const shellAssets = [...worker.matchAll(/"\.\/([^"?]+)(?:\?[^"?]+)?"/g)].map((match) => match[1]);
  for (const asset of shellAssets) assert.ok(existsSync(join(root, asset)), `${asset} must exist`);
});

test("primary chat entry, connection test, retry and direct image UI stay enabled", () => {
  const index = read("index.html");
  const home = read("ui-home.js");
  const settings = read("ui-settings.js");
  const styles = read("styles.css");
  assert.match(index, /data-action="draw"/);
  assert.match(index, /data-action="sticker"/);
  assert.match(index, /data-action="transfer"/);
  assert.match(index, /data-action="scratch"/);
  assert.match(index, /data-action="audio"/);
  assert.match(settings, /testProviderConnection/);
  assert.match(home, /message-retry-btn/);
  assert.doesNotMatch(styles, /\.home-ecg-dock\s*\{[^}]*display:\s*none/s);
});

test("HTML entry points contain no inline executable script or event handler", () => {
  for (const name of ["index.html", "home.html", "settings.html", "privacy.html"]) {
    const html = read(name);
    assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/i, `${name} has inline script`);
    assert.doesNotMatch(html, /\son[a-z]+\s*=/i, `${name} has inline event handler`);
  }
});

test("privacy copy distinguishes local storage from provider transport", () => {
  const index = read("index.html");
  const privacy = read("privacy.html");
  assert.doesNotMatch(index, /所有資料.*不會上傳|資料只存在你的裝置上/);
  assert.match(index, /請求.*API 來源/);
  assert.match(privacy, /聊天內容.*傳送/);
});

test("PWA JavaScript modules stay below the project file-size ceiling", () => {
  const files = readdirSync(root).filter((name) => name.endsWith(".js"));
  for (const name of files) {
    const lines = read(name).split("\n").length;
    assert.ok(lines <= 2650, `${name} has ${lines} lines`);
  }
});
