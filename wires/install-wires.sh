#!/usr/bin/env bash
# Install the Wires infrastructure: the shared library, the wires command, and
# its verbs. Nothing here is an application's; the application's installer
# calls this and then installs its own payload.
#
#   install-wires.sh check [--app-min N]    decide, refuse, or ask - writes nothing
#   install-wires.sh install                the write, applying what check decided
#
# Two entry points because the decision and the write belong at different
# moments of an application install: check before anything is stopped or moved
# (two outcomes are refusals, and that early a refusal leaves the machine
# untouched), install after the runtime lands. install re-derives the answer
# from the same files rather than trusting state passed between calls.
#
# Every kit carries its own copy of this infrastructure - one self-sufficient
# installer is the distribution model - so every install is also a write onto a
# machine other applications may depend on. Unguarded, whichever kit ran last
# would own ~/wires/lib. The ABI range (see runtime-env.sh) arbitrates:
#
#   kit newer, nobody stranded             install it        (the silent path)
#   kit newer, would strand an app         ask, naming them
#   kit older                              keep what is installed,
#                                          exit 3 - the app installs alone
#   kit older AND its app below OLDEST     refuse: exit 1
#
# "Newer" is two questions, not one. The ABI range answers whether an
# application can consume the installed interface; the shipment version answers
# which library is more recent. Compatibility alone leaves equal-ABI installs
# last-writer-wins - two kits both speaking ABI 1 carry different libraries.
set -euo pipefail
export LC_ALL=C.UTF-8

# The Wires files sit beside this script - in wires/ in a checkout, flat in a
# kit - which is what lets one script serve both layouts with no path table.
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wires/runtime-env.sh
. "$here/runtime-env.sh"

BIN="$HOME/.local/bin"
installed_lib="$HOME/wires/lib/runtime-env.sh"
installed_ver="$HOME/wires/lib/VERSION"
kit_abi="${WIRES_ABI:-1}"
kit_oldest="${WIRES_ABI_OLDEST:-1}"
inst_abi="$(wires_abi_field "$installed_lib" WIRES_ABI 2>/dev/null || echo 0)"
inst_oldest="$(wires_abi_field "$installed_lib" WIRES_ABI_OLDEST 2>/dev/null || echo 1)"

# The shipment's version, from $here/.. - the kit root in a kit, the repo root
# in a checkout, each holding VERSION. Kept unstripped: install.sh drops the
# +suffix when recording the *application's* version, and that collapses every
# build of one release to the same string, which this comparison cannot use.
kit_version="$(cat "$here/../VERSION" 2>/dev/null || echo 0)"
# Absent on a library installed before the stamp existed, which reads as 0 and
# loses to any real version.
inst_version="$(head -1 "$installed_ver" 2>/dev/null || echo 0)"

