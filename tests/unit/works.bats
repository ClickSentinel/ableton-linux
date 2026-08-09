#!/usr/bin/env bats
#
# scripts/works — the dispatcher.
#
# It does two things worth testing: it finds its verbs, and it refuses what is
# not a command. Finding them is the part with a trap in it — PATH holds a
# symlink to this file, so $0 is the link's own path and the verbs are not
# beside it — and nothing exercised the installed shape until now.
#
#   ./tests/run.sh tests/unit/works.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

W() { bash "$REPO/scripts/works" "$@"; }

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export WORKS_HOME="$BATS_TEST_TMPDIR/opt"
    unset WORKS_RUNTIME
    mkdir -p "$HOME" "$WORKS_HOME"
    . "$REPO/scripts/runtime-env.sh"
    C="$(works_runtime_store)"
}

a_build() {
    mkdir -p "$C/$1/bin"
    printf '#!/bin/sh\necho wine-11.13\n' > "$C/$1/bin/wine"; chmod +x "$C/$1/bin/wine"
    printf 'dist-version: %s\npatch-stack:  %s\nwine:         wine-11.13\n' \
        "${1%%+*}" "aaaaaaaxxx" > "$C/$1/ABLETON-WINE-BUILD-INFO.txt"
}

store() { a_build 2026.06.01.1+bbbbbbb; ln -sfn "2026.06.01.1+bbbbbbb" "$C/stable"; }

# --- finding the verbs --------------------------------------------------------

# guards: the installed shape is a symlink on PATH pointing into works/bin, with
# the verbs in works/lib. Resolving $0 with dirname alone looks for ../lib beside
# the *link*, which is ~/.local/lib and holds nothing.
@test "works resolves its verbs through a symlink on PATH" {
    mkdir -p "$WORKS_HOME/bin" "$WORKS_HOME/lib" "$BATS_TEST_TMPDIR/pathdir"
    install -m755 "$REPO/scripts/works"          "$WORKS_HOME/bin/works"
    install -m755 "$REPO/scripts/works-runtime"  "$WORKS_HOME/lib/works-runtime"
    install -m755 "$REPO/scripts/works-update"   "$WORKS_HOME/lib/works-update"
    install -m644 "$REPO/scripts/runtime-env.sh" "$WORKS_HOME/lib/runtime-env.sh"
    ln -sfn "$WORKS_HOME/bin/works" "$BATS_TEST_TMPDIR/pathdir/works"
    store

    run "$BATS_TEST_TMPDIR/pathdir/works" runtime path
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ "$output" = "$C/2026.06.01.1+bbbbbbb" ]
}

@test "works says so when the verbs are missing rather than failing obscurely" {
    mkdir -p "$BATS_TEST_TMPDIR/alone"
    install -m755 "$REPO/scripts/works" "$BATS_TEST_TMPDIR/alone/works"
    run "$BATS_TEST_TMPDIR/alone/works" runtime list
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot find its verbs"* ]]
}

# --- dispatch -----------------------------------------------------------------

@test "runtime is delegated" {
    store
    run W runtime path
    [ "$status" -eq 0 ]
    [ "$output" = "$C/2026.06.01.1+bbbbbbb" ]
}

@test "update is delegated" {
    run W update --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"works update"* ]]
}

# guards: `works stop` is the documented spelling and has to arrive at the same
# place as `works runtime stop`, arguments intact
@test "stop is delegated to the runtime verb" {
    store
    run W stop
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing is running"* ]]
}

# --- refusals -----------------------------------------------------------------

@test "no command at all prints the usage" {
    run W
    [ "$status" -eq 0 ]
    [[ "$output" == *"works runtime list"* ]]
}

@test "an unknown command is refused, with the usage to hand" {
    run W nonsense
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such command: nonsense"* ]]
    [[ "$output" == *"works runtime list"* ]]
}

# guards: a flag first is a different mistake from a wrong word, and saying
# "no such command: --check" would send someone looking for the wrong thing
@test "a flag where a command belongs says so in its own terms" {
    run W --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"takes a command first"* ]]
}

# --- help ---------------------------------------------------------------------

# guards: the help is a fixed line range over the header comment, so editing that
# comment drags the prose beneath it into the output or drops a command off it
@test "help ends on a command, not on prose" {
    run W --help
    [ "$status" -eq 0 ]
    last="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -1)"
    [[ "$last" == "  works "* ]] || { echo "help trails into prose: $last" >&2; false; }
}

@test "help names every command it dispatches" {
    run W --help
    for c in "works runtime" "works update" "works stop"; do
        [[ "$output" == *"$c"* ]] || { echo "help omits $c" >&2; false; }
    done
    run W -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"works runtime"* ]]
}
