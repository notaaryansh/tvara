#!/usr/bin/env python3
"""Verify Frida is installed and we can see WhatsApp."""
import sys
import subprocess

def main():
    try:
        import frida
    except ImportError:
        print("FAIL: frida not installed. Run: pip3 install frida-tools")
        sys.exit(1)
    print(f"frida version: {frida.__version__}")

    # Try to enumerate processes
    try:
        local = frida.get_local_device()
        procs = local.enumerate_processes()
    except Exception as e:
        print(f"FAIL: cannot enumerate processes: {e}")
        sys.exit(1)

    wa = [p for p in procs if "WhatsApp" in p.name]
    if not wa:
        print("FAIL: WhatsApp not running. Open it first.")
        sys.exit(1)
    p = wa[0]
    print(f"Found WhatsApp PID={p.pid}")

    # Try to actually attach
    try:
        session = frida.attach(p.pid)
        print(f"ATTACH OK: session={session}")
        session.detach()
        print("Attach + detach succeeded. Frida can hook this process.")
    except Exception as e:
        print(f"ATTACH FAIL: {e}")
        print()
        print("This is the hardened-runtime block. To proceed you need either:")
        print("  1. Disable SIP from Recovery Mode (csrutil disable)")
        print("  2. Resign WhatsApp without hardened runtime")
        print("  3. Use a debug/test build (not available)")
        sys.exit(2)

if __name__ == "__main__":
    main()
