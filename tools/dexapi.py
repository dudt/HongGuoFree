#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""定向解析：给定类名，dump 其方法注解（Retrofit 风格接口路径、参数注解）。

用法：
    python tools/dexapi.py <dexdir> <class-substring> [<class-substring> ...]
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dexref import Dex, load_dir  # noqa: E402
from dexann import read_annotation_set  # noqa: E402


def dump_class(dex: Dex, i: int) -> None:
    d = dex.data
    off = dex.class_defs_off + i * 32
    (cidx, acc, sidx, ifaces, src, ann_off, cdata, sv) = struct.unpack_from("<IIIIIIII", d, off)
    cls = dex.type_at(cidx)
    sup = dex.type_at(sidx) if sidx != 0xFFFFFFFF else None
    print(f"### {dex.name}  {cls}   super={sup}")
    try:
        cls_anns = read_annotation_set(dex, ann_off)
    except Exception:
        cls_anns = []
    for a in cls_anns:
        print(f"  @class {a['type']} {a['elements']}")
    if not cdata:
        return
    o = cdata
    sf_n, o = dex.uleb(o)
    in_n, o = dex.uleb(o)
    dm_n, o = dex.uleb(o)
    vm_n, o = dex.uleb(o)
    fidx = 0
    for _ in range(sf_n):
        diff, o = dex.uleb(o)
        _a, o = dex.uleb(o)
        fidx += diff
    fidx = 0
    for _ in range(in_n):
        diff, o = dex.uleb(o)
        _a, o = dex.uleb(o)
        fidx += diff
    for count in (dm_n, vm_n):
        midx = 0
        for _ in range(count):
            diff, o = dex.uleb(o)
            macc, o = dex.uleb(o)
            code, o = dex.uleb(o)
            aoff, o = dex.uleb(o)
            midx += diff
            try:
                c, name, ret = dex.method_at(midx)
            except Exception:
                continue
            anns = []
            try:
                anns = read_annotation_set(dex, aoff)
            except Exception:
                pass
            if anns:
                print(f"  -> {name}{ret}  code=0x{code:x}")
                for a in anns:
                    print(f"       @{a['type']}  {a['elements']}")


def main() -> int:
    dexdir, needles = sys.argv[1], [n.lower() for n in sys.argv[2:]]
    dexes = load_dir(Path(dexdir))
    n = 0
    for dex in dexes:
        for i in range(dex.class_defs_size):
            off = dex.class_defs_off + i * 32
            (cidx,) = struct.unpack_from("<I", dex.data, off)
            try:
                cls = dex.type_at(cidx)
            except Exception:
                continue
            if any(x in cls.lower() for x in needles):
                dump_class(dex, i)
                n += 1
    print(f"-- {n} classes", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
