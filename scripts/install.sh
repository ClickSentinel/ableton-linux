#!/usr/bin/env bash
# End-user step 1: install the Wine runtime, launcher, and desktop entries (reverse with uninstall.sh).
# Does not touch the Wine prefix: that is setup-prefix.sh.
set -euo pipefail
# readelf and sha256sum output is parsed below; localised output breaks the
# checks (issue #36). C.UTF-8, never plain C: wine cannot create non-ASCII
# filenames under a non-UTF-8 locale (issues #51, #55).
export LC_ALL=C.UTF-8
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
# The Wires files sit beside this script in a kit (the kit is flat) and in
# wires/ in a checkout. Resolved once; every stage below uses it.
wires_src="$here"; [ -f "$wires_src/wires" ] || wires_src="$root/wires"

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
# Runtime naming, path resolution, tarball selection and the process scan all
# resolve in one place; see wires/runtime-env.sh.
for _l in "$(dirname "$0")/runtime-env.sh" "$root/wires/runtime-env.sh"; do
    # shellcheck source=wires/runtime-env.sh
    [ -r "$_l" ] && . "$_l" && break
done
command -v wires_runtime_path >/dev/null 2>&1 || {
    echo "!! runtime-env.sh not found next to $0" >&2; exit 1; }
NAME="$(wires_runtime_name)"
verb_spoke=0

cleanup()
{
    rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ "$verb_spoke" -eq 0 ]; then
        # Only for aborts before the runtime install runs: past that point the
        # verb owns the rollback and has already said what happened.
        echo "!! install aborted; nothing was changed" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT

# tarball: prefer dist/ (freshly built), else a release tarball dropped in root
if [ -n "${WIRES_RUNTIME_TARBALL:-}" ]; then
    tarball="$WIRES_RUNTIME_TARBALL"
    [ -f "$tarball" ] || { echo "!! WIRES_RUNTIME_TARBALL is not a file: $tarball" >&2; exit 1; }
else
    tarball="$(wires_pick_tarball "$root/dist")"
    [ -n "$tarball" ] || tarball="$(wires_pick_tarball "$root")"
fi
[ -n "$tarball" ] || { echo "!! no ${NAME}-*.tar.zst found: run ./build.sh first, or drop a release tarball in $root/dist/"; exit 1; }

echo "== verify checksum =="
if [ -f "$tarball.sha256" ]; then
    ( cd "$(dirname "$tarball")" && sha256sum -c "$(basename "$tarball").sha256" )
else
    echo "   (no .sha256 next to tarball: skipping)"
fi

# --- the infrastructure gate --------------------------------------------------
# Decided by Wires itself: wires/install-wires.sh owns both the arbitration and
# the write, because the infrastructure is not this application's to version.
# check runs here - before anything is stopped or moved, since two of its
# outcomes are refusals and a refusal this early leaves the machine untouched -
# and the write happens after the runtime lands, applying the same decision.
#
#   exit 0  install (or refresh) the infrastructure     the silent path
#   exit 3  a newer one is installed; keep it, this kit adds only its app
#   exit 1  refused - stranding, or this kit is too old for this machine
#
# The floor this kit's application declares is read from its own launcher and
# passed in: which generation the app needs is app knowledge, and the gate
# should not know where any application keeps it.
kit_app_min="$(wires_abi_field "$here/ableton-live" WIRES_ABI_MIN 2>/dev/null || echo 1)"
gate_rc=0
"$wires_src/install-wires.sh" check --app-min "$kit_app_min" || gate_rc=$?
# 3 (keep the newer infrastructure) proceeds like 0: the write step re-derives
# the same decision and keeps it, so nothing here needs to remember which.
case "$gate_rc" in 0|3) ;; *) exit 1 ;; esac

# Which channel this kit belongs to, not which one the machine follows:
# installing a nightly while configured for stable must not point `stable` at a
# nightly build. Kits older than the marker say nothing, and stable is what
# they all were. Passed to the verb as an argument - a caller handing over a
# flag is legible where a caller planting a file the callee reads is not.
CHANNEL="stable"
for _c in "$here/../channel" "$root/dist/channel"; do
    [ -r "$_c" ] || continue
    case "$(head -1 "$_c" | tr -d '[:space:]')" in
        stable)  CHANNEL=stable ;;
        nightly) CHANNEL=nightly ;;
    esac
    break
