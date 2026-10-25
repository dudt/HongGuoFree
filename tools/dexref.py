#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DEX 交叉引用工具：找出「哪个类的哪个方法引用了某字符串/某方法」。

用法：
    python tools/dexref.py strings  <dir>  <substr> [--limit N]
    python tools/dexref.py refs     <dir>  <exact-string> [--limit N]
    python tools/dexref.py methods  <dir>  <class-substr> [--limit N]
    python tools/dexref.py code     <dir>  <class> <method> [--overload N]

只做静态解析，不执行任何代码。
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


# ------------------------------------------------------------------ reader

class Dex:
    def __init__(self, data: bytes, name: str):
        self.data = data
        self.name = name
        if data[:4] != b"dex\n":
            raise ValueError("not a dex: " + name)
        (self.string_ids_size, self.string_ids_off) = struct.unpack_from("<II", data, 0x38)
        (self.type_ids_size, self.type_ids_off) = struct.unpack_from("<II", data, 0x40)
        (self.proto_ids_size, self.proto_ids_off) = struct.unpack_from("<II", data, 0x48)
        (self.field_ids_size, self.field_ids_off) = struct.unpack_from("<II", data, 0x50)
        (self.method_ids_size, self.method_ids_off) = struct.unpack_from("<II", data, 0x58)
        (self.class_defs_size, self.class_defs_off) = struct.unpack_from("<II", data, 0x60)
        self._strings: list[str] | None = None
        self._types: list[str] | None = None

    # -- uleb / string
    def uleb(self, off: int) -> tuple[int, int]:
        d = self.data
        r = 0
        s = 0
        for _ in range(5):
            if off >= len(d):
                return r, off
            b = d[off]
            off += 1
            r |= (b & 0x7F) << s
            if not b & 0x80:
                return r, off
            s += 7
        return r, off

    def string_at(self, idx: int) -> str:
        if self._strings is not None:
            return self._strings[idx]
        (o,) = struct.unpack_from("<I", self.data, self.string_ids_off + idx * 4)
        p = o
        _, p = self.uleb(p)          # utf16 len
        e = self.data.find(b"\x00", p)
        return self.data[p:e].decode("utf-8", "replace")

    @property
    def strings(self) -> list[str]:
        if self._strings is None:
            self._strings = [self._raw_string(i) for i in range(self.string_ids_size)]
        return self._strings

    def _raw_string(self, idx: int) -> str:
        (o,) = struct.unpack_from("<I", self.data, self.string_ids_off + idx * 4)
        p = o
        _, p = self.uleb(p)
        e = self.data.find(b"\x00", p)
        return self.data[p:e].decode("utf-8", "replace")

    def type_at(self, idx: int) -> str:
        (sid,) = struct.unpack_from("<I", self.data, self.type_ids_off + idx * 4)
        return self.string_at(sid)

    @property
    def types(self) -> list[str]:
        if self._types is None:
            self._types = [self.type_at(i) for i in range(self.type_ids_size)]
        return self._types

    def method_at(self, idx: int) -> tuple[str, str, str]:
        cls_idx, proto_idx, name_idx = struct.unpack_from("<HHI", self.data, self.method_ids_off + idx * 8)
        cls = self.type_at(cls_idx)
        name = self.string_at(name_idx)
        (_shorty_idx, ret_idx) = struct.unpack_from("<II", self.data, self.proto_ids_off + proto_idx * 12)
        ret = self.type_at(ret_idx)
        return cls, name, ret

    def class_defs(self):
        """yield (class_type, superclass_type, source_file, class_data_off)"""
        for i in range(self.class_defs_size):
            base = self.class_defs_off + i * 32
            (cidx, _acc, sidx, _ifaces, src_idx, _ann, cdata_off, _sv) = struct.unpack_from(
                "<IIIIIIII", self.data, base)
            src = self.string_at(src_idx) if src_idx != 0xFFFFFFFF else None
            sup = self.type_at(sidx) if sidx != 0xFFFFFFFF else None
            yield self.type_at(cidx), sup, src, cdata_off

    def class_data(self, off: int):
        """返回 (static_fields, instance_fields, direct_methods, virtual_methods)；
        每项为 list[(name_idx, type_idx, access, code_off)]。"""
        d = self.data
        sf, off = self.uleb(off)
        inf, off = self.uleb(off)
        dm, off = self.uleb(off)
        vm, off = self.uleb(off)

        def fields(n, off):
            out = []
            idx = 0
            for _ in range(n):
                diff, off = self.uleb(off)
                acc, off = self.uleb(off)
                idx += diff
                out.append((idx, acc))
            return out, off

        def methods(n, off):
            out = []
            idx = 0
            for _ in range(n):
                diff, off = self.uleb(off)
                acc, off = self.uleb(off)
                code, off = self.uleb(off)
                idx += diff
                out.append((idx, acc, code))
            return out, off

        sfl, off = fields(sf, off)
        infl, off = fields(inf, off)
        dml, off = methods(dm, off)
        vml, off = methods(vm, off)
        return sfl, infl, dml, vml

    def code_strings(self, code_off: int) -> set[int]:
        """扫描一段 code_item 里 const-string / const-string-jumbo 引用的字符串索引。"""
        if code_off == 0:
            return set()
        d = self.data
        (regs, ins, outs, tries, _dbg, insns_size) = struct.unpack_from("<HHHHII", d, code_off)
        base = code_off + 16
        out: set[int] = set()
        i = 0
        n = insns_size
        while i < n:
            (w,) = struct.unpack_from("<H", d, base + i * 2)
            op = w & 0xFF
            if op == 0x1A:                       # const-string  (2 code units)
                (idx,) = struct.unpack_from("<H", d, base + i * 2 + 2)
                out.add(idx)
                i += 2
                continue
            if op == 0x1B:                       # const-string/jumbo (3 units)
                (idx,) = struct.unpack_from("<I", d, base + i * 2 + 2)
                out.add(idx)
                i += 3
                continue
            # 其余指令长度
            i += _insn_len(d, base + i * 2)
        return out

    def code_invoke_methods(self, code_off: int) -> set[int]:
        """扫描 code_item 里的 invoke-* 引用的 method_ids 索引。"""
        if code_off == 0:
            return set()
        d = self.data
        (_r, _i, _o, _t, _dbg, insns_size) = struct.unpack_from("<HHHHII", d, code_off)
        base = code_off + 16
        out: set[int] = set()
        i = 0
        while i < insns_size:
            (w,) = struct.unpack_from("<H", d, base + i * 2)
            op = w & 0xFF
            if op in (0x6E, 0x6F, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78):
                (idx,) = struct.unpack_from("<H", d, base + i * 2 + 2)
                out.add(idx)
            i += _insn_len(d, base + i * 2)
        return out


