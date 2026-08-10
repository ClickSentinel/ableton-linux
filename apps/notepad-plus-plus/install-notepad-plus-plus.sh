#!/usr/bin/env bash
# Install Notepad++ as a Works application, or remove it again.
#
#   install-notepad-plus-plus.sh [install]     into the selected Plug
#   install-notepad-plus-plus.sh uninstall     payload and launcher only; the
#                                              Plug is untouched
#
# The second-application probe: an app-only kit. It ships no runtime and
# requires one already installed - the store deduplicates by build, so only
# runtime-bearing kits ever add one.
set -euo pipefail
export LC_ALL=C.UTF-8
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

APP=notepad-plus-plus
VERSION=8.9.7
# The vendored installer, pinned. A payload that does not match is not installed.
NPP_SHA256=1884e093bae261c4942210334e1f2eae71354913e4ded3cc1a4a18c5320741ec

for _l in "$root/works/runtime-env.sh" "$HOME/works/lib/runtime-env.sh"; do
    [ -r "$_l" ] && . "$_l" && break
done
command -v works_runtime_path >/dev/null 2>&1 || {
    echo "!! runtime-env.sh not found under $root/works or ~/works/lib" >&2; exit 1; }

BIN="$HOME/.local/bin"
appdir="$HOME/works/apps/$APP"

if [ "${1:-install}" = uninstall ]; then
    rm -f "$BIN/$APP"
    rm -rf "$appdir"
    echo "removed $APP; the Plug and anything installed in it are untouched"
    exit 0
fi

# --- an app-only kit requires a runtime --------------------------------------
rt="$(works_runtime_path)"
if [ ! -x "$rt/bin/wine" ]; then
    echo "!! no Works runtime is installed ($rt does not hold a wine)." >&2
    echo "   This kit carries no runtime; install a runtime-bearing kit first." >&2
    exit 1
fi

# --- the infrastructure handshake --------------------------------------------
gate="$root/works/install-works.sh"
[ -x "$gate" ] || gate="$here/install-works.sh"
[ -x "$gate" ] || { echo "!! install-works.sh not found; this kit is incomplete" >&2; exit 1; }
rc=0; "$gate" check --app-min 1 || rc=$?
case "$rc" in 0|3) ;; *) exit 1 ;; esac

# --- payload ------------------------------------------------------------------
payload=""
for f in "$here"/npp.*.Installer*.exe "$HOME/Downloads"/npp.${VERSION}.Installer.x64.exe; do
    [ -f "$f" ] && { payload="$f"; break; }
done
[ -n "$payload" ] || {
    echo "!! no npp.*.Installer*.exe next to this script" >&2; exit 1; }
got="$(sha256sum "$payload" | cut -d' ' -f1)"
[ "$got" = "$NPP_SHA256" ] || {
    echo "!! $payload does not match the pinned checksum; refusing" >&2
    echo "   expected $NPP_SHA256" >&2
    echo "   got      $got" >&2
    exit 1; }

# --- the selected Plug --------------------------------------------------------
# Applications install into the Plug that selection resolves to: one prefix
# holds many tenants, and per-project Plugs are the user's act (works plug
# new / use), never an installer's default. WORKS_PLUG overrides per run.
plug="$(works_plug_path)"
if [ ! -d "$plug" ]; then
    if [ "$(dirname "$plug")" = "$(works_plugs_dir)" ]; then
        "$root/works/works-plug" new "${plug##*/}" || true
    fi
    mkdir -p "$plug"
fi
# First boot writes the registry and the base stamp; idempotent afterwards.
echo "== preparing the Plug =="
WINEPREFIX="$plug" WINEDLLOVERRIDES="mscoree,mshtml=" "$rt/bin/wineboot" -u
WINEPREFIX="$plug" "$rt/bin/wineserver" -w

echo "== installing Notepad++ $VERSION (silent) =="
WINEPREFIX="$plug" "$rt/bin/wine" "$payload" /S
WINEPREFIX="$plug" "$rt/bin/wineserver" -w
[ -f "$plug/drive_c/Program Files/Notepad++/notepad++.exe" ] || {
    echo "!! the installer ran but notepad++.exe is not in the Plug" >&2; exit 1; }

# --- the infrastructure write, then this application's own -------------------
"$gate" install
mkdir -p "$appdir" "$BIN"
install -m755 "$here/$APP" "$appdir/$APP"
printf '%s\n' "$VERSION" > "$appdir/VERSION"
ln -sfn "$appdir/$APP" "$BIN/$APP"

echo
echo "OK: Notepad++ $VERSION in the npp Plug. Launch: $APP"
