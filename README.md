# 红果免广告（HongGuoFree）

一个 **纯短剧、零广告** 的 iOS 播放器外壳：没有开屏广告、没有中插广告、没有「再看 30 秒」的倒计时。

> ⚠️ 先说清楚：这个 App **不抓取、不破解、不分发** 红果短剧（或任何平台）的视频。它只是一个播放器 + 内容源协议，
> 默认内置的 6 部「剧」是演示数据，播放的是 Apple / Google 的公开测试流（BigBuckBunny 等），只用来验证界面和播放链路。
> 想看你自己的内容，需要在「我的 → 内容源」里填入**你自己有版权或已获授权**的 JSON 接口。详见 [免责声明](#免责声明)。

---

## 目录

- [它能做什么](#它能做什么)
- [能不能真的「复刻红果」](#能不能真的复刻红果)
- [项目结构](#项目结构)
- [方式 A：用 GitHub Actions 云端编译 IPA（推荐，没有 Mac 也能用）](#方式-a用-github-actions-云端编译-ipa推荐没有-mac-也能用)
- [方式 B：用自己的证书签名（你已经买了证书，看这里）](#方式-b用自己的证书签名你已经买了证书看这里)
- [方式 C：在 Mac 上本地编译](#方式-c在-mac-上本地编译)
- [安装到 iPhone 的几种方式](#安装到-iphone-的几种方式)
- [内容源 JSON 协议](#内容源-json-协议)
- [功能清单](#功能清单)
- [常见问题](#常见问题)
- [免责声明](#免责声明)

---

## 它能做什么

| 能力 | 说明 |
| --- | --- |
| 竖屏短剧流 | 首页卡片流，分类筛选、播放量、评分、标签 |
| 沉浸播放 | 全屏 AVPlayer，点一下显隐控件，上滑选集、下滑退出 |
| 无广告 | 代码里**没有任何广告 SDK**，也没有倒计时逻辑，播放器直接从第一个视频帧开始 |
| 选集 / 自动连播 | 每 30 集分段，播完自动下一集，可开单集循环 |
| 断点续播 | 每 5 秒记一次进度，首页「继续观看」直接接着放 |
| 收藏 / 历史 | 追剧页两个 Tab，长按可清除单剧进度 |
| 倍速 | 0.75x ~ 2.0x，播放页和设置页都能改 |
| 自定义内容源 | 填一个返回 JSON 的 http(s) 地址即可换成自己的内容 |
| 暗色 UI | 深色主题 + 品牌红，纯 SwiftUI，无第三方依赖 |

## 能不能真的「复刻红果」？

分三层，说人话：

1. **界面和播放体验：能。** 这个工程就是干这个的，编译出来装到手机上就是一个完整的短剧 App。
2. **内容：不能靠「解析」白拿。** 红果（抖音系）的接口有签名、有设备指纹、有加密的播放地址，属于反爬/反调试措施。
   绕过它既违反用户协议，在国内也有明确的法律风险（著作权 + 技术措施规避）。我不会提供这部分代码。
3. **想真的看剧：接合法内容源。** 三条正经路子：
   - 你自己有版权/授权的短剧素材 → 搭个静态 JSON + 对象存储/自建 HLS 切片，App 直接播；
   - 用有开放接口的正版短剧/影视 API（很多聚合平台提供付费 API）；
   - 家里 NAS（Jellyfin / Emby）转成 m3u8，用本工程当客户端。

   本工程的 JSON 协议就是为这个准备的，见 [内容源 JSON 协议](#内容源-json-协议)。

---

## 项目结构

```
.
├── project.yml                    # XcodeGen 工程描述（不用手改 .xcodeproj）
├── HongGuoFree/
│   ├── Info.plist                 # Bundle 配置（含 ATS 放开，便于自建 http 源）
│   ├── App/HongGuoFreeApp.swift   # 入口 + 依赖装配 + 全局外观
│   ├── Design/Theme.swift         # 颜色/圆角/组件样式
│   ├── Models/Models.swift        # Drama / Episode / PlaySource / 进度模型
│   ├── Storage/
│   │   ├── SettingsStore.swift    # 设置 + 收藏/历史/进度落盘
│   │   └── AppStore.swift         # 内容源加载、搜索、分类、继续观看
│   ├── Player/PlayerEngine.swift  # AVPlayer 封装：连播、倍速、续播、失败重试
│   ├── Features/
│   │   ├── Feed/FeedView.swift        # 首页
│   │   ├── Detail/DramaDetailView.swift # 详情 + 选集
│   │   ├── Search/SearchView.swift     # 发现 + 热播榜
│   │   ├── Library/LibraryView.swift   # 追剧（收藏/历史）
│   │   ├── Settings/SettingsView.swift # 我的（内容源、偏好、免责声明）
│   │   └── Player/{PlayerScreen,MiniPlayerBar}.swift
│   ├── Resources/sample-feed.json # 演示内容（6 部剧 / 156 集）
│   └── Assets.xcassets            # App 图标 + 颜色
├── .github/workflows/ios-build.yml # GitHub Actions：出未签名 + 可选签名 IPA
├── scripts/make_ipa.sh            # Mac 本地一键出 IPA
└── tools/
    ├── generate_assets.py         # 重新生成图标与演示数据
    └── check.py                   # 无 Xcode 时的静态自检
```

---

## 方式 A：用 GitHub Actions 云端编译 IPA（推荐，没有 Mac 也能用）

工作流：`.github/workflows/ios-build.yml`，在 **macos-14** 上跑，产出两个 artifact：

- `HongGuoFree-unsigned-ipa` —— **未签名 IPA**（默认就有）
- `HongGuoFree-signed-ipa` —— 配了证书 secrets 才生成

### A1. 传代码

```bash
cd HONGGUO
git init
git add .
git commit -m "feat: 红果免广告 v1.0.0"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

### A2. 跑起来

推上去后自动触发；也可以手动：**仓库 → Actions → Build iOS IPA → Run workflow**。
可填两个参数：

| 参数 | 作用 |
| --- | --- |
| `bundle_id` | 覆盖 Bundle ID，默认 `com.hongguofree.app` |
| `export_method` | `development` / `ad-hoc` / `enterprise` / `app-store`，仅在配了证书时生效 |

### A3. 下载

运行结束后，页面底部 **Artifacts** → 下载 `HongGuoFree-unsigned-ipa` → 解压得到 `HongGuoFree-unsigned.ipa`。

> 未签名 IPA 不能直接双击安装，需要下面「方式 B」的自签步骤，或丢给 Sideloadly / 爱思助手。

---

## 方式 B：用自己的证书签名（你已经买了证书，看这里）

你有 `.p12` 证书 + `.mobileprovision` 描述文件，两条路：

### B1. 让 GitHub Actions 帮你签（不用 Mac）

把下面 4 个值加到 **仓库 → Settings → Secrets and variables → Actions → New repository secret**：

| Secret 名 | 怎么得到 |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | 证书 `.p12` 转 base64 |
| `P12_PASSWORD` | 导出 `.p12` 时设的密码 |
| `PROVISIONING_PROFILE_BASE64` | 描述文件 `.mobileprovision` 转 base64 |
| `KEYCHAIN_PASSWORD` | 随便设一个临时密码（CI 里的临时钥匙串用） |
| `SIGNING_IDENTITY`（可选） | 证书全名，如 `Apple Distribution: XXX (TEAMID)`；不填会自动取第一个 |

**在 Windows 上转 base64**（PowerShell，注意 `-Wrap 0` 不能省，否则带换行会解码失败）：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\cert.p12")) | Set-Content -NoNewline -Encoding ascii cert.b64
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\profile.mobileprovision")) | Set-Content -NoNewline -Encoding ascii profile.b64
Get-Content cert.b64 | Set-Clipboard      # 粘贴到 BUILD_CERTIFICATE_BASE64
Get-Content profile.b64 | Set-Clipboard   # 粘贴到 PROVISIONING_PROFILE_BASE64
```

⚠️ 描述文件里的 **Bundle ID 必须和 `bundle_id` 参数一致**（默认 `com.hongguofree.app`）。
如果你买的是 `com.yourname.hongguo`，就在 Run workflow 时把 `bundle_id` 填成一样的，或者改 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER`。

再跑一次工作流，Artifacts 里就会多出 `HongGuoFree-signed-ipa`，解压后可以直接装。

### B2. 在 Mac 上本地签

```bash
chmod +x scripts/make_ipa.sh
./scripts/make_ipa.sh          # 未签名
./scripts/make_ipa.sh --sign   # 用钥匙串里的证书签（先把 p12 双击导入钥匙串）
```

### B3. 用 Sideloadly / 爱思助手自签（不需要 Mac，不需要开发者账号）

1. Windows 装 [Sideloadly](https://sideloadly.io/)（或爱思助手）；
2. 手机用数据线连电脑，信任此电脑；
3. 把 `HongGuoFree-unsigned.ipa` 拖进去；
4. Apple ID 一栏填你自己的 Apple ID（免费账号即可，7 天有效期，最多 3 个 App）；
5. 填 `.p12` + `.mobileprovision`（有付费证书就填，能签 1 年）；
6. 点 Start，完成后手机上 **设置 → 通用 → VPN与设备管理 → 信任** 对应描述文件。

---

## 方式 C：在 Mac 上本地编译

```bash
brew install xcodegen
xcodegen generate
open HongGuoFree.xcodeproj     # 选自己的 Team，连真机，⌘R
```

只想出包不打开 Xcode：见上面 `scripts/make_ipa.sh`。

---

## 安装到 iPhone 的几种方式

| 方式 | 需要 | 有效期 | 备注 |
| --- | --- | --- | --- |
| 自签 IPA（Sideloadly / 爱思助手 / AltStore） | Apple ID 或你的 p12 | 免费 7 天 / 付费证书 1 年 | 最常用，本工程默认产物就是给这个用的 |
| 已签名 IPA + Apple Configurator | 你的企业/个人证书 | 证书有效期 | 拖进手机即可 |
| Xcode 直接运行 | Mac + 数据线 | 7 天（免费账号） | 调试最方便 |
| TestFlight / App Store | 开发者账号 + 审核 | — | 上架前必须去掉演示内容和免责声明里的"播放器外壳"定位 |

---

## 内容源 JSON 协议

App 默认读内置 `sample-feed.json`。在「我的 → 内容源」填一个 http(s) 地址后，会改为拉取你的接口。
完整示例见 `HongGuoFree/Resources/sample-feed.json`，最小结构：

```json
{
  "name": "我的内容源",
  "categories": [{ "id": "hot", "title": "热播" }],
  "dramas": [
    {
      "id": "demo-001",
      "title": "剧名",
      "tagline": "一句话卖点",
      "synopsis": "剧情简介",
      "tags": ["总裁", "甜宠"],
      "categoryIDs": ["hot"],
      "coverURL": "https://example.com/cover.jpg",
      "playCount": 12000,
      "rating": 9.1,
      "isFinished": true,
      "episodes": [
        {
          "id": "demo-001-1",
          "index": 1,
          "title": "第 1 集",
          "duration": 90,
          "sources": [
            { "url": "https://example.com/ep1.m3u8", "quality": "1080P", "kind": "hls", "priority": 10 },
            { "url": "https://example.com/ep1.mp4",  "quality": "720P",  "kind": "mp4", "priority": 5 }
          ]
        }
      ]
    }
  ]
}
```

字段说明：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `dramas[].id` / `title` / `episodes` | ✅ | 唯一 ID、剧名、分集数组 |
| `episodes[].id` / `index` / `sources` | ✅ | 集 ID、集号（从 1 开始）、播放源数组 |
| `sources[].url` | ✅ | `m3u8`（HLS）或 `mp4` 直链，`priority` 大的优先 |
| `sources[].kind` |  | `hls` / `mp4`，留空会按 URL 后缀猜 |
| `coverURL` |  | 海报；留空用剧名生成的渐变色块 |
| `categories` |  | 首页顶部分类；不填会自动从 `tags` 推导 |
| 其余字段 |  | 仅影响展示，缺失不会崩 |

> 自建服务如果是 http（非 https），Info.plist 已经放开 ATS，可以直接用；
> 但 iOS 14+ 访问局域网地址会弹「本地网络」权限，允许即可。

---

## 功能清单

- [x] 首页竖屏卡片流、分类筛选、下拉刷新
- [x] 全屏播放：点击显隐控件、15 秒快进快退、进度条拖动
- [x] 上滑打开选集、下滑退出播放
- [x] 自动连播下一集 / 单集循环 / 0.75x–2x 倍速
- [x] 断点续播（5 秒一次落盘）+ 首页「继续观看」
- [x] 收藏、观看历史、长按清除进度
- [x] 搜索 + 热播榜
- [x] 底部迷你播放条
- [x] 自定义内容源（http/https JSON）
- [x] 加载失败兜底：自动回落到内置演示数据
- [x] GitHub Actions 出未签名 / 已签名 IPA
- [x] 无任何第三方依赖、无广告 SDK、无统计 SDK

## 常见问题

**Q：编译报 `No such module 'AVKit'`？**
A：检查是否用 `xcodegen generate` 重新生成了工程；本工程没有 Pod/SPM 依赖，正常不会出现。

**Q：Actions 报 `xcodegen: command not found`？**
A：工作流里已经 `brew install xcodegen`，如果 brew 抽风，重跑一次即可。

**Q：签名后安装报 `Invalid signature` / `Unable to Install`？**
A：99% 是 Bundle ID 和描述文件不匹配。用 `security cms -D -i profile.mobileprovision | plutil -p -` 看 `application-identifier`，把 `bundle_id` 改成一致的。

**Q：装上后视频转圈？**
A：内置演示流是境外 CDN，国内网络可能很慢。换成自己的内容源就正常了。

**Q：能上架 App Store 吗？**
A：这个工程是「播放器外壳 + 演示内容」，直接提交会被 4.2（最低功能）和 5.2.3（版权）拒。要上架必须换成自有版权内容并补全隐私政策、举报入口等。

**Q：能加「解析红果链接」的功能吗？**
A：不能，也不会做。原因见上文「能不能真的复刻红果」第 2 点。

---

## 免责声明

本项目仅用于 **SwiftUI 播放器技术演示**：

- 不包含、不抓取、不破解任何第三方平台的视频内容或接口；
- 内置演示数据中的剧名/简介为虚构文案，视频为 Apple、Google 公开提供的测试流；
- 使用者需自行确保所接入的内容源拥有合法授权，并遵守所在地法律法规及各平台用户协议；
- 因使用本项目产生的任何法律责任由使用者自行承担。

如果这个项目对你有帮助，点个 Star ⭐️ 就好。