# 指令长度表（以 code unit 计）
def _insn_len(d: bytes, p: int) -> int:
    op = d[p]
    # 先按单字节操作码处理
    if op == 0x00:
        # nop 或 payload 伪指令
        (w,) = struct.unpack_from("<H", d, p)
        if w == 0x0100:      # packed-switch-payload
            size = struct.unpack_from("<H", d, p + 2)[0]
            return 4 + size * 2
        if w == 0x0200:      # sparse-switch-payload
            size = struct.unpack_from("<H", d, p + 2)[0]
            return 2 + size * 4
        if w == 0x0300:      # fill-array-data-payload
            elw = struct.unpack_from("<H", d, p + 2)[0]
            size = struct.unpack_from("<I", d, p + 4)[0]
            return 4 + (elw * size + 1) // 2
        return 1
    if op in (0x02, 0x05, 0x08, 0x13, 0x15, 0x16, 0x19, 0x1A, 0x1C, 0x1F, 0x20,
              0x22, 0x23, 0x29, 0xFE, 0xFF):
        return 2
    if op in (0x03, 0x06, 0x09, 0x14, 0x17, 0x1B, 0x24, 0x25, 0x26, 0x2A, 0x2B,
              0x2C, 0xFC, 0xFD):
        return 3
    if op in (0x18,):
        return 5
    if op in (0x04, 0x07, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12,
              0x1D, 0x1E, 0x21, 0x27, 0x28):
        return 1
    if op in (0xFA, 0xFB):
        return 4
    # 35c / 3rc 系列
    if 0x52 <= op <= 0x5F:
        return 3
    if 0x6E <= op <= 0x72:
        return 3
    if 0x74 <= op <= 0x78:
        return 3
    if op == 0x73:
        return 3
    if 0x90 <= op <= 0xAF:
        return 2
    if 0xB0 <= op <= 0xCF:
        return 1
    if 0xD0 <= op <= 0xD7:
        return 2
    if 0xD8 <= op <= 0xE2:
        return 2
    if 0x2D <= op <= 0x3D:
        return 2
    if 0x44 <= op <= 0x51:
        return 2
    if 0x60 <= op <= 0x6D:
        return 2
    if 0x90 <= op <= 0xAF:
        return 2
    return 1


