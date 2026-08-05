#!/usr/bin/env bash
# Assemble dist/ableton-wine-setup-<VERSION>.run: setup-run-header.sh + a tar of the end-user kit
# (runtime tarball, scripts, winetricks payloads, static cabextract, ableton-linkd).
# Repackaging only; Wine is not rebuilt.
set -euo pipefail
# ldd and sha256sum output is parsed below; localised output breaks the checks.
# C.UTF-8, never plain C: wine cannot create non-ASCII filenames under a
# non-UTF-8 locale (issues #51, #55).
export LC_ALL=C.UTF-8
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ableton-wine-build:22.04}"
# Runtime naming and tarball selection resolve in one place; see
# scripts/runtime-env.sh.
for _l in "$(dirname "$0")/runtime-env.sh" "$here/runtime-env.sh"; do
    # shellcheck source=scripts/runtime-env.sh
    [ -r "$_l" ] && . "$_l" && break
done
command -v ableton_pick_tarball >/dev/null 2>&1 || {
    echo "!! runtime-env.sh not found next to $0" >&2; exit 1; }
NAME="$(ableton_runtime_name)"
VERSION="$(cat VERSION)"
# ABLETON_RUNTIME_TARBALL pins one outright; otherwise the exact-version
# runtime if present, else the newest properly-named one. Never a bare glob.
if [ -n "${ABLETON_RUNTIME_TARBALL:-}" ]; then
    tarball="$ABLETON_RUNTIME_TARBALL"
    [ -f "$tarball" ] || { echo "!! ABLETON_RUNTIME_TARBALL is not a file: $tarball" >&2; exit 1; }
else
    tarball="dist/${NAME}-${VERSION}.tar.zst"
    [ -f "$tarball" ] || tarball="$(ableton_pick_tarball dist)"
fi

[ -n "$tarball" ] && [ -f "$tarball" ] || { echo "!! no ${NAME}-*.tar.zst in dist/: run ./build.sh first" >&2; exit 1; }
# The kit carries this tarball and the kit's own install.sh selects it by name,
# so a name the selector rejects builds a kit that packs cleanly and then dies
# on the user's machine with "no tarball found". Only the pin reaches here with
# an unchecked name — the branch above already filters — but the pin is exactly
# how a published nightly gets packed, and those are named
# <name>-<version>+nightly.<sha>.tar.zst.
#
# install.sh honours its own pin whatever the name, deliberately: there the
# consequence lands on whoever set the variable. Here it lands on whoever is
# handed the .run, so this refuses instead.
ableton_is_runtime_tarball "$tarball" || {
    echo "!! not a name the kit's install.sh will select: $(basename "$tarball")" >&2
    echo "   expected ${NAME}-<YYYY.MM.DD.N>.tar.zst — rename it, or drop it in dist/ under that name" >&2
    exit 1; }
[ -f "$tarball.sha256" ] || { echo "!! $tarball.sha256 missing" >&2; exit 1; }
echo "   runtime: $(basename "$tarball")"

echo "== [0/5] build audit (no unaudited runtime gets packed) =="
bash scripts/build-audit.sh "$tarball"

echo "== [1/5] static cabextract (bundled so SteamOS needs no extra package) =="
( cd vendor && sha256sum -c cabextract.sha256 )
if [ ! -x dist/cabextract-static ]; then
    command -v "$ENGINE" >/dev/null || { echo "!! need $ENGINE to build cabextract" >&2; exit 1; }
    relabel=""
    if [ -f /sys/fs/selinux/enforce ]; then relabel=",Z"; fi
    $ENGINE run --rm \
        -v "$root:/src:ro$relabel" \
        -v "$root/dist:/out:rw$relabel" \
        "$IMAGE" bash -ec '
            mkdir -p /work/cab && cd /work/cab
            tar xzf /src/vendor/cabextract-1.11.tar.gz --strip-components=1
            ./configure LDFLAGS="-static" >/dev/null
            make -s
            ldd cabextract 2>&1 | grep -q "not a dynamic executable" || {
                echo "!! cabextract did not link statically" >&2; exit 1; }
            ./cabextract --version
            strip cabextract
            install -m755 cabextract /out/cabextract-static'
fi
dist/cabextract-static --version >/dev/null 2>&1 || \
    { echo "!! dist/cabextract-static does not run on this host" >&2; exit 1; }
echo "   cabextract-static: $(dist/cabextract-static --version 2>&1 | head -1)"

echo "== [2/5] ableton-linkd (persistent Ableton Link peer, from the vendored SDK) =="
if [ ! -x dist/ableton-linkd ]; then
    ENGINE="$ENGINE" IMAGE="$IMAGE" ./scripts/build-ableton-linkd.sh
