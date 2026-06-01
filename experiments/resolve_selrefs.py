#!/usr/bin/env python3
"""Resolve the 11 selrefs called by WAMessageDeepLink.parseURL:context:.

Each selref at offset 0x480..0x4d0 from 0x1082be000 in the binary is a
64-bit pointer to a selector string (in __TEXT,__objc_methname). We read
the binary, follow the pointer, and print the resolved selector name.
"""
import struct
import subprocess

BIN = "/Applications/WhatsApp.app/Contents/MacOS/WhatsApp"

# Find arm64 slice offset
out = subprocess.check_output(["file", BIN]).decode()
print("Binary type:", out.strip())

# The IMP at 0x1013d9dd0 is a Virtual Address (VA) in the arm64 slice.
# Selrefs at 0x1082be480-0x1082be4d0 are also VAs.
# We need to translate VA -> File Offset.

# Use otool to get __TEXT,__objc_selrefs and __TEXT,__objc_methname load addresses
def get_section_info():
    info = {}
    out = subprocess.check_output(["otool", "-l", "-arch", "arm64", BIN]).decode()
    cur = None
    section_name = None
    seg_name = None
    for line in out.split("\n"):
        line = line.strip()
        if line.startswith("Section"):
            cur = {}
        elif line.startswith("sectname"):
            section_name = line.split()[1]
        elif line.startswith("segname"):
            seg_name = line.split()[1]
        elif line.startswith("addr "):
            cur["addr"] = int(line.split()[1], 16)
        elif line.startswith("offset "):
            cur["offset"] = int(line.split()[1])
            if section_name and seg_name and "addr" in cur:
                info[f"{seg_name},{section_name}"] = cur.copy()
            cur = None
    return info

sections = get_section_info()
print()
print("Relevant sections (addr -> file offset):")
for key in ["__DATA_CONST,__objc_selrefs", "__DATA,__objc_selrefs",
            "__TEXT,__objc_methname"]:
    if key in sections:
        s = sections[key]
        print(f"  {key}: VA=0x{s['addr']:x} file_off=0x{s['offset']:x}")
print()

# Read the file once
with open(BIN, "rb") as f:
    data = f.read()

# We need the file offset for the arm64 slice.
# Universal binaries start with fat header. Find the arm64 slice offset.
import struct as _s
magic = _s.unpack(">I", data[:4])[0]
slice_start = 0
if magic in (0xcafebabe, 0xcafebabf):
    # Fat binary. Parse arches.
    nfat = _s.unpack(">I", data[4:8])[0]
    is_64 = (magic == 0xcafebabf)
    entry_size = 32 if is_64 else 20
    for i in range(nfat):
        off = 8 + i * entry_size
        if is_64:
            cputype, cpusubtype, file_off, sz, align, _ = _s.unpack(">IIQQII", data[off:off+32])
        else:
            cputype, cpusubtype, file_off, sz, align = _s.unpack(">IIIII", data[off:off+20])
        # arm64 is 0x100000c
        if cputype == 0x100000c:
            slice_start = file_off
            print(f"arm64 slice at file_offset = 0x{slice_start:x}, size = 0x{sz:x}")
            break

# VA -> file offset translation: file_offset = (VA - section.addr) + section.offset + slice_start
# But for simplicity, find the section that contains 0x1082be480 and translate
def va_to_file_off(va):
    for key, s in sections.items():
        # Section addresses end at addr + size. We don't have size here but
        # assume the right section contains it if addr <= va < addr + 0x10MB
        if s["addr"] <= va < s["addr"] + 0x1000000:
            return slice_start + s["offset"] + (va - s["addr"])
    return None

# Read each selref at 0x1082be480, 0x488, 0x490, ... 0x4d0
print()
print("Resolving 11 selectors called by WAMessageDeepLink.parseURL:context::")
print()
for offset in range(0x480, 0x4d8, 8):
    va = 0x1082be000 + offset
    fo = va_to_file_off(va)
    if fo is None:
        print(f"  va=0x{va:x}: section not found")
        continue
    # Read 8 bytes (the pointer)
    raw = data[fo:fo+8]
    if len(raw) < 8:
        print(f"  va=0x{va:x}: read short")
        continue
    ptr_va = _s.unpack("<Q", raw)[0]
    # Sometimes the upper bits are tagged; mask off auth bits
    ptr_va = ptr_va & ((1 << 48) - 1)
    # Now follow ptr_va to a C string
    str_fo = va_to_file_off(ptr_va)
    if str_fo is None:
        # Maybe it's in __TEXT,__objc_methname directly
        # Try a wider range
        sel_str = "?"
    else:
        # Read null-terminated string
        end = data.find(b"\x00", str_fo)
        sel_str = data[str_fo:end].decode("ascii", errors="replace")
    print(f"  selref @ 0x{va:x}  ->  ptr 0x{ptr_va:x}  ->  '{sel_str}'")
