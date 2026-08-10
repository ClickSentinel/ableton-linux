#!/usr/bin/env bats
#
# works/works-app — the applications installed on this machine.
#
# The apps directory is the census, so listing is a walk and removal is a
# directory - and removal must never reach into a Plug: what an application
# installed into a prefix stays until the Plug goes.
#
#   ./tests/run.sh tests/unit/works-app.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

APPCMD() { bash "$REPO/works/works-app" "$@"; }

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export HOME
    export WORKS_HOME="$HOME/works"
    unset WORKS_RUNTIME WORKS_PLUG
    mkdir -p "$HOME/.local/bin" "$WORKS_HOME/apps"
}

an_app() {   # name, [version], [min]
    local d="$WORKS_HOME/apps/$1"
    mkdir -p "$d"
    printf '#!/bin/sh\nWORKS_ABI_MIN=%s\n' "${3:-1}" > "$d/$1"
    chmod +x "$d/$1"
    [ -z "${2:-}" ] || printf '%s\n' "$2" > "$d/VERSION"
    ln -sfn "$d/$1" "$HOME/.local/bin/$1"
}

@test "list names every application with version and floor" {
    an_app ableton-live 2026.08.10.1 1
    an_app notepad-plus-plus 8.9.7 1
    run APPCMD list
    [ "$status" -eq 0 ]
    [[ "$output" == *"ableton-live"* ]]
    [[ "$output" == *"2026.08.10.1"* ]]
    [[ "$output" == *"notepad-plus-plus"* ]]
    [[ "$output" == *"8.9.7"* ]]
}

@test "list says so with nothing installed" {
    run APPCMD list
    [ "$status" -eq 0 ]
    [[ "$output" == *"(none)"* ]]
}

@test "rm removes the application and its own link, and nothing else" {
    an_app ableton-live 2026.08.10.1
    an_app notepad-plus-plus 8.9.7
    mkdir -p "$WORKS_HOME/plugs/studio/drive_c"
    printf 'work\n' > "$WORKS_HOME/plugs/studio/drive_c/set.als"

    run APPCMD rm notepad-plus-plus -y
    [ "$status" -eq 0 ]
    [ ! -e "$WORKS_HOME/apps/notepad-plus-plus" ]
    [ ! -e "$HOME/.local/bin/notepad-plus-plus" ]
    # the other application and the Plug's contents are untouched
    [ -x "$WORKS_HOME/apps/ableton-live/ableton-live" ]
    [ "$(cat "$WORKS_HOME/plugs/studio/drive_c/set.als")" = "work" ]
}

# guards: a same-named command from anywhere else is not ours to delete
@test "rm leaves a foreign PATH command alone" {
    an_app notepad-plus-plus 8.9.7
    printf '#!/bin/sh\n' > "$HOME/.local/bin/foreign"
    rm -f "$HOME/.local/bin/notepad-plus-plus"
    ln -sfn "$HOME/.local/bin/foreign" "$HOME/.local/bin/notepad-plus-plus"
    APPCMD rm notepad-plus-plus -y >/dev/null
    [ -L "$HOME/.local/bin/notepad-plus-plus" ]
}

@test "rm refuses an unknown application and lists what is installed" {
    an_app ableton-live
    run APPCMD rm nope -y
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such application"* ]]
    [[ "$output" == *"ableton-live"* ]]
}

# guards: with no terminal nobody consented; -y is how a script says it meant it
@test "rm without a terminal refuses unless -y" {
    an_app notepad-plus-plus
    run setsid bash "$REPO/works/works-app" rm notepad-plus-plus
    [ "$status" -ne 0 ]
    [ -d "$WORKS_HOME/apps/notepad-plus-plus" ]
}

@test "help ends on a command, not on prose" {
    run APPCMD help
    [ "$status" -eq 0 ]
    [[ "$output" == *"works app rm"* ]]
}
