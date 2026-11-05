#!/usr/bin/env python3
"""Check whether a prebuilt .ko can load on a kernel you just built.

usage: check_module.py MODULE.ko Module.symvers

Reads the module's undefined symbols and its __versions CRC table and compares
them with the exports in Module.symvers.  Prints one line per problem and exits
1 if the module would be rejected (unknown symbol, CRC mismatch, GPL-only).
"""
import struct
import sys


def parse_elf(path):
    d = open(path, "rb").read()
    if d[:4] != b"\x7fELF" or d[4] != 2 or d[5] != 1:
        sys.exit("%s: not a 64-bit little-endian ELF" % path)
    shoff = struct.unpack_from("<Q", d, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    secs = []
    for i in range(shnum):
        o = shoff + i * shentsize
        name, typ, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack_from("<IIQQQQIIQQ", d, o)
        secs.append({"name": name, "type": typ, "off": off, "size": size, "link": link})
    shstr = secs[shstrndx]["off"]
    for s in secs:
        e = d.index(b"\0", shstr + s["name"])
        s["sname"] = d[shstr + s["name"]:e].decode()
    return d, secs


def cstr(d, off):
    return d[off:d.index(b"\0", off)].decode(errors="replace")


def undefined_symbols(d, secs):
    out = []
    for s in secs:
        if s["type"] != 2:  # SHT_SYMTAB
            continue
        stroff = secs[s["link"]]["off"]
        for j in range(1, s["size"] // 24):
            st_name, st_info, _o, st_shndx, _v, _z = struct.unpack_from(
                "<IBBHQQ", d, s["off"] + j * 24)
            if st_shndx == 0 and st_name and (st_info >> 4) != 2:  # undefined, not weak
                out.append(cstr(d, stroff + st_name))
    return out


def versions(d, secs):
    for s in secs:
        if s["sname"] == "__versions":
            res = {}
            for i in range(s["size"] // 64):
                o = s["off"] + i * 64
                crc = struct.unpack_from("<Q", d, o)[0]
                res[cstr(d, o + 8)] = crc & 0xFFFFFFFF
            return res
    return None


def modinfo(d, secs, key):
    for s in secs:
        if s["sname"] == ".modinfo":
            blob = d[s["off"]:s["off"] + s["size"]]
            for item in blob.split(b"\0"):
                if item.startswith(key.encode() + b"="):
                    return item.split(b"=", 1)[1].decode(errors="replace")
    return None


def load_symvers(path):
    res = {}
    for line in open(path):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 4:
            res[p[1]] = (int(p[0], 16), p[2], p[3])
    return res


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    ko, symvers = sys.argv[1:]
    d, secs = parse_elf(ko)
    exports = load_symvers(symvers)
    undef = sorted(set(undefined_symbols(d, secs)))
    vers = versions(d, secs)
    lic = modinfo(d, secs, "license") or ""
    depends = modinfo(d, secs, "depends") or ""
    gpl_ok = lic.startswith("GPL") or lic in ("Dual BSD/GPL", "Dual MIT/GPL", "Dual MPL/GPL")

    print("module  : %s" % ko)
    print("license : %s    depends: %s" % (lic or "(none)", depends or "(none)"))
    print("imports : %d    __versions table: %s" % (
        len(undef), "present" if vers is not None else "absent (no CRC check)"))
    bad = 0
    for s in undef:
        if s not in exports:
            print("MISSING     %s  (not exported by vmlinux or in-tree modules; "
                  "fine only if one of its 'depends' modules provides it)" % s)
            bad += 1
            continue
        crc, owner, kind = exports[s]
        if vers is not None and s in vers and vers[s] != crc:
            print("CRC MISMATCH %s  module=0x%08x kernel=0x%08x" % (s, vers[s], crc))
            bad += 1
        if "GPL" in kind and not gpl_ok:
            print("GPL-ONLY    %s  (%s) but module license is '%s'" % (s, kind, lic))
            bad += 1
    if bad:
        print("RESULT: would NOT load (%d problem(s))" % bad)
        sys.exit(1)
    print("RESULT: every import resolves with matching CRCs; the module should load")


if __name__ == "__main__":
    main()