# 0 = install the infrastructure, 3 = keep the installed one. The refusal and
# the prompt live in `check`; decide() prints nothing.
#
# Two comparisons, in this order, because they answer different questions.
#
# The interface never goes backward: an installed higher ABI is kept whatever
# the versions say, since applications may declare a floor it satisfies and
# this kit's does not - installing over it is the mirror of the stranding the
# prompt below refuses.
#
# Within one interface, the newer shipment wins.
#
# Compared with sort -V, not -gt: these are release stamps like 2026.08.08.1,
# not integers. Equal versions install, so a rebuild of one release replaces
# itself rather than being refused.
#
# A labelled build sorts after the plain release of the same date - the
# opposite of wires_pick_tarball, which is choosing what to offer and ranks a
# release above a nightly. This asks which came later.
wires_version_older() {     # older <a> <b> -> true when $1 precedes $2
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

decide() {
    [ -r "$installed_lib" ] || return 0
    [ "$inst_abi" -gt "$kit_abi" ] && return 3
    if [ "$inst_abi" -eq "$kit_abi" ] && wires_version_older "$kit_version" "$inst_version"; then
        return 3
    fi
    return 0
}

cmd_check() {
    local app_min=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --app-min) shift; app_min="${1:-1}" ;;
            --app-min=*) app_min="${1#--app-min=}" ;;
            *) echo "!! install-wires check: unknown option $1" >&2; exit 2 ;;
        esac
        shift
    done
    # Refused, not defaulted. 1 is the most permissive floor there is, so a
    # mistyped --app-min would quietly turn the gate down rather than trip it,
    # and this argument comes from an installer rather than from a person.
    case "$app_min" in ''|*[!0-9]*)
        echo "!! install-wires check: --app-min takes a number, not '$app_min'" >&2
        exit 2 ;;
    esac

    if decide; then
        # Installing (or refreshing) this generation. The one question left is
        # whether this kit's OLDEST strands an application already here.
        local stranded
        stranded="$(wires_apps_below_min "$kit_oldest")"
        if [ -n "$stranded" ] && [ "${WIRES_ALLOW_ABI_BREAK:-0}" != 1 ]; then
            echo "!! Upgrading the Wires infrastructure to generation $kit_abi drops support" >&2
            echo "   for generations before $kit_oldest, and these installed applications" >&2
            echo "   declare an older floor:" >&2
            printf '%s\n' "$stranded" | sed 's/^/     /' >&2
            echo "   They would stop launching until each is updated with its own installer." >&2
            wires_ask_tty 'Continue anyway? [y/N] '
            case "$?" in
                0) ;;
                2) echo "   No terminal to ask on; set WIRES_ALLOW_ABI_BREAK=1 if you mean it." >&2
                   exit 1 ;;
                *) exit 1 ;;
            esac
        fi
        exit 0
    fi

    # A newer infrastructure is already here. Never downgrade it - but the
    # calling kit's application is about to run under it, so the promise has to
    # hold in the other direction too: the installed OLDEST must still cover
    # the floor that application declares.
    if [ "$inst_oldest" -gt "$app_min" ]; then
        echo "!! This kit's application is written against Wires generation $app_min," >&2
        echo "   and the installed infrastructure (generation $inst_abi) supports" >&2
        echo "   generation $inst_oldest at the oldest. This kit is too old for this" >&2
        echo "   machine: use a current installer." >&2
        exit 1
    fi
    echo "   wires: keeping the installed infrastructure (version $inst_version," \
         "generation $inst_abi; this kit carries version $kit_version," \
         "generation $kit_abi)"
    exit 3
}

cmd_install() {
    if ! decide; then
        # check already reported this; installing anyway is exactly the downgrade the
        # gate exists to prevent. Exit 0: keeping the newer one is success.
        exit 0
    fi
    mkdir -p "$HOME/wires/bin" "$HOME/wires/lib" "$BIN"
    # `wires` acts on the runtime and the store, which no application owns, so
    # it sits in wires/bin rather than in any app's directory. Its verbs go
    # beside the shared library: they implement the command, they are not
    # commands themselves.
    install -m755 "$here/wires" "$HOME/wires/bin/wires"
    # The verbs by glob, not by name: a list here is a list that can disagree
    # with what the kit carries, and the failure is a verb that installs but
    # cannot be reached.
    local _v
    for _v in "$here"/wires-*; do
        [ -f "$_v" ] || continue
        install -m755 "$_v" "$HOME/wires/lib/${_v##*/}"
    done
    install -m644 "$here/runtime-env.sh" "$HOME/wires/lib/runtime-env.sh"
    # Which shipment this library came from - the only record of it, and what
    # decide() reads on the next install.
    #
    # It follows the newest kit installed, not the selected runtime: the store
    # keeps many runtimes and a channel can move back to an older one, while
    # there is one library and it does not roll back with it. WIRES_ABI is what
    # keeps an older application running against it.
    printf '%s\n' "$kit_version" > "$HOME/wires/lib/VERSION"
    ln -sfn "$HOME/wires/bin/wires" "$BIN/wires"
    # Legacy PATH commands from before `wires`, and app-toolkit copies from
    # before the toolkit lived with its app - removed so lib stays what the
    # census and the gate say it is: Wires, whole, nothing else.
    rm -f "$BIN/ableton-runtime" "$BIN/ableton-update" \
          "$BIN/wires-runtime" "$BIN/wires-update" 2>/dev/null || true
    rm -f "$HOME/wires/lib/detect-scale.sh" "$HOME/wires/lib/detect-theme.sh" \
          "$HOME/wires/lib/shortcut-hold.sh" 2>/dev/null || true
}

case "${1:-}" in
    check)   shift; cmd_check "$@" ;;
    install) shift; cmd_install "$@" ;;
    *) echo "usage: install-wires.sh {check [--app-min N] | install}" >&2; exit 2 ;;
esac
