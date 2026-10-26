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
import { signHeaders, setSignDevice } from "./sign.mjs";

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

// 单次回传上限。
// 红果单集最大约 20 MB（1080P / 2~3 分钟），设 32 MiB 保证一集能一次性给完，
// 避免 Content-Range 与客户端请求不一致导致 AVPlayer 卡住。
const SEG_SIZE = 32 * 1024 * 1024;

// 版本号：解密/头部处理逻辑有改动就 +1
const SERVER_VERSION = "7";

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

/**
 * 把 sample auxiliary information 的 box 改成 free。
 *
 * senc / saiz / saio 里存的是「每样本的 IV + 加密标志」。
 * 我们已经把样本解成明文，这些表就失效了；而 sinf 被清掉后，
 * AVPlayer 看到 senc 会尝试走加密路径，但找不到加密描述，
 * 结果是 item.status 永远停在 .unknown —— 表现为黑屏 + 00:00。
 *
 * 注意：senc 必须整块清零（不能只改 fourcc），
 * 否则残留的 IV 数据会被误读成别的 box。
 */
function blankAuxBoxes(data) {
  for (const name of ["senc", "saiz", "saio"]) {
    let off = 0;
    const needle = Buffer.from(name);
    while ((off = data.indexOf(needle, off)) >= 0) {
      if (off < 4) {
        off += 4;
        continue;
      }
      const size = data.readUInt32BE(off - 4);
      const end = off - 4 + size;
      // 只处理合理的 box，避免误伤字符串里的偶然匹配
      if (size >= 8 && size <= data.length && end <= data.length) {
        data.write("free", off, "ascii");
        data.fill(0, off + 4, end);
        off = end;
      } else {
        off += 4;
      }
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
  // senc/saiz/saio 也必须清掉：样本已解密，这些加密辅助表会让
  // AVPlayer 误判为加密流并卡在 .unknown（黑屏 + 00:00）
  blankAuxBoxes(header);
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
const infoCache = new Map();   // seriesId -> { time, value }
const discoverCache = new Map(); // tab:offset:count -> { time, value }
const danmakuCache = new Map();  // vid:cursor:offset -> { time, value }
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
/**
 * 并发去重：同一 vid 的多个并发请求共用一次解析。
 * AVPlayer 会同时发 HEAD + 多个 Range，没有这个会重复解析 3~4 遍。
 */
const inflight = new Map();

async function resolveStream(vid) {
  const cached = streamCache.get(vid);
  if (cached && Date.now() - cached.time < CACHE_TTL) return cached.value;

  const running = inflight.get(vid);
  if (running) return running;

  const p = (async () => {
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
  })();

  inflight.set(vid, p);
  try {
    return await p;
  } finally {
    inflight.delete(vid);
  }
}

// ---------------------------------------------------------------- 弹幕

/**
 * 弹幕列表。
 *
 * 关键参数（这些是硬门槛，缺一个就 110001）：
 *   group_id        = 单集 vid
 *   group_type      = 30        （30 是弹幕专用；1=剧评 会走另一套）
 *   comment_type    = 20
 *   comment_source  = 601
 *   server_channel  = 1000
 *   business_param.start_offset_time     = 起始毫秒
 *   business_param.playlet_item_duration = 整集时长（毫秒）
 *
 * 响应里 data_list[].comment.expand.offset_time 是弹幕出现时间（毫秒），
 * common_list_info.cursor 是 JSON 串，原样回传即可翻页。
 */
async function fetchDanmaku(vid, seriesId, durationMs, cursor = "", offsetMs = 0) {
  const dev = freshDevice();

  // cursor 是上游返回的 JSON 串，形如
  //   {"start_offset_time":0,"end_offset_time":30000,...}
  // 翻页时 business_param.start_offset_time 必须与 cursor 里的 start 一致，
  // 否则上游判 110001。
  let startOffset = offsetMs;
  if (cursor) {
    const c = jsonBody(cursor);
    if (c && Number.isFinite(Number(c.start_offset_time))) {
      startOffset = Number(c.start_offset_time);
    }
  }

  const body = JSON.stringify({
    group_id: String(vid),
    group_type: 30,
    comment_type: 20,
    comment_source: 601,
    server_channel: 1000,
    sort: 1,
    count: 90,
    cursor: cursor || "",
    aid: 8662,
    compliance_status: 0,
    business_param: {
      book_id: String(seriesId),
      start_offset_time: startOffset,
      playlet_item_duration: durationMs,
      need_danmaku_guide_type: [],
    },
  });

  // 评论/弹幕接口强制校验签名（multi_video_model 不需要，这两个要）
  const khronos = Math.floor(Date.now() / 1000);
  const ticket = Date.now();
  const query = qs({ ...dev, ts: String(khronos), _rticket: String(ticket) });
  setSignDevice({ device_id: dev.device_id, version_name: dev.version_name });
  const sig = signHeaders(query, Buffer.from(body), khronos);

  const url = `${API_HOST}/novel/commentapi/comment/list/${vid}/v1/?${query}`;
  const { status, data } = await fetchText(
    url,
    {
      "User-Agent": APP_UA,
      "Content-Type": "application/json; charset=UTF-8",
      Accept: "application/json",
      "x-ss-req-ticket": String(ticket),
      "x-tt-request-tag": "t=0;n=0",
      "sdk-version": "2",
      "passport-sdk-version": "50561",
      "x-xs-from-web": "0",
      ...sig,
    },
    25000,
    { method: "POST", body }
  );

  const txt = data.toString("utf8");
  const j = jsonBody(txt);
  const code = Number((j && (j.code ?? j.Code)) ?? -1);
  if (status !== 200 || !j) throw new Error(`danmaku HTTP ${status}`);
  if (code !== 0) throw new Error(`danmaku 失败 ${code}: ${j.Message || j.message || ""}`);

  const d = j.data || {};
  const info = d.common_list_info || {};
  const rows = d.data_list || [];

  const items = [];
  for (const row of rows) {
    const c = row.comment || {};
    const common = c.common || {};
    const expand = c.expand || {};
    const stat = c.stat || {};
    const text = seen(((common.content || {}).text));
    const offset = Number(expand.offset_time || 0);
    if (!text) continue;
    items.push({
      id: seen(c.comment_id),
      text,
      offset_ms: offset,
      offset_sec: Math.round(offset / 100) / 10,
      digg: Number(stat.digg_count || 0),
      reply: Number(stat.reply_count || 0),
      user_id: seen((common.user_info || {}).user_id),
    });
  }
  items.sort((a, b) => a.offset_ms - b.offset_ms);

  return {
    items,
    cursor: seen(info.cursor),
    has_more: Boolean(info.has_more) && Boolean(info.cursor),
    next_offset_ms: Number((d.extra || {}).next_query_danmaku_list_time || 0),
    count: Number(((d.common_list_info || {}).cursor
      ? (jsonBody(info.cursor) || {}).danmaku_count
      : 0) || 0),
  };
}

/**
 * 弹幕窗口串行拉取 + 失败重试。
 *
 * 上游对同一 vid 的连续请求有节流：并发或过快会返回 110001。
 * 所以这里用全局串行队列，每次请求之间留间隔，失败退避重试。
 */
let danmakuChain = Promise.resolve();
const DANMAKU_GAP_MS = 120;

function enqueueDanmaku(task) {
  const run = danmakuChain.then(async () => {
    await new Promise((r) => setTimeout(r, DANMAKU_GAP_MS));
    return task();
  });
  // 链不因单次失败而断
  danmakuChain = run.catch(() => {});
  return run;
}

/** 带重试的弹幕请求 */
async function fetchDanmakuRetry(vid, seriesId, durationMs, cursor, offsetMs, tries = 4) {
  let lastErr = null;
  for (let i = 0; i < tries; i += 1) {
    try {
      return await enqueueDanmaku(() =>
        fetchDanmaku(vid, seriesId, durationMs, cursor, offsetMs)
      );
    } catch (e) {
      lastErr = e;
      const msg = String(e.message || "");
      // 只有节流类错误才重试
      if (!/110001|110002|timeout|ECONN/i.test(msg)) break;
      await new Promise((r) => setTimeout(r, 600 * (i + 1)));
    }
  }
  throw lastErr || new Error("danmaku failed");
}

/** 预热：提前把解析结果放进缓存（失败忽略） */
async function warmStream(vid) {
  try {
    await resolveStream(vid);
  } catch {
    /* 忽略 */
  }
}

// ---------------------------------------------------------------- 发现页 / 详情

/** App 端短剧商城 feed：只给 series_id/item_id，需要补详情 */
async function mallFeed(tabType = 201, offset = 0, count = 20) {
  const dev = freshDevice();
  const url = `${API_HOST}/reading/playlet/shortbuy_api/get_mall_playlet_feed/v1/?${qs({
    ...dev, tab_type: String(tabType), offset: String(offset), count: String(count),
  })}`;
  const { status, data } = await fetchText(url, { "User-Agent": APP_UA });
  if (status !== 200) throw new Error(`mall_feed HTTP ${status}`);
  const j = jsonBody(data.toString("utf8")) || {};
  const cells = ((j.data || {}).cell_view || {}).cell_data || [];
  const out = [];
  for (const c of cells) {
    const fmap = (((c.cell_extra_data || {}).rec_filter_info || {}).filter_id_map) || {};
    const sid = seen(fmap.series_id);
    const iid = seen(fmap.item_id);
    if (!sid) continue;
    // 顺手从 long_press_action 里挖标题/分类
    const lp = (c.cell_long_press_action || {}).new_long_press_action_card_playlet || [];
    let title = "";
    const tags = [];
    for (const it of lp) {
      if (it.selection_head === "这个视频") title = seen(it.selection_text);
      else if (it.selection_head === "分类") tags.push(seen(it.selection_text));
      else if (it.selection_head === "视频类型") tags.push(seen(it.selection_text));
    }
    const style = c.style || {};
    const epText = seen(style.episode_list_text);
    out.push({ seriesId: sid, itemId: iid, title, tags, episodeText: epText });
  }
  return out;
}

/** 专辑详情（App 端 album_detail，album_id 必须是字符串） */
async function albumDetail(seriesId) {
  const dev = freshDevice();
  const url = `${API_HOST}/novel/player/album_detail/v1/?${qs(dev)}`;
  const { status, data } = await fetchText(
    url,
    { "User-Agent": APP_UA, "Content-Type": "application/json; charset=UTF-8" },
    25000,
    { method: "POST", body: JSON.stringify({ album_id: String(seriesId) }) }
  );
  if (status !== 200) throw new Error(`album_detail HTTP ${status}`);
  const j = jsonBody(data.toString("utf8")) || {};
  if (Number(j.code ?? -1) !== 0) return null;
  return (j.data || {}).album_data || null;
}

/** 发现页：feed + 并发补详情 */
async function discover(tabType, offset, count) {
  const items = await mallFeed(tabType, offset, count);
  // feed 有时返回重复卡片，按 seriesId 去重
  const uniq = [];
  const seenIds = new Set();
  for (const it of items) {
    if (seenIds.has(it.seriesId)) continue;
    seenIds.add(it.seriesId);
    uniq.push(it);
  }
  const enriched = await Promise.all(
    uniq.map(async (it) => {
      const [ad, sv] = await Promise.all([
        albumDetail(it.seriesId).catch(() => null),
        seriesVids(it.seriesId).catch(() => null),
      ]);
      const base = { ...it };
      if (ad) {
        base.title = it.title || seen(ad.title);
        base.cover = seen(ad.cover);
        base.intro = seen(ad.intro);
        base.playCount = Number(ad.play_cnt || 0);
        base.followedCount = Number(ad.followed_cnt || 0);
        base.seriesStatus = Number(ad.series_status || 0);
      }
      if (sv) {
        base.episodeCount = sv.vids.length;
        base.freeEpisodes = sv.free;
        if (!base.cover) base.cover = sv.cover;
        if (!base.title) base.title = sv.title;
      }
      return base;
    })
  );
  return enriched;
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

  // 请求日志：确认 AVPlayer 到底有没有打过来、发了什么
  const t0 = Date.now();
  const clientIp = (req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").toString();
  console.log(
    `[req] ${new Date().toISOString().slice(11, 23)} ${req.method} ${path}` +
    `${url.search ? url.search.slice(0, 80) : ""} ` +
    `range=${req.headers.range || "-"} ua=${(req.headers["user-agent"] || "-").slice(0, 30)} from=${clientIp}`
  );
  res.on("finish", () => {
    console.log(`[res] ${req.method} ${path} -> ${res.statusCode} (${Date.now() - t0}ms)`);
  });
  res.on("close", () => {
    if (!res.writableFinished) {
      console.log(`[res] ${req.method} ${path} -> ABORTED after ${Date.now() - t0}ms`);
    }
  });

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
        // 版本号：改过解密逻辑就 +1，方便确认服务器跑的是哪版
        version: SERVER_VERSION,
        time: new Date().toISOString(),
        auth: ACCESS_TOKEN ? "required" : "open",
        features: {
          // 这三项必须全为 true，否则就是旧代码
          blankSenc: true,        // 清除 senc/saiz/saio（修黑屏的关键）
          fullLengthNoRange: true, // 无 Range 时返回 200 + 完整长度
          cencDecrypt: true,
          danmaku: true,
        },
        endpoints: ["/api/detail", "/api/episodes", "/api/play", "/api/stream", "/api/download"],
      });
      return;
    }

    if (!authorized(req, url)) {
      sendJSON(res, 401, { ok: false, error: "token 无效" });
      return;
    }

    // --- 发现页：真实短剧列表
    if (path === "/api/discover") {
      const tab = Number(url.searchParams.get("tab") || 201);
      const offset = Number(url.searchParams.get("offset") || 0);
      const count = Math.min(Number(url.searchParams.get("count") || 20), 20);
      const key = `d:${tab}:${offset}:${count}`;
      const hit = discoverCache.get(key);
      let items;
      if (hit && Date.now() - hit.time < CACHE_TTL) {
        items = hit.value;
      } else {
        items = await discover(tab, offset, count);
        discoverCache.set(key, { time: Date.now(), value: items });
      }
      sendJSON(res, 200, {
        ok: true,
        tab,
        offset,
        count: items.length,
        has_more: items.length >= 6,
        items: items.map((it) => ({
          series_id: it.seriesId,
          item_id: it.itemId,
          title: it.title || "",
          cover: it.cover || "",
          intro: it.intro || "",
          tags: it.tags || [],
          episode_text: it.episodeText || "",
          episode_count: it.episodeCount || 0,
          free_episodes: it.freeEpisodes || 0,
          play_count: it.playCount || 0,
          followed_count: it.followedCount || 0,
          detail_url: `/api/detail?series_id=${it.seriesId}`,
        })),
      });
      return;
    }

    // --- 剧集详情
    if (path === "/api/detail") {
      const sid = seen(url.searchParams.get("series_id"));
      if (!sid) return sendJSON(res, 400, { ok: false, error: "缺少 series_id" });
      const info = await seriesVids(sid);
      // 预热第一集：iOS 端拿完 detail 就会播第 1 集，
      // 提前解析好，避免 AVPlayer 等待超时（黑屏 + 00:00）。
      if (info.vids.length) warmStream(info.vids[0]).catch(() => {});
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
      // 预热：客户端拿到 play 信息后紧接着就会请求 /api/stream，
      // 这里把缓存打好，避免 AVPlayer 等 2 秒解析超时。
      warmStream(vid).catch(() => {});
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

    // --- 弹幕（整集，一次给全）
    if (path === "/api/danmaku") {
      const vid = seen(url.searchParams.get("vid"));
      const seriesId = seen(url.searchParams.get("series_id"));
      if (!vid) return sendJSON(res, 400, { ok: false, error: "缺少 vid" });
      if (!seriesId) return sendJSON(res, 400, { ok: false, error: "缺少 series_id" });

      // 单窗口模式（带 cursor 或 offset_ms）
      const cursor = url.searchParams.get("cursor") || "";
      const offsetParam = url.searchParams.get("offset_ms");
      const singleWindow = Boolean(cursor) || offsetParam !== null;

      const s = await resolveStream(vid);
      const durationMs = Math.round(Number(s.duration || 0) * 1000);

      if (singleWindow) {
        const offsetMs = Number(offsetParam || 0);
        const key = `dm:${vid}:${cursor}:${offsetMs}`;
        const hit = danmakuCache.get(key);
        let page;
        if (hit && Date.now() - hit.time < CACHE_TTL) {
          page = hit.value;
        } else {
          page = await fetchDanmakuRetry(vid, seriesId, durationMs, cursor, offsetMs);
          danmakuCache.set(key, { time: Date.now(), value: page });
        }
        sendJSON(res, 200, {
          ok: true, vid,
          count: page.items.length,
          total: page.count,
          has_more: page.has_more,
          next_cursor: page.cursor,
          next_offset_ms: page.next_offset_ms,
          items: page.items,
        });
        return;
      }

      // 整集模式：遍历时间窗，去重排序后一次返回
      const allKey = `dmall:${vid}`;
      const hitAll = danmakuCache.get(allKey);
      if (hitAll && Date.now() - hitAll.time < CACHE_TTL) {
        sendJSON(res, 200, hitAll.value);
        return;
      }

      const totalSec = Math.max(Math.round(durationMs / 1000), 120);
      const step = 30;
      const merged = new Map();
      let reportedTotal = 0;
      let failures = 0;

      const offsets = [];
      for (let off = 0; off <= totalSec + step; off += step) offsets.push(off);

      // 每批 4 个窗口并行（上游对同一 vid 有节流，靠 enqueueDanmaku 串行化）
      const BATCH = 4;
      for (let i = 0; i < offsets.length; i += BATCH) {
        const batch = offsets.slice(i, i + BATCH);
        await Promise.all(batch.map(async (off) => {
          try {
            let page = await fetchDanmakuRetry(vid, seriesId, durationMs, "", off * 1000);
            if (!reportedTotal) reportedTotal = page.count || 0;
            for (const it of page.items) merged.set(it.id, it);

            let cur = page.cursor || "";
            let guard = 0;
            while (page.has_more && cur && guard < 6) {
              guard += 1;
              const more = await fetchDanmakuRetry(vid, seriesId, durationMs, cur, off * 1000);
              for (const it of more.items) merged.set(it.id, it);
              if (more.cursor === cur) break;
              cur = more.cursor || "";
              page = more;
            }
          } catch {
            failures += 1;
          }
        }));
      }

      const items = [...merged.values()].sort((a, b) => a.offset_ms - b.offset_ms);
      const payload = {
        ok: true,
        vid,
        count: items.length,
        total: Math.max(reportedTotal, items.length),
        has_more: false,
        next_cursor: "",
        next_offset_ms: 0,
        windows_failed: failures,
        items,
      };
      danmakuCache.set(allKey, { time: Date.now(), value: payload });
      sendJSON(res, 200, payload);
      return;
    }

    // --- 流式播放（AVPlayer 直连）
    if (path === "/api/stream") {
      const vid = seen(url.searchParams.get("vid"));
      if (!vid) return sendJSON(res, 400, { ok: false, error: "缺少 vid" });
      const s = await resolveStream(vid);
      const total = s.total;

      // HEAD：只回头，绝不能走下面的解密流程。
      // 之前 HEAD 命中了「无 Range → 分块发整集」分支，
      // 要下载并解密整个文件才返回，AVPlayer 等不及就放弃了（黑屏 + 00:00）。
      if (req.method === "HEAD") {
        res.writeHead(200, {
          "Content-Type": "video/mp4",
          "Content-Length": total,
          "Accept-Ranges": "bytes",
          "Access-Control-Allow-Origin": "*",
          "Cache-Control": "no-store",
        });
        res.end();
        return;
      }

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
      //
      // 关键：客户端明确要的区间必须完整满足。
      // AVPlayer 会发 `bytes=0-<total-1>` 想一次拿全；如果这里私自截断，
      // Content-Range 与请求不一致，它会判定数据不全然后卡住（黑屏 + 00:00）。
      // 只有客户端要的范围超过 SEG_SIZE 且不是「从 0 开始要全片」时才分片。
      const [start, rawEnd] = range;
      const wantLen = rawEnd - start + 1;
      const end = wantLen <= SEG_SIZE
        ? Math.min(rawEnd, total - 1)
        : Math.min(rawEnd, start + SEG_SIZE - 1, total - 1);

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
