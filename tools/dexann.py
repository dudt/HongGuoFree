#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解析 DEX 注解：把 Retrofit 风格接口（@GET/@POST/@Field/@Operation…）还原成接口表。

用法：
    python tools/dexann.py <dexdir> [--filter SUBSTR] [--csv OUT]
"""
from __future__ import annotations

import argparse
import csv
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dexref import Dex, load_dir  # noqa: E402

VALUE_BYTE = 0x00
VALUE_SHORT = 0x02
VALUE_CHAR = 0x03
VALUE_INT = 0x04
VALUE_LONG = 0x06
VALUE_FLOAT = 0x10
VALUE_DOUBLE = 0x11
VALUE_METHOD_TYPE = 0x15
VALUE_METHOD_HANDLE = 0x16
VALUE_STRING = 0x17
VALUE_TYPE = 0x18
VALUE_FIELD = 0x19
VALUE_METHOD = 0x1A
VALUE_ENUM = 0x1B
VALUE_ARRAY = 0x1C
VALUE_ANNOTATION = 0x1D
VALUE_NULL = 0x1E
VALUE_BOOLEAN = 0x1F


def read_encoded_value(dex: Dex, off: int):
    d = dex.data
    b = d[off]
    off += 1
    vtype = b & 0x1F
    varg = b >> 5
    if vtype in (VALUE_BYTE, VALUE_SHORT, VALUE_CHAR, VALUE_INT, VALUE_LONG):
        raw = int.from_bytes(d[off:off + varg + 1], "little", signed=True)
        return raw, off + varg + 1
    if vtype in (VALUE_FLOAT, VALUE_DOUBLE):
        raw = int.from_bytes(d[off:off + varg + 1], "little", signed=False)
        return raw, off + varg + 1
    if vtype == VALUE_STRING:
        idx = int.from_bytes(d[off:off + varg + 1], "little")
        return dex.string_at(idx), off + varg + 1
    if vtype in (VALUE_TYPE, VALUE_FIELD, VALUE_METHOD, VALUE_ENUM, VALUE_METHOD_TYPE):
        idx = int.from_bytes(d[off:off + varg + 1], "little")
        try:
            if vtype == VALUE_TYPE:
                return dex.type_at(idx), off + varg + 1
            if vtype == VALUE_FIELD:
                c, t, n = struct.unpack_from("<HHI", d, dex.field_ids_off + idx * 8)
                return f"{dex.type_at(c)}->{dex.string_at(n)}:{dex.type_at(t)}", off + varg + 1
            if vtype == VALUE_METHOD:
                c, n, r = dex.method_at(idx)
                return f"{c}->{n}{r}", off + varg + 1
            if vtype == VALUE_ENUM:
                c, t, n = struct.unpack_from("<HHI", d, dex.field_ids_off + idx * 8)
                return f"{dex.type_at(c)}.{dex.string_at(n)}", off + varg + 1
        except Exception:
            return f"<bad idx {idx}>", off + varg + 1
    if vtype == VALUE_ARRAY:
        n, off = dex.uleb(off)
        out = []
        for _ in range(n):
            v, off = read_encoded_value(dex, off)
            out.append(v)
        return out, off
    if vtype == VALUE_ANNOTATION:
        v, off = read_encoded_annotation(dex, off)
        return v, off
    if vtype == VALUE_NULL:
        return None, off
    if vtype == VALUE_BOOLEAN:
        return bool(varg), off
    if vtype == VALUE_METHOD_HANDLE:
        idx = int.from_bytes(d[off:off + varg + 1], "little")
        return f"<method_handle {idx}>", off + varg + 1
    return f"<vtype 0x{vtype:02x}>", off + varg + 1


def read_encoded_annotation(dex: Dex, off: int) -> tuple[dict, int]:
    type_idx, off = dex.uleb(off)
    n, off = dex.uleb(off)
    elems = {}
    for _ in range(n):
        name_idx, off = dex.uleb(off)
        v, off = read_encoded_value(dex, off)
        try:
            name = dex.string_at(name_idx)
        except Exception:
            name = f"<{name_idx}>"
        elems[name] = v
    try:
        tname = dex.type_at(type_idx)
    except Exception:
        tname = f"<{type_idx}>"
    return {"type": tname, "elements": elems}, off


def read_annotation_set(dex: Dex, off: int) -> list[dict]:
    if off == 0:
        return []
    size, = struct.unpack_from("<I", dex.data, off)
    out = []
    for i in range(size):
        aoff, = struct.unpack_from("<I", dex.data, off + 4 + i * 4)
        try:
            a, _ = read_encoded_annotation(dex, aoff)
            out.append(a)
        except Exception:
            out.append({"type": "<error>", "elements": {}})
    return out


def class_annotations(dex: Dex, cdata_off: int, class_def_off: int):
    """返回 (class_anns, {method_idx: [anns]}, {field_idx: [anns]})"""
    d = dex.data
    (cidx, acc, sidx, ifaces, src, ann_off, cdata, sv) = struct.unpack_from("<IIIIIIII", d, class_def_off)
    cls = read_annotation_set(dex, ann_off)
    meth: dict[int, list] = {}
    fld: dict[int, list] = {}
    if cdata:
        sfl, infl, dml, vml = dex.class_data(cdata)
        allm = dml + vml
        if allm:
            moff, = struct.unpack_from("<I", d, cdata)
            # 需要重新走一遍拿到 methods annotations_off
            pass
    # 直接重新解析 class_data 以保留 annotations_off
    if cdata:
        off = cdata
        sf_n, off = dex.uleb(off)
        in_n, off = dex.uleb(off)
        dm_n, off = dex.uleb(off)
        vm_n, off = dex.uleb(off)
        for _ in range(sf_n):
            _diff, off = dex.uleb(off)
            _acc, off = dex.uleb(off)
        for _ in range(in_n):
            _diff, off = dex.uleb(off)
            _acc, off = dex.uleb(off)
        # 字段注解需要 field_idx 累积
        # （此处省略字段注解，接口表只关心方法）
        midx = 0
        for n, is_virtual in ((dm_n, False), (vm_n, True)):
            midx = 0
            for _ in range(n):
                diff, off = dex.uleb(off)
                _acc, off = dex.uleb(off)
                code, off = dex.uleb(off)
                aoff, off = dex.uleb(off)
                midx += diff
                anns = read_annotation_set(dex, aoff)
                if anns:
                    meth.setdefault(midx, []).extend(anns)
    return cls, meth, fld


HTTP_TYPES = {
    "Lcom/bytedance/multi/rpc/annotation/HttpMethod;",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--filter", default="")
    ap.add_argument("--csv", default="")
    a = ap.parse_args()
    dexes = load_dir(Path(a.dir))
    rows = []
    for dex in dexes:
        for i in range(dex.class_defs_size):
            cdef_off = dex.class_defs_off + i * 32
            try:
                cls_anns, meth_anns, _fld = class_annotations(dex, 0, cdef_off)
            except Exception as e:
                continue
            if not meth_anns:
                continue
            for midx, anns in meth_anns.items():
                try:
                    c, name, ret = dex.method_at(midx)
                except Exception:
                    continue
                kinds = [x["type"] for x in anns]
                path = ""
                http = ""
                fields = []
                op = ""
                for x in anns:
                    t = x["type"]
                    el = x["elements"]
                    if t in ("Lcom/bytedance/multi/rpc/annotation/Operation;",):
                        op = str(el.get("value", el.get("method", "")))
                    if t.endswith("/Field;"):
                        fields.append(el)
                    if "HttpMethod" in t:
                        http = str(el.get("value", ""))
                    if t in ("Lcom/bytedance/multi/rpc/annotation/Serializer;",):
                        pass
                # 找接口路径：注解类型里带 GET/POST 的字符串常量
                joined = " ".join(f"{k}={v}" for x in anns for k, v in x["elements"].items())
                rows.append({
                    "dex": dex.name,
                    "class": c,
                    "method": name,
                    "ret": ret,
                    "ann_types": ",".join(sorted(set(kinds))),
                    "op": op,
                    "http": http,
                    "detail": joined[:400],
                })
    if a.filter:
        f = a.filter.lower()
        rows = [r for r in rows if f in r["class"].lower() or f in r["detail"].lower()]
    for r in rows:
        print(f"{r['class']}->{r['method']}{r['ret']}")
        print(f"    ann={r['ann_types']}")
        if r["detail"]:
            print(f"    {r['detail']}")
    print(f"-- {len(rows)} annotated methods", file=sys.stderr)
    if a.csv:
        with open(a.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else ["dex"])
            w.writeheader()
            w.writerows(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
