#!/usr/bin/env python3
"""One-time pass over the disassembly to build an index: addr -> file offset.
Each disassembly line starts with 16-hex chars + tab.
"""
import sys
from pathlib import Path

DISASM = "/tmp/wa_arm64.disasm"
INDEX = "/tmp/wa_arm64.index"


def build():
    """Index every 16-hex-prefixed line with its byte offset."""
    out = open(INDEX, "wb")
    with open(DISASM, "rb") as f:
        offset = 0
        for line in f:
            if len(line) >= 17 and line[16:17] == b"\t":
                hex_part = line[:16]
                try:
                    addr = int(hex_part, 16)
                    # 8-byte addr LE + 8-byte offset LE
                    out.write(addr.to_bytes(8, "little") + offset.to_bytes(8, "little"))
                except ValueError:
                    pass
            offset += len(line)
    out.close()
    print("Index built:", Path(INDEX).stat().st_size, "bytes")


if __name__ == "__main__":
    build()
