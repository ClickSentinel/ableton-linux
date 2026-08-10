#!/usr/bin/env bats
#
# wires/wires-app — the applications installed on this machine.
#
# The apps directory is the census, so listing is a walk and removal is a
# directory - and removal must never reach into a Plug: what an application
# installed into a prefix stays until the Plug goes.
#
#   ./tests/run.sh tests/unit/wires-app.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

APPCMD() { bash "$REPO/wires/wires-app" "$@"; }

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export HOME
    export WIRES_HOME="$HOME/wires"
    unset WIRES_RUNTIME WIRES_PLUG
    mkdir -p "$HOME/.local/bin" "$WIRES_HOME/apps"
}

an_app() {   # name, [version], [min]
    local d="$WIRES_HOME/apps/$1"
    mkdir -p "$d"
    printf '#!/bin/sh\nWIRES_ABI_MIN=%s\n' "${3:-1}" > "$d/$1"
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
    mkdir -p "$WIRES_HOME/plugs/studio/drive_c"
    printf 'work\n' > "$WIRES_HOME/plugs/studio/drive_c/set.als"

    run APPCMD rm notepad-plus-plus -y
    [ "$status" -eq 0 ]
    [ ! -e "$WIRES_HOME/apps/notepad-plus-plus" ]
    [ ! -e "$HOME/.local/bin/notepad-plus-plus" ]
    # the other application and the Plug's contents are untouched
    [ -x "$WIRES_HOME/apps/ableton-live/ableton-live" ]
    [ "$(cat "$WIRES_HOME/plugs/studio/drive_c/set.als")" = "work" ]
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
    run setsid bash "$REPO/wires/wires-app" rm notepad-plus-plus
    [ "$status" -ne 0 ]
    [ -d "$WIRES_HOME/apps/notepad-plus-plus" ]
}

@test "help ends on a command, not on prose" {
    run APPCMD help
    [ "$status" -eq 0 ]
    [[ "$output" == *"wires app rm"* ]]
}

# guards: found in review. An unknown option exited 1 from the app and Plug
# verbs and 2 from the runtime verb, so a caller could not tell "that is not an
# option" from "the command ran and refused" without reading the message.
@test "a usage error exits 2, the same as it does from every other verb" {
    run bash "$REPO/wires/wires" app rm --bogus
    [ "$status" -eq 2 ]
    run bash "$REPO/wires/wires" app rm one two
    [ "$status" -eq 2 ]
    run bash "$REPO/wires/wires" app rm
    [ "$status" -eq 2 ]
    run bash "$REPO/wires/wires" plug rm --bogus
    [ "$status" -eq 2 ]
    run bash "$REPO/wires/wires" runtime install --bogus
    [ "$status" -eq 2 ]
}
