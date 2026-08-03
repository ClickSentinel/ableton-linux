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
