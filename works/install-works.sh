#!/usr/bin/env bash
# Install the Works infrastructure: the shared library, the works command, and
# its verbs. Nothing here is an application's; the application's installer
# calls this and then installs its own payload.
#
#   install-works.sh check [--app-min N]    decide, refuse, or ask - writes nothing
#   install-works.sh install                the write, applying what check decided
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
# would own ~/works/lib. The ABI range (see runtime-env.sh) arbitrates:
#
#   kit newer or equal, nobody stranded    install it        (the silent path)
#   kit newer, would strand an app         ask, naming them
#   kit older, its app still supported     keep the newer infrastructure,
#                                          exit 3 - the app installs alone
#   kit older, its app below OLDEST        refuse: exit 1
#
# Equal generations install unconditionally: the contract is identical by
# definition of the number, so last-writer-wins is safe exactly there.
set -euo pipefail
export LC_ALL=C.UTF-8

# The Works files sit beside this script - in works/ in a checkout, flat in a
# kit - which is what lets one script serve both layouts with no path table.
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=works/runtime-env.sh
. "$here/runtime-env.sh"

BIN="$HOME/.local/bin"
installed_lib="$HOME/works/lib/runtime-env.sh"
kit_abi="${WORKS_ABI:-1}"
kit_oldest="${WORKS_ABI_OLDEST:-1}"
inst_abi="$(works_abi_field "$installed_lib" WORKS_ABI 2>/dev/null || echo 0)"
inst_oldest="$(works_abi_field "$installed_lib" WORKS_ABI_OLDEST 2>/dev/null || echo 1)"

# 0 = install the infrastructure, 3 = keep the installed one. The refusal and
# the prompt live in `check`; decide() prints nothing.
decide() {
    if [ -r "$installed_lib" ] && [ "$inst_abi" -gt "$kit_abi" ]; then
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
            *) echo "!! install-works check: unknown option $1" >&2; exit 2 ;;
        esac
        shift
    done
    case "$app_min" in ''|*[!0-9]*) app_min=1 ;; esac

    if decide; then
        # Installing (or refreshing) this generation. The one question left is
        # whether this kit's OLDEST strands an application already here.
        local stranded
        stranded="$(works_apps_below_min "$kit_oldest")"
        if [ -n "$stranded" ] && [ "${WORKS_ALLOW_ABI_BREAK:-0}" != 1 ]; then
            echo "!! Upgrading the Works infrastructure to generation $kit_abi drops support" >&2
            echo "   for generations before $kit_oldest, and these installed applications" >&2
            echo "   declare an older floor:" >&2
            printf '%s\n' "$stranded" | sed 's/^/     /' >&2
            echo "   They would stop launching until each is updated with its own installer." >&2
            if { : >/dev/tty; } 2>/dev/null; then
                printf 'Continue anyway? [y/N] ' > /dev/tty
                local ans=""
                read -r -t 60 ans < /dev/tty || printf '\n' > /dev/tty 2>/dev/null || true
                case "$ans" in y|Y|yes|Yes|YES) ;; *) exit 1 ;; esac
            else
                echo "   No terminal to ask on; set WORKS_ALLOW_ABI_BREAK=1 if you mean it." >&2
                exit 1
            fi
        fi
        exit 0
    fi

    # A newer infrastructure is already here. Never downgrade it - but the
    # calling kit's application is about to run under it, so the promise has to
    # hold in the other direction too: the installed OLDEST must still cover
    # the floor that application declares.
    if [ "$inst_oldest" -gt "$app_min" ]; then
        echo "!! This kit's application is written against Works generation $app_min," >&2
        echo "   and the installed infrastructure (generation $inst_abi) supports" >&2
        echo "   generation $inst_oldest at the oldest. This kit is too old for this" >&2
        echo "   machine: use a current installer." >&2
        exit 1
    fi
    echo "   works: keeping the installed infrastructure (generation $inst_abi;" \
         "this kit carries $kit_abi)"
    exit 3
}

cmd_install() {
    if ! decide; then
        # check already reported this; installing anyway is exactly the downgrade the
        # gate exists to prevent. Exit 0: keeping the newer one is success.
        exit 0
    fi
    mkdir -p "$HOME/works/bin" "$HOME/works/lib" "$BIN"
    # `works` acts on the runtime and the store, which no application owns, so
    # it sits in works/bin rather than in any app's directory. Its verbs go
    # beside the shared library: they implement the command, they are not
    # commands themselves.
    install -m755 "$here/works" "$HOME/works/bin/works"
    install -m755 "$here/works-runtime" "$HOME/works/lib/works-runtime"
    install -m755 "$here/works-update" "$HOME/works/lib/works-update"
    install -m755 "$here/works-plug" "$HOME/works/lib/works-plug"
    install -m755 "$here/works-app" "$HOME/works/lib/works-app"
    install -m644 "$here/runtime-env.sh" "$HOME/works/lib/runtime-env.sh"
    ln -sfn "$HOME/works/bin/works" "$BIN/works"
    # Legacy PATH commands from before `works`, and app-toolkit copies from
    # before the toolkit lived with its app - removed so lib stays what the
    # census and the gate say it is: Works, whole, nothing else.
    rm -f "$BIN/ableton-runtime" "$BIN/ableton-update" \
          "$BIN/works-runtime" "$BIN/works-update" 2>/dev/null || true
    rm -f "$HOME/works/lib/detect-scale.sh" "$HOME/works/lib/detect-theme.sh" \
          "$HOME/works/lib/shortcut-hold.sh" 2>/dev/null || true
}

case "${1:-}" in
    check)   shift; cmd_check "$@" ;;
    install) shift; cmd_install "$@" ;;
    *) echo "usage: install-works.sh {check [--app-min N] | install}" >&2; exit 2 ;;
esac
