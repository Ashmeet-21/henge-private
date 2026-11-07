#!/usr/bin/env python3
"""Turns host/prof_ios.c's "hvprof: 12.34% +0x1a2b3c" lines into Henge function names, on any computer.

    python3 tools/prof_symbolize.py Henge.ipa henge-native.log

The offsets are from the app image's start; the Release build keeps its symbol table, which this
reads straight from the .ipa (or a bare Henge binary). Each sample goes to the function at or below
its address. Prints, per profile dump, the busy split (translated code vs Henge) and the top functions.
"""
import re
import struct
import sys
import zipfile
from bisect import bisect_right
from collections import defaultdict

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64, LC_SYMTAB = 0x19, 0x2
N_STAB, N_TYPE, N_SECT = 0xE0, 0x0E, 0x0E


def read_binary(path):
    if path.endswith(".ipa"):
        with zipfile.ZipFile(path) as z:
            name = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/[^/.]+", n)
                        and n.split("/")[-1] == n.split("/")[1][:-4])
            return z.read(name)
    with open(path, "rb") as f:
        return f.read()


def symbols(data):
    """(address relative to the image start, name), sorted. Only defined function-section symbols."""
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64:
        raise SystemExit("not a thin 64-bit Mach-O (fat binaries: extract the arm64 slice first)")
    off, text_vmaddr, symtab = 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            segname = data[off + 8:off + 24].rstrip(b"\0")
            if segname == b"__TEXT":
                text_vmaddr = struct.unpack_from("<Q", data, off + 24)[0]
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, off + 8)
        off += size
    if text_vmaddr is None or symtab is None:
        raise SystemExit("no __TEXT segment or symbol table")
    symoff, nsyms, stroff, _ = symtab
    out = []
    for i in range(nsyms):
        strx, ntype, nsect, _, value = struct.unpack_from("<IBBhQ", data, symoff + 16 * i)
        if ntype & N_STAB or (ntype & N_TYPE) != N_SECT or value < text_vmaddr:
            continue
        end = data.index(b"\0", stroff + strx)
        name = data[stroff + strx:end].decode("utf-8", "replace")
        out.append((value - text_vmaddr, name[1:] if name.startswith("_") else name))
    out.sort()
    return out


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    syms = symbols(read_binary(sys.argv[1]))
    addrs = [a for a, _ in syms]
    dumps, current, header = [], None, None
    for line in open(sys.argv[2], encoding="utf-8", errors="replace"):
        m = re.search(r"hvprof: (\d+) samples, idle ([\d.]+)%, of busy: jit ([\d.]+)%, other images ([\d.]+)%", line)
        if m:
            current = defaultdict(float)
            header = m.groups()
            dumps.append((header, current))
            continue
        m = re.search(r"hvprof:\s+([\d.]+)% \+(0x[0-9a-f]+)", line)
        if m and current is not None:
            pct, offset = float(m.group(1)), int(m.group(2), 16)
            i = bisect_right(addrs, offset) - 1
            current[syms[i][1] if i >= 0 else "?"] += pct
    if not dumps:
        raise SystemExit("no hvprof lines (is HV_PROF_IOS=1 in henge-env.txt?)")
    for (samples, idle, jit, other), funcs in dumps:
        print(f"{samples} samples, idle {idle}%; of busy: translated code {jit}%, other libraries {other}%")
        for name, pct in sorted(funcs.items(), key=lambda kv: -kv[1])[:20]:
            print(f"  {pct:6.2f}%  {name}")
        print()


if __name__ == "__main__":
    main()
