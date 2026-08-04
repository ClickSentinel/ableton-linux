# shellcheck shell=bash
# Where the patched Wine runtime and the Ableton prefix live, in one place.
#
# Sourced, never executed. Seven scripts resolved these paths independently
# before this existed, which was survivable while each was a single line with a
# default. It stops being survivable once the path depends on a release
# channel: the resolution grows a marker read, a validation, and two fallbacks,
# and seven copies of that will not stay in agreement. The collision is not
# hypothetical - PR #120 added a /proc scan and a wineserver stop that must
# scope to the same root install.sh is about to replace, and a resolver that
# disagrees there swaps a runtime out from under running processes.
#
# The resolvers are pure: they echo and touch nothing, so a caller takes only
# what it wants and they can be tested without a sandbox. Binding the current
# shell to the runtime is opt-in, because only three of the callers want it -
# the rest would be changed by an exported PATH or a cleared WINEDLLOVERRIDES.
#
#   . "$lib/runtime-env.sh"
#   WINE_ROOT="$(ableton_wine_root)"           # just the path
#   ableton_bind_runtime                       # the full launcher binding

# The installed runtime. ABLETON_WINE_ROOT overrides it - the tests, the
# regression VMs and anyone bisecting a build rely on that, so it stays the
# outermost say regardless of what channel support later resolves underneath.
ableton_wine_root() {
    printf '%s\n' "${ABLETON_WINE_ROOT:-$HOME/.local/opt/wine-d2d1-nspa-11.13}"
}

# The Ableton prefix. Separate from the runtime on purpose: a channel switch
# changes both, but a test or a clone changes only this one.
ableton_wine_prefix() {
    printf '%s\n' "${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
}

# Bind this shell to the runtime: drop inherited Wine settings that would
# reach the wrong build, then export what wine and its helpers read.
#
# The unset list is deliberately the four the launchers have always cleared.
# setup-prefix.sh additionally clears WINEESYNC and WINEFSYNC and keeps doing
# so at its own call site: folding them in here would silently start dropping a
# user's WINEESYNC on every launch, which is a behaviour change wearing a
# refactor's clothes.
ableton_bind_runtime() {
    unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH
    WINE_ROOT="$(ableton_wine_root)"
    WINEPREFIX="$(ableton_wine_prefix)"
    WINESERVER="$WINE_ROOT/bin/wineserver"
    PATH="$WINE_ROOT/bin:$PATH"
    export WINEPREFIX WINESERVER PATH
}

# The process table to read. Only the tests set this, pointing it at a fixture
# tree of fake exe symlinks; /proc cannot be stubbed through PATH the way pgrep
# can, so without a seam the accurate implementation is the untestable one.
ableton_proc_root() {
    printf '%s\n' "${ABLETON_PROC_ROOT:-/proc}"
}

# Every pid whose binary lives under the runtime. From PR #120, which found the
# reason a command line cannot answer this: Wine's in-prefix helpers show a
# Windows path in argv (C:\windows\system32\...), so no pattern reaches them.
# The exe link is the real binary - bin/wineserver, or the wine-preloader every
# in-prefix process runs from - so the match is exact rather than a guess, and
# is scoped to this runtime instead of any Wine on the machine.
ableton_runtime_pids() {
    local proc root d
    root="$(ableton_wine_root)"
    proc="$(ableton_proc_root)"
    for d in "$proc"/[0-9]*; do
        case "$(readlink "$d/exe" 2>/dev/null)" in
            "$root"/*) printf '%s\n' "${d##*/}" ;;
        esac
    done
}

# Anything at all using the runtime: the predicate to ask before replacing its
# files. The name match stays as a second opinion because failing open here
# means installing over a running runtime.
ableton_runtime_busy() {
    [ -n "$(ableton_runtime_pids)" ] || \
        pgrep -af '[A]bleton Live.*\.exe|[P]ush2DisplayProcess.exe' >/dev/null 2>&1
}

# Live itself, as opposed to the support processes around it. A launcher wants
# this and not runtime_busy: a wineserver lingering after Live exits must still
# count as "Live is down", or the stale-server kill never runs.
ableton_live_pids() {
    local proc p
    proc="$(ableton_proc_root)"
    for p in $(ableton_runtime_pids); do
        case "$(tr -s '\0' ' ' < "$proc/$p/cmdline" 2>/dev/null)" in
            *"Ableton Live"*.exe*) printf '%s\n' "$p" ;;
        esac
    done
}

ableton_live_running() {
    [ -n "$(ableton_live_pids)" ]
}
