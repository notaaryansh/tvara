#!/usr/bin/env python3
"""Attach to WhatsApp and capture the call chain when user navigates to a message.

Run this, then manually inside WhatsApp:
  1. Open any chat
  2. Tap the search icon (chat info → Search in chat)
  3. Type a unique word from an old message and tap a result
  4. Watch the captured output here

Hit Ctrl+C when done. The script prints every hooked method call with
arguments + backtrace — that gives us the actual dispatch chain.
"""
import sys
import frida
from pathlib import Path

def on_message(msg, data):
    if msg['type'] == 'error':
        print(f"  [error] {msg['description']}")
        return
    payload = msg.get('payload', {})
    if not isinstance(payload, dict):
        print(f"  {payload}")
        return
    t = payload.get('type')
    if t == 'candidates':
        print(f"\n=== Discovered {payload['total']} candidate classes ===")
        for c in payload['classes']:
            print(f"  {c}")
    elif t == 'hooked':
        print(f"[hooked] {payload['className']} {payload['selector']}")
    elif t == 'hook-error':
        print(f"[hook-error] {payload['className']} {payload['selector']}: {payload['error']}")
    elif t == 'call':
        print(f"\n>>> CALL: [{payload['className']} {payload['selector']}]")
        for i, a in enumerate(payload['args']):
            print(f"    arg{i}: {a}")
    elif t == 'stack':
        print(f"    backtrace:")
        for f in payload['frames']:
            print(f"      {f}")

def main():
    procs = frida.get_local_device().enumerate_processes()
    wa = [p for p in procs if 'WhatsApp' in p.name]
    if not wa:
        print("WhatsApp not running. Open it first.")
        sys.exit(1)
    pid = wa[0].pid
    print(f"Attaching to WhatsApp PID={pid}...")
    session = frida.attach(pid)

    script_src = Path(__file__).parent.joinpath('hooks/scroll_to_message.js').read_text()
    script = session.create_script(script_src)
    script.on('message', on_message)
    script.load()
    script.exports_sync.init()

    print()
    print("=== HOOKS ARMED ===")
    print("Now inside WhatsApp:")
    print("  1. Open any chat")
    print("  2. Use Search in chat to navigate to an old message")
    print("Backtraces + arguments will print here.")
    print("Press Ctrl+C when done.")
    print()
    try:
        sys.stdin.read()
    except KeyboardInterrupt:
        pass
    session.detach()

if __name__ == "__main__":
    main()
