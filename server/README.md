# 红果解析服务

单文件 Node.js 服务，把红果短剧变成 iOS/浏览器能直接播的普通 MP4。

## 它做什么

```
红果 App 接口(multi_video_model)  →  1080P CDN 地址 + CENC 内容密钥
        ↓
   逐样本 AES-128-CTR 解密（服务端做）
        ↓
   HTTP Range 输出明文 MP4  →  AVPlayer / <video> 直接播
```

iOS 端只需要把 `/api/stream?vid=xxx` 当普通视频 URL 用，**没有任何解密逻辑**。

## 部署

### 1. 最低要求

- Node.js ≥ 18（需要原生 `fetch`）
- 一个能出网的机器（能访问 `api5-normal-sinfonlineb.fqnovel.com` 和 CDN）

### 2. 直接跑

```bash
node server/hongguo-server.mjs
# 红果解析服务已启动: http://0.0.0.0:8787
```

### 3. 带参数

```bash
PORT=3000 HOST=0.0.0.0 ACCESS_TOKEN=your-secret node server/hongguo-server.mjs
```

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `8787` | 监听端口 |
| `HOST` | `0.0.0.0` | 监听地址 |
| `ACCESS_TOKEN` | 空 | 设了之后所有接口要带 `?token=xxx` 或 `X-Auth-Token` |

### 4. systemd（Linux 长驻）

```ini
# /etc/systemd/system/hongguo.service
[Unit]
Description=Hongguo Resolver
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/hongguo
ExecStart=/usr/bin/node /opt/hongguo/server/hongguo-server.mjs
Environment=PORT=8787
Environment=ACCESS_TOKEN=changeme
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now hongguo
sudo systemctl status hongguo
```

### 5. Docker

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY server/hongguo-server.mjs ./server/
EXPOSE 8787
CMD ["node", "server/hongguo-server.mjs"]
```

```bash
docker build -t hongguo .
docker run -d -p 8787:8787 -e ACCESS_TOKEN=changeme hongguo
```

### 6. 公网访问建议

- 套 Nginx / Caddy 上 HTTPS（iOS 的 ATS 对明文 http 有要求，但本 App 已放开）
- 一定要设 `ACCESS_TOKEN`，否则任何人都能白嫖你的带宽
- 加简单限流，避免被刷

```nginx
location / {
    proxy_pass http://127.0.0.1:8787;
    proxy_set_header Host $host;
    proxy_buffering off;           # 流式必需
    proxy_read_timeout 300s;
}
```

## 接口

| 接口 | 说明 |
|---|---|
| `GET /` | 健康检查 |
| `GET /api/detail?series_id=<id>` | 剧集详情 + 分集清单 |
| `GET /api/episodes?series_id=<id>` | 只要 vid 列表 |
| `GET /api/play?vid=<vid>` | 单集信息（质量/CENC/密钥/总字节） |
| `GET /api/stream?vid=<vid>` | **流式播放**（支持 Range，AVPlayer 直连） |
| `GET /api/download?vid=<vid>` | 整集下载（完整 MP4） |

### 示例

```bash
# 拿分集清单
curl "http://127.0.0.1:8787/api/detail?series_id=7674087569709091865"

# 单集信息
curl "http://127.0.0.1:8787/api/play?vid=7674093407425285145"
# {"ok":true,"quality":"1080P","encrypted":true,"total_bytes":6614469,
#  "duration":94.28,"cenc_key_hex":"238ebe...","stream_url":"/api/stream?vid=..."}

# 下载整集
curl -o ep1.mp4 "http://127.0.0.1:8787/api/download?vid=7674093407425285145"

# 直接播（浏览器 / VLC / AVPlayer）
open "http://127.0.0.1:8787/api/stream?vid=7674093407425285145"
```

## iOS 接入

App 里「我的 → 解析服务」填地址（如 `http://192.168.1.10:8787`），
红果详情页就会多出一个「全集播放（1080P · 解析服务）」按钮。

需要 Token 时一并填进口令框。

## 关键实现要点（改代码前必读）

### 1. 签名是摆设，别浪费时间

红果的 `x-gorgon` / `x-argus` / `x-ladon` / `x-helios` / `x-medusa` **全都不校验**。实测：

```
真签名                     → code=0
全部换成随机字符串          → code=0
完全不带任何签名头          → code=0
```

所以这个服务一行签名代码都没有。

### 2. 唯一的门槛是 device_id

```
复用固定 device_id  → 100001 参数错误（被服务端标记）
每次随机 device_id  → code=0
```

服务里 `freshDevice()` 每次调用都生成新的 19 位随机 ID。**不要改成常量，也不要缓存。**

### 3. 请求体的两个魔数

```js
{
  biz_param: { video_platform: 1024 },   // 不是 0~11
  mixed_video_id_map: { "1004": [vid] }  // key 必须是 "1004"
}
```

改错任何一个都会得到 `video platform invalid, param:0`。

### 4. CENC 解密是逐样本的

不能对整段做一次 AES-CTR —— 每个样本有自己的 IV（在 `saiz`/`saio` 指向的辅助数据里），
必须按样本边界切开、各自 derive counter。

服务里 `parseTrack()` → `buildSamples()` → `decryptPartial()` 三件套。

### 5. 头部要「去加密标记」

AVPlayer 看到 `encv`/`enca` 会尝试走 DRM。所以 `prepareCencHeader()` 会把：

- `encv` → `hvc1`
- `enca` → `mp4a`
- `sinf` → `free`（清零）

只改头部，样本数据由 `decryptPartial` 处理。

## 已知限制

- **单进程内存**：CENC 样本表缓存在内存里，一部 600 集的剧如果全拉一遍会占不少。默认 TTL 5 分钟。
- **无并发控制**：多个客户端同时请求同一集会重复解析。生产环境建议加 Redis 或简单的 in-flight 去重。
- **CDN 地址会过期**：`url_expire` 通常 1~2 小时，缓存 TTL 设的是 5 分钟，足够安全。
- **`/api/download` 是全量缓冲**：大文件会占内存。要省内存可以改成边下边发的纯流式。

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `110001 未知异常` | device_id 被标记 | 服务已自动随机，若仍出现说明 IP 被限流，等一会儿 |
| `100001 video platform invalid` | 请求体字段错 | 检查 `video_platform: 1024` 和 `mixed_video_id_map` |
| `video_model HTTP 404` | 路径打错 | 确认 `/novel/player/multi_video_model/v1/` |
| 播放黑屏但 206 正常 | 头部没去加密标记 | 检查 `prepareCencHeader` 是否被调用 |
| 声音正常画面花 | CENC 样本表错位 | 检查 `parseTrack` 的 `saiz`/`saio` 解析 |
