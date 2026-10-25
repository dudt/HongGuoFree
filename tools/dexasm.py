#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DEX 线性反汇编（smali 风格），用于快速还原请求构造 / 签名逻辑。

用法：
    python tools/dexasm.py <dexdir> <class> <method> [--overload N] [--hex]

class 用 dex 内部描述符，如 Lcom/dragon/read/app/launch/apiboost/b;
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dexref import Dex, load_dir  # noqa: E402


def field_at(dex: Dex, idx: int):
    c, t, n = struct.unpack_from("<HHI", dex.data, dex.field_ids_off + idx * 8)
    return dex.type_at(c), dex.string_at(n), dex.type_at(t)


# ---- 常用 opcode 表（只覆盖常见指令，其余按长度跳过并打印原始字）
OPS = {
    0x00: ("nop", "10x"), 0x01: ("move", "12x"), 0x02: ("move/from16", "22x"),
    0x03: ("move/16", "32x"), 0x04: ("move-wide", "12x"), 0x05: ("move-wide/from16", "22x"),
    0x06: ("move-wide/16", "32x"), 0x07: ("move-object", "12x"),
    0x08: ("move-object/from16", "22x"), 0x09: ("move-object/16", "32x"),
    0x0A: ("move-result", "11x"), 0x0B: ("move-result-wide", "11x"),
    0x0C: ("move-result-object", "11x"), 0x0D: ("move-exception", "11x"),
    0x0E: ("return-void", "10x"), 0x0F: ("return", "11x"),
    0x10: ("return-wide", "11x"), 0x11: ("return-object", "11x"),
    0x12: ("const/4", "11n"), 0x13: ("const/16", "21s"), 0x14: ("const", "31i"),
    0x15: ("const/high16", "21h"), 0x16: ("const-wide/16", "21s"),
    0x17: ("const-wide/32", "31i"), 0x18: ("const-wide", "51l"),
    0x19: ("const-wide/high16", "21h"), 0x1A: ("const-string", "21c"),
    0x1B: ("const-string/jumbo", "31c"), 0x1C: ("const-class", "21c"),
    0x1D: ("monitor-enter", "11x"), 0x1E: ("monitor-exit", "11x"),
    0x1F: ("check-cast", "21c"), 0x20: ("instance-of", "22c"),
    0x21: ("array-length", "12x"), 0x22: ("new-instance", "21c"),
    0x23: ("new-array", "22c"), 0x24: ("filled-new-array", "35c"),
    0x25: ("filled-new-array/range", "3rc"), 0x26: ("fill-array-data", "31t"),
    0x27: ("throw", "11x"), 0x28: ("goto", "10t"), 0x29: ("goto/16", "20t"),
    0x2A: ("goto/32", "30t"), 0x2B: ("packed-switch", "31t"),
    0x2C: ("sparse-switch", "31t"),
    0x2D: ("cmpl-float", "23x"), 0x2E: ("cmpg-float", "23x"),
    0x2F: ("cmpl-double", "23x"), 0x30: ("cmpg-double", "23x"),
    0x31: ("cmp-long", "23x"),
    0x32: ("if-eq", "22t"), 0x33: ("if-ne", "22t"), 0x34: ("if-lt", "22t"),
    0x35: ("if-ge", "22t"), 0x36: ("if-gt", "22t"), 0x37: ("if-le", "22t"),
    0x38: ("if-eqz", "21t"), 0x39: ("if-nez", "21t"), 0x3A: ("if-ltz", "21t"),
    0x3B: ("if-gez", "21t"), 0x3C: ("if-gtz", "21t"), 0x3D: ("if-lez", "21t"),
    0x44: ("aget", "23x"), 0x45: ("aget-wide", "23x"), 0x46: ("aget-object", "23x"),
    0x47: ("aget-boolean", "23x"), 0x48: ("aget-byte", "23x"), 0x49: ("aget-char", "23x"),
    0x4A: ("aget-short", "23x"), 0x4B: ("aput", "23x"), 0x4C: ("aput-wide", "23x"),
    0x4D: ("aput-object", "23x"), 0x4E: ("aput-boolean", "23x"), 0x4F: ("aput-byte", "23x"),
    0x50: ("aput-char", "23x"), 0x51: ("aput-short", "23x"),
    0x52: ("iget", "22c"), 0x53: ("iget-wide", "22c"), 0x54: ("iget-object", "22c"),
    0x55: ("iget-boolean", "22c"), 0x56: ("iget-byte", "22c"), 0x57: ("iget-char", "22c"),
    0x58: ("iget-short", "22c"), 0x59: ("iput", "22c"), 0x5A: ("iput-wide", "22c"),
    0x5B: ("iput-object", "22c"), 0x5C: ("iput-boolean", "22c"), 0x5D: ("iput-byte", "22c"),
    0x5E: ("iput-char", "22c"), 0x5F: ("iput-short", "22c"),
    0x60: ("sget", "21c"), 0x61: ("sget-wide", "21c"), 0x62: ("sget-object", "21c"),
    0x63: ("sget-boolean", "21c"), 0x64: ("sget-byte", "21c"), 0x65: ("sget-char", "21c"),
    0x66: ("sget-short", "21c"), 0x67: ("sput", "21c"), 0x68: ("sput-wide", "21c"),
    0x69: ("sput-object", "21c"), 0x6A: ("sput-boolean", "21c"), 0x6B: ("sput-byte", "21c"),
    0x6C: ("sput-char", "21c"), 0x6D: ("sput-short", "21c"),
    0x6E: ("invoke-virtual", "35c"), 0x6F: ("invoke-super", "35c"),
    0x70: ("invoke-direct", "35c"), 0x71: ("invoke-static", "35c"),
    0x72: ("invoke-interface", "35c"),
    0x74: ("invoke-virtual/range", "3rc"), 0x75: ("invoke-super/range", "3rc"),
    0x76: ("invoke-direct/range", "3rc"), 0x77: ("invoke-static/range", "3rc"),
    0x78: ("invoke-interface/range", "3rc"),
    0x7B: ("neg-int", "12x"), 0x7C: ("not-int", "12x"), 0x7D: ("neg-long", "12x"),
    0x7E: ("not-long", "12x"), 0x7F: ("neg-float", "12x"), 0x80: ("neg-double", "12x"),
    0x81: ("int-to-long", "12x"), 0x82: ("int-to-float", "12x"),
    0x83: ("int-to-double", "12x"), 0x84: ("long-to-int", "12x"),
    0x85: ("long-to-float", "12x"), 0x86: ("long-to-double", "12x"),
    0x87: ("float-to-int", "12x"), 0x88: ("float-to-long", "12x"),
    0x89: ("float-to-double", "12x"), 0x8A: ("double-to-int", "12x"),
    0x8B: ("double-to-long", "12x"), 0x8C: ("double-to-float", "12x"),
    0x8D: ("int-to-byte", "12x"), 0x8E: ("int-to-char", "12x"),
    0x8F: ("int-to-short", "12x"),
}
for i, nm in enumerate(["add", "sub", "mul", "div", "rem", "and", "or", "xor", "shl", "shr", "ushr"]):
    OPS[0x90 + i] = (f"{nm}-int", "23x")
    OPS[0x9B + i] = (f"{nm}-long", "23x")
    OPS[0xA6 + i] = (f"{nm}-float", "23x")
    OPS[0xAB + i] = (f"{nm}-double", "23x")
