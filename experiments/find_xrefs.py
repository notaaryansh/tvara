#!/usr/bin/env python3
"""
Find which functions reference the deeplink param-name strings
('chat_jid', 'message_id', etc.) in WhatsApp's arm64 slice.

Strategy:
1. Locate each target string in __cstring → its VA.
2. Find the __cfstring entry that wraps that C string (str_ptr matches).
   The CFString entry's own VA is what Objective-C code references.
3. Scan __text for adrp+ldr (or adrp+add) pairs that load that CFString
   VA into a register — those are the use-sites.
4. Map each use-site to the enclosing function via the __FUNCTION_STARTS
   load command (LC_FUNCTION_STARTS provides function-boundary deltas).

Output: for each target string, a list of (function_VA, use_VA) pairs.

Reuses universal-binary translation logic from INVESTIGATION.md §3.
"""
import struct
import subprocess
import sys
from pathlib import Path

BIN = "/Applications/WhatsApp.app/Contents/MacOS/WhatsApp"
TARGETS = ["chat_jid", "message_id", "conversation_id", "category_id",
           "notification_id", "stanza_id", "chatJid", "messageId",
           "messageID", "stanzaId", "msgKey", "msgKeyId", "msg", "phone",
           "jid", "lid", "id", "key"]


def parse_fat():
    with open(BIN, "rb") as f:
        magic = struct.unpack(">I", f.read(4))[0]
        nfat = struct.unpack(">I", f.read(4))[0]
        for _ in range(nfat):
            if magic == 0xcafebabf:
                ct, _, off, size, _, _ = struct.unpack(">iIQQII", f.read(32))
            else:
                ct, _, off, size, _ = struct.unpack(">iIIII", f.read(20))
            if ct == 0x100000c:
                return off, size
    raise RuntimeError("no arm64 slice")


def parse_sections():
    """Return list of (segname, sectname, addr, size, file_off_in_slice)."""
    out = subprocess.run(["otool", "-l", "-arch", "arm64", BIN],
                         capture_output=True, text=True).stdout
    sections = []
    cur_seg = None
    cur_sect = {}
    in_sect = False
    for line in out.split("\n"):
        s = line.strip()
        if s.startswith("segname "):
            cur_seg = s.split()[1]
        elif s.startswith("sectname "):
            if cur_sect:
                sections.append(cur_sect)
            cur_sect = {"seg": cur_seg, "sect": s.split()[1]}
            in_sect = True
        elif in_sect:
            if s.startswith("addr "):
                cur_sect["addr"] = int(s.split()[1], 16)
            elif s.startswith("size "):
                cur_sect["size"] = int(s.split()[1], 16)
            elif s.startswith("offset "):
                cur_sect["off"] = int(s.split()[1])
    if cur_sect:
        sections.append(cur_sect)
    return [s for s in sections if "addr" in s]


def va_to_file_off(sections, slice_off, va):
    """Translate arm64 VA to absolute file offset."""
    for sec in sections:
        if sec["addr"] <= va < sec["addr"] + sec["size"]:
            return slice_off + sec["off"] + (va - sec["addr"])
    return None


def find_string_vas(sections, slice_off, target):
    """Find all VAs in __cstring/__const where the C string `target` lives."""
    needle = target.encode() + b"\x00"
    hits = []
    for sec in sections:
        if sec["seg"] != "__TEXT" or sec["sect"] not in ("__cstring", "__ustring", "__const"):
            continue
        with open(BIN, "rb") as f:
            f.seek(slice_off + sec["off"])
            data = f.read(sec["size"])
        start = 0
        while True:
            i = data.find(needle, start)
            if i < 0:
                break
            # Must be string-aligned (preceded by \0 or section start)
            if i == 0 or data[i-1] == 0:
                hits.append(sec["addr"] + i)
            start = i + 1
    return hits


def find_cfstring_wrappers(sections, slice_off, str_vas):
    """Find __cfstring entries whose str_ptr matches any of str_vas."""
    cf = next((s for s in sections if s["sect"] == "__cfstring"), None)
    if not cf:
        return {}
    with open(BIN, "rb") as f:
        f.seek(slice_off + cf["off"])
        data = f.read(cf["size"])
    result = {}  # str_va -> cfstring_va
    str_va_set = set(str_vas)
    for i in range(0, cf["size"], 32):
        if i + 32 > cf["size"]:
            break
        isa, flags, sp, sl = struct.unpack("<QQQQ", data[i:i+32])
        if sp in str_va_set:
            cf_va = cf["addr"] + i
            result[sp] = cf_va
    return result


