#!/usr/bin/env bats
#
# wires/wires — the dispatcher.
#
# It does two things worth testing: it finds its verbs, and it refuses what is
# not a command. Finding them is the part with a trap in it — PATH holds a
# symlink to this file, so $0 is the link's own path and the verbs are not
# beside it — and nothing exercised the installed shape until now.
#
#   ./tests/run.sh tests/unit/wires.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

W() { bash "$REPO/wires/wires" "$@"; }

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    unset WIRES_RUNTIME
    mkdir -p "$HOME" "$WIRES_HOME"
    . "$REPO/wires/runtime-env.sh"
    C="$(wires_runtime_store)"
}

a_build() {
    mkdir -p "$C/$1/bin"
    printf '#!/bin/sh\necho wine-11.13\n' > "$C/$1/bin/wine"; chmod +x "$C/$1/bin/wine"
    printf 'dist-version: %s\npatch-stack:  %s\nwine:         wine-11.13\n' \
        "${1%%+*}" "aaaaaaaxxx" > "$C/$1/ABLETON-WINE-BUILD-INFO.txt"
}

store() { a_build 2026.06.01.1+bbbbbbb; ln -sfn "2026.06.01.1+bbbbbbb" "$C/stable"; }

# --- finding the verbs --------------------------------------------------------

# guards: the installed shape is a symlink on PATH pointing into wires/bin, with
# the verbs in wires/lib. Resolving $0 with dirname alone looks for ../lib beside
# the *link*, which is ~/.local/lib and holds nothing.
@test "wires resolves its verbs through a symlink on PATH" {
    mkdir -p "$WIRES_HOME/bin" "$WIRES_HOME/lib" "$BATS_TEST_TMPDIR/pathdir"
    install -m755 "$REPO/wires/wires"          "$WIRES_HOME/bin/wires"
    install -m755 "$REPO/wires/wires-runtime"  "$WIRES_HOME/lib/wires-runtime"
    install -m755 "$REPO/wires/wires-update"   "$WIRES_HOME/lib/wires-update"
    install -m644 "$REPO/wires/runtime-env.sh" "$WIRES_HOME/lib/runtime-env.sh"
    ln -sfn "$WIRES_HOME/bin/wires" "$BATS_TEST_TMPDIR/pathdir/wires"
    store

    run "$BATS_TEST_TMPDIR/pathdir/wires" runtime path
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ "$output" = "$C/2026.06.01.1+bbbbbbb" ]
}

@test "wires says so when the verbs are missing rather than failing obscurely" {
    mkdir -p "$BATS_TEST_TMPDIR/alone"
    install -m755 "$REPO/wires/wires" "$BATS_TEST_TMPDIR/alone/wires"
    run "$BATS_TEST_TMPDIR/alone/wires" runtime list
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

# guards: `wires stop` is the documented spelling and has to arrive at the same
# place as `wires runtime stop`, arguments intact
@test "update is delegated" {
    run W update --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"wires update"* ]]
}

@test "stop is delegated to the runtime verb" {
    store
    run W stop
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing is running"* ]]
}

# --- refusals -----------------------------------------------------------------

# guards: someone who typed `wires` to find out what it does wants the shape,
# with the alternatives inline the way every other CLI writes them - not the
# full per-option list, which is what `wires help` is for
@test "no command at all prints the short usage" {
    run W
    [ "$status" -eq 0 ]
    [[ "$output" == *"wires runtime {list|path|use}"* ]]
    [[ "$output" == *"wires help"* ]]
}

# guards: a wrong word should not answer with the whole manual
@test "an unknown command is refused with the short usage, not the long one" {
    run W nonsense
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such command: nonsense"* ]]
    [[ "$output" == *"wires runtime {list|path|use}"* ]]
    [[ "$output" != *"the runtime root, for scripts and docs"* ]] \
        || { echo "the error printed the long form" >&2; false; }
}

# guards: a flag first is a different mistake from a wrong word, and saying
# "no such command: --check" would send someone looking for the wrong thing
@test "a flag where a command belongs says so in its own terms" {
    run W --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"takes a command first"* ]]
}

# --- help ---------------------------------------------------------------------

# guards: the help used to be a fixed line range over the header comment, which
# rotted into printing a sentence and a half of the prose underneath it. It is
# written out now, and this holds that line.
@test "help ends on a command, not on prose" {
    run W --help
    [ "$status" -eq 0 ]
    last="$(printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -1)"
    [[ "$last" == "  wires "* ]] || { echo "help trails into prose: $last" >&2; false; }
}

# guards: `wires help` is the spelling a person reaches for before they know the
# flags, and it has to reach the same place as --help
@test "help is spelled three ways and they agree" {
    run W help
    [ "$status" -eq 0 ]
    local viahelp="$output"
    run W --help
    [ "$output" = "$viahelp" ]
    run W -h
    [ "$output" = "$viahelp" ]
}

@test "the long form carries the detail the short form leaves out" {
    run W help
    [[ "$output" == *"the runtime root, for scripts and docs"* ]]
    [[ "$output" != *"{list|path|use}"* ]]
}

@test "help names every command it dispatches" {
    run W --help
    for c in "wires runtime" "wires update" "wires stop"; do
        [[ "$output" == *"$c"* ]] || { echo "help omits $c" >&2; false; }
    done
    run W -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"wires runtime"* ]]
}

@test "app is reachable through the dispatcher" {
    run bash "$REPO/wires/wires" app list
    [ "$status" -eq 0 ]
    [[ "$output" == *"APP"* ]]
}

# guards: the plural is what fingers type after `wires app list` teaches the
# pattern; each noun answers to both
@test "the plural nouns alias to the singular" {
    run bash "$REPO/wires/wires" plugs list
    [ "$status" -eq 0 ]
    run bash "$REPO/wires/wires" runtimes list
    [ "$status" -eq 0 ]
    run bash "$REPO/wires/wires" apps list
    [ "$status" -eq 0 ]
}
