#!/usr/bin/env python3
"""Resolve a CFString VM address inside the WhatsApp Mac binary to its C-string content."""
import struct
import subprocess
import sys
from pathlib import Path

BIN = "/Applications/WhatsApp.app/Contents/MacOS/WhatsApp"


def parse_arm64_slice(path):
    data = Path(path).read_bytes()
    magic = struct.unpack(">I", data[:4])[0]
    if magic != 0xCAFEBABE:
        return data, 0
    n = struct.unpack(">I", data[4:8])[0]
    for i in range(n):
        off = 8 + i * 20
        cputype, cpusubtype, offset, sz, align = struct.unpack(">IIIII", data[off : off + 20])
        # arm64 cputype = 0x0100000c (CPU_TYPE_ARM | CPU_ARCH_ABI64)
        if cputype == 0x0100000C:
            return data[offset : offset + sz], 0
    raise RuntimeError("no arm64 slice")


def section_table(path):
    out = subprocess.check_output(["otool", "-arch", "arm64", "-l", path]).decode()
    sections = []
    cur = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("Section"):
            if cur is not None:
                sections.append(cur)
            cur = {}
        elif cur is None:
            continue
        elif s.startswith("sectname "):
            cur["sectname"] = s.split()[1]
        elif s.startswith("segname "):
            cur["segname"] = s.split()[1]
        elif s.startswith("addr "):
            cur["addr"] = int(s.split()[-1], 16)
        elif s.startswith("size ") and "size" not in cur:
            cur["size"] = int(s.split()[-1], 16)
        elif s.startswith("offset ") and "offset" not in cur:
            cur["offset"] = int(s.split()[-1])
    if cur is not None:
        sections.append(cur)
    return sections


def find_section_for(addr, sections):
    for s in sections:
        if "addr" in s and "size" in s:
            if s["addr"] <= addr < s["addr"] + s["size"]:
                return s
    return None


def cfstring_to_cstring_vm(cfstring_vm, slice_bytes, sections):
    cf_sec = find_section_for(cfstring_vm, sections)
    if not cf_sec:
        raise RuntimeError(f"cfstring vm {hex(cfstring_vm)} not in any section")
    delta = cfstring_vm - cf_sec["addr"]
    raw = slice_bytes[cf_sec["offset"] + delta : cf_sec["offset"] + delta + 32]
    # CFConstantString layout: isa(8) flags(8) cstr_ptr(8) length(8)
    isa, flags, cstr_ptr, length = struct.unpack("<QQQQ", raw)
    return cstr_ptr, length


def read_cstring_vm(vm, length, slice_bytes, sections):
    sec = find_section_for(vm, sections)
    if not sec:
        return None
    delta = vm - sec["addr"]
    return slice_bytes[sec["offset"] + delta : sec["offset"] + delta + length].decode("utf-8", errors="replace")


def resolve(addr):
    slice_bytes, _ = parse_arm64_slice(BIN)
    sections = section_table(BIN)
    cstr_ptr, length = cfstring_to_cstring_vm(addr, slice_bytes, sections)
    s = read_cstring_vm(cstr_ptr, length, slice_bytes, sections)
    return s


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: dump_cfstring.py 0x108277b08 [0x...]")
        sys.exit(1)
    for arg in sys.argv[1:]:
        addr = int(arg, 16)
        try:
            s = resolve(addr)
            print(f"{hex(addr)}: {s!r}")
        except Exception as e:
            print(f"{hex(addr)}: ERR {e}")
