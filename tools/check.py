#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""静态自检：没有 Xcode 的机器上也能先排除大部分低级错误。

检查内容：
1. Info.plist 是否是合法 plist
2. 所有 .json / .xcassets 的 Contents.json 是否合法
3. project.yml / workflow yml 的 YAML 语法（有 PyYAML 时严格校验）
4. 每个 .swift 文件的括号配对（跳过字符串与注释）
5. Swift 文件里引用的本地类型是否都有定义

运行：
    python tools/check.py
"""
from __future__ import annotations

import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ERRORS: list[str] = []
WARNINGS: list[str] = []


def fail(msg: str) -> None:
    ERRORS.append(msg)


def warn(msg: str) -> None:
    WARNINGS.append(msg)


# ---------------------------------------------------------------- 1. plist

def check_plist() -> None:
    path = ROOT / "HongGuoFree" / "Info.plist"
    try:
        with path.open("rb") as fh:
            data = plistlib.load(fh)
    except Exception as exc:  # noqa: BLE001
        fail(f"Info.plist 解析失败：{exc}")
        return
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
                "CFBundleExecutable", "UILaunchScreen"):
        if key not in data:
            fail(f"Info.plist 缺少必需键：{key}")
    print(f"  Info.plist OK（{len(data)} 个键）")


# ---------------------------------------------------------------- 2. JSON

def check_json() -> None:
    files = list(ROOT.rglob("*.json"))
    for path in files:
        if "node_modules" in path.parts:
            continue
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            fail(f"{path.relative_to(ROOT)} JSON 解析失败：{exc}")
    print(f"  JSON OK（{len(files)} 个文件）")

    feed = ROOT / "HongGuoFree" / "Resources" / "sample-feed.json"
    if feed.exists():
        payload = json.loads(feed.read_text(encoding="utf-8"))
        dramas = payload.get("dramas", [])
        if not dramas:
            fail("sample-feed.json 里没有 dramas")
        total = 0
        for drama in dramas:
            for key in ("id", "title", "episodes"):
                if key not in drama:
                    fail(f"sample-feed.json 中 {drama.get('id', '?')} 缺少 {key}")
            for episode in drama.get("episodes", []):
                total += 1
                if not episode.get("sources"):
                    fail(f"{drama.get('id')} 第 {episode.get('index')} 集没有 sources")
                for source in episode.get("sources", []):
                    if not str(source.get("url", "")).startswith(("http://", "https://")):
                        fail(f"{drama.get('id')} 第 {episode.get('index')} 集播放地址不是 http(s)")
        print(f"  sample-feed OK（{len(dramas)} 部剧 / {total} 集）")


# ---------------------------------------------------------------- 3. YAML

def check_yaml() -> None:
    files = list(ROOT.rglob("*.yml")) + list(ROOT.rglob("*.yaml"))
    try:
        import yaml  # type: ignore
    except ImportError:
        warn("未安装 PyYAML，跳过 YAML 严格校验")
        for path in files:
            text = path.read_text(encoding="utf-8")
            if "\t" in text:
                fail(f"{path.relative_to(ROOT)} 含有 Tab 字符（YAML 不允许）")
        print(f"  YAML 基础检查完成（{len(files)} 个文件，未做严格解析）")
        return

    for path in files:
        try:
            loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            fail(f"{path.relative_to(ROOT)} YAML 解析失败：{exc}")
            continue
        if not isinstance(loaded, dict):
            fail(f"{path.relative_to(ROOT)} 顶层不是字典")
            continue
        if path.name == "ios-build.yml":
            jobs = loaded.get("jobs", {})
            if "build" not in jobs:
                fail("ios-build.yml 缺少 build job")
            else:
                steps = jobs["build"].get("steps", [])
                names = [s.get("name") for s in steps if isinstance(s, dict)]
                if not any(n and "unsigned IPA" in n for n in names):
                    fail("ios-build.yml 缺少打包未签名 IPA 的步骤")
                if not any(n and "Upload unsigned IPA" == n for n in names):
                    fail("ios-build.yml 缺少上传未签名 IPA 的步骤")
                print(f"  ios-build.yml OK（{len(steps)} 个步骤）")
        if path.name == "project.yml":
            targets = loaded.get("targets", {})
            if "HongGuoFree" not in targets:
                fail("project.yml 缺少 HongGuoFree target")
            else:
                print("  project.yml OK")
    print(f"  YAML OK（{len(files)} 个文件）")


# ---------------------------------------------------------------- 4. Swift 括号

def strip_swift_noise(text: str) -> str:
    """去掉注释与字符串字面量，只留结构性字符。"""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        # 行注释
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        # 块注释（支持嵌套）
        if ch == "/" and nxt == "*":
            depth = 1
            i += 2
            while i < n and depth:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    i += 2
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue
        # 多行字符串 """
        if text.startswith('"""', i):
            i += 3
            while i < n and not text.startswith('"""', i):
                i += 1
            i += 3
            out.append('""')
            continue
        # 普通字符串
        if ch == '"':
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        # 字符/插值里的 \( ) 已在字符串处理中跳过
        out.append(ch)
        i += 1
    return "".join(out)


