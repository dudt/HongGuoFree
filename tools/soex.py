#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""列出 ELF .so 的动态符号（导出/导入）。"""
from __future__ import annotations

import struct
import sys
from pathlib import Path


def main() -> int:
    b = Path(sys.argv[1]).read_bytes()
    e_shoff, = struct.unpack_from("<Q", b, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", b, 0x3A)
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * 64
        name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from(
            "<IIQQQQIIQQ", b, off)
        secs.append(dict(name=name, typ=typ, addr=addr, offset=offset, size=size,
                         link=link, entsize=entsize))
    shstr = secs[e_shstrndx]

    def sname(o: int) -> str:
        e = b.index(b"\x00", shstr["offset"] + o)
        return b[shstr["offset"] + o:e].decode("utf-8", "replace")

    for s in secs:
        s["sname"] = sname(s["name"])
    dynsym = next((s for s in secs if s["sname"] == ".dynsym"), None)
    dynstr = next((s for s in secs if s["sname"] == ".dynstr"), None)
    if not (dynsym and dynstr):
        print("no .dynsym", file=sys.stderr)
        return 1
    n = dynsym["size"] // 24
    want = sys.argv[2] if len(sys.argv) > 2 else ""
    exported = []
    imported = []
    for i in range(n):
        o = dynsym["offset"] + i * 24
        nm, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", b, o)
        e = b.index(b"\x00", dynstr["offset"] + nm)
        name = b[dynstr["offset"] + nm:e].decode("utf-8", "replace")
        if not name:
            continue
        kind = info & 0xF
        if shndx == 0:
            imported.append((name, kind))
        elif kind in (1, 2, 6, 10):
            exported.append((name, value, size, kind))
    print(f"=== exported ({len(exported)}) ===")
    for name, value, size, kind in exported:
        if want and want.lower() not in name.lower():
            continue
        print(f"  0x{value:08x} size={size:<8} kind={kind}  {name}")
    print(f"=== imported ({len(imported)}) ===")
    for name, kind in imported:
        if want and want.lower() not in name.lower():
            continue
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
