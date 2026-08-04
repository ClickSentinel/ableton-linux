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
    setup_stubs
    stub pgrep 1                # runtime_busy's fallback must not read the host
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

# --- process detection -------------------------------------------------------
# /proc cannot be stubbed through PATH, so the lib reads ABLETON_PROC_ROOT and
# these build a fixture tree instead of trusting whatever the machine is doing.

fake_proc() {   # fake_proc <pid> <exe-target> [cmdline]
    local d="$ABLETON_PROC_ROOT/$1"
    mkdir -p "$d"
    ln -sfn "$2" "$d/exe"
    [ $# -lt 3 ] || printf '%s\0' "$3" > "$d/cmdline"
}

proc_setup() {
    export ABLETON_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
    export ABLETON_WINE_ROOT="$BATS_TEST_TMPDIR/rt"
    mkdir -p "$ABLETON_PROC_ROOT"
}

@test "runtime pids: a process running from the runtime is found" {
    proc_setup
    fake_proc 101 "$ABLETON_WINE_ROOT/bin/wineserver"
    [ "$(ableton_runtime_pids)" = "101" ]
}

# guards: scoping — a Live under an unrelated Wine is neither counted nor killed
@test "runtime pids: a process from another Wine install is ignored" {
    proc_setup
    fake_proc 202 "/usr/lib/wine/wine-preloader" "Ableton Live 12 Suite.exe"
    [ -z "$(ableton_runtime_pids)" ]
}

@test "runtime pids: non-numeric entries in the tree are skipped" {
    proc_setup
    mkdir -p "$ABLETON_PROC_ROOT/self" "$ABLETON_PROC_ROOT/sys"
    ln -sfn "$ABLETON_WINE_ROOT/bin/wine" "$ABLETON_PROC_ROOT/self/exe"
    [ -z "$(ableton_runtime_pids)" ]
}

@test "live pids: Live is told apart from the support processes around it" {
    proc_setup
    fake_proc 101 "$ABLETON_WINE_ROOT/bin/wineserver" "wineserver"
    fake_proc 102 "$ABLETON_WINE_ROOT/bin/wine-preloader" \
        'C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe'
    [ "$(ableton_live_pids)" = "102" ]
    ableton_live_running
}

# guards: the launcher's stale-wineserver kill — a lingering server must still
# read as "Live is down", or that kill never runs
@test "a lingering wineserver means busy, but not that Live is running" {
    proc_setup
    fake_proc 101 "$ABLETON_WINE_ROOT/bin/wineserver" "wineserver"
    ableton_runtime_busy
    ! ableton_live_running
}

@test "an idle machine is neither busy nor running Live" {
    proc_setup
    ! ableton_runtime_busy
    ! ableton_live_running
}

# --- container vs legacy resolution ------------------------------------------
# The layout migration moves the runtime into a container directory. The
# resolver has to answer correctly on both sides of that move, because an
# install that has not migrated yet still has to launch.

@test "runtime root: the container wins once it exists" {
    export ABLETON_OPT_DIR="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$ABLETON_OPT_DIR/ableton-wine/stable"
    [ "$(ableton_wine_root)" = "$ABLETON_OPT_DIR/ableton-wine/stable" ]
}

# guards: an install that predates the migration must still resolve and launch
@test "runtime root: falls back to the legacy path before migrating" {
    export ABLETON_OPT_DIR="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$ABLETON_OPT_DIR"
    [ "$(ableton_wine_root)" = "$(ableton_legacy_root)" ]
}

# guards: the compatibility symlink must stay vestigial — resolving through it
# would make it load-bearing, and no later release could drop it
@test "runtime root: the container wins even with the legacy symlink present" {
    export ABLETON_OPT_DIR="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$ABLETON_OPT_DIR/ableton-wine/stable"
    ln -s "ableton-wine/stable" "$(ableton_legacy_root)"
    [ "$(ableton_wine_root)" = "$ABLETON_OPT_DIR/ableton-wine/stable" ]
}

@test "runtime root: an explicit pin beats the container" {
    export ABLETON_OPT_DIR="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$ABLETON_OPT_DIR/ableton-wine/stable"
    ABLETON_WINE_ROOT=/tmp/pinned
    [ "$(ableton_wine_root)" = "/tmp/pinned" ]
}

# guards: observed during the first real migration — six "/proc/PID/cmdline:
# No such file or directory" lines, because the processes exited between the
# scan and the read. tr's 2>/dev/null cannot suppress that: the shell reports a
# failed redirection itself, before tr runs. Same bug is in install.sh on main.
@test "live pids: a process that exits mid-scan is skipped, not an error" {
    proc_setup
    fake_proc 101 "$ABLETON_WINE_ROOT/bin/wine-preloader"   # exe, but no cmdline
    run ableton_live_pids
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr$output" != *"No such file"* ]]
}
