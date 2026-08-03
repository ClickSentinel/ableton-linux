#!/usr/bin/env bats
#
# scripts/runtime-env.sh — the shared runtime and prefix resolution.
#
# Seven scripts resolved these paths independently until this existed. The
# resolvers are pure so they can be tested here rather than through a launcher
# sandbox, which is the whole reason they echo instead of assigning.
#
#   ./tests/run.sh tests/unit/runtime-env.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset ABLETON_WINE_ROOT ABLETON_WINEPREFIX
    unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH WINEESYNC WINEFSYNC
    . "$REPO/scripts/runtime-env.sh"
}

@test "runtime root: defaults under the user's own opt directory" {
    [ "$(ableton_wine_root)" = "$HOME/.local/opt/wine-d2d1-nspa-11.13" ]
}

@test "runtime root: ABLETON_WINE_ROOT wins, so a bisect or VM run can pin one" {
    ABLETON_WINE_ROOT=/tmp/altroot
    [ "$(ableton_wine_root)" = "/tmp/altroot" ]
}

@test "prefix: defaults to ~/.wine-ableton" {
    [ "$(ableton_wine_prefix)" = "$HOME/.wine-ableton" ]
}

@test "prefix: ABLETON_WINEPREFIX wins, which the clone workflow depends on" {
    ABLETON_WINEPREFIX=/tmp/altpfx
    [ "$(ableton_wine_prefix)" = "/tmp/altpfx" ]
}

@test "root and prefix are independent: overriding one leaves the other alone" {
    ABLETON_WINE_ROOT=/tmp/altroot
    [ "$(ableton_wine_prefix)" = "$HOME/.wine-ableton" ]
    unset ABLETON_WINE_ROOT
    ABLETON_WINEPREFIX=/tmp/altpfx
    [ "$(ableton_wine_root)" = "$HOME/.local/opt/wine-d2d1-nspa-11.13" ]
}

@test "the resolvers are pure: calling them exports and unsets nothing" {
    WINEDLLOVERRIDES=mscoree=n
    ableton_wine_root >/dev/null
    ableton_wine_prefix >/dev/null
    [ "${WINEDLLOVERRIDES:-gone}" = "mscoree=n" ]
    [ -z "${WINEPREFIX:-}" ]
    [ -z "${WINESERVER:-}" ]
}

@test "binding exports the prefix, the server, and the runtime's bin on PATH" {
    ABLETON_WINE_ROOT=/tmp/altroot
    ableton_bind_runtime
    [ "$WINE_ROOT" = "/tmp/altroot" ]
    [ "$WINESERVER" = "/tmp/altroot/bin/wineserver" ]
    [ "${PATH%%:*}" = "/tmp/altroot/bin" ]
    [ "$WINEPREFIX" = "$HOME/.wine-ableton" ]
}

# guards: the four cleared here are the launchers' long-standing set
@test "binding clears inherited Wine settings that would reach the wrong build" {
    WINELOADER=/usr/bin/wine WINEDLLPATH=/usr/lib WINEDLLOVERRIDES=mscoree=n WINEARCH=win32
    ableton_bind_runtime
    for v in WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH; do
        [ -z "${!v:-}" ] || { echo "$v survived binding as '${!v}'" >&2; false; }
    done
}

# guards: setup-prefix.sh clears these two itself; folding them in would drop a
# user's WINEESYNC on every launch, a behaviour change wearing a refactor's clothes
@test "binding leaves the sync backends alone, unlike setup-prefix.sh's own unset" {
    WINEESYNC=1 WINEFSYNC=1
    ableton_bind_runtime
    [ "${WINEESYNC:-}" = "1" ]
    [ "${WINEFSYNC:-}" = "1" ]
}