PAIRS = {"}": "{", "]": "[", ")": "("}


def check_swift() -> None:
    files = sorted((ROOT / "HongGuoFree").rglob("*.swift"))
    defined: set[str] = set()
    type_re = re.compile(
        r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|@\w+\s+)*"
        r"(?:struct|class|enum|protocol|extension|typealias|actor)\s+([A-Za-z_][A-Za-z0-9_]*)",
        re.MULTILINE,
    )

    for path in files:
        text = path.read_text(encoding="utf-8")
        for match in type_re.finditer(text):
            defined.add(match.group(1))

        stripped = strip_swift_noise(text)
        stack: list[tuple[str, int]] = []
        line = 1
        for ch in stripped:
            if ch == "\n":
                line += 1
            elif ch in "{[(":
                stack.append((ch, line))
            elif ch in "}])":
                if not stack:
                    fail(f"{path.relative_to(ROOT)}:{line} 多余的 '{ch}'")
                    break
                open_ch, open_line = stack.pop()
                if open_ch != PAIRS[ch]:
                    fail(f"{path.relative_to(ROOT)}:{line} '{ch}' 与第 {open_line} 行的 '{open_ch}' 不匹配")
                    break
        else:
            if stack:
                open_ch, open_line = stack[-1]
                fail(f"{path.relative_to(ROOT)}:{open_line} 的 '{open_ch}' 没有闭合")

        # import 了 Foundation/SwiftUI 之外还需要 AVKit 的文件
        if "AVPlayerLayer" in text and "import AVKit" not in text and "import AVFoundation" not in text:
            fail(f"{path.relative_to(ROOT)} 使用了 AVPlayerLayer 但没有 import AVKit/AVFoundation")

    print(f"  Swift 括号检查完成（{len(files)} 个文件）")

    # 5. 引用检查：把出现过的 "看起来像类型" 的标识符，对照已定义集合
    known_system = {
        "View", "Button", "Text", "Image", "Color", "Font", "Capsule", "Circle",
        "VStack", "HStack", "ZStack", "Spacer", "ScrollView", "LazyVStack",
        "LazyVGrid", "GridItem", "ForEach", "NavigationStack", "NavigationLink",
        "NavigationPath", "TabView", "Toggle", "Picker", "Slider", "Menu",
        "ProgressView", "AsyncImage", "GeometryReader", "RoundedRectangle",
        "LinearGradient", "Transaction", "Label", "Divider", "Group", "AnyView",
        "State", "Binding", "Environment", "EnvironmentObject", "StateObject",
        "ObservableObject", "Published", "AppStorage", "FocusState", "App",
        "Scene", "WindowGroup", "ViewModifier", "ButtonStyle", "Configuration",
        "Context", "UIViewRepresentable", "UIView", "UIColor", "UIFont",
        "UINavigationBarAppearance", "UITabBarAppearance", "UIPasteboard",
        "UIApplication", "AVPlayer", "AVPlayerItem", "AVPlayerLayer",
        "AVPlayerItemDidPlayToEndTime", "AVPlayerItemPlaybackStalled",
        "CMTime", "URLSession", "URLRequest", "HTTPURLResponse", "URL", "Data",
        "Date", "UUID", "UserDefaults", "FileManager", "JSONEncoder",
        "JSONDecoder", "NotificationCenter", "DispatchQueue", "DispatchWorkItem",
        "RunLoop", "Task", "AnyCancellable", "Set", "Array", "String", "Double",
        "Int", "Bool", "CGFloat", "NSObjectProtocol", "NSObject", "LocalizedError",
        "Error", "Codable", "Hashable", "Identifiable", "Equatable", "StringProtocol",
    }
    missing: dict[str, str] = {}
    usage_re = re.compile(r"(?<![.\w])([A-Z][A-Za-z0-9_]{2,})(?=\s*[({.]|\s*$)", re.MULTILINE)
    for path in files:
        text = strip_swift_noise(path.read_text(encoding="utf-8"))
        for name in usage_re.findall(text):
            if name in defined or name in known_system:
                continue
            missing.setdefault(name, path.relative_to(ROOT).as_posix())
    if missing:
        listing = "，".join(f"{k}({v})" for k, v in sorted(missing.items()))
        warn(f"以下大写标识符未在工程内定义（可能是系统 API，请人工确认）：{listing}")

    print(f"  工程内定义的类型：{len(defined)} 个")


# ---------------------------------------------------------------- main

def main() -> int:
    print("静态自检开始：")
    if not (ROOT / "HongGuoFree").is_dir():
        print("找不到 HongGuoFree/ 目录")
        return 2
    check_plist()
    check_json()
    check_yaml()
    check_swift()

    print()
    if WARNINGS:
        print("提示：")
        for item in WARNINGS:
            print(f"  - {item}")
    if ERRORS:
        print("发现问题：")
        for item in ERRORS:
            print(f"  ✗ {item}")
        return 1
    print("全部检查通过 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
