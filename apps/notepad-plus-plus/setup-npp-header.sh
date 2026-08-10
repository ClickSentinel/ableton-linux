#!/bin/sh
# Notepad++ for the Works runtime - single-file installer (self-extracting).
# Usage:  sh notepad-plus-plus-setup-@VERSION@.run [options]
# Options:
#   --uninstall      remove the launcher and payload; the Plug is kept
#   --extract DIR    unpack this installer's files into DIR and exit
#   --help           this text
#
# An app-only kit: it carries the Works infrastructure and the application,
# and no Wine runtime - one must already be installed. The store deduplicates
# runtimes by build, so only runtime-bearing kits ever add one.
# Everything after the marker line is a tar archive; this header never changes it.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
export LC_ALL=C.UTF-8

VERSION="@VERSION@"
PAYLOAD_SHA="@PAYLOAD_SHA@"
self="$(readlink -f -- "$0")"

say()  { printf '%s\n' "$*"; }
fail() { printf '!! %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Notepad++ for the Works runtime - single-file installer (self-extracting).
Usage:  sh notepad-plus-plus-setup-@VERSION@.run [options]
Options:
  --uninstall      remove the launcher and payload; the Plug is kept
  --extract DIR    unpack this installer's files into DIR and exit
  --help           this text
EOF
}

mode=install
extract_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h)   usage; exit 0 ;;
        --uninstall) mode=uninstall ;;
        --extract)   mode=extract; extract_dir="${2:?--extract needs a directory}"; shift ;;
        *)           fail "unknown option: $1 (try --help)" ;;
    esac
    shift
done

say "== Notepad++ for Works $VERSION =="

workdir="$(mktemp -d "${TMPDIR:-/tmp}/npp-setup.XXXXXX")"
cleanup() {
    rc=$?
    if [ "$rc" -eq 0 ]; then rm -rf "$workdir"
    else say "(kept $workdir for inspection; the failure details are above)"; fi
    exit "$rc"
}
trap cleanup EXIT

offset="$(awk '/^__PAYLOAD_BELOW__$/{print NR+1; exit}' "$self")"
[ -n "$offset" ] || fail "this installer file is incomplete: copy or download the .run file again"
say "-- checking the installer's own files and unpacking them"
tail -n +"$offset" "$self" > "$workdir/payload.tar"
actual="$(sha256sum "$workdir/payload.tar" | awk '{print $1}')"
[ "$actual" = "$PAYLOAD_SHA" ] || fail "this installer file failed its integrity check; copy the .run file again and retry"
kit="$workdir/kit"
mkdir -p "$kit"
tar -xf "$workdir/payload.tar" -C "$kit"
rm -f "$workdir/payload.tar"

case "$mode" in
    extract)
        mkdir -p "$extract_dir"
        cp -a "$kit/." "$extract_dir/"
        say "OK: kit extracted to $extract_dir"
        ;;
    uninstall)
        bash "$kit/apps/notepad-plus-plus/install-notepad-plus-plus.sh" uninstall
        ;;
    install)
        bash "$kit/apps/notepad-plus-plus/install-notepad-plus-plus.sh"
        ;;
esac
exit 0
__PAYLOAD_BELOW__
