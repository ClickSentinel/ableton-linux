#!/usr/bin/env bash
# Build the three text-rendering probes with the system Wine's winegcc.
#
#     tools/build_fontprobes.sh [output-directory]
#
# Each probe answers one question about a runtime and needs no application:
#
#   cleartype-probe   does DirectWrite put distinct coverage in the three
#                     subpixels of a ClearType texture, or one grey value
#                     copied three times
#   d2d-text-probe    does that coverage survive to a Direct2D target
#   gdi-text-probe    is GDI text subpixel
#
# Greyscale gives an exactly constant reading in each, so the failing value
# is known in advance and no reference image is required.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/../build}"
mkdir -p "$out"

command -v winegcc >/dev/null || {
    echo "!! winegcc is missing; install the system Wine development package" >&2
    exit 1
}

winegcc -o "$out/cleartype-probe" "$here/cleartype-probe.c" -ldwrite -luuid -luser32 -lgdi32 -lole32
winegcc -o "$out/d2d-text-probe"  "$here/d2d-text-probe.c"  -ld2d1 -ldwrite -luuid -luser32 -lgdi32 -lole32
winegcc -o "$out/gdi-text-probe"  "$here/gdi-text-probe.c"  -luser32 -lgdi32

echo "built:"
echo "  $out/cleartype-probe.exe.so"
echo "  $out/d2d-text-probe.exe.so"
echo "  $out/gdi-text-probe.exe.so"
