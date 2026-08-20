/*
 * Holt PWA portable backup bundle.
 *
 * The encrypted wrapper intentionally mirrors the native format in
 * lib/services/encrypted_backup_bundle.dart:
 *   HOLTBKP1 + JSON header + repeated AES-256-GCM records.
 * The payload is a normal ZIP (stored entries, no compression), so the
 * plaintext bundle remains inspectable by standard ZIP tools when a user
 * explicitly chooses to work with an old .holt.zip export.
 */

const MAGIC = new Uint8Array([0x48, 0x4f, 0x4c, 0x54, 0x42, 0x4b, 0x50, 0x31]);
const FORMAT_VERSION = 1;
const DEFAULT_ITERATIONS = 600000;
const CHUNK_SIZE = 1024 * 1024;
const MAC_LENGTH = 16;
const SALT_LENGTH = 16;
const NONCE_PREFIX_LENGTH = 8;
const MAX_ZIP_ENTRY_BYTES = 64 * 1024 * 1024;
const MAX_ZIP_TOTAL_BYTES = 256 * 1024 * 1024;
const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

function ensureCrypto() {
  if (!globalThis.crypto?.subtle || !globalThis.crypto.getRandomValues) {
    throw new Error("目前瀏覽器不支援本機加密，請用 Safari／Chrome 的 HTTPS 版本開啟 Holt。");
  }
}

function concatBytes(...parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const result = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

function uint32(value) {
  const result = new Uint8Array(4);
  new DataView(result.buffer).setUint32(0, value >>> 0, false);
  return result;
}

function readUint16(bytes, offset) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint16(offset, true);
}

function readUint32(bytes, offset) {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(offset, true);
}