fi
dist/ableton-linkd --help >/dev/null 2>&1 || \
    { echo "!! dist/ableton-linkd does not run on this host" >&2; exit 1; }
echo "   ableton-linkd: $(du -h dist/ableton-linkd | cut -f1), statically carries libstdc++/libgcc"

echo "== [3/5] stage the kit =="
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
kit="$stage/kit"
mkdir -p "$kit/bin" "$kit/dist" "$kit/vendor"
cp -a "$tarball" "$tarball.sha256" "$kit/dist/"
cp -a "dist/BUILD-INFO-${VERSION}.txt" "$kit/" 2>/dev/null || true
mkdir -p "$kit/scripts"
cp -a scripts/runtime-env.sh scripts/install.sh scripts/setup-prefix.sh scripts/uninstall.sh \
      scripts/ableton-live scripts/max9 scripts/detect-scale.sh \
      scripts/detect-theme.sh scripts/check-live-audio.sh scripts/setup-link.sh \
      "$kit/scripts/"
install -m644 scripts/ableton-linkd.service "$kit/scripts/ableton-linkd.service"
install -m644 tools/setsyscolors.exe "$kit/scripts/setsyscolors.exe"
install -m644 tools/learnheal.exe "$kit/scripts/learnheal.exe"
cp -a desktop "$kit/desktop"
cp -a vendor/winetricks vendor/winetricks-cache "$kit/vendor/"
# Bitstream Vera must ship: it is the terminal entry of Max for Live's font
# fallback chain, and without it any M4L device that requests a typeface the
# prefix lacks hangs Live outright (frozen window, audio still playing). Not a
# nice-to-have - see notes/FINDINGS-M4L-CARBON-REGULATOR-DEADLOCK-2026-07-29.md
# and install_maxplug_fallback_fonts() in setup-prefix.sh.
( cd vendor && sha256sum -c bitstream-vera.sha256 )
mkdir -p "$kit/vendor/fonts/bitstream-vera"
# The notice ships beside the fonts as well as in licenses/, so the directory
# stays self-describing if it is copied out of an extracted kit on its own.
install -m644 vendor/fonts/bitstream-vera/*.ttf \
              vendor/fonts/bitstream-vera/COPYRIGHT.TXT \
              "$kit/vendor/fonts/bitstream-vera/"
cp -a VERSION README.md TROUBLESHOOTING.md BUILDING.md "$kit/"
install -m755 dist/cabextract-static "$kit/bin/cabextract"
install -m755 dist/ableton-linkd "$kit/bin/ableton-linkd"
# Ableton Link is GPLv2+ with no linking exception, so the built daemon's
# complete corresponding source travels with the kit: the pinned tarball in
# vendor/ plus the license text and a pointer note in licenses/.
install -m644 vendor/link-4.0.tar.zst "$kit/vendor/link-4.0.tar.zst"
mkdir -p "$kit/licenses"
tar -I zstd -xOf vendor/link-4.0.tar.zst ./LICENSE.md > "$kit/licenses/link-LICENSE.md"
cat > "$kit/licenses/SOURCE.txt" <<'EOF'
ableton-linkd is built from Ableton Link 4.0, GPLv2+; complete corresponding
source is in vendor/link-4.0.tar.zst in this kit and at https://github.com/Ableton/link
EOF
# The Bitstream Vera license permits redistribution of the unmodified fonts, but
# requires the copyright, trademark and permission notices travel with every
# copy. The fonts here are byte-identical upstream 1.10 files.
install -m644 vendor/fonts/bitstream-vera/COPYRIGHT.TXT \
              "$kit/licenses/bitstream-vera-COPYRIGHT.txt"

echo "== [4/5] pack + seal =="
payload="$stage/payload.tar"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    -cf "$payload" -C "$kit" .
payload_sha="$(sha256sum "$payload" | awk '{print $1}')"
out="dist/ableton-wine-setup-${VERSION}.run"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@PAYLOAD_SHA@/$payload_sha/g" \
    scripts/setup-run-header.sh > "$out"
cat "$payload" >> "$out"
chmod +x "$out"
( cd dist && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )

echo "== [5/5] wrapper self-check =="
sh "$out" --help >/dev/null
echo
echo "OK: $out ($(du -h "$out" | cut -f1))"
echo "Copy it (plus your Ableton installer .exe) to a USB stick and run:"
echo "  sh /run/media/*/*/ableton-wine-setup-${VERSION}.run"