done

# ableton-linkd is not part of the runtime tree; the kit carries it in bin/, a
# checkout in dist/. Checked before the runtime install so a kit missing its
# own pieces stops while nothing has moved.
linkd=""
for f in "$here/../bin/ableton-linkd" "$root/dist/ableton-linkd"; do
    if [ -f "$f" ]; then linkd="$f"; break; fi
done
[ -n "$linkd" ] || { echo "!! package is missing bin/ableton-linkd" >&2; exit 1; }
linkd_unit=""
for f in "$here/ableton-linkd.service" "$root/scripts/ableton-linkd.service"; do
    if [ -f "$f" ]; then linkd_unit="$f"; break; fi
done
[ -n "$linkd_unit" ] || { echo "!! package is missing scripts/ableton-linkd.service" >&2; exit 1; }
if command -v readelf >/dev/null; then
    # ableton-linkd must resolve against host C-runtime sonames only:
    # -static-libstdc++/-static-libgcc keep libstdc++ and libgcc_s out of
    # DT_NEEDED, and any other dependency means those flags were omitted.
    linkd_needed="$(readelf -d "$linkd" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')"
    for so in $linkd_needed; do
        case "$so" in
            linux-vdso.so*|libm.so*|libc.so*|libpthread.so*|libatomic.so*|ld-linux*.so*) ;;
            *) echo "!! ableton-linkd links an unexpected library: $so" >&2
               exit 1 ;;
        esac
    done
    if printf '%s\n' "$linkd_needed" | grep -q libstdc++; then
        echo "!! ableton-linkd links a shared libstdc++ (needs -static-libstdc++)" >&2
        exit 1
    fi
fi

# The store lifecycle - stop, migrate, stage, guard, promote, prune, and the
# rollback if any of it fails - is Wires' own: `wires runtime install` owns it
# whole, and this application vouches for the build's contents through the
# validator it passes in. WIRES_RUNTIME reaches the verb through the
# environment and keeps its meaning: pinned installs are flat, with a dated
# rollback and no channel.
verb_spoke=1
"$wires_src/wires-runtime" install "$tarball" --channel "$CHANNEL" \
    --validate "$here/validate-runtime.sh"

echo "== install launcher -> ~/wires/apps/ableton-live =="
mkdir -p "$BIN" "$HOME/wires/apps/ableton-live" "$HOME/wires/bin" "$HOME/wires/lib"
# The launcher belongs to the application, so it lives with it and ~/.local/bin
# holds a link. Anything else means the app's directory does not contain the app:
# backing up ~/wires would miss its entry point, and removing the app directory
# would leave a working command behind pointing at nothing.
install -m755 "$here/ableton-live" "$HOME/wires/apps/ableton-live/ableton-live"
ln -sfn "$HOME/wires/apps/ableton-live/ableton-live" "$BIN/ableton-live"

# The infrastructure write, exactly as `check` decided it up top: the command,
# the verbs, the shared library, the PATH link, and the legacy cleanup all live
# in wires/install-wires.sh, because none of it is this application's.
"$wires_src/install-wires.sh" install

# Dated copies of the launcher accumulated here on every install, one per run,
# with nothing to prune them - the same defect the version store exists to end,
# on the PATH this time. The store rolls the runtime back and the launcher comes
# from the kit, so the copies bought nothing. Clear out any left behind.
rm -f "$BIN"/ableton-live.rollback-* 2>/dev/null || true

echo "== install the shared toolkit -> ~/wires/lib =="
# The launcher sources these on every start (DPI auto-calibration, light/dark
# theme sync, and crash-safe GNOME shortcut holding).
# Two directories because they hold two different things: the toolkit any
# application sources, and this application's own payload.
mkdir -p "$HOME/wires/lib" "$HOME/wires/apps/ableton-live"
# The app toolkit lives with the app, not in lib: lib is generation-locked by
# the infrastructure gate, so app payload there would skip its own update
# whenever a newer infrastructure is kept - and the app's directory should
# contain the app. The launcher sources these as siblings.
install -m644 "$here/detect-scale.sh" "$HOME/wires/apps/ableton-live/detect-scale.sh"
install -m644 "$here/detect-theme.sh" "$HOME/wires/apps/ableton-live/detect-theme.sh"
install -m644 "$here/shortcut-hold.sh" "$HOME/wires/apps/ableton-live/shortcut-hold.sh"
# setsyscolors.exe repaints the top bar mid-session when the Live theme changes;
# without it the colors still apply on the next launch. Kit stages it next to
# these scripts; a repo checkout carries it in tools/.
for f in "$here/setsyscolors.exe" "$root/tools/setsyscolors.exe"; do
    if [ -f "$f" ]; then
        install -m644 "$f" "$HOME/wires/apps/ableton-live/setsyscolors.exe"
        break
    fi
