#!/usr/bin/env bash
# Build ableton-linkd from the vendored Ableton Link SDK. The script extracts
# vendor/link-4.0.tar.zst to a temporary directory and compiles only against
# that archive, proving that the vendored source is sufficient.
# Header-only C++17 + asio; static libstdc++/libgcc keep the shipped
# binary's DT_NEEDED to host libc/libm/libpthread/libatomic sonames only.
# An optional output path lets the caller select the destination.
set -euo pipefail
cd "$(dirname "$0")"
VENDOR=../vendor
TARBALL=$VENDOR/link-4.0.tar.zst
OUTPUT="${1:-ableton-linkd}"
case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
esac

[ -f "$TARBALL" ] || { echo "!! $TARBALL missing (vendored Ableton Link SDK)" >&2; exit 1; }
[ -d "$(dirname "$OUTPUT")" ] || {
    echo "!! output directory does not exist: $(dirname "$OUTPUT")" >&2
    exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# checksum gate first: same pin as `make verify`
( cd "$VENDOR" && sha256sum -c link.sha256 )

zstd -dc "$TARBALL" | tar -x -C "$WORK"
SDK=$WORK   # tarball ships the repo files at its root (./include, ./modules)

g++ -std=c++17 -O2 -Wall -Wno-multichar \
  -DLINK_PLATFORM_UNIX=1 -DLINK_PLATFORM_LINUX=1 \
  -I "$SDK/include" -I "$SDK/modules/asio-standalone/asio/include" \
  -static-libstdc++ -static-libgcc \
  -o "$WORK/ableton-linkd" ableton-linkd.cpp \
  -lpthread -latomic
strip "$WORK/ableton-linkd"
"$WORK/ableton-linkd" --help >/dev/null
install -m755 "$WORK/ableton-linkd" "$OUTPUT"
echo "built $OUTPUT"
