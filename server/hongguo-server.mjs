/**
 * 红果短剧解析服务 — 单文件、零框架依赖
 *
 * 部署：
 *   node hongguo-server.mjs                 # 默认 :8787
 *   PORT=3000 HOST=0.0.0.0 node hongguo-server.mjs
 *
 * 接口：
 *   GET  /                             健康检查
 *   GET  /api/detail?series_id=<id>    剧集详情 + 分集清单（含每集可播状态）
 *   GET  /api/episodes?series_id=<id>  只要分集 vid 列表
 *   GET  /api/play?vid=<vid>           单集播放信息（明文 URL / 质量 / 是否 CENC）
 *   GET  /api/stream?vid=<vid>         流式播放（AVPlayer 直连，支持 Range）
 *   GET  /api/download?vid=<vid>       整集下载（解密后完整 MP4）
 *
 * 关键点（实测结论，别乱改）：
 *   1. multi_video_model 的 x-gorgon/x-argus/x-ladon/x-helios/x-medusa
 *      全是装饰，随便填甚至不填都能过 —— 所以这里不做签名。
 *   2. 唯一门槛是 device_id/iid 必须是没被标记过的随机值，
 *      用固定值会稳定 110001。所以每次请求都生成新的。
 *   3. biz_param.video_platform 必须是 1024；
 *      mixed_video_id_map 的 key 必须是 "1004"。
 */
import http from "node:http";
import crypto from "node:crypto";
import { URL } from "node:url";

const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || "0.0.0.0";

// 可选访问口令：设置后所有接口需要 ?token=xxx 或 X-Auth-Token 头
const ACCESS_TOKEN = process.env.ACCESS_TOKEN || "";

const API_HOST = "https://api5-normal-sinfonlineb.fqnovel.com";
const MODEL_PATH = "/novel/player/multi_video_model/v1/";
const WEB = "https://hongguoduanju.com";
const APP_UA =
  "com.phoenix.read/74232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)";
const WEB_UA =
  "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36";

const SEG_SIZE = 1024 * 1024; // 单次回传上限

// ---------------------------------------------------------------- 工具

const seen = (v, d = "") => String(v == null ? d : v).trim();

function randId() {
  const lo = 10n ** 18n;
  const hi = 9n * 10n ** 18n;
  const r = BigInt("0x" + crypto.randomBytes(8).toString("hex")) % (hi - lo);
  return String(lo + r);
}

/** 每次生成一套干净指纹（服务端会标记被滥用的 device_id） */
function freshDevice() {
  return {
    iid: randId(),
    device_id: randId(),
    ac: "wifi",
    channel: "update_64",
    aid: "8662",
    app_name: "novelread",
    version_code: "74232",
    version_name: "7.4.2.32",
    device_platform: "android",
    os: "android",
    ssmix: "a",
    device_type: "25053RT47C",
    device_brand: "Redmi",
    language: "zh",
    os_api: "36",
    os_version: "16",
    manifest_version_code: "74232",
    resolution: "1280*2772",
    dpi: "520",
    update_version_code: "74232",
    host_abi: "arm64-v8a",
    dragon_device_type: "phone",
    pv_player: "74232",
    compliance_status: "0",
    need_personal_recommend: "1",
    player_so_load: "1",
    is_android_pad_screen: "0",
  };
}

function qs(obj) {
  return Object.entries(obj)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    .join("&");
}

function jsonBody(v) {
  try {
    return JSON.parse(v);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- HTTP

async function fetchText(url, headers = {}, timeout = 25000, init = {}) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeout);
  try {
    const resp = await fetch(url, { headers, signal: ctl.signal, ...init });
    const buf = Buffer.from(await resp.arrayBuffer());
    return { status: resp.status, headers: resp.headers, data: buf };
  } finally {
    clearTimeout(timer);
  }
}

