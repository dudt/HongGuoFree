// 最终验证：完全不带任何签名头，只用设备参数 + 干净 fingerprint
import crypto from "node:crypto";
import axios from "axios";

const DEVICE = {
  iid: null, device_id: null, ac: "wifi", channel: "update_64", aid: "8662",
  app_name: "novelread", version_code: "74232", version_name: "7.4.2.32",
  device_platform: "android", os: "android", ssmix: "a",
  device_type: "25053RT47C", device_brand: "Redmi", language: "zh",
  os_api: "36", os_version: "16", manifest_version_code: "74232",
  resolution: "1280*2772", dpi: "520", update_version_code: "74232",
  host_abi: "arm64-v8a", dragon_device_type: "phone", pv_player: "74232",
  compliance_status: "0", need_personal_recommend: "1",
  player_so_load: "1", is_android_pad_screen: "0",
};
const UA = "com.phoenix.read/74232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)";
const API = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/";

function randId() {
  const lo = 10n ** 18n, hi = 9n * 10n ** 18n;
  const r = BigInt("0x" + crypto.randomBytes(8).toString("hex")) % (hi - lo);
  return String(lo + r);
}
// 与作者 pythonUrlEncode 一致：encodeURIComponent + !'() 转义
function enc(v) {
  return encodeURIComponent(String(v == null ? "" : v))
    .replace(/[!'()]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}
function qs(obj) {
  return Object.entries(obj).map(([k, v]) => `${enc(k)}=${enc(v)}`).join("&");
}

const vid = process.argv[2];

async function run(label, headers, useQuery = true) {
  const dev = { ...DEVICE, device_id: randId(), iid: randId() };
  const khronos = Math.floor(Date.now() / 1000);
  const values = { ...dev };
  if (useQuery) { values.ts = String(khronos); values._rticket = String(Date.now()); }
  const url = `${API}?${qs(values)}`;
  const payload = JSON.stringify({
    biz_param: { detail_page_version: 0, device_level: 3, disable_digg_stat: false,
      need_all_video_definition: true, need_mp4_align: false,
      use_os_player: false, use_server_dns: false, video_platform: 1024 },
    mixed_video_id_map: { "1004": [String(vid)] },
  });
  try {
    const resp = await axios.post(url, payload, {
      headers: { "User-Agent": UA, "Content-Type": "application/json; charset=UTF-8", ...headers },
      timeout: 25000, responseType: "text", validateStatus: () => true,
    });
    const txt = String(resp.data || "");
    let code = "?";
    try { const j = JSON.parse(txt); code = j.Code ?? j.code; } catch { /* noop */ }
    const ok = Number(code) === 0;
    console.log(`  ${ok ? "OK  " : "FAIL"} ${label.padEnd(42)} len=${String(txt.length).padStart(6)} code=${code}`);
    return { ok, txt };
  } catch (e) {
    console.log(`  ERR  ${label.padEnd(42)} ${e.message}`);
    return { ok: false, txt: "" };
  }
}

console.log(`vid=${vid}\n=== 完全无签名头（纯设备参数）===`);
await run("无签名头 + ts/_rticket", {});
await run("无签名头 + 无 ts/_rticket", {}, false);
await run("只有一个假 x-gorgon", { "x-gorgon": "0" });
await run("只有一个假 x-ss-stub", { "x-ss-stub": "0" });

console.log("\n=== 成功时返回了什么 ===");
const { txt } = await run("再跑一次拿数据", {});
if (txt.length > 100) {
  try {
    const j = JSON.parse(txt);
    const key = Object.keys(j.data || {})[0];
    const entry = j.data[key];
    const model = typeof entry.video_model === "string" ? JSON.parse(entry.video_model) : entry.video_model;
    console.log("  video_id    :", model.video_id);
    console.log("  fallback_api:", String(model.fallback_api?.fallback_api || model.fallback_api).slice(0, 110));
    console.log("  url_expire  :", model.url_expire);
  } catch (e) {
    console.log("  parse err:", e.message);
  }
}