def find_xrefs_to_va(sections, slice_off, target_va):
    """
    Scan __text for adrp+add or adrp+ldr pairs that materialize target_va.
    Returns list of (use_va, instr_pair).
    """
    text = next((s for s in sections if s["sect"] == "__text"), None)
    if not text:
        return []
    with open(BIN, "rb") as f:
        f.seek(slice_off + text["off"])
        data = f.read(text["size"])
    base = text["addr"]
    hits = []
    page = target_va & ~0xfff
    off_in_page = target_va & 0xfff
    # Walk every 4-byte instruction
    for i in range(0, len(data) - 8, 4):
        ins0 = struct.unpack("<I", data[i:i+4])[0]
        # adrp Xd, page-of-target?
        if (ins0 & 0x9f000000) != 0x90000000:
            continue
        imm_lo = (ins0 >> 29) & 3
        imm_hi = (ins0 >> 5) & 0x7ffff
        imm = ((imm_hi << 2) | imm_lo) << 12
        if imm & 0x100000000:
            imm |= ~0xffffffff
        cur_va = base + i
        adrp_target_page = (cur_va & ~0xfff) + imm
        if adrp_target_page != page:
            continue
        rd_adrp = ins0 & 0x1f
        # Look at next instruction
        ins1 = struct.unpack("<I", data[i+4:i+8])[0]
        # add Xd, Xn, #imm  (32-bit add immediate, sf=1)
        if (ins1 & 0xff800000) == 0x91000000:
            rn = (ins1 >> 5) & 0x1f
            rd_add = ins1 & 0x1f
            imm12 = (ins1 >> 10) & 0xfff
            if rn == rd_adrp and imm12 == off_in_page:
                hits.append(cur_va)
                continue
        # ldr Xd, [Xn, #imm]  (64-bit load, sf=1)
        if (ins1 & 0xffc00000) == 0xf9400000:
            rn = (ins1 >> 5) & 0x1f
            imm12 = ((ins1 >> 10) & 0xfff) << 3
            if rn == rd_adrp and imm12 == off_in_page:
                hits.append(cur_va)
                continue
    return hits


def parse_function_starts(slice_off):
    """Return sorted list of function-start VAs from LC_FUNCTION_STARTS."""
    out = subprocess.run(["otool", "-l", "-arch", "arm64", BIN],
                         capture_output=True, text=True).stdout
    fs_off = fs_size = None
    in_cmd = False
    for line in out.split("\n"):
        s = line.strip()
        if s.startswith("cmd "):
            in_cmd = (s == "cmd LC_FUNCTION_STARTS")
        elif in_cmd:
            if s.startswith("dataoff "):
                fs_off = int(s.split()[1])
            elif s.startswith("datasize "):
                fs_size = int(s.split()[1])
                break
    if fs_off is None:
        return []
    with open(BIN, "rb") as f:
        f.seek(slice_off + fs_off)
        data = f.read(fs_size)
    # ULEB128 deltas, first is offset from base VA
    starts = []
    cur = 0x100000000  # arm64 typical base (TEXT __text addr is 0x100005000)
    # Use the actual __text base instead — but for function starts the spec
    # is deltas added to the prior entry; the FIRST delta is added to the
    # __text segment's vmaddr. We have __TEXT segment; close enough to use
    # __text base for our heuristic mapping.
    p = 0
    sections = parse_sections()
    text = next(s for s in sections if s["sect"] == "__text")
    cur = text["addr"]
    first = True
    while p < len(data):
        # decode uleb128
        val = 0
        shift = 0
        while True:
            b = data[p]; p += 1
            val |= (b & 0x7f) << shift
            if not (b & 0x80):
                break
            shift += 7
        if val == 0 and not first:
            break
        if first:
            cur = text["addr"] + val
            first = False
        else:
            cur += val
        starts.append(cur)
    return sorted(starts)


def enclosing_function(starts, va):
    """Binary-search for the function start at or before va."""
    import bisect
    i = bisect.bisect_right(starts, va) - 1
    return starts[i] if i >= 0 else None


def main():
    slice_off, _slice_size = parse_fat()
    sections = parse_sections()
    func_starts = parse_function_starts(slice_off)
    print(f"arm64 slice @ file_off {slice_off}; {len(func_starts)} functions")

    for tgt in TARGETS:
        str_vas = find_string_vas(sections, slice_off, tgt)
        if not str_vas:
            print(f"\n[{tgt}]  no exact C-string match")
            continue
        wrappers = find_cfstring_wrappers(sections, slice_off, str_vas)
        print(f"\n[{tgt}]  string VAs: {[hex(v) for v in str_vas]}")
        if wrappers:
            print(f"  __cfstring wrappers: {[(hex(k), hex(v)) for k,v in wrappers.items()]}")

        # XRefs to __cfstring wrappers (preferred — that's how Obj-C code refs)
        all_refs = []
        for str_va, cf_va in wrappers.items():
            refs = find_xrefs_to_va(sections, slice_off, cf_va)
            for r in refs:
                fn = enclosing_function(func_starts, r)
                all_refs.append((r, fn))
        # Also xrefs to raw C string (rare but Swift may do this)
        for str_va in str_vas:
            refs = find_xrefs_to_va(sections, slice_off, str_va)
            for r in refs:
                fn = enclosing_function(func_starts, r)
                all_refs.append((r, fn))
        # Dedup
        seen = set()
        for use_va, fn_va in all_refs:
            if (use_va, fn_va) in seen:
                continue
            seen.add((use_va, fn_va))
            print(f"    use@{hex(use_va)}  in fn@{hex(fn_va) if fn_va else '?'}")


if __name__ == "__main__":
    main()
