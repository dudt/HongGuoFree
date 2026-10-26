// 带签名的评论/弹幕请求（复用作者的 x-gorgon / x-argus / x-ladon / x-helios / x-medusa）
import fs from "node:fs";
import vm from "node:vm";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.resolve(__dirname, "../hongguoTV-main/server/vendor/hongguo.cjs");
const axios = (await import("axios")).default;

const source = fs.readFileSync(SRC, "utf8");
function randId() {
  const lo = 10n ** 18n, hi = 9n * 10n ** 18n;
  return String(lo + BigInt("0x" + crypto.randomBytes(8).toString("hex")) % (hi - lo));
}
const DID = randId(), IID = randId();
const patched = source.replace(
  /const DEVICE = \{[\s\S]*?\};/,
  `const DEVICE = { iid: '${IID}', device_id: '${DID}', ac: 'wifi', channel: 'update_64', aid: '8662', app_name: 'novelread', version_code: '74232', version_name: '7.4.2.32', device_platform: 'android', os: 'android', ssmix: 'a', device_type: '25053RT47C', device_brand: 'Redmi', language: 'zh', os_api: '36', os_version: '16', manifest_version_code: '74232', resolution: '1280*2772', dpi: '520', update_version_code: '74232', host_abi: 'arm64-v8a', dragon_device_type: 'phone', pv_player: '74232', compliance_status: '0', need_personal_recommend: '1', player_so_load: '1', is_android_pad_screen: '0' };`
);
const context = vm.createContext({
  require: (n) => { if (n === "node:crypto") return crypto; throw new Error("unsupported " + n); },
  Buffer, URL, URLSearchParams, console,
  axios: axios.create({ maxContentLength: 64 * 1024 * 1024, maxBodyLength: 8 * 1024 * 1024 }),
});
const EXTRA = ["xGorgon", "helios", "buildMedusa", "be32", "le32", "pythonUrlEncode", "DEVICE", "APP_UA"];
vm.runInContext(patched + "\nthis.api={" + EXTRA.join(",") + "};", context, { timeout: 5000 });
const api = context.api;

const HOST = "https://api5-normal-sinfonlineb.fqnovel.com";

/** 带签名的 POST */
async function signedPost(pathname, bodyObj) {
  const khronos = Math.floor(Date.now() / 1000);
  const ticket = Date.now();
  const values = { ...api.DEVICE, ts: String(khronos), _rticket: String(ticket) };
  const query = api.pythonUrlEncode(values);
  const url = `${HOST}${pathname}?${query}`;
  const body = JSON.stringify(bodyObj);
  const random = Math.floor(Math.random() * 65536);

  const headers = {
    "User-Agent": api.APP_UA,
    Accept: "application/json; charset=utf-8,application/x-protobuf",
    "Content-Type": "application/json; charset=UTF-8",
    "x-ss-req-ticket": String(ticket),
    "x-tt-request-tag": "t=0;n=0",
    "sdk-version": "2",
    "passport-sdk-version": "50561",
    "x-xs-from-web": "0",
    "x-khronos": String(khronos),
    "x-ladon": api.be32(khronos).toString("base64"),
    "x-argus": api.le32(khronos).toString("base64"),
    "x-gorgon": api.xGorgon(query, Buffer.from(body), khronos, random),
    "x-helios": api.helios(khronos),
    "x-medusa": api.buildMedusa(url, Buffer.from(body), khronos),
    "x-tt-dt": "",
  };

  const resp = await axios.post(url, body, {
    headers, timeout: 25000, responseType: "text", validateStatus: () => true,
  });
  return { status: resp.status, text: String(resp.data || "") };
}

// ---- 主流程
const BASE = "http://127.0.0.1:8787";
const disc = await (await fetch(`${BASE}/api/discover?tab=201&offset=0&count=5`)).json();
const top = disc.items.reduce((a, b) => ((a.play_count || 0) > (b.play_count || 0) ? a : b));
const detail = await (await fetch(`${BASE}/api/detail?series_id=${top.series_id}`)).json();
const ep = detail.episodes[0];
const play = await (await fetch(`${BASE}/api/play?vid=${ep.vid}`)).json();
const durMs = Math.round(Number(play.duration || 0) * 1000);

console.log(`剧: ${top.title}`);
console.log(`  SID=${top.series_id}  VID=${ep.vid}  duration=${durMs}ms\n`);

function bodyFor(kind) {
  const group = kind === "series" ? top.series_id : ep.vid;
  const b = {
    group_id: group,
    group_type: kind === "series" ? 1 : 30,
    comment_type: { episode: 4, series: 2, danmaku: 20 }[kind],
    comment_source: { episode: 4, series: 1, danmaku: 601 }[kind],
    server_channel: { episode: 18, series: 46, danmaku: 1000 }[kind],
    sort: 1,
    count: kind === "danmaku" ? 90 : 20,
    cursor: "",
    aid: 8662,
    compliance_status: 0,
    business_param: { book_id: top.series_id, need_count: true },
  };
  if (kind === "episode") b.business_param.sort = "video_innerflow";
  if (kind === "danmaku") {
    b.business_param = {
      book_id: top.series_id,
      start_offset_time: 0,
      playlet_item_duration: durMs,
      need_danmaku_guide_type: [],
    };
  }
  return b;
}

// 解析弹幕：直接构造，不依赖 bodyFor
function danmakuBody(vid, sid, durMs, cursor = "", offsetMs = 0) {
  return {
    group_id: vid,
    group_type: 30,
    comment_type: 20,
    comment_source: 601,
    server_channel: 1000,
    sort: 1,
    count: 90,
    cursor: cursor,
    aid: 8662,
    compliance_status: 0,
    business_param: {
      book_id: sid,
      start_offset_time: offsetMs,
      playlet_item_duration: durMs,
      need_danmaku_guide_type: [],
    },
  };
}

const r1 = await signedPost(
  `/novel/commentapi/comment/list/${ep.vid}/v1/`,
  danmakuBody(ep.vid, top.series_id, durMs)
);
const j1 = JSON.parse(r1.text);
console.log("code:", j1.code ?? j1.Code);
const cli = (j1.data || {}).common_list_info || {};
console.log("cursor:", cli.cursor);
console.log("has_more:", cli.has_more);
const list = (j1.data || {}).data_list || [];
console.log("data_list 条数:", list.length);
if (list.length) {
  console.log("\n=== 第一条完整结构 ===");
  console.log(JSON.stringify(list[0], null, 1));
}