/** 拉远端 Range，返回 { data, total } */
async function remoteRange(url, start, end, timeout = 30000) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeout);
  try {
    const resp = await fetch(url, {
      headers: {
        "User-Agent": APP_UA,
        Referer: "https://novel.snssdk.com/",
        Range: `bytes=${start}-${end}`,
      },
      signal: ctl.signal,
    });
    let data = Buffer.from(await resp.arrayBuffer());
    let total = 0;
    const cr = resp.headers.get("content-range") || "";
    const m = cr.match(/\/(\d+)$/);
    if (m) total = Number(m[1]);
    if (resp.status === 200) {
      total ||= Number(resp.headers.get("content-length") || data.length);
      data = data.subarray(start, end + 1);
    }
    return { data, total, status: resp.status };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------- spade / 密钥

/** spade URL 解密：aes-128-cbc，key/iv 由 sha512(seed) 与 sha512(h1||constants) 派生 */
function decryptSpadeUrl(value, seed) {
  const encoded = seen(value);
  if (!encoded) return "";
  const raw = Buffer.from(encoded, "base64");
  if (raw.length < 5) throw new Error("spade URL 密文太短");
  if (raw[0] !== 0xa8 || raw[2] !== 0x01 || raw[3] !== 0x00) {
    throw new Error("spade URL 头格式不符");
  }
  const cipherLength = Math.floor((raw.length - 4) / 16) * 16;
  if (!cipherLength) throw new Error("spade URL 没有完整密文块");
  const constants = Buffer.from(
    "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524" +
      "f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58",
    "hex"
  );
  const h1 = crypto.createHash("sha512").update(seed).digest();
  const h2 = crypto
    .createHash("sha512")
    .update(Buffer.concat([h1, constants]))
    .digest();
  const d = crypto.createDecipheriv(
    "aes-128-cbc",
    h2.subarray(0, 16),
    h2.subarray(16, 32)
  );
  d.setAutoPadding(false);
  let pt = Buffer.concat([
    d.update(raw.subarray(4, 4 + cipherLength)),
    d.final(),
  ]);
  if (pt.length) {
    const pad = pt[pt.length - 1];
    if (pad >= 1 && pad <= 16 && pad <= pt.length) pt = pt.subarray(0, pt.length - pad);
  }
  while (pt.length && pt[pt.length - 1] === 0) pt = pt.subarray(0, pt.length - 1);
  return pt.toString("utf8");
}

/** spade_a -> AES-128 内容密钥（位运算还原，勿改顺序） */
function deriveContentKey(value) {
  const raw = Buffer.from(
    seen(value).replace(/-/g, "+").replace(/_/g, "/"),
    "base64"
  );
  if (raw.length < 3) throw new Error("spade_a 太短");
  let v8 = raw.length - (raw[0] ^ raw[1] ^ raw[2]) + 47;
  v8 = Math.min(v8, raw.length - 1);
  if (v8 < 33) throw new Error("spade_a 长度无效");
  const work = Buffer.from(raw.subarray(1, 1 + v8));
  let a = 85;
  let b = 246;
  for (let i = 0; i < v8; i += 1) {
    const old = work[i];
    const prev = i & 1 ? a : b;
    if (i & 1) a = old;
    else b = old;
    const pop = i.toString(2).split("1").length - 1;
    work[i] = (-21 - pop + (prev ^ old)) & 255;
  }
  return Buffer.from(work.subarray(1, 33).toString("ascii"), "hex");
}

// ---------------------------------------------------------------- App 接口

async function requestVideoModel(vid) {
  const dev = freshDevice();
  const url = `${API_HOST}${MODEL_PATH}?${qs(dev)}`;
  const payload = JSON.stringify({
    biz_param: {
      detail_page_version: 0,
      device_level: 3,
      disable_digg_stat: false,
      need_all_video_definition: true,
      need_mp4_align: false,
      use_os_player: false,
      use_server_dns: false,
      video_platform: 1024,
    },
    mixed_video_id_map: { "1004": [String(vid)] },
  });
  const { status, data } = await fetchText(
    url,
    {
      "User-Agent": APP_UA,
      "Content-Type": "application/json; charset=UTF-8",
      Accept: "application/json; charset=utf-8,application/x-protobuf",
    },
    25000,
    { method: "POST", body: payload }
  );
  const txt = data.toString("utf8");
  const j = jsonBody(txt);
  if (status !== 200 || !j) throw new Error(`video_model HTTP ${status}`);
  const code = Number(j.Code ?? j.code ?? -1);
  if (code !== 0) {
    console.error("[vm-debug]", JSON.stringify({
      code,
      msg: j.Message || j.message,
      debug_info: j.debug_info,
      bodyHead: txt.slice(0, 240),
      urlHead: url.slice(0, 220),
      payloadHead: payload.slice(0, 240),
    }, null, 1));
    throw new Error(
      `video_model 失败 ${code}: ${j.Message || j.message || ""} ${j.debug_info || ""}`.trim()
    );
  }
  const map = j.data || {};
  const entry = map[String(vid)] || Object.values(map).find((x) => x && typeof x === "object");
  if (!entry) throw new Error("video_model 没有对应视频");
  const model = typeof entry.video_model === "string" ? jsonBody(entry.video_model) : entry.video_model;
  if (!model) throw new Error("video_model 内容为空");
  return model;
}

async function fetchVideoInfo(vid) {
  const model = await requestVideoModel(vid);
  const fb =
    typeof model.fallback_api === "string"
      ? (jsonBody(model.fallback_api)?.fallback_api || model.fallback_api)
      : model.fallback_api?.fallback_api;
  if (!fb) throw new Error("fallback_api 为空");
  const { status, data } = await fetchText(fb, {
    "User-Agent": APP_UA,
    Referer: "https://novel.snssdk.com/",
  });
  if (status !== 200) throw new Error(`fallback_api HTTP ${status}`);
  const outer = jsonBody(data.toString("utf8"));
  const info = outer?.video_info?.data || {};
  return { model, info };
}

// ---------------------------------------------------------------- CENC

function readBox(data, offset) {
  if (offset < 0 || offset + 8 > data.length) return null;
  let size = data.readUInt32BE(offset);
  const type = data.toString("ascii", offset + 4, offset + 8);
  let header = 8;
  if (size === 1) {
    if (offset + 16 > data.length) return null;
    const large = data.readBigUInt64BE(offset + 8);
    if (large > BigInt(Number.MAX_SAFE_INTEGER)) return null;
    size = Number(large);
    header = 16;
  } else if (size === 0) {
    size = data.length - offset;
  }
  if (size < header || offset + size > data.length) return null;
  return { offset, size, type, header, bodyStart: offset + header };
}

function findBox(data, type, start = 0) {
  for (let off = Math.max(0, start); off + 8 <= data.length; off += 1) {
    const box = readBox(data, off);
    if (box?.type === type) return box;
  }
  return null;
}

function boxBody(data, type, start = 0) {
  const box = findBox(data, type, start);
  return box ? data.subarray(box.bodyStart, box.offset + box.size) : null;
}

function readU64(data, offset) {
  const v = data.readBigUInt64BE(offset);
  if (v > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("MP4 offset 过大");
  return Number(v);
}

function parseTrack(moov, track) {
  const stbl = findBox(moov, "stbl", track.bodyStart);
  if (!stbl) return null;
  const stsz = boxBody(moov, "stsz", stbl.bodyStart);
  const stsc = boxBody(moov, "stsc", stbl.bodyStart);
  const chunkBox = findBox(moov, "stco", stbl.bodyStart) || findBox(moov, "co64", stbl.bodyStart);
  const saiz = boxBody(moov, "saiz", stbl.bodyStart);
  const saio = boxBody(moov, "saio", stbl.bodyStart);
  if (!stsz || !stsc || !chunkBox || !saiz || !saio) return null;
  if (stsz.length < 12 || stsc.length < 8 || saiz.length < 9 || saio.length < 8) return null;

  const defaultSampleSize = stsz.readUInt32BE(4);
  const sampleCount = stsz.readUInt32BE(8);
  const sizes = [];
  if (defaultSampleSize) sizes.push(...Array(sampleCount).fill(defaultSampleSize));
  else
    for (let i = 0; i < sampleCount && 12 + (i + 1) * 4 <= stsz.length; i += 1)
      sizes.push(stsz.readUInt32BE(12 + i * 4));
  if (sizes.length !== sampleCount) return null;

  const chunkCount =
    chunkBox.bodyStart + 8 <= chunkBox.offset + chunkBox.size
      ? moov.readUInt32BE(chunkBox.bodyStart + 4)
      : 0;
  const offsets = [];
  for (let i = 0; i < chunkCount; i += 1) {
    const wide = chunkBox.type === "co64";
    const at = chunkBox.bodyStart + 8 + i * (wide ? 8 : 4);
    if (at + (wide ? 8 : 4) > chunkBox.offset + chunkBox.size) return null;
    offsets.push(wide ? readU64(moov, at) : moov.readUInt32BE(at));
  }

  const entryCount = stsc.readUInt32BE(4);
  const entries = [];
  for (let i = 0; i < entryCount; i += 1) {
    const at = 8 + i * 12;
    if (at + 8 > stsc.length) return null;
    entries.push({ firstChunk: stsc.readUInt32BE(at), samplesPerChunk: stsc.readUInt32BE(at + 4) });
  }
  const samplesPerChunk = offsets.map((_v, index) => {
    let sel = 0;
    for (const e of entries) if (e.firstChunk <= index + 1) sel = e.samplesPerChunk;
    return sel;
  });

  const auxDefault = saiz[4];
  const auxCount = saiz.readUInt32BE(5);
  const auxSizes = [];
  if (auxDefault) auxSizes.push(...Array(auxCount).fill(auxDefault));
  else for (let i = 0; i < auxCount && 9 + i < saiz.length; i += 1) auxSizes.push(saiz[9 + i]);
  if (auxSizes.length !== auxCount) return null;

  const saioVer = saio.readUInt32BE(0) >>> 24;
  const offSize = saioVer === 1 ? 8 : 4;
  const saioCount = saio.readUInt32BE(4);
  if (!saioCount || 8 + offSize > saio.length) return null;
  const auxOffset = offSize === 8 ? readU64(saio, 8) : saio.readUInt32BE(8);

  return { sizes, offsets, samplesPerChunk, auxOffset, auxSizes, sampleCount };
}

function buildSamples(data, tracks) {
  const samples = [];
  for (const track of tracks) {
    let sampleIndex = 0;
    let auxPos = 0;
    const auxTotal = track.auxSizes.reduce((s, v) => s + Math.max(v, 8), 0);
    if (track.auxOffset < 0 || track.auxOffset + auxTotal > data.length) {
      throw new Error("MP4 辅助数据越界");
    }
    const aux = data.subarray(track.auxOffset, track.auxOffset + auxTotal);
    for (let chunk = 0; chunk < track.offsets.length && sampleIndex < track.sampleCount; chunk += 1) {
      let offset = track.offsets[chunk];
      const count = track.samplesPerChunk[chunk] || 0;
      for (let i = 0; i < count && sampleIndex < track.sampleCount; i += 1) {
        const size = track.sizes[sampleIndex];
        const auxSize = Math.max(track.auxSizes[sampleIndex] || 8, 8);
        if (offset + size > Number.MAX_SAFE_INTEGER || auxPos + auxSize > aux.length) {
          throw new Error("MP4 样本索引越界");
        }
        const iv = Buffer.alloc(16);
        aux.copy(iv, 0, auxPos, auxPos + Math.min(8, auxSize));
        samples.push({ start: offset, end: offset + size, iv });
        offset += size;
        sampleIndex += 1;
        auxPos += auxSize;
      }
    }
  }
  return samples.sort((a, b) => a.start - b.start);
}

function replaceFourcc(data, from, to) {
  let off = 0;
  const src = Buffer.from(from);
  while ((off = data.indexOf(src, off)) >= 0) {
    data.write(to, off, "ascii");
    off += src.length;
  }
}

function replaceSinf(data) {
  let off = 0;
  while ((off = data.indexOf(Buffer.from("sinf"), off)) >= 0) {
    if (off < 4) {
      off += 4;
      continue;
    }
    const size = data.readUInt32BE(off - 4);
    const end = off - 4 + size;
    if (size >= 8 && size < 50000 && end <= data.length) {
      data.write("free", off, "ascii");
      data.fill(0, off + 4, end);
      off = end;
    } else {
      off += 4;
    }
  }
}

function prepareCencHeader(data, key) {
  const ftypSize = data.readUInt32BE(0);
  const moov = readBox(data, ftypSize);
  if (!moov || moov.type !== "moov") throw new Error("MP4 moov 无效");
  const moovBody = data.subarray(moov.bodyStart, moov.offset + moov.size);
  const tracks = [];
  let cursor = 0;
  for (;;) {
    const t = findBox(moovBody, "trak", cursor);
    if (!t) break;
    tracks.push(t);
    cursor = t.offset + t.size;
  }
  const parsed = tracks.map((t) => parseTrack(moovBody, t)).filter(Boolean);
  const samples = key ? buildSamples(data, parsed) : [];
  const header = Buffer.from(data.subarray(0, moov.offset + moov.size));
  replaceFourcc(header, "encv", "hvc1");
  replaceFourcc(header, "enca", "mp4a");
  replaceSinf(header);
  return { header, samples };
}

function addCounter(iv, blocks) {
  const value = (iv.readBigUInt64BE(0) << 64n) | iv.readBigUInt64BE(8);
  const next = (value + BigInt(blocks)) & ((1n << 128n) - 1n);
  const out = Buffer.alloc(16);
  out.writeBigUInt64BE(next >> 64n, 0);
  out.writeBigUInt64BE(next & ((1n << 64n) - 1n), 8);
  return out;
}

function decryptPartial(data, start, key, prepared) {
  const out = Buffer.from(data);
  const end = start + out.length;
  if (start < prepared.header.length) {
    prepared.header.copy(out, 0, start, Math.min(end, prepared.header.length));
  }
  if (!key) return out;
  let i = 0;
  while (i < prepared.samples.length && prepared.samples[i].end <= start) i += 1;
  for (; i < prepared.samples.length; i += 1) {
    const s = prepared.samples[i];
    if (s.start >= end) break;
    const oStart = Math.max(start, s.start);
    const oEnd = Math.min(end, s.end);
    if (oStart >= oEnd) continue;
    const rel = oStart - s.start;
    const block = Math.floor(rel / 16);
    const skip = rel % 16;
    const d = crypto.createDecipheriv("aes-128-ctr", key, addCounter(s.iv, block));
    if (skip) d.update(Buffer.alloc(skip));
    const plain = Buffer.concat([
      d.update(out.subarray(oStart - start, oEnd - start)),
      d.final(),
    ]);
    plain.copy(out, oStart - start);
  }
  return out;
}

// ---------------------------------------------------------------- 缓存

const streamCache = new Map(); // vid -> { time, value }
const infoCache = new Map();   // vid -> { time, value }
const CACHE_TTL = 5 * 60 * 1000;

function qualityNumber(v) {
  const t = seen(v);
  const m = t.match(/(2160|1440|1080|720|576|540|480|360)/);
  if (m) return Number(m[1]);
  return (
    { 1920: 1080, 1280: 720, 1024: 576, 854: 480, 640: 360 }[t] ||
    (/^\d{3,4}$/.test(t) ? Number(t) : 0)
  );
}

function qualityLabel(v) {
  const n = qualityNumber(v);
  if (n) return `${n}P`;
  return seen(v, "自动");
}

function qualityRows(videoList) {
  const rows = [];
  if (!videoList || typeof videoList !== "object") return rows;
  for (const [key, value] of Object.entries(videoList)) {
    const item = value && typeof value === "object" ? value : {};
    const q = seen(item.quality_desc || item.height || item.vheight || item.quality || key);
    if (item.main_url && !rows.some((r) => r.quality === key)) rows.push({ key, quality: q, item });
  }
  return rows.sort((a, b) => qualityNumber(b.quality || b.key) - qualityNumber(a.quality || a.key));
}

/** 解析一集：拿到明文 URL + 内容密钥 + 样本表 */
async function resolveStream(vid) {
  const cached = streamCache.get(vid);
  if (cached && Date.now() - cached.time < CACHE_TTL) return cached.value;

  const { info } = await fetchVideoInfo(vid);
  const rows = qualityRows(info.video_list);
  if (!rows.length) throw new Error("没有可用清晰度");
  const selected = rows[0];

  let url = seen(selected.item.main_url).replace(/\\\//g, "/").replace(/\\u0026/g, "&").replace(/&amp;/g, "&");
  const seed = Buffer.from(seen(info.key_seed), "base64");
  if (seed.length && url) url = decryptSpadeUrl(url, seed);
  const key = selected.item.spade_a ? deriveContentKey(selected.item.spade_a) : null;

  // 拉头部建 CENC 索引
  const first = await remoteRange(url, 0, 256 * 1024 - 1);
  const head = first.data;
  const total = first.total || head.length;
  const moov = readBox(head, head.readUInt32BE(0));
  let prepared = null;
  let encrypted = false;
  if (moov && moov.type === "moov") {
    const moovEnd = moov.offset + moov.size;
    let headerBuf = head;
    if (moovEnd > head.length) {
      const rest = await remoteRange(url, head.length, moovEnd - 1);
      headerBuf = Buffer.concat([head.subarray(0, head.length), rest.data]);
    }
    headerBuf = headerBuf.subarray(0, moovEnd);
    encrypted = headerBuf.indexOf(Buffer.from("encv")) >= 0 || headerBuf.indexOf(Buffer.from("enca")) >= 0;
    prepared = prepareCencHeader(headerBuf, encrypted ? key : null);
  }

  const value = {
    vid: String(vid),
    url,
    key,
    quality: qualityLabel(selected.quality || selected.key),
    total,
    encrypted,
    prepared,
    duration: Number(info.video_duration || 0),
  };
  streamCache.set(vid, { time: Date.now(), value });
  return value;
}

// ---------------------------------------------------------------- 网页端（拿全集清单）

async function seriesVids(seriesId) {
  const cached = infoCache.get(seriesId);
  if (cached && Date.now() - cached.time < CACHE_TTL) return cached.value;
  const { status, data } = await fetchText(`${WEB}/detail?series_id=${seriesId}`, {
    "User-Agent": WEB_UA,
  });
  if (status !== 200) throw new Error(`详情页 HTTP ${status}`);
  const html = data.toString("utf8");
  const listMatch = html.match(/vid_list\W{0,4}\[([^\]]+)\]/);
  const vids = listMatch ? [...listMatch[1].matchAll(/"(\d{15,20})"/g)].map((m) => m[1]) : [];
  const title = (html.match(/"series_name"\s*:\s*"([^"]*)"/) || [])[1] || "";
  const intro = (html.match(/"series_intro"\s*:\s*"([^"]*)"/) || [])[1] || "";
  const cover = (html.match(/"series_cover"\s*:\s*"([^"]*)"/) || [])[1] || "";
  const free = Number((html.match(/"accessible_episode_cnt"\s*:\s*(\d+)/) || [])[1] || 0);
  const total = Number((html.match(/"episode_cnt"\s*:\s*(\d+)/) || [])[1] || vids.length);
  const value = { seriesId: String(seriesId), title, intro, cover, free, total, vids };
  infoCache.set(seriesId, { time: Date.now(), value });
  return value;
}

// ---------------------------------------------------------------- HTTP 服务

function send(res, status, body, headers = {}) {
  const isBuf = Buffer.isBuffer(body);
  const payload = isBuf ? body : Buffer.from(String(body));
  res.writeHead(status, {
    "Content-Length": payload.length,
    "Access-Control-Allow-Origin": "*",
    ...headers,
  });
  res.end(payload);
}

function sendJSON(res, status, obj) {
  send(res, status, JSON.stringify(obj), { "Content-Type": "application/json; charset=utf-8" });
}

function authorized(req, url) {
  if (!ACCESS_TOKEN) return true;
  const t = url.searchParams.get("token") || req.headers["x-auth-token"] || "";
  return t === ACCESS_TOKEN;
}

/** 解析 Range 头，返回 [start, end] 或 null */
function parseRange(header, total) {
  if (!header) return null;
  const m = String(header).match(/bytes=(\d*)-(\d*)/);
  if (!m) return null;
  let start = m[1] === "" ? null : Number(m[1]);
  let end = m[2] === "" ? null : Number(m[2]);
  if (start === null && end === null) return null;
  if (start === null) {
    start = Math.max(0, total - end);
    end = total - 1;
  } else if (end === null || end >= total) {
    end = total - 1;
  }
  if (start > end || start >= total) return "invalid";
  return [start, end];
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  const path = url.pathname.replace(/\/+$/, "") || "/";

  try {
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
      });
      res.end();
      return;
    }

    if (path === "/" || path === "/health") {
      sendJSON(res, 200, {
        ok: true,
        service: "hongguo-resolver",
        time: new Date().toISOString(),
        auth: ACCESS_TOKEN ? "required" : "open",
        endpoints: ["/api/detail", "/api/episodes", "/api/play", "/api/stream", "/api/download"],
      });
      return;
    }

    if (!authorized(req, url)) {
      sendJSON(res, 401, { ok: false, error: "token 无效" });
      return;
    }

    // --- 剧集详情
    if (path === "/api/detail") {
      const sid = seen(url.searchParams.get("series_id"));
      if (!sid) return sendJSON(res, 400, { ok: false, error: "缺少 series_id" });
      const info = await seriesVids(sid);
      sendJSON(res, 200, {
        ok: true,
        series_id: info.seriesId,
        title: info.title,
        intro: info.intro,
        cover: info.cover,
        free_episodes: info.free,
        total_episodes: info.total,
        episodes: info.vids.map((v, i) => ({
          index: i + 1,
          vid: v,
          playable: true,
          play_url: `/api/stream?vid=${v}`,
        })),
      });
      return;
    }

    // --- 只要 vid 列表
    if (path === "/api/episodes") {
      const sid = seen(url.searchParams.get("series_id"));
      if (!sid) return sendJSON(res, 400, { ok: false, error: "缺少 series_id" });
      const info = await seriesVids(sid);
      sendJSON(res, 200, { ok: true, title: info.title, count: info.vids.length, vids: info.vids });
      return;
    }

    // --- 单集信息
    if (path === "/api/play") {
      const vid = seen(url.searchParams.get("vid"));
      if (!vid) return sendJSON(res, 400, { ok: false, error: "缺少 vid" });
      const s = await resolveStream(vid);
      sendJSON(res, 200, {
        ok: true,
        vid: s.vid,
        quality: s.quality,
        duration: s.duration,
        total_bytes: s.total,
        encrypted: s.encrypted,
        cdn_url: s.url,
        cenc_key_hex: s.key ? Buffer.from(s.key).toString("hex") : null,
        stream_url: `/api/stream?vid=${vid}`,
        download_url: `/api/download?vid=${vid}`,
      });
      return;
    }

    // --- 流式播放（AVPlayer 直连）
    if (path === "/api/stream") {
      const vid = seen(url.searchParams.get("vid"));
      if (!vid) return sendJSON(res, 400, { ok: false, error: "缺少 vid" });
      const s = await resolveStream(vid);
      const total = s.total;

      // 没有 Range：必须回 200 + 完整 Content-Length，且不能带 Content-Range，
      // 否则 AVPlayer 会误判文件大小。客户端会自己用 Range 再要片段。
      const range = parseRange(req.headers.range, total);
      if (range === "invalid") {
        send(res, 416, "range not satisfiable", { "Content-Range": `bytes */${total}` });
        return;
      }

      if (!range) {
        // 无 Range：回 200，声明完整长度，分块发送（不缓冲整个文件）
        res.writeHead(200, {
          "Content-Type": "video/mp4",
          "Content-Length": total,
          "Accept-Ranges": "bytes",
          "Access-Control-Allow-Origin": "*",
          "Cache-Control": "no-store",
        });
        try {
          for (let pos = 0; pos < total; pos += SEG_SIZE) {
            const segEnd = Math.min(pos + SEG_SIZE - 1, total - 1);
            const remote = await remoteRange(s.url, pos, segEnd);
            const plain = decryptPartial(
              remote.data, pos,
              s.encrypted ? s.key : null,
              s.prepared || { header: Buffer.alloc(0), samples: [] }
            );
            if (!res.write(plain)) {
              await new Promise((r) => res.once("drain", r));
            }
          }
        } catch (e) {
          console.error("[stream-200]", vid, e.message);
        }
        res.end();
        return;
      }

      // 有 Range：回 206
      const [start, rawEnd] = range;
      const end = Math.min(rawEnd, start + SEG_SIZE - 1, total - 1);
      const remote = await remoteRange(s.url, start, end);
      const plain = decryptPartial(
        remote.data, start,
        s.encrypted ? s.key : null,
        s.prepared || { header: Buffer.alloc(0), samples: [] }
      );

      res.writeHead(206, {
        "Content-Type": "video/mp4",
        "Content-Length": plain.length,
        "Accept-Ranges": "bytes",
        "Content-Range": `bytes ${start}-${end}/${total}`,
        "Access-Control-Allow-Origin": "*",
        "Cache-Control": "no-store",
      });
      res.end(plain);
      return;
    }

    // --- 整集下载
    if (path === "/api/download") {
      const vid = seen(url.searchParams.get("vid"));
      if (!vid) return sendJSON(res, 400, { ok: false, error: "缺少 vid" });
      const s = await resolveStream(vid);
      res.writeHead(200, {
        "Content-Type": "video/mp4",
        "Content-Length": s.total,
        "Content-Disposition": `attachment; filename="${vid}.mp4"`,
        "Access-Control-Allow-Origin": "*",
      });
      for (let pos = 0; pos < s.total; pos += SEG_SIZE) {
        const end = Math.min(pos + SEG_SIZE - 1, s.total - 1);
        const remote = await remoteRange(s.url, pos, end);
        const plain = decryptPartial(remote.data, pos, s.encrypted ? s.key : null, s.prepared || { header: Buffer.alloc(0), samples: [] });
        res.write(plain);
      }
      res.end();
      return;
    }

    sendJSON(res, 404, { ok: false, error: "未知接口", path });
  } catch (e) {
    console.error("[error]", path, e.message);
    if (!res.headersSent) sendJSON(res, 500, { ok: false, error: e.message });
    else res.end();
  }
});

server.listen(PORT, HOST, () => {
  console.log(`红果解析服务已启动: http://${HOST}:${PORT}`);
  console.log(`  鉴权: ${ACCESS_TOKEN ? "已启用 ACCESS_TOKEN" : "未启用（任何人可访问）"}`);
  console.log(`  接口: /api/detail /api/episodes /api/play /api/stream /api/download`);
});