done
# learnheal.exe auto-heals the Learn View / doc sidebar fossil-on-open
# (notes/ABLETON-WINE-LEARNVIEW-FLICKER.md); without it the pane needs a
# manual splitter nudge once per session.
for f in "$here/learnheal.exe" "$root/tools/learnheal.exe"; do
    if [ -f "$f" ]; then
        install -m644 "$f" "$HOME/wires/apps/ableton-live/learnheal.exe"
        break
    fi
done
# ableton-linkd anchors the Ableton Link session natively so tempo and
# timeline survive a Live restart (notes/ABLETON-WINE-LINK-FIRSTCLASS.md).
# The launcher auto-starts it. The .run wrapper calls setup-link.sh once after
# this install; repository installs may call the staged script directly.
# Stop a running daemon before replacing the binary, else the old process
# keeps running from the deleted inode and the update takes effect only
# after a reboot. SIGTERM is a clean exit for it, so Restart=on-failure
# does not undo the stop.
linkd_active=0
if systemctl --user is-active --quiet ableton-linkd.service 2>/dev/null; then
    linkd_active=1
    systemctl --user stop ableton-linkd.service 2>/dev/null || true
fi
pkill -x ableton-linkd 2>/dev/null || true   # launcher-started instance, no unit
install -m755 "$linkd" "$HOME/wires/apps/ableton-live/ableton-linkd"
install -m644 "$linkd_unit" "$HOME/wires/apps/ableton-live/ableton-linkd.service"
if [ "$linkd_active" -eq 1 ]; then
    systemctl --user start ableton-linkd.service 2>/dev/null || true
fi
# Keep the setup command installed for retries after a firewall or
# hook-removal failure.
install -m755 "$here/setup-link.sh" "$HOME/wires/apps/ableton-live/setup-link.sh"

# The prefix setup belongs to this application, not to the runtime: it seeds
# fonts, winetricks components and registry policy for Live specifically. It has
# only ever been run out of the unpacked kit, which the .run deletes on the way
# out - so it existed on no installed machine, `wires plug new` printed a path to
# it that could not work, and there was no supported way to set a second Plug up
# at all. That is what blocked the documented recovery for a 32-bit prefix.
install -m755 "$here/setup-prefix.sh" "$HOME/wires/apps/ableton-live/setup-prefix.sh"

# Where this application's kit came from, so an updater can ask the right channel
# for the right application without a table of URLs in the library every
# application shares. One line, written by the installer from the kit that
# installed it; never edited by hand, and absent on a checkout install, which has
# no origin to record.
for _o in "$here/../origin" "$root/dist/origin"; do
    [ -r "$_o" ] || continue
    install -m644 "$_o" "$HOME/wires/apps/ableton-live/origin"
    break
done

# Record the application's version so a later installer can tell what it is
# updating. The release version only: the kit label carries the runtime build
# discriminator, and an application listing that shows a runtime id in its
# VERSION column is reporting the wrong object's version.
_v="$(cat "$root/VERSION" 2>/dev/null || echo unknown)"
printf '%s\n' "${_v%%+*}" > "$HOME/wires/apps/ableton-live/VERSION"

echo "== install desktop entries -> $APPS =="
mkdir -p "$APPS"
# Detect the installed Live edition for the menu entry (issue #39): the
# newest Program exe under the prefix wins, matching the launcher's
# discovery. Without an install yet, generic values apply; the launcher
# completes the entry on the first start after Live is installed.
live_name="Ableton Live"
live_icon="live-suite"
live_wmclass=""
live_prefix="$(wires_plug_path)"
newest=""
for exe in "$live_prefix"/drive_c/ProgramData/Ableton/Live*/Program/Ableton\ Live*.exe; do
    [ -e "$exe" ] || continue
    if [ -z "$newest" ] || [ "$exe" -nt "$newest" ]; then newest="$exe"; fi
