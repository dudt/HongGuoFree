#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""不依赖 jadx/apktool 的 APK 静态提取工具。

- 解析 AndroidManifest.xml（二进制 AXML）
- 从所有 classes*.dex 提取 MUTF-8 字符串（DEX string_ids 表）
- 按关键词过滤出接口路径、签名参数、DRM 相关标识

用法：
    python tools/apk_probe.py manifest  <apk>
    python tools/apk_probe.py strings   <apk> [--out DIR] [--grep PATTERN]
    python tools/apk_probe.py listing   <apk>
"""
from __future__ import annotations

import argparse
import re
import struct
import sys
import zipfile
from pathlib import Path


# ---------------------------------------------------------------- AXML

RES_STRING_POOL_TYPE = 0x0001
RES_XML_START_ELEMENT_TYPE = 0x0102
RES_XML_END_ELEMENT_TYPE = 0x0103
RES_XML_RESOURCE_MAP_TYPE = 0x0180
UTF8_FLAG = 0x00000100
TYPE_STRING = 0x03


def _read_length(data: bytes, off: int, utf8: bool) -> tuple[int, int]:
    """读 string pool 的长度（utf8 用 1-2 字节，utf16 用 2-4 字节）。"""
    if utf8:
        n = data[off]
        off += 1
        if n & 0x80:
            n = ((n & 0x7F) << 8) | data[off]
            off += 1
        return n, off
    n = struct.unpack_from("<H", data, off)[0]
    off += 2
    if n & 0x8000:
        n2 = struct.unpack_from("<H", data, off)[0]
        off += 2
        n = ((n & 0x7FFF) << 16) | n2
    return n, off


def parse_string_pool(data: bytes, start: int) -> list[str]:
    typ, header_size, size = struct.unpack_from("<HHI", data, start)
    if typ != RES_STRING_POOL_TYPE:
        return []
    count, _styles, flags, strings_start, _styles_start = struct.unpack_from("<IIIII", data, start + 8)
    utf8 = bool(flags & UTF8_FLAG)
    offsets = struct.unpack_from("<%dI" % count, data, start + header_size)
    base = start + strings_start
    out: list[str] = []
    for off in offsets:
        p = base + off
        try:
            if utf8:
                _len, p = _read_length(data, p, True)   # utf16 长度
                blen, p = _read_length(data, p, True)   # 字节长度
                raw = data[p:p + blen]
                out.append(raw.decode("utf-8", "replace"))
            else:
                slen, p = _read_length(data, p, False)
                raw = data[p:p + slen * 2]
                out.append(raw.decode("utf-16-le", "replace"))
        except Exception:
            out.append("")
    return out


def parse_axml(data: bytes) -> tuple[list[str], list[dict]]:
    """返回 (字符串池, 元素列表)。元素含 tag/attrs。"""
    pool: list[str] = []
    res_map: list[int] = []
    elements: list[dict] = []
    pos = 8  # 跳过文件头
    total = len(data)
    while pos + 8 <= total:
        typ, header_size, size = struct.unpack_from("<HHI", data, pos)
        if size <= 0 or pos + size > total:
            break
        if typ == RES_STRING_POOL_TYPE and not pool:
            pool = parse_string_pool(data, pos)
        elif typ == RES_XML_RESOURCE_MAP_TYPE:
            n = (size - header_size) // 4
            res_map = list(struct.unpack_from("<%dI" % n, data, pos + header_size))
        elif typ == RES_XML_START_ELEMENT_TYPE:
            ext = pos + header_size
            _ns, name_idx, attr_start, attr_size, attr_count = struct.unpack_from("<IIHHH", data, ext)
            tag = pool[name_idx] if name_idx < len(pool) else ""
            attrs = []
            apos = ext + attr_start
            for _ in range(attr_count):
                a_ns, a_name, a_raw, a_typed_size, _res0, a_type, a_data = struct.unpack_from(
                    "<IIIHBBI", data, apos)
                aname = pool[a_name] if a_name < len(pool) else ""
                if not aname and a_name < len(res_map):
                    aname = "res_0x%08x" % res_map[a_name]
                value = None
                if a_raw != 0xFFFFFFFF and a_raw < len(pool):
                    value = pool[a_raw]
                elif a_type == TYPE_STRING and a_data < len(pool):
                    value = pool[a_data]
                elif a_type == 0x12:      # bool
                    value = bool(a_data)
                elif a_type == 0x10:      # int dec
                    value = a_data
                elif a_type == 0x11:      # int hex
                    value = hex(a_data)
                attrs.append({"name": aname, "value": value, "type": a_type})
                apos += attr_size
            elements.append({"tag": tag, "attrs": attrs})
        pos += size
    return pool, elements


def cmd_manifest(apk: Path) -> int:
    with zipfile.ZipFile(apk) as z:
        raw = z.read("AndroidManifest.xml")
    pool, elements = parse_axml(raw)
    print("=== 元素总数: %d ===" % len(elements))

    def attr(el, name):
        for a in el["attrs"]:
            if a["name"] == name:
                return a["value"]
        return None

    for el in elements:
        tag = el["tag"]
        if tag == "manifest":
            print("package      :", attr(el, "package"))
            print("versionName  :", attr(el, "versionName"))
            print("versionCode  :", attr(el, "versionCode"))
            print("compileSdk   :", attr(el, "compileSdkVersion"))
        elif tag == "uses-permission":
            print("permission   :", attr(el, "name"))
        elif tag in ("application",):
            print("application  :", attr(el, "name"))
            print("  debuggable :", attr(el, "debuggable"))
            print("  networkSec :", attr(el, "usesCleartextTraffic"))
            print("  appComponentFactory:", attr(el, "appComponentFactory"))
        elif tag == "activity" and attr(el, "exported") is True:
            print("activity(exp):", attr(el, "name"))
    return 0


# ---------------------------------------------------------------- DEX

def dex_strings(data: bytes) -> list[str]:
    """解析 DEX string_ids，返回全部字符串（MUTF-8）。"""
    if data[:4] != b"dex\n":
        return []
    string_ids_size, string_ids_off = struct.unpack_from("<II", data, 0x38)
    if string_ids_size == 0 or string_ids_off == 0:
        return []
    if string_ids_off + string_ids_size * 4 > len(data):
        return []
    out: list[str] = []
    append = out.append
    for i in range(string_ids_size):
        (data_off,) = struct.unpack_from("<I", data, string_ids_off + i * 4)
        p = data_off
        # uleb128: utf16 length（跳过）
        while p < len(data) and data[p] & 0x80:
            p += 1
        p += 1
        end = data.find(b"\x00", p)
        if end < 0:
            continue
        append(data[p:end].decode("utf-8", "replace"))
    return out


def cmd_strings(apk: Path, out_dir: Path | None, pattern: str | None) -> int:
    with zipfile.ZipFile(apk) as z:
        dex_names = sorted(
            (n for n in z.namelist() if re.fullmatch(r"classes\d*\.dex", n)),
            key=lambda n: (len(n), n),
        )
        print("dex 文件: %d 个" % len(dex_names))
        all_strings: list[str] = []
        for name in dex_names:
            raw = z.read(name)
            ss = dex_strings(raw)
            print("  %-16s %8d 条字符串" % (name, len(ss)))
            all_strings.extend(ss)

    uniq = list(dict.fromkeys(all_strings))
    print("去重后: %d 条" % len(uniq))

    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "dex-strings.txt").write_text("\n".join(uniq), encoding="utf-8")
        print("已写入:", out_dir / "dex-strings.txt")

    if pattern:
        rx = re.compile(pattern, re.I)
        hits = [s for s in uniq if rx.search(s)]
        print("\n=== 匹配 %r：%d 条 ===" % (pattern, len(hits)))
        for s in hits[:400]:
            print(" ", s)
    return 0


def cmd_listing(apk: Path) -> int:
    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        print("=== assets（前 80）===")
        for n in [x for x in names if x.startswith("assets/")][:80]:
            print(" ", n)
        print("\n=== lib ===")
        for n in sorted(x for x in names if x.startswith("lib/")):
            print(" ", n)
        print("\n=== 其它根文件 ===")
        for n in names:
            if "/" not in n:
                print(" ", n)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["manifest", "strings", "listing"])
    ap.add_argument("apk")
    ap.add_argument("--out")
    ap.add_argument("--grep")
    args = ap.parse_args()
    apk = Path(args.apk)
    if not apk.is_file():
        print("找不到 APK:", apk)
        return 2
    if args.cmd == "manifest":
        return cmd_manifest(apk)
    if args.cmd == "strings":
        return cmd_strings(apk, Path(args.out) if args.out else None, args.grep)
    return cmd_listing(apk)


if __name__ == "__main__":
    sys.exit(main())
