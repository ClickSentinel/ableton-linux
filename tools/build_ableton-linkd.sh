#!/usr/bin/env bash
# Build ableton-linkd (native Ableton Link session anchor + probe) from the
# vendored Link SDK: extracts vendor/link-4.0.tar.zst to a temp dir and
# compiles against THAT, so the build proves the vendored source is
# sufficient and never touches a checked-out ableton-link clone.
# Header-only C++17 + asio; static libstdc++/libgcc keep the shipped
# binary's DT_NEEDED to host libc/libm/libpthread/libatomic sonames only.
set -e
cd "$(dirname "$0")"
VENDOR=../vendor
TARBALL=$VENDOR/link-4.0.tar.zst

[ -f "$TARBALL" ] || { echo "!! $TARBALL missing (vendored Ableton Link SDK)" >&2; exit 1; }

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
  -o ableton-linkd ableton-linkd.cpp \
  -lpthread -latomic
echo "built ableton-linkd"