done
if [ -n "$newest" ]; then
    live_name="$(basename "$newest" .exe)"
    live_wmclass="$(basename "$newest" | tr '[:upper:]' '[:lower:]')"
    edition="$(printf '%s' "$live_name" | awk '{print tolower($NF)}')"
    if [ -f "$root/desktop/icons/scalable/apps/live-$edition.svg" ]; then
        live_icon="live-$edition"
    fi
fi
# Does this entry belong to someone else? Only a file that is actually a
# desktop entry - non-empty, with an Exec line - and whose Exec does not route
# through our launcher.
hand_made_desktop() {
    [ -s "$1" ] || return 1
    grep -q '^Exec=' "$1" || return 1
    ! grep -qF "$2" "$1"
}

# The visible launcher entry: an entry whose Exec does not route through the
# launcher is treated as hand-made and preserved; ours is refreshed so the
# name, icon and WM class track the installed edition.
#
# Hand-made means it has an Exec line. Testing existence alone preserved an
# empty file forever, so a truncated entry left by an interrupted install kept
# every later install from writing a working one (found on the fedora rig,
# zero bytes, preserved across four installs).
if hand_made_desktop "$APPS/ableton-live.desktop" "$BIN/ableton-live"; then
    echo "   preserving existing $APPS/ableton-live.desktop (it does not route through the launcher)"
else
    sed -e "s#@HOME@#$HOME#g" -e "s#@NAME@#$live_name#g" \
        -e "s#@ICON@#$live_icon#g" -e "s#@WMCLASS@#$live_wmclass#g" \
        "$root/desktop/ableton-live.desktop.in" > "$APPS/ableton-live.desktop"
    # A guessed window class would not match the installed edition's window.
    [ -n "$live_wmclass" ] || sed -i '/^StartupWMClass=/d' "$APPS/ableton-live.desktop"
    echo "   installed $APPS/ableton-live.desktop ($live_name)"
fi
# The authorisation handlers (ableton: URLs, .auz response files). They take
# winemenubuilder's canonical names on purpose: a prefix where winemenubuilder
# still runs (a Live beta in a scratch prefix, say) exports its own handler
# over ours, pointing at stock wine and the wrong prefix. An entry that does
# not route through the launcher is replaced, not preserved, and canonical
# copies are staged for the launcher's start-time repair.
# See notes/ABLETON-WINE-ONLINE-AUTH.md.
for d in wine-protocol-ableton wine-extension-auz; do
    sed "s#@HOME@#$HOME#g" "$root/desktop/$d.desktop.in" > "$HOME/wires/apps/ableton-live/$d.desktop"
    if [ -e "$APPS/$d.desktop" ] && grep -qF "$BIN/ableton-live" "$APPS/$d.desktop"; then
        echo "   preserving existing $APPS/$d.desktop"
    else
        [ ! -e "$APPS/$d.desktop" ] || echo "   replacing $APPS/$d.desktop (it does not route through the launcher)"
        cp "$HOME/wires/apps/ableton-live/$d.desktop" "$APPS/$d.desktop"
    fi
done
update-desktop-database "$APPS" 2>/dev/null || true