function base64Encode(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

function base64Decode(value) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function crc32(bytes) {
  if (!crc32.table) {
    crc32.table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      crc32.table[n] = c >>> 0;
    }
  }
  let value = 0xffffffff;
  for (const byte of bytes) value = crc32.table[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function zipLocalHeader(name, checksum, size) {
  const header = new Uint8Array(30);
  const view = new DataView(header.buffer);
  view.setUint32(0, 0x04034b50, true);
  view.setUint16(4, 20, true);
  view.setUint16(6, 0x800, true); // UTF-8 names
  view.setUint16(8, 0, true); // store, not deflate
  view.setUint32(14, checksum, true);
  view.setUint32(18, size, true);
  view.setUint32(22, size, true);
  view.setUint16(26, name.length, true);
  view.setUint16(28, 0, true);
  return header;
}

function zipCentralHeader(name, checksum, size, localOffset) {
  const header = new Uint8Array(46);
  const view = new DataView(header.buffer);
  view.setUint32(0, 0x02014b50, true);
  view.setUint16(4, 20, true);
  view.setUint16(6, 20, true);
  view.setUint16(8, 0x800, true);
  view.setUint16(10, 0, true);
  view.setUint32(16, checksum, true);
  view.setUint32(20, size, true);
  view.setUint32(24, size, true);
  view.setUint16(28, name.length, true);
  view.setUint32(42, localOffset, true);
  return header;
}

function zipEndHeader(count, centralSize, centralOffset) {
  const header = new Uint8Array(22);
  const view = new DataView(header.buffer);
  view.setUint32(0, 0x06054b50, true);
  view.setUint16(8, count, true);
  view.setUint16(10, count, true);
  view.setUint32(12, centralSize, true);
  view.setUint32(16, centralOffset, true);
  return header;
}

/** Creates a standards-compliant ZIP using STORE entries. */
export function createZip(entries) {
  if (entries.length > 0xffff) throw new Error("備份檔案數量過多");
  const localParts = [];
  const centralParts = [];
  let offset = 0;
  for (const entry of entries) {
    const name = textEncoder.encode(entry.name);
    const data = entry.bytes instanceof Uint8Array ? entry.bytes : new Uint8Array(entry.bytes);
    if (!name.length || name.length > 0xffff || data.length > 0xffffffff) throw new Error("備份項目過大");
    const checksum = crc32(data);
    const local = concatBytes(zipLocalHeader(name, checksum, data.length), name, data);
    localParts.push(local);
    centralParts.push(zipCentralHeader(name, checksum, data.length, offset), name);
    offset += local.length;
  }
  const central = concatBytes(...centralParts);
  return concatBytes(...localParts, central, zipEndHeader(entries.length, central.length, offset));
}

function isSafeZipName(name) {
  if (!name || name.includes("\\") || name.startsWith("/") || name.includes("\0")) return false;
  // Older native ZIP writers include explicit directory entries such as
  // `media/`. They are safe to ignore; empty path components elsewhere are
  // still rejected to prevent traversal and ambiguous archive paths.
  const path = name.endsWith("/") ? name.slice(0, -1) : name;
  if (!path) return false;
  const parts = path.split("/");
  return !parts.some((part) => part === ".." || part === "" || part === ".");
}

async function inflateRaw(bytes) {
  if (!globalThis.DecompressionStream) throw new Error("此瀏覽器不支援舊 ZIP 的解壓縮");
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/**
 * Reads STORE and DEFLATE ZIPs, allowing native and older .holt.zip files.
 *
 * `wantedNames` may be a Set or a predicate. A predicate lets the importer
 * inspect only JSON metadata without inflating large media/database entries.
 */
export async function readZip(bytes, wantedNames = null) {
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const start = Math.max(0, data.length - 0xffff - 22);
  let eocd = -1;
  for (let i = data.length - 22; i >= start; i--) {
    if (readUint32(data, i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error("不是有效的 ZIP 備份");
  const count = readUint16(data, eocd + 10);
  const centralSize = readUint32(data, eocd + 12);
  const centralOffset = readUint32(data, eocd + 16);
  if (centralOffset + centralSize > data.length || count === 0xffff) throw new Error("不支援的 ZIP 格式");

  const entries = new Map();
  const seenNames = new Set();
  let totalBytes = 0;
  let cursor = centralOffset;
  for (let i = 0; i < count; i++) {
    const centralEntryStart = cursor;
    if (readUint32(data, cursor) !== 0x02014b50) throw new Error("ZIP 目錄損壞");
    const flags = readUint16(data, cursor + 8);
    const method = readUint16(data, cursor + 10);
    const compressedSize = readUint32(data, cursor + 20);
    const uncompressedSize = readUint32(data, cursor + 24);
    const nameLength = readUint16(data, cursor + 28);
    const extraLength = readUint16(data, cursor + 30);
    const commentLength = readUint16(data, cursor + 32);
    const localOffset = readUint32(data, cursor + 42);
    const rawName = data.subarray(cursor + 46, cursor + 46 + nameLength);
    const name = textDecoder.decode(rawName);
    cursor += 46 + nameLength + extraLength + commentLength;
    if (!isSafeZipName(name)) throw new Error(`ZIP 含有不安全路径：${name}`);
    if (seenNames.has(name)) throw new Error(`ZIP 含有重复项目：${name}`);
    if (flags & 1) throw new Error(`ZIP 项目使用不支持的传统 ZIP 加密：${name}`);
    seenNames.add(name);
    if (name.endsWith("/")) continue;
    if (localOffset + 30 > data.length || readUint32(data, localOffset) !== 0x04034b50) throw new Error("ZIP 項目損壞");
    const localNameLength = readUint16(data, localOffset + 26);
    const localExtraLength = readUint16(data, localOffset + 28);
    const contentStart = localOffset + 30 + localNameLength + localExtraLength;
    const contentEnd = contentStart + compressedSize;
    if (contentEnd > data.length) throw new Error("ZIP 項目不完整");
    const wanted = typeof wantedNames === "function"
      ? wantedNames(name)
      : !wantedNames || wantedNames.has(name);
    if (!wanted) continue;
    // Large database/media entries are intentionally skipped by metadata-only
    // imports. Apply the inflate limit only to entries we actually read.
    if (uncompressedSize > MAX_ZIP_ENTRY_BYTES) throw new Error("ZIP 項目超過安全大小上限");
    const compressed = data.subarray(contentStart, contentEnd);
    let content;
    if (method === 0) content = new Uint8Array(compressed);
    else if (method === 8) content = await inflateRaw(compressed);
    else throw new Error("ZIP 使用了不支援的壓縮方式");
    totalBytes += content.length;
    if (totalBytes > MAX_ZIP_TOTAL_BYTES || content.length !== uncompressedSize || crc32(content) !== readUint32(data, centralEntryStart + 16)) {
      throw new Error("ZIP 項目校驗失敗");
    }
    entries.set(name, content);
  }
  return entries;
}

async function deriveKey(password, salt, iterations) {
  const material = await globalThis.crypto.subtle.importKey("raw", textEncoder.encode(password), "PBKDF2", false, ["deriveKey"]);
  return globalThis.crypto.subtle.deriveKey(
    { name: "PBKDF2", salt, iterations, hash: "SHA-256" },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

async function aesGcm(key, nonce, data, aad, decrypt = false) {
  const params = { name: "AES-GCM", iv: nonce, additionalData: aad, tagLength: 128 };
  const result = decrypt
    ? await globalThis.crypto.subtle.decrypt(params, key, data)
    : await globalThis.crypto.subtle.encrypt(params, key, data);
  return new Uint8Array(result);
}

export function isEncryptedBackup(bytes) {
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  return data.length >= MAGIC.length && MAGIC.every((value, i) => data[i] === value);
}

/** Encrypts a ZIP using the same chunk record format as the native app. */
export async function encryptHoltBackup(zipBytes, password) {
  ensureCrypto();
  if (!password) throw new Error("備份密碼不可為空");
  const salt = globalThis.crypto.getRandomValues(new Uint8Array(SALT_LENGTH));
  const noncePrefix = globalThis.crypto.getRandomValues(new Uint8Array(NONCE_PREFIX_LENGTH));
  const header = textEncoder.encode(JSON.stringify({
    type: "holt_encrypted_backup",
    version: FORMAT_VERSION,
    kdf: "pbkdf2-hmac-sha256",
    iterations: DEFAULT_ITERATIONS,
    salt: base64Encode(salt),
    cipher: "aes-256-gcm",
    chunk_size: CHUNK_SIZE,
    nonce_prefix: base64Encode(noncePrefix),
  }));
  const prefix = concatBytes(MAGIC, uint32(header.length), header);
  const key = await deriveKey(password, salt, DEFAULT_ITERATIONS);
  const records = [prefix];
  let index = 0;
  for (let offset = 0; offset < zipBytes.length; offset += CHUNK_SIZE) {
    const clear = zipBytes.subarray(offset, Math.min(offset + CHUNK_SIZE, zipBytes.length));
    const indexBytes = uint32(index);
    const encrypted = await aesGcm(key, concatBytes(noncePrefix, indexBytes), clear, concatBytes(prefix, indexBytes));
    records.push(uint32(encrypted.length - MAC_LENGTH), encrypted.subarray(0, encrypted.length - MAC_LENGTH), encrypted.subarray(encrypted.length - MAC_LENGTH));
    index++;
  }
  const indexBytes = uint32(index);
  const finalEncrypted = await aesGcm(key, concatBytes(noncePrefix, indexBytes), new Uint8Array(), concatBytes(prefix, indexBytes));
  records.push(uint32(0), finalEncrypted);
  return concatBytes(...records);
}

/** Decrypts both PWA- and native-produced .holt.backup files. */
export async function decryptHoltBackup(bytes, password) {
  ensureCrypto();
  if (!password) throw new Error("備份密碼不可為空");
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (!isEncryptedBackup(data)) throw new Error("不是 Holt 加密備份檔");
  if (data.length < 12) throw new Error("加密備份不完整");
  const headerLength = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(8, false);
  if (!headerLength || headerLength > 64 * 1024 || 12 + headerLength > data.length) throw new Error("加密備份標頭無效");
  let header;
  try { header = JSON.parse(textDecoder.decode(data.subarray(12, 12 + headerLength))); } catch (_) { throw new Error("加密備份標頭無效"); }
  if (header.type !== "holt_encrypted_backup" || header.version !== FORMAT_VERSION || header.kdf !== "pbkdf2-hmac-sha256" || header.cipher !== "aes-256-gcm") throw new Error("不支援的加密備份格式");
  if (!Number.isInteger(header.iterations) || header.iterations < 10000 || header.iterations > 2000000 || !Number.isInteger(header.chunk_size) || header.chunk_size < 4096 || header.chunk_size > 16 * 1024 * 1024) throw new Error("加密備份參數無效");
  const salt = base64Decode(header.salt);
  const noncePrefix = base64Decode(header.nonce_prefix);
  if (salt.length !== SALT_LENGTH || noncePrefix.length !== NONCE_PREFIX_LENGTH) throw new Error("加密備份參數無效");
  const prefix = data.subarray(0, 12 + headerLength);
  const key = await deriveKey(password, salt, header.iterations);
  const output = [];
  let cursor = prefix.length;
  let index = 0;
  while (true) {
    if (cursor + 4 > data.length) throw new Error("加密備份不完整");
    const cipherLength = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(cursor, false); cursor += 4;
    if (cipherLength > header.chunk_size || cursor + cipherLength + MAC_LENGTH > data.length) throw new Error("加密備份資料區塊無效");
    const cipherText = data.subarray(cursor, cursor + cipherLength); cursor += cipherLength;
    const mac = data.subarray(cursor, cursor + MAC_LENGTH); cursor += MAC_LENGTH;
    const indexBytes = uint32(index);
    const clear = await aesGcm(key, concatBytes(noncePrefix, indexBytes), concatBytes(cipherText, mac), concatBytes(prefix, indexBytes), true).catch(() => { throw new Error("備份密碼錯誤或檔案已損壞"); });
    if (cipherLength === 0) {
      if (clear.length || cursor !== data.length) throw new Error("加密備份尾端無效");
      return concatBytes(...output);
    }
    output.push(clear);
    index++;
    if (index > 0xffffffff) throw new Error("加密備份過大");
  }
}

export async function readBackupDump(bytes, password = "") {
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const plain = isEncryptedBackup(data) ? await decryptHoltBackup(data, password) : data;
  let text = "";
  try { text = textDecoder.decode(plain); } catch (_) { /* ZIP path below */ }
  if (text.trimStart().startsWith("{")) return JSON.parse(text);

  // Native portable bundles declare the JSON payload in manifest.json. Older
  // exports may omit the manifest or use data.json/export.json, so inspect
  // only root-level JSON metadata and leave media/database entries untouched.
  const entries = await readZip(
    plain,
    (name) => name === "manifest.json" || (!name.includes("/") && name.endsWith(".json")),
  );
  let manifest = null;
  const manifestBytes = entries.get("manifest.json");
  if (manifestBytes) {
    try { manifest = JSON.parse(textDecoder.decode(manifestBytes)); } catch (_) {}
  }

  const declaredData = typeof manifest?.data === "string" ? manifest.data : "";
  if (declaredData && !entries.has(declaredData)) {
    const declaredEntries = await readZip(plain, new Set([declaredData]));
    for (const [name, content] of declaredEntries) entries.set(name, content);
  }

  const preferredNames = [declaredData, "backup.json", "data.json", "export.json", "holt_export.json"];
  const candidateNames = [
    ...preferredNames,
    ...entries.keys(),
  ].filter((name, index, all) => name && name !== "manifest.json" && all.indexOf(name) === index);

  for (const name of candidateNames) {
    const content = entries.get(name);
    if (!content) continue;
    try {
      const parsed = JSON.parse(textDecoder.decode(content));
      if (parsed?.type === "holt_pwa_backup" ||
          parsed?.type === "holt_full_export" ||
          parsed?.type === "yanci_full_export") {
        return parsed;
      }
    } catch (_) {
      // Ignore unrelated JSON metadata and continue looking for the payload.
    }
  }

  throw new Error("ZIP 備份缺少可匯入的 Holt JSON 資料");
}

export function makePortableZip(dump) {
  const backup = textEncoder.encode(JSON.stringify(dump, null, 2));
  const manifest = textEncoder.encode(JSON.stringify({
    type: "holt_pwa_portable_backup",
    version: 1,
    data: "backup.json",
    created_at: new Date().toISOString(),
  }, null, 2));
  return createZip([
    { name: "manifest.json", bytes: manifest },
    { name: "backup.json", bytes: backup },
  ]);
}
