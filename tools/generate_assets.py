#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 App 图标（Assets.xcassets/AppIcon.appiconset）与内置演示内容 sample-feed.json。

只依赖 Pillow。运行方式：
    python tools/generate_assets.py
"""
from __future__ import annotations

import json
import math
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "HongGuoFree" / "Assets.xcassets"
ICONSET = ASSETS / "AppIcon.appiconset"
RESOURCES = ROOT / "HongGuoFree" / "Resources"

# ---------------------------------------------------------------- 图标绘制

ACCENT_TOP = (255, 59, 92)
ACCENT_MID = (176, 19, 60)
BASE_DARK = (11, 11, 16)


def _lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def draw_icon(size: int = 1024) -> Image.Image:
    scale = 4  # 超采样后缩小，边缘更干净
    s = size * scale
    img = Image.new("RGB", (s, s), BASE_DARK)
    px = img.load()

    # 对角渐变背景
    top = ACCENT_TOP
    mid = ACCENT_MID
    for y in range(s):
        for x in range(s):
            t = (x / s * 0.35 + y / s * 0.65)
            if t < 0.55:
                color = _lerp(top, mid, t / 0.55)
            else:
                color = _lerp(mid, BASE_DARK, (t - 0.55) / 0.45)
            px[x, y] = color

    # 右上角柔光
    glow = Image.new("L", (s, s), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([s * 0.42, -s * 0.38, s * 1.38, s * 0.58], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.10))
    white = Image.new("RGB", (s, s), (255, 214, 205))
    img = Image.composite(white, img, glow.point(lambda v: int(v * 0.32)))

    draw = ImageDraw.Draw(img, "RGBA")

    # 圆角三角形：先画遮罩，再做「模糊 + 阈值」得到圆角
    mask = Image.new("L", (s, s), 0)
    md = ImageDraw.Draw(mask)
    cx, cy = s * 0.5, s * 0.455
    r = s * 0.245
    pts = [
        (cx - r * 0.70, cy - r),
        (cx - r * 0.70, cy + r),
        (cx + r * 1.05, cy),
    ]
    md.polygon(pts, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(s * 0.018))
    mask = mask.point(lambda v: 255 if v > 128 else 0)
    white_layer = Image.new("RGBA", (s, s), (255, 255, 255, 248))
    img.paste(white_layer, (0, 0), mask)

    draw = ImageDraw.Draw(img, "RGBA")

    # 右下角 “AD” + 斜杠：表示无广告
    badge_r = s * 0.132
    bx, by = s * 0.725, s * 0.735
    draw.ellipse([bx - badge_r, by - badge_r, bx + badge_r, by + badge_r],
                 fill=(12, 12, 18, 240), outline=(255, 255, 255, 70), width=int(s * 0.007))

    font = None
    for candidate in (
        "C:/Windows/Fonts/arialbd.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ):
        if os.path.exists(candidate):
            font = ImageFont.truetype(candidate, int(badge_r * 0.82))
            break
    if font is None:
        font = ImageFont.load_default()

    label = "AD"
    bbox = draw.textbbox((0, 0), label, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text((bx - tw / 2 - bbox[0], by - th / 2 - bbox[1] - s * 0.004),
              label, font=font, fill=(255, 255, 255, 240))

    # 斜杠（带圆头）
    line_w = int(s * 0.030)
    pad = badge_r * 0.66
    p1 = (bx - pad, by + pad)
    p2 = (bx + pad, by - pad)
    draw.line([p1, p2], fill=(255, 59, 92, 255), width=line_w)
    cap = line_w / 2
    for p in (p1, p2):
        draw.ellipse([p[0] - cap, p[1] - cap, p[0] + cap, p[1] + cap], fill=(255, 59, 92, 255))

    return img.resize((size, size), Image.LANCZOS)


ICON_SPECS = [
    ("iphone", "20x20", "2x", 40), ("iphone", "20x20", "3x", 60),
    ("iphone", "29x29", "2x", 58), ("iphone", "29x29", "3x", 87),
    ("iphone", "40x40", "2x", 80), ("iphone", "40x40", "3x", 120),
    ("iphone", "60x60", "2x", 120), ("iphone", "60x60", "3x", 180),
    ("ipad", "20x20", "1x", 20), ("ipad", "20x20", "2x", 40),
    ("ipad", "29x29", "1x", 29), ("ipad", "29x29", "2x", 58),
    ("ipad", "40x40", "1x", 40), ("ipad", "40x40", "2x", 80),
    ("ipad", "76x76", "1x", 76), ("ipad", "76x76", "2x", 152),
    ("ipad", "83.5x83.5", "2x", 167),
    ("ios-marketing", "1024x1024", "1x", 1024),
]


def write_icon_set() -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    cache: dict[int, Image.Image] = {}
    images = []
    for idiom, size, scale, px in ICON_SPECS:
        if px not in cache:
            cache[px] = draw_icon(px)
        # 每个槽位独立文件名，避免 actool 报重复文件
        name = f"icon-{idiom}-{size.replace('.', '_')}@{scale}.png"
        cache[px].save(ICONSET / name, "PNG")
        images.append({
            "filename": name,
            "idiom": idiom,
            "scale": scale,
            "size": size,
        })

    # 清掉旧命名的残留文件
    keep = {item["filename"] for item in images} | {"Contents.json"}
    for path in ICONSET.iterdir():
        if path.name not in keep:
            path.unlink()

    (ICONSET / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}},
                   ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"图标已生成：{len(images)} 个尺寸 -> {ICONSET}")


# ---------------------------------------------------------------- 颜色资源

def write_colors() -> None:
    accent_dir = ASSETS / "AccentColor.colorset"
    accent_dir.mkdir(parents=True, exist_ok=True)
    (accent_dir / "Contents.json").write_text(json.dumps({
        "colors": [{
            "color": {
                "color-space": "srgb",
                "components": {"alpha": "1.000", "blue": "0x5C", "green": "0x3B", "red": "0xFF"},
            },
            "idiom": "universal",
        }],
        "info": {"author": "xcode", "version": 1},
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    launch_dir = ASSETS / "LaunchBackground.colorset"
    launch_dir.mkdir(parents=True, exist_ok=True)
    (launch_dir / "Contents.json").write_text(json.dumps({
        "colors": [{
            "color": {
                "color-space": "srgb",
                "components": {"alpha": "1.000", "blue": "0x10", "green": "0x0B", "red": "0x0B"},
            },
            "idiom": "universal",
        }],
        "info": {"author": "xcode", "version": 1},
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    (ASSETS / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"颜色资源已生成 -> {ASSETS}")


# ---------------------------------------------------------------- 演示内容

HLS = [
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8",
    "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
    "https://test-streams.mux.dev/pts_shift/master.m3u8",
]
MP4 = [
    "https://storage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4",
    "https://storage.googleapis.com/gtv-videos-bucket/sample/SubaruOutbackOnStreetAndDirt.mp4",
]

DRAMAS = [
    {
        "id": "demo-rebirth-ceo",
        "title": "重生之我在豪门当团宠",
        "tagline": "被扫地出门的养女，一朝重生，把欺负过她的人一个个请下神坛。",
        "synopsis": "林知夏在豪门当了十八年“多余的人”，重生回被赶出家门那天。这一次，她不再讨好任何人，先把属于自己的一分不少拿回来。",
        "tags": ["重生", "逆袭", "豪门"],
        "categoryIDs": ["rebirth", "hot"],
        "playCount": 12860000,
        "rating": 9.2,
        "isFinished": True,
        "episodes": 30,
    },
    {
        "id": "demo-ceo-contract",
        "title": "总裁的契约小娇妻",
        "tagline": "一纸婚约三年为期，谁先动心谁认输。",
        "synopsis": "为了救弟弟，苏晚签下了那份荒唐的契约。三年里她努力扮演合格的“陆太太”，却在最后一晚听见他说：不许走。",
        "tags": ["总裁", "甜宠", "契约"],
        "categoryIDs": ["sweet", "hot"],
        "playCount": 9420000,
        "rating": 8.8,
        "isFinished": False,
        "episodes": 24,
    },
    {
        "id": "demo-ancient-doctor",
        "title": "神医小娘子",
        "tagline": "现代医生穿成落魄农女，一根银针救活半个县城。",
        "synopsis": "外科医生顾清穿成被退婚的农女，家里只有三亩薄田和一个病秧子弟弟。她靠一手医术从摆摊开始，最后开出了县城最大的药堂。",
        "tags": ["古装", "医术", "励志"],
        "categoryIDs": ["ancient"],
        "playCount": 7130000,
        "rating": 9.0,
        "isFinished": True,
        "episodes": 36,
    },
    {
        "id": "demo-mystery-hotel",
        "title": "深夜旅馆的第 13 号房",
        "tagline": "每个住进 13 号房的人，第二天都会忘记自己来过。",
        "synopsis": "记者程野为了查清哥哥失踪的真相，住进了那间不存在的房间。门锁落下的那一刻，他听见有人在墙里数数。",
        "tags": ["悬疑", "烧脑", "现代"],
        "categoryIDs": ["mystery"],
        "playCount": 5610000,
        "rating": 8.5,
        "isFinished": False,
        "episodes": 18,
    },
    {
        "id": "demo-sweet-campus",
        "title": "同桌，借个心",
        "tagline": "全校第一的笔记本上，只写了你的名字。",
        "synopsis": "转学第一天，夏梧就被安排坐在年级第一旁边。她以为对方高冷，直到发现他的错题本里夹满了她随手画的涂鸦。",
        "tags": ["校园", "甜宠", "青春"],
        "categoryIDs": ["sweet"],
        "playCount": 4380000,
        "rating": 8.9,
        "isFinished": True,
        "episodes": 20,
    },
    {
        "id": "demo-warrior-return",
        "title": "战神归来只想种田",
        "tagline": "打完最后一场仗，他只想回家给女儿做顿饭。",
        "synopsis": "退役战神江野回到小县城，只想安静种地养娃。可当年的仇家、现在的对手，都不肯让他如愿。",
        "tags": ["逆袭", "热血", "现代"],
        "categoryIDs": ["hot", "mystery"],
        "playCount": 3120000,
        "rating": 8.1,
        "isFinished": False,
        "episodes": 28,
    },
]


def build_feed() -> dict:
    dramas = []
    for d_index, spec in enumerate(DRAMAS):
        count = spec["episodes"]
        episodes = []
        for i in range(1, count + 1):
            use_hls = (i + d_index) % 3 == 0
            primary = HLS[(i + d_index) % len(HLS)] if use_hls else MP4[(i + d_index) % len(MP4)]
            fallback = MP4[(i + d_index + 3) % len(MP4)]
            episodes.append({
                "id": f'{spec["id"]}-{i}',
                "index": i,
                "title": f"第 {i} 集",
                "duration": 0,
                "sources": [
                    {
                        "url": primary,
                        "quality": "1080P",
                        "kind": "hls" if use_hls else "mp4",
                        "priority": 10,
                    },
                    {
                        "url": fallback,
                        "quality": "720P",
                        "kind": "mp4",
                        "priority": 5,
                    },
                ],
            })
        dramas.append({
            "id": spec["id"],
            "title": spec["title"],
            "tagline": spec["tagline"],
            "synopsis": spec["synopsis"],
            "tags": spec["tags"],
            "categoryIDs": spec["categoryIDs"],
            "coverURL": None,
            "playCount": spec["playCount"],
            "rating": spec["rating"],
            "isFinished": spec["isFinished"],
            "episodes": episodes,
        })

    return {
        "version": 1,
        "name": "本地演示内容",
        "updatedAt": "2026-01-01T00:00:00Z",
        "categories": [
            {"id": "hot", "title": "热播", "systemImage": "flame.fill"},
            {"id": "rebirth", "title": "重生", "systemImage": "arrow.triangle.2.circlepath"},
            {"id": "sweet", "title": "甜宠", "systemImage": "heart.fill"},
            {"id": "ancient", "title": "古装", "systemImage": "crown.fill"},
            {"id": "mystery", "title": "悬疑", "systemImage": "moon.stars.fill"},
        ],
        "dramas": dramas,
    }


def write_feed() -> None:
    RESOURCES.mkdir(parents=True, exist_ok=True)
    feed = build_feed()
    out = RESOURCES / "sample-feed.json"
    out.write_text(json.dumps(feed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    total = sum(len(d["episodes"]) for d in feed["dramas"])
    print(f"演示内容已生成：{len(feed['dramas'])} 部剧 / {total} 集 -> {out}")


if __name__ == "__main__":
    write_icon_set()
    write_colors()
    write_feed()
