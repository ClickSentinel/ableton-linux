#!/usr/bin/env bash
# Assemble dist/notepad-plus-plus-setup-<version>.run: the app-only kit as a
# single file. The kit inside carries the repository's own shape - works/ and
# apps/notepad-plus-plus/ - so the scripts run unmodified from checkout and kit.
set -euo pipefail
export LC_ALL=C.UTF-8
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cd "$root"

VERSION="$(sed -n 's/^VERSION=//p' "$here/install-notepad-plus-plus.sh" | head -1)"
[ -n "$VERSION" ] || { echo "!! no VERSION in install-notepad-plus-plus.sh" >&2; exit 1; }

# The vendored payload, verified against the installer's own pin before it is
# packed: a kit that would refuse its own payload must not build.
pin="$(sed -n 's/^NPP_SHA256=//p' "$here/install-notepad-plus-plus.sh" | head -1)"
payload=""
for f in "$here"/npp.*.Installer*.exe "$HOME/Downloads/npp.${VERSION}.Installer.x64.exe"; do
    [ -f "$f" ] && { payload="$f"; break; }
done
[ -n "$payload" ] || { echo "!! no npp installer exe beside $here or in ~/Downloads" >&2; exit 1; }
got="$(sha256sum "$payload" | cut -d' ' -f1)"
[ "$got" = "$pin" ] || { echo "!! $payload does not match the installer's pinned sha256" >&2; exit 1; }

echo "== stage the kit =="
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
kit="$stage/kit"
mkdir -p "$kit/works" "$kit/apps/notepad-plus-plus"
cp -a works/runtime-env.sh works/works works/works-runtime works/works-update \
      works/works-plug works/install-works.sh "$kit/works/"
cp -a "$here/install-notepad-plus-plus.sh" "$here/notepad-plus-plus" \
      "$here/ONBOARDING.md" "$kit/apps/notepad-plus-plus/"
install -m644 "$payload" "$kit/apps/notepad-plus-plus/$(basename "$payload")"

echo "== pack and seal =="
mkdir -p dist
tar -C "$kit" -cf "$stage/payload.tar" .
sha="$(sha256sum "$stage/payload.tar" | cut -d' ' -f1)"
out="dist/notepad-plus-plus-setup-${VERSION}.run"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@PAYLOAD_SHA@/$sha/g" \
    "$here/setup-npp-header.sh" > "$out"
cat "$stage/payload.tar" >> "$out"
chmod +x "$out"
( cd dist && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )

echo "== self-check: the sealed kit unpacks and refuses without a runtime =="
check="$(mktemp -d)"
sh "$out" --extract "$check/kit" >/dev/null
[ -x "$check/kit/works/install-works.sh" ] || { echo "!! extracted kit is missing works/" >&2; exit 1; }
[ -f "$check/kit/apps/notepad-plus-plus/$(basename "$payload")" ] || { echo "!! extracted kit is missing the payload" >&2; exit 1; }
# An empty HOME has no runtime; the app-only kit must refuse, not half-install.
if env -i PATH="$PATH" HOME="$check/home" sh "$out" > "$check/refusal.log" 2>&1; then
    echo "!! installed with no runtime present; an app-only kit must refuse" >&2; exit 1
fi
grep -q "no Works runtime is installed" "$check/refusal.log" || {
    echo "!! refused for the wrong reason:" >&2; cat "$check/refusal.log" >&2; exit 1; }
rm -rf "$check"

echo
echo "OK: $out ($(du -h "$out" | cut -f1))"
