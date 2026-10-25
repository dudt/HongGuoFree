// 关键测试：签名内容是否被真正校验？还是只要"有这些头"就行？
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
const EXTRA = ["signedVideoRequest", "VIDEO_API", "pythonUrlEncode", "branchOf", "md5", "xGorgon", "helios", "buildMedusa", "DEVICE"];
vm.runInContext(patched + "\nthis.api={" + EXTRA.join(",") + "};", context, { timeout: 5000 });
const api = context.api;

const vid = process.argv[2];
const payload = JSON.stringify({
  biz_param: { detail_page_version: 0, device_level: 3, disable_digg_stat: false,
    need_all_video_definition: true, need_mp4_align: false,
    use_os_player: false, use_server_dns: false, video_platform: 1024 },
  mixed_video_id_map: { "1004": [String(vid)] },
});

const signed = api.signedVideoRequest(payload);

async function attempt(name, headers, url = signed.url, body = signed.body) {
  try {
    const resp = await axios.post(url, body, {
      headers, timeout: 25000, responseType: "text", validateStatus: () => true,
    });
    const txt = String(resp.data || "");
    let code = "?";
    try { const j = JSON.parse(txt); code = j.Code ?? j.code; } catch { /* noop */ }
    const ok = Number(code) === 0;
    console.log(`  ${ok ? "OK  " : "FAIL"} ${name.padEnd(38)} len=${String(txt.length).padStart(6)} code=${code}`);
    return ok;
  } catch (e) {
    console.log(`  ERR  ${name.padEnd(38)} ${e.message}`);
    return false;
  }
}

const H = { ...signed.headers };
const hex = (n) => crypto.randomBytes(n).toString("hex");
const b64 = (n) => crypto.randomBytes(n).toString("base64");

console.log(`vid=${vid}\n`);

console.log("=== 基线 ===");
await attempt("真签名", H);

console.log("\n=== 篡改签名内容（保持头的存在）===");
await attempt("x-gorgon 换成随机 hex", { ...H, "x-gorgon": hex(24) });
await attempt("x-ss-stub 换随机", { ...H, "x-ss-stub": hex(16).toUpperCase() });
await attempt("x-khronos 换成旧时间戳", { ...H, "x-khronos": String(Math.floor(Date.now()/1000) - 86400) });
await attempt("x-argus/x-ladon 换随机 base64", { ...H, "x-argus": b64(4), "x-ladon": b64(4) });
await attempt("x-helios 换随机", { ...H, "x-helios": b64(48) });
await attempt("x-medusa 换随机", { ...H, "x-medusa": b64(120) });
await attempt("全部签名头都换随机", {
  ...H,
  "x-gorgon": hex(24), "x-ss-stub": hex(16).toUpperCase(),
  "x-argus": b64(4), "x-ladon": b64(4),
  "x-helios": b64(48), "x-medusa": b64(120),
});

console.log("\n=== 改 body 但不重签（签名与内容不匹配）===");
const tampered = JSON.parse(payload);
tampered.biz_param.video_platform = 1024;
const tamperedBody = JSON.stringify(tampered).replace('"1004"', '"1005"');
await attempt("body 改 key 但不重签", H, signed.url, Buffer.from(tamperedBody));

console.log("\n=== 无签名头，只带设备参数 ===");
await attempt("完全无签名头", {
  "User-Agent": H["User-Agent"],
  "Content-Type": "application/json; charset=UTF-8",
  "Accept": "application/json",
});

console.log("\n=== 换 device_id 但不重签 ===");
const otherDid = randId();
const newQ = api.pythonUrlEncode({ ...api.DEVICE, device_id: otherDid, ts: H["x-khronos"], _rticket: H["x-ss-req-ticket"] });
await attempt("device_id 与签名不符", H, `${api.VIDEO_API}?${newQ}`, signed.body);