for i, nm in enumerate(["add", "sub", "mul", "div", "rem", "and", "or", "xor", "shl", "shr", "ushr"]):
    OPS[0xB0 + i] = (f"{nm}-int/2addr", "12x")
    OPS[0xBB + i] = (f"{nm}-long/2addr", "12x")
    OPS[0xC6 + i] = (f"{nm}-float/2addr", "12x")
    OPS[0xCB + i] = (f"{nm}-double/2addr", "12x")
for i, nm in enumerate(["add", "rsub", "mul", "div", "rem", "and", "or", "xor"]):
    OPS[0xD0 + i] = (f"{nm}-int/lit16", "22s")
for i, nm in enumerate(["add", "rsub", "mul", "div", "rem", "and", "or", "xor"]):
    OPS[0xD8 + i] = (f"{nm}-int/lit8", "22b")
OPS[0xFA] = ("invoke-polymorphic", "45cc")
OPS[0xFB] = ("invoke-polymorphic/range", "4rcc")
OPS[0xFC] = ("invoke-custom", "35c")
OPS[0xFD] = ("invoke-custom/range", "3rc")
OPS[0xFE] = ("const-method-handle", "21c")
OPS[0xFF] = ("const-method-type", "21c")


def insn_len(dex: Dex, p: int) -> int:
    d = dex.data
    w, = struct.unpack_from("<H", d, p)
    op = w & 0xFF
    if op == 0x00:
        if w == 0x0100:
            size, = struct.unpack_from("<H", d, p + 2)
            return 4 + size * 2
        if w == 0x0200:
            size, = struct.unpack_from("<H", d, p + 2)
            return 2 + size * 4
        if w == 0x0300:
            elw, = struct.unpack_from("<H", d, p + 2)
            size, = struct.unpack_from("<I", d, p + 4)
            return 4 + (elw * size + 1) // 2
        return 1
    fmt = OPS.get(op, ("?", "10x"))[1]
    return {
        "10x": 1, "12x": 1, "11x": 1, "11n": 1, "10t": 1,
        "20t": 2, "22x": 2, "21s": 2, "21h": 2, "21c": 2, "21t": 2,
        "23x": 2, "22b": 2, "22s": 2, "22c": 2, "22t": 2,
        "32x": 3, "30t": 3, "31i": 3, "31c": 3, "31t": 3, "35c": 3, "3rc": 3,
        "45cc": 4, "4rcc": 4, "51l": 5,
    }[fmt]


