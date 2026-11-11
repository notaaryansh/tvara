#!/usr/bin/env bash
# Memory benchmark: prints a Markdown table of the memory footprint of
# tvara and any other launchers that are currently running.
#
#   scripts/bench-memory.sh              # one reading now
#   scripts/bench-memory.sh --samples 6 --interval 10   # six readings, 10s apart
#   scripts/bench-memory.sh --detail     # also print tvara's top categories
#
# "Footprint" is phys_footprint — the number Activity Monitor shows in its
# Memory column, and the one macOS uses for memory-pressure decisions. It
# is NOT RSS (which also counts shared, clean file-backed pages).
#
# For a fair comparison: launch each app, use it for a few searches, then
# leave it untouched for the idle reading. Say which state you measured.
set -euo pipefail

SAMPLES=1
INTERVAL=5
DETAIL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --samples)  SAMPLES="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --detail)   DETAIL=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# Display name : exact process name
APPS=("tvara:tvara" "Raycast:Raycast" "Alfred:Alfred" "Spotlight:Spotlight")

# Footprint of one pid in MB (integer), or empty if it can't be read.
footprint_mb() {
    footprint -p "$1" 2>/dev/null \
        | awk '/phys_footprint:/ { v=$2; u=$3;
                 if (u=="GB") v*=1024; else if (u=="KB") v/=1024;
                 else if (u=="B") v/=1048576;
                 printf "%d", v + 0.5; exit }'
}

echo "macOS $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM"
echo
echo "| App | Min (MB) | Max (MB) | Samples |"
echo "| --- | ---: | ---: | ---: |"

for entry in "${APPS[@]}"; do
    name="${entry%%:*}"; proc="${entry##*:}"
    pid="$(pgrep -x "$proc" | head -1 || true)"
    if [[ -z "$pid" ]]; then
        echo "| $name | not running | | |"
        continue
    fi
    min=""; max=""; n=0
    for ((i = 0; i < SAMPLES; i++)); do
        mb="$(footprint_mb "$pid")"
        # A process that is still launching can report 0; skip those.
        if [[ -n "$mb" && "$mb" -gt 0 ]]; then
            [[ -z "$min" || "$mb" -lt "$min" ]] && min="$mb"
            [[ -z "$max" || "$mb" -gt "$max" ]] && max="$mb"
            n=$((n + 1))
        fi
        (( i + 1 < SAMPLES )) && sleep "$INTERVAL"
    done
    echo "| $name | ${min:-?} | ${max:-?} | $n |"
done

if [[ "$DETAIL" == 1 ]]; then
    pid="$(pgrep -x tvara | head -1 || true)"
    if [[ -n "$pid" ]]; then
        echo
        echo "tvara, largest categories:"
        footprint -p "$pid" | awk '/Category/ {on=1; next} on && NF' | head -14
    fi
fi
