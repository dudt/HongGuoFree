// 探测：multi_video_model 到底强制校验哪几个签名头
// 逐个移除头，看哪个会失败
import fs from "node:fs";
import vm from "node:vm";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.resolve(__dirname, "../hongguoTV-main/server/vendor/hongguo.cjs");
let axios;
try { ({ default: axios } = await import("axios")); } catch { axios = null; }
if (!axios) { console.error("need axios"); process.exit(2); }

const source = fs.readFileSync(SRC, "utf8");
function randId() {
  const lo = 10n ** 18n, hi = 9n * 10n ** 18n;
  const r = BigInt("0x" + crypto.randomBytes(8).toString("hex")) % (hi - lo);
  return String(lo + r);
}
const DID = randId(), IID = randId();
const patched = source.replace(
  /const DEVICE = \{[\s\S]*?\};/,
  `const DEVICE = { iid: '${IID}', device_id: '${DID}', ac: 'wifi', channel: 'update_64', aid: '8662', app_name: 'novelread', version_code: '74232', version_name: '7.4.2.32', device_platform: 'android', os: 'android', ssmix: 'a', device_type: '25053RT47C', device_brand: 'Redmi', language: 'zh', os_api: '36', os_version: '16', manifest_version_code: '74232', resolution: '1280*2772', dpi: '520', update_version_code: '74232', host_abi: 'arm64-v8a', dragon_device_type: 'phone', pv_player: '74232', compliance_status: '0', need_personal_recommend: '1', player_so_load: '1', is_android_pad_screen: '0' };`
);
const context = vm.createContext({
  require: (n) => { if (n === "node:crypto") return crypto; throw new Error("unsupported " + n); },
  Buffer, URL, URLSearchParams, console,
  axios: axios.create({ maxContentLength: 64*1024*1024, maxBodyLength: 8*1024*1024 }),
});
const EXTRA = ["signedVideoRequest", "VIDEO_API", "pythonUrlEncode", "branchOf", "md5", "xGorgon", "helios", "buildMedusa"];
vm.runInContext(patched + "\nthis.api={" + EXTRA.join(",") + "};", context, { timeout: 5000 });
const api = context.api;

const vid = process.argv[2];
const payload = JSON.stringify({
  biz_param: { detail_page_version: 0, device_level: 3, disable_digg_stat: false,
    need_all_video_definition: true, need_mp4_align: false,
    use_os_player: false, use_server_dns: false, video_platform: 1024 },
  mixed_video_id_map: { "1004": [String(vid)] },
});

// 构造一次完整签名
const signed = api.signedVideoRequest(payload);
const baseHeaders = { ...signed.headers };

// 逐个移除
const SIG_HEADERS = ["x-gorgon", "x-argus", "x-ladon", "x-khronos", "x-helios", "x-medusa", "x-ss-stub",
                     "x-ss-req-ticket", "x-tt-request-tag", "sdk-version", "passport-sdk-version",
                     "x-vc-bdturing-sdk-version", "x-xs-from-web", "x-tt-dt"];

async function attempt(name, headers) {
  try {
    const resp = await axios.post(signed.url, signed.body, {
      headers, timeout: 25000, responseType: "text", validateStatus: () => true,
    });
    const txt = String(resp.data || "");
    let code = "?";
    try { const j = JSON.parse(txt); code = j.Code ?? j.code; } catch { /* noop */ }
    const ok = Number(code) === 0;
    console.log(`  ${ok ? "OK  " : "FAIL"} ${name.padEnd(34)} len=${String(txt.length).padStart(6)} code=${code}`);
    return ok;
  } catch (e) {
    console.log(`  ERR  ${name.padEnd(34)} ${e.message}`);
    return false;
  }
}

console.log(`vid=${vid}  device_id=${DID}\n`);
console.log("=== 基线 ===");
await attempt("全部头", baseHeaders);

console.log("\n=== 逐个移除 ===");
for (const h of SIG_HEADERS) {
  const copy = { ...baseHeaders };
  delete copy[h];
  delete copy[h.toLowerCase()];
  for (const k of Object.keys(copy)) {
    if (k.toLowerCase() === h.toLowerCase()) { delete copy[k]; }
  }
  await attempt(`去掉 ${h}`, copy);
}

console.log("\n=== 只留最小集 ===");
await attempt("只留 gorgon+stub+khronos", {
  "User-Agent": baseHeaders["User-Agent"],
  "Content-Type": "application/json; charset=UTF-8",
  "x-gorgon": baseHeaders["x-gorgon"],
  "x-ss-stub": baseHeaders["x-ss-stub"],
  "x-khronos": baseHeaders["x-khronos"],
  "x-ss-req-ticket": baseHeaders["x-ss-req-ticket"],
});
await attempt("只留 gorgon+khronos+argus+ladon", {
  "User-Agent": baseHeaders["User-Agent"],
  "Content-Type": "application/json; charset=UTF-8",
  "x-gorgon": baseHeaders["x-gorgon"],
  "x-khronos": baseHeaders["x-khronos"],
  "x-argus": baseHeaders["x-argus"],
  "x-ladon": baseHeaders["x-ladon"],
  "x-ss-stub": baseHeaders["x-ss-stub"],
  "x-ss-req-ticket": baseHeaders["x-ss-req-ticket"],
});
