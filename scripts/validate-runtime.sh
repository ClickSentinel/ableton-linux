#!/usr/bin/env bash
# Does this staged runtime tree carry what Ableton Live needs? Run by
# `wires runtime install --validate` against the unpacked candidate before
# anything is promoted: Wires files and guards the build, the application
# vouches for it, and this is the voucher. Component knowledge only - the
# store, the base guard and the rollback are not this script's business.
#
#   validate-runtime.sh <candidate-dir>
set -euo pipefail
export LC_ALL=C.UTF-8

candidate="${1:?usage: validate-runtime.sh <candidate-dir>}"

for required in \
    bin/wine bin/wineserver \
    lib/wine/x86_64-windows/libusb-1.0.dll \
    lib/wine/x86_64-unix/libusb-1.0.so \
    lib/wine/x86_64-unix/comdlg32.so \
    lib/wine/x86_64-unix/winealsa.so \
    lib/wine/x86_64-unix/winegstreamer.so \
    lib/wine/x86_64-windows/pipeasio64.dll \
    lib/wine/x86_64-windows/pipeasio.dll \
    lib/wine/x86_64-unix/pipeasio64.dll.so \
    lib/wine/x86_64-unix/pipeasio.dll.so; do
    [ -s "$candidate/$required" ] || { echo "!! package is missing $required" >&2; exit 1; }
done
if [ -e "$candidate/lib/wine/i386-windows/libusb-1.0.dll" ] || \
   [ -e "$candidate/lib/wine/i386-unix/libusb-1.0.so" ]; then
    echo "!! package unexpectedly contains a 32-bit Push 2 bridge" >&2
    exit 1
fi
if command -v readelf >/dev/null && command -v strings >/dev/null; then
    readelf -d "$candidate/lib/wine/x86_64-unix/libusb-1.0.so" | \
        grep -F 'Shared library: [libusb-1.0.so.0]' >/dev/null || {
            echo "!! Push 2 bridge is not linked to host libusb-1.0.so.0" >&2
            exit 1
        }
    strings "$candidate/lib/wine/x86_64-unix/comdlg32.so" | \
        grep -F 'org.freedesktop.portal.FileChooser' >/dev/null || {
            echo "!! package comdlg32 lacks the XDG portal backend" >&2
            exit 1
        }
    readelf -d "$candidate/lib/wine/x86_64-unix/pipeasio64.dll.so" | \
        grep -F 'Shared library: [libpipewire-0.3.so.0]' >/dev/null || {
            echo "!! PipeASIO is not linked to host libpipewire-0.3.so.0" >&2
            exit 1
        }
    readelf -d "$candidate/lib/wine/x86_64-unix/winegstreamer.so" | \
        grep -F 'Shared library: [libgstreamer-1.0.so.0]' >/dev/null || {
            echo "!! winegstreamer is not linked to host libgstreamer-1.0.so.0" >&2
            exit 1
        }
else
    # binutils absent (e.g. stock SteamOS); the tarball checksum already covers
    # content integrity.
    echo "   (binutils not found: skipping deep binary checks)"
fi
