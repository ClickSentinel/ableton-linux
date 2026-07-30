#!/usr/bin/env bash
# Watch Wine's GetCursorPos for physically impossible jumps while you hover.
#
# Why this exists: the M4L misplaced-tooltip trace shows the app place a tooltip
# correctly at the pointer, then call GetCursorPos and immediately move it far
# away. So the question is whether Wine's answer is wrong.
#
# On Wayland it usually cannot be checked against a "real" pointer position:
# XWayland only reports pointer coordinates while the pointer is over one of its
# own surfaces, and xdotool sees XWayland rather than the compositor. So instead
# of comparing against an external source, this looks for jumps that a hovering
# hand cannot produce - a >150px step between samples 50ms apart - and reports
# the foreground window at that moment, because the reported symptom is that
# focus changes when a tooltip appears.
#
#   tools/curprobe.sh [seconds]
#
# Hover over an M4L device UI and provoke tooltips while it runs.
set -uo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SECS="${1:-30}"
JUMP="${JUMP:-150}"
WINE_ROOT="${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.13}"
export WINEPREFIX="${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}" WINEDEBUG=-all

[ -x "$here/curprobe.exe" ] || {
    echo "== building curprobe.exe =="
    x86_64-w64-mingw32-gcc -O2 -o "$here/curprobe.exe" "$here/curprobe.c" -luser32 \
        || { echo "!! build failed (need mingw-w64)" >&2; exit 1; }
}

OUT="${OUT:-/tmp/curprobe-$(date +%H%M%S).txt}"
echo "sampling ${SECS}s -> $OUT"
echo "hover over an M4L device UI and make tooltips appear..."
"$WINE_ROOT/bin/wine" "$here/curprobe.exe" "$SECS" 50 > "$OUT" 2>/dev/null

python3 - "$OUT" "$JUMP" <<'PY'
import sys
rows=[]
for ln in open(sys.argv[1]):
    f=ln.split()
    if len(f)>=4 and f[0].isdigit():
        rows.append((int(f[0]),int(f[1]),int(f[2]),f[3],'GETCURSORPOS_FAILED' in ln))
jump=int(sys.argv[2])
if len(rows)<5:
    print(f"!! only {len(rows)} samples - did wine run?"); sys.exit(2)
print(f"{len(rows)} samples over {(rows[-1][0]-rows[0][0])/1000:.1f}s\n")
fails=[r for r in rows if r[4]]
if fails: print(f"!! GetCursorPos FAILED {len(fails)} times\n")
bad=[]
for a,b in zip(rows,rows[1:]):
    d=max(abs(b[1]-a[1]),abs(b[2]-a[2]))
    if d>=jump: bad.append((a,b,d,a[3]!=b[3]))
print(f"jumps >= {jump}px between consecutive 50ms samples: {len(bad)}")
for a,b,d,fgch in bad[:20]:
    print(f"  ({a[1]},{a[2]}) -> ({b[1]},{b[2]})  delta={d:>5}  dt={b[0]-a[0]:>4}ms"
          f"  fg {a[3]} -> {b[3]}{'   <== FOREGROUND CHANGED' if fgch else ''}")
withfg=sum(1 for *_ ,f in bad if f)
print(f"\nof those, {withfg} coincided with a foreground-window change")
ys={r[2] for r in rows}
print(f"distinct Y values seen: {len(ys)}   range {min(ys)}..{max(ys)}" if ys else "")
print("\nNOTE: a hovering hand cannot move 150px in 50ms repeatedly. Frequent")
print("jumps - especially alongside a foreground change - mean Wine is reporting")
print("a cursor position the pointer never occupied, which is a Wine-side bug.")
PY