def dump(dex: Dex, code_off: int):
    d = dex.data
    regs, ins, outs, tries, dbg, n = struct.unpack_from("<HHHHII", d, code_off)
    base = code_off + 16
    print(f"  registers={regs} ins={ins} outs={outs} insns={n} tries={tries}")
    i = 0
    while i < n:
        p = base + i * 2
        w, = struct.unpack_from("<H", d, p)
        op = w & 0xFF
        hi = w >> 8
        name, fmt = OPS.get(op, (f"op_{op:02x}", "10x"))
        extra = ""
        try:
            if fmt == "21c":
                idx, = struct.unpack_from("<H", d, p + 2)
                if op == 0x1A:
                    extra = f' "{dex.string_at(idx)}"'
                elif op in (0x1C,):
                    extra = f" {dex.type_at(idx)}"
                elif 0x60 <= op <= 0x6D:
                    c, nm, t = field_at(dex, idx)
                    extra = f" {c}->{nm}:{t}"
                else:
                    extra = f" #{idx}"
            elif fmt == "22c":
                idx, = struct.unpack_from("<H", d, p + 2)
                if 0x52 <= op <= 0x5F:
                    c, nm, t = field_at(dex, idx)
                    extra = f" {c}->{nm}:{t}"
                else:
                    extra = f" {dex.type_at(idx)}"
            elif fmt == "31c":
                idx, = struct.unpack_from("<I", d, p + 2)
                extra = f' "{dex.string_at(idx)}"' if op == 0x1B else f" #{idx}"
            elif fmt in ("35c", "3rc"):
                if fmt == "35c":
                    idx, = struct.unpack_from("<H", d, p + 2)
                    cnt = hi >> 4
                    regs_list = [w >> 12] + [(w >> 8) & 0xF] + [(w >> 4) & 0xF] + [w & 0xF]
                    extra = f" {{{', '.join('v%d' % r for r in regs_list[:cnt])}}}"
                else:
                    idx, = struct.unpack_from("<H", d, p + 2)
                    cnt = hi
                    first, = struct.unpack_from("<H", d, p + 4)
                    extra = f" {{v{first}..v{first + cnt - 1}}}"
                if idx < dex.method_ids_size:
                    c, nm, r = dex.method_at(idx)
                    extra += f" {c}->{nm}{r}"
                else:
                    extra += f" #m{idx}"
            elif fmt == "31t":
                tgt, = struct.unpack_from("<i", d, p + 2)
                extra = f" -> {i + tgt:+d}"
            elif fmt == "21t":
                tgt, = struct.unpack_from("<h", d, p + 2)
                extra = f" -> {i + tgt:+d}"
            elif fmt == "22t":
                tgt, = struct.unpack_from("<h", d, p + 2)
                extra = f" -> {i + tgt:+d}"
            elif fmt == "22b":
                v, = struct.unpack_from("<b", d, p + 2)
                extra = f" #{v}"
            elif fmt == "22s":
                v, = struct.unpack_from("<h", d, p + 2)
                extra = f" #{v}"
            elif fmt == "21s":
                v, = struct.unpack_from("<h", d, p + 2)
                extra = f" #{v}"
            elif fmt == "11n":
                extra = f" #{hi if hi < 8 else hi - 16}"
            elif fmt == "31i":
                v, = struct.unpack_from("<i", d, p + 2)
                extra = f" #{v} (0x{v & 0xFFFFFFFF:x})"
            elif fmt == "51l":
                v, = struct.unpack_from("<q", d, p + 2)
                extra = f" #{v} (0x{v & 0xFFFFFFFFFFFFFFFF:x})"
            elif fmt == "21h":
                v, = struct.unpack_from("<h", d, p + 2)
                extra = f" #0x{v & 0xFFFF:x}"
            elif fmt == "30t":
                tgt, = struct.unpack_from("<i", d, p + 2)
                extra = f" -> {i + tgt:+d}"
        except Exception as e:      # pragma: no cover
            extra = f" <decode error {e}>"
        print(f"  {i:6d}: {name:22s} {hi:3d}{extra}")
        i += insn_len(dex, p)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("cls")
    ap.add_argument("method")
    ap.add_argument("--overload", type=int, default=0)
    a = ap.parse_args()
    dexes = load_dir(Path(a.dir))
    want = a.cls if a.cls.startswith("L") else "L" + a.cls.replace(".", "/") + ";"
    found = 0
    for dex in dexes:
        for ctype, sup, src, cdata_off in dex.class_defs():
            if ctype != want or not cdata_off:
                continue
            _sf, _inf, dml, vml = dex.class_data(cdata_off)
            hits = []
            for kind, mlist in (("direct", dml), ("virtual", vml)):
                for midx, acc, code in mlist:
                    _c, nm, ret = dex.method_at(midx)
                    if nm == a.method:
                        hits.append((kind, nm, ret, code, acc))
            if not hits:
                continue
            if a.overload >= len(hits):
                print(f"only {len(hits)} overloads", file=sys.stderr)
                return 2
            kind, nm, ret, code, acc = hits[a.overload]
            print(f"### {dex.name}  {ctype}->{nm}{ret}  [{kind}] acc=0x{acc:x} code=0x{code:x}")
            if code:
                dump(dex, code)
            found += 1
    if not found:
        print("method not found", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
