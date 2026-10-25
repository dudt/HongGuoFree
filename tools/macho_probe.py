#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mach-O 快速探针：不依赖 IDA，直接解析 load commands + 搜字符串。

用法：
    python tools/macho_probe.py <macho> info
    python tools/macho_probe.py <macho> find  <needle> [<needle> ...]
    python tools/macho_probe.py <macho> ctx   <needle> [radius]
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_UUID = 0x1B
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
LC_ENCRYPTION_INFO_64 = 0x2C


def parse(path: Path):
    with open(path, "rb") as f:
        head = f.read(32)
        magic = struct.unpack_from("<I", head, 0)[0]
        if magic != MH_MAGIC_64:
            raise SystemExit(f"not a 64-bit LE Mach-O: magic=0x{magic:08x}")
        cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _res = struct.unpack_from("<iiIIIII", head, 4)
        f.seek(32)
        cmds = f.read(sizeofcmds)

    segs = []
    dylibs = []
    uuid = None
    build = None
    encrypted = None
    off = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", cmds, off)
        if cmdsize == 0:
            break
        if cmd == LC_SEGMENT_64:
            name = cmds[off + 8:off + 24].rstrip(b"\x00").decode("utf-8", "replace")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", cmds, off + 24)
            maxprot, initprot, nsects, sflags = struct.unpack_from("<iiII", cmds, off + 56)
            segs.append(dict(name=name, vmaddr=vmaddr, vmsize=vmsize, fileoff=fileoff,
                             filesize=filesize, initprot=initprot, nsects=nsects))
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            noff = struct.unpack_from("<I", cmds, off + 8)[0]
            e = cmds.index(b"\x00", off + noff)
            dylibs.append(cmds[off + noff:e].decode("utf-8", "replace"))
        elif cmd == LC_UUID:
            uuid = cmds[off + 8:off + 24].hex()
        elif cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from("<III", cmds, off + 8)
            build = dict(platform=platform, minos=minos, sdk=sdk)
        elif cmd == LC_ENCRYPTION_INFO_64:
            cryptoff, cryptsize, cryptid = struct.unpack_from("<III", cmds, off + 8)
            encrypted = dict(cryptoff=cryptoff, cryptsize=cryptsize, cryptid=cryptid)
        off += cmdsize

    return dict(cputype=cputype, cpusub=cpusub, filetype=filetype, ncmds=ncmds,
                flags=flags, segs=segs, dylibs=dylibs, uuid=uuid, build=build,
                encrypted=encrypted)


def ver(v: int) -> str:
    return f"{v >> 16}.{(v >> 8) & 0xFF}.{v & 0xFF}"


def cmd_info(path: Path):
    m = parse(path)
    print(f"file      : {path}")
    print(f"size      : {path.stat().st_size:,} bytes")
    print(f"cputype   : {m['cputype']}  sub={m['cpusub']}  filetype={m['filetype']}")
    print(f"ncmds     : {m['ncmds']}   flags=0x{m['flags']:x}")
    print(f"uuid      : {m['uuid']}")
    if m["build"]:
        b = m["build"]
        print(f"build     : platform={b['platform']} minos={ver(b['minos'])} sdk={ver(b['sdk'])}")
    print(f"encrypted : {m['encrypted']}")
    print("segments  :")
    for s in m["segs"]:
        print(f"  {s['name']:16s} vm=0x{s['vmaddr']:012x} size=0x{s['vmsize']:x} "
              f"fileoff=0x{s['fileoff']:x} filesize=0x{s['filesize']:x} prot={s['initprot']}")
    print(f"dylibs    : {len(m['dylibs'])}")
    for d in m["dylibs"]:
        print("   ", d)


def cmd_find(path: Path, needles: list[str]):
    m = parse(path)
    text = next((s for s in m["segs"] if s["name"] == "__TEXT"), None)
    if not text:
        raise SystemExit("no __TEXT")
    # 只扫 __TEXT（字符串/代码都在这里），避免扫 515MB 全文件
    data = path.read_bytes()[text["fileoff"]:text["fileoff"] + text["filesize"]]
    print(f"scanning __TEXT: {len(data):,} bytes @file 0x{text['fileoff']:x} "
          f"vm 0x{text['vmaddr']:x}")
    for nd in needles:
        b = nd.encode()
        hits = []
        i = 0
        while True:
            i = data.find(b, i)
            if i < 0:
                break
            hits.append(text["vmaddr"] + i)
            i += 1
        print(f"\n{nd!r}: {len(hits)} hits")
        for h in hits[:20]:
            print(f"   0x{h:x}")


def cmd_ctx(path: Path, needle: str, radius: int = 160):
    m = parse(path)
    text = next(s for s in m["segs"] if s["name"] == "__TEXT")
    data = path.read_bytes()[text["fileoff"]:text["fileoff"] + text["filesize"]]
    b = needle.encode()
    i = 0
    n = 0
    while n < 6:
        i = data.find(b, i)
        if i < 0:
            break
        lo = max(0, i - radius)
        hi = min(len(data), i + radius)
        seg = data[lo:hi]
        printable = "".join(chr(c) if 32 <= c < 127 else "." for c in seg)
        print(f"--- 0x{text['vmaddr'] + i:x}")
        print("   ", printable)
        i += 1
        n += 1


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    p = Path(sys.argv[1])
    c = sys.argv[2]
    if c == "info":
        cmd_info(p)
    elif c == "find":
        cmd_find(p, sys.argv[3:])
    elif c == "ctx":
        cmd_ctx(p, sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 160)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
