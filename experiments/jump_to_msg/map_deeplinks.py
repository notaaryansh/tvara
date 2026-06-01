#!/usr/bin/env python3
"""For each WA*DeepLink class, extract the cfstrings it compares in its parseURL: method.

Uses a binary-searchable address index (see index_disasm.py) so each lookup is O(log n).
"""
import bisect
import mmap
import re
import struct
import subprocess
from pathlib import Path

from dump_cfstring import (
    parse_arm64_slice,
    section_table,
    find_section_for,
    cfstring_to_cstring_vm,
    read_cstring_vm,
)

DISASM = "/tmp/wa_arm64.disasm"
INDEX = "/tmp/wa_arm64.index"
META = "/tmp/wa_arm64_oc.txt"
BIN = "/Applications/WhatsApp.app/Contents/MacOS/WhatsApp"


# ---- index ----
class AddrIndex:
    def __init__(self):
        self.f_idx = open(INDEX, "rb")
        self.idx = mmap.mmap(self.f_idx.fileno(), 0, prot=mmap.PROT_READ)
        self.n = len(self.idx) // 16
        self.f_dis = open(DISASM, "rb")
        self.dis = mmap.mmap(self.f_dis.fileno(), 0, prot=mmap.PROT_READ)

    def addr_at(self, i):
        return struct.unpack_from("<Q", self.idx, i * 16)[0]

    def offset_at(self, i):
        return struct.unpack_from("<Q", self.idx, i * 16 + 8)[0]

    def find_idx(self, addr):
        lo, hi = 0, self.n
        while lo < hi:
            mid = (lo + hi) // 2
            if self.addr_at(mid) < addr:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def read_function(self, start_addr, max_lines=4000):
        i = self.find_idx(start_addr)
        if i == self.n or self.addr_at(i) != start_addr:
            return []
        start_off = self.offset_at(i)
        # Heuristic: function ends when we see another "stp xN,xN,[sp,#-0x.."
        body = []
        end_off = min(start_off + 80 * max_lines, len(self.dis))
        chunk = self.dis[start_off:end_off]
        text = chunk.decode("utf-8", errors="replace")
        for idx, ln in enumerate(text.splitlines()):
            if idx > 0 and ("stp\tx" in ln and ", [sp, #-" in ln):
                break
            body.append(ln)
            if len(body) > max_lines:
                break
        return body


# ---- classes ----
def find_classes_and_addrs():
    text = Path(META).read_text()
    lines = text.splitlines()
    pairs = []
    i = 0
    while i < len(lines):
        m = re.match(r"\s+name +0x[0-9a-f]+ (WA\w+DeepLink)$", lines[i])
        if m:
            cls = m.group(1)
            for j in range(i + 1, min(i + 600, len(lines))):
                if re.match(r"\s+name +0x[0-9a-f]+ (WA\w+DeepLink)$", lines[j]):
                    break
                if "parseURL:context:" in lines[j]:
                    for k in range(j + 1, min(j + 5, len(lines))):
                        m2 = re.match(r"\s+imp +(0x[0-9a-f]+)", lines[k])
                        if m2 and m2.group(1) != "0x0":
                            pairs.append((cls, int(m2.group(1), 16)))
                            break
                    break
            i = j
        else:
            i += 1
    seen = set()
    out = []
    for c, a in pairs:
        if (c, a) in seen:
            continue
        seen.add((c, a))
        out.append((c, a))
    return out


# ---- cfstring resolution ----
SLICE, _ = parse_arm64_slice(BIN)
SECTIONS = section_table(BIN)


def resolve_cfstring(vm):
    cf_sec = find_section_for(vm, SECTIONS)
    if not cf_sec or cf_sec.get("sectname") != "__cfstring":
        return None
    try:
        ptr, length = cfstring_to_cstring_vm(vm, SLICE, SECTIONS)
        return read_cstring_vm(ptr, length, SLICE, SECTIONS)
    except Exception:
        return None


def extract_cfstrings(body):
    refs = set()
    for ln in body:
        m = re.search(r"Objc cfstring ref: @\"([^\"]*)\"", ln)
        if m and m.group(1) != "bad cfstring ref":
            refs.add(m.group(1))
    # adrp + add pattern (otool marks unknown ones as "bad cfstring ref")
    for idx, ln in enumerate(body):
        m = re.search(r"adrp\s+(x\d+),\s*\d+\s*;\s*(0x[0-9a-f]+)", ln)
        if not m:
            continue
        reg = m.group(1)
        page = int(m.group(2), 16)
        for j in range(idx + 1, min(idx + 4, len(body))):
            m2 = re.search(r"add\s+(x\d+),\s*(x\d+),\s*#(0x[0-9a-f]+)", body[j])
            if m2 and m2.group(1) == reg and m2.group(2) == reg:
                vm = page + int(m2.group(3), 16)
                s = resolve_cfstring(vm)
                if s is not None:
                    refs.add(s)
                break
    return refs


def main():
    idx = AddrIndex()
    pairs = find_classes_and_addrs()
    print(f"# Found {len(pairs)} deep-link classes\n")
    for cls, addr in pairs:
        body = idx.read_function(addr)
        strings = extract_cfstrings(body)
        # Filter out only "interesting" ones: short, ascii, look like host/path/query
        keep = sorted({s for s in strings if s and len(s) < 60 and " " not in s and "\n" not in s})
        print(f"{cls:<48} @ {hex(addr):<14} {keep}")


if __name__ == "__main__":
    main()