echo "== install icons =="
# App and MIME icons (issue #39, PR #25). User-local hicolor is the fallback
# theme on every desktop; scalable SVGs need no cache.
ICONS="$HOME/.local/share/icons/hicolor"
install -d "$ICONS/scalable/apps" "$ICONS/scalable/mimetypes" "$ICONS/symbolic/apps"
install -m644 "$root"/desktop/icons/scalable/apps/*.svg "$ICONS/scalable/apps/"
install -m644 "$root"/desktop/icons/scalable/mimetypes/*.svg "$ICONS/scalable/mimetypes/"
install -m644 "$root"/desktop/icons/symbolic/apps/*.svg "$ICONS/symbolic/apps/"
gtk-update-icon-cache -q "$ICONS" 2>/dev/null || true

echo "== register the authorisation MIME types =="
# .auz is the response file ableton.com serves for offline authorisation. The
# prefix side is registered by Live's installer; the host side is ours, since
# winemenubuilder (which would export it) is disabled by setup-prefix.sh.
mkdir -p "$HOME/.local/share/mime/packages"
install -m644 "$root/desktop/x-wine-extension-auz.xml" "$HOME/.local/share/mime/packages/x-wine-extension-auz.xml"
# Live document types: sets, clips, packs and the rest (issue #40, PR #25).
install -m644 "$root/desktop/icons/application-ableton-live.xml" "$HOME/.local/share/mime/packages/application-ableton-live.xml"
update-mime-database "$HOME/.local/share/mime" >/dev/null 2>&1 || true
# Pin the defaults: with a second claimant present, cache order decides, and
# Chromium consults only the mimeapps.list default.
if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default wine-protocol-ableton.desktop x-scheme-handler/ableton 2>/dev/null || true
    xdg-mime default wine-extension-auz.desktop application/x-wine-extension-auz 2>/dev/null || true
    xdg-mime default ableton-live.desktop application/x-ableton-live-set \
        application/x-ableton-live-clip application/x-ableton-live-pack 2>/dev/null || true
fi

# Standalone Max 9 in the same prefix, only when present; rerun the
# installer after adding Max. Removes the winemenubuilder exports a
# stray default-prefix run leaves behind: they run stock wine against
# the patched-runtime prefix and their MIME claims shadow ours.
max_unix="$live_prefix/drive_c/Program Files/Cycling '74/Max 9/Max.exe"
if [ -f "$max_unix" ]; then
    echo "== install the Max 9 launcher =="
    install -m755 "$here/max9" "$BIN/max9"
    if hand_made_desktop "$APPS/max9.desktop" "$BIN/max9"; then
        echo "   preserving existing $APPS/max9.desktop (it does not route through the launcher)"
    else
        sed "s#@HOME@#$HOME#g" "$root/desktop/max9.desktop.in" > "$APPS/max9.desktop"
    fi
    sed "s#@HOME@#$HOME#g" "$root/desktop/wine-protocol-c74max.desktop.in" > "$APPS/wine-protocol-c74max.desktop"
    # Stable icon name from the winemenubuilder-extracted set, when present
    # (the hex prefix varies per install).
    for d in 16x16 24x24 32x32 48x48 128x128 256x256; do
        for f in "$ICONS/$d/apps/"*_Max.0.png; do
            [ -e "$f" ] || continue
            cp -f "$f" "$ICONS/$d/apps/max9.png"
            break
        done
    done
    rm -f "$APPS/wine/Programs/Cycling '74/Max 9/Max 9.desktop"
    rmdir -p "$APPS/wine/Programs/Cycling '74/Max 9" 2>/dev/null || true
    for e in maxpat maxproj maxhelp maxzip amxd mxf; do
        f="$APPS/wine-extension-$e.desktop"
        if [ -e "$f" ] && ! grep -qF "$BIN/" "$f"; then rm -f "$f"; fi
        rm -f "$HOME/.local/share/mime/packages/x-wine-extension-$e.xml"
    done
    update-mime-database "$HOME/.local/share/mime" >/dev/null 2>&1 || true
    update-desktop-database "$APPS" 2>/dev/null || true
    if command -v xdg-mime >/dev/null 2>&1; then
        xdg-mime default max9.desktop application/x-ableton-live-max-device 2>/dev/null || true
        xdg-mime default wine-protocol-c74max.desktop x-scheme-handler/c74max 2>/dev/null || true
    fi
    echo "   installed max9 launcher and desktop entry"
fi

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "!! note: $BIN is not on your PATH: add it or call ~/.local/bin/ableton-live directly" ;;
esac

# winegstreamer resolves against the host GStreamer at runtime (issue #44).
# Live runs without it (wav/aiff), so this is a note, not a failure.
# no grep -q: under pipefail it SIGPIPEs ldconfig and falsely fires this note
if ! ldconfig -p 2>/dev/null | grep 'libgstreamer-1\.0\.so\.0' >/dev/null; then
    echo "!! note: no host libgstreamer-1.0.so.0 found: mp3 and video import will not work until GStreamer (with its base and good plugin sets) is installed"
fi

trap - EXIT

echo
# The verb owns rollback either way: the store keeps previous builds, a pinned
# install keeps a dated sibling.
if [ -n "${WIRES_RUNTIME:-}" ]; then
    echo "OK. A dated rollback of the previous runtime sits beside the pin."
else
    echo "OK. Previous builds stay in the store: wires runtime list"
fi
echo "Next: ./scripts/setup-prefix.sh"