def load_dir(root: Path) -> list[Dex]:
    out = []
    for p in sorted(root.glob("classes*.dex"), key=lambda x: (len(x.name), x.name)):
        try:
            out.append(Dex(p.read_bytes(), p.name))
        except Exception as e:      # pragma: no cover
            print("skip", p, e, file=sys.stderr)
    return out


# ------------------------------------------------------------------ commands

def cmd_strings(dexes, sub, limit):
    hits = 0
    for dex in dexes:
        for i, s in enumerate(dex.strings):
            if sub in s:
                print(f"{dex.name}\t{i}\t{s}")
                hits += 1
                if limit and hits >= limit:
                    return
    print(f"-- {hits} hits", file=sys.stderr)


def cmd_refs(dexes, exact, limit):
    total = 0
    for dex in dexes:
        target = {i for i, s in enumerate(dex.strings) if s == exact}
        if not target:
            continue
        print(f"### {dex.name}  string_ids={sorted(target)}")
        for ctype, sup, src, cdata_off in dex.class_defs():
            if not cdata_off:
                continue
            try:
                _sf, _inf, dml, vml = dex.class_data(cdata_off)
            except Exception:
                continue
            for kind, mlist in (("direct", dml), ("virtual", vml)):
                for midx, acc, code in mlist:
                    if not code:
                        continue
                    try:
                        ss = dex.code_strings(code)
                    except Exception:
                        continue
                    if ss & target:
                        c, name, ret = dex.method_at(midx)
                        print(f"  {ctype}  ->  {name} {ret}   [{kind}] code=0x{code:x}")
                        total += 1
                        if limit and total >= limit:
                            return
    print(f"-- {total} referencing methods", file=sys.stderr)


def cmd_methods(dexes, cls_sub, limit):
    total = 0
    for dex in dexes:
        for ctype, sup, src, cdata_off in dex.class_defs():
            if cls_sub not in ctype:
                continue
            print(f"### {dex.name}  {ctype}   super={sup}  src={src}")
            if not cdata_off:
                continue
            try:
                sfl, infl, dml, vml = dex.class_data(cdata_off)
            except Exception:
                continue
            for midx, acc, code in dml + vml:
                _c, name, ret = dex.method_at(midx)
                print(f"    {name}{ret}  code=0x{code:x}  acc=0x{acc:x}")
                total += 1
                if limit and total >= limit:
                    return
    print(f"-- {total} methods", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["strings", "refs", "methods"])
    ap.add_argument("dir")
    ap.add_argument("arg")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    dexes = load_dir(Path(a.dir))
    if a.cmd == "strings":
        cmd_strings(dexes, a.arg, a.limit)
    elif a.cmd == "refs":
        cmd_refs(dexes, a.arg, a.limit)
    else:
        cmd_methods(dexes, a.arg, a.limit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
