#!/usr/bin/env bats
#
# scripts/ableton-runtime — choosing which build is live.
#
# The store made rollback possible and nothing exposed it: switching meant
# `ln -sfn` against a name you had to look up. These cover the two things that
# matter — that `use` refuses anything that is not a runtime you could actually
# launch, and that `path` answers on both layouts, because scripts and docs
# resolve through it instead of naming a directory.
#
#   ./tests/run.sh tests/unit/ableton-runtime.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

RT() { bash "$REPO/scripts/ableton-runtime" "$@"; }

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export ABLETON_OPT_DIR="$BATS_TEST_TMPDIR/opt"
    unset ABLETON_WINE_ROOT
    mkdir -p "$HOME" "$ABLETON_OPT_DIR"
    . "$REPO/scripts/runtime-env.sh"
    C="$(ableton_container_root)"
    LEGACY="$(ableton_legacy_root)"
}

plant() {
    local dir="$1" ver="$2" disc="$3" at="${4:-}" base="${5:-wine-11.13}"
    mkdir -p "$dir/bin"
    printf '#!/bin/sh\necho wine-11.13\n' > "$dir/bin/wine"; chmod +x "$dir/bin/wine"
    { printf 'dist-version: %s\n' "$ver"; printf 'patch-stack:  %s\n' "$disc"
      printf 'wine:         %s\n' "$base"
      [ -z "$at" ] || printf 'built-at:     %s\n' "$at"; } > "$dir/ABLETON-WINE-BUILD-INFO.txt"
}

store() {
    plant "$C/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z
    plant "$C/2026.06.01.1+bbbbbbb" 2026.06.01.1 bbbbbbbxxx 2026-06-01T00:00:00Z
    ln -s "2026.06.01.1+bbbbbbb" "$C/stable"
}

# --- path ---------------------------------------------------------------------

# guards: docs and scripts resolve through this instead of naming a directory,
# so it has to answer before the store exists as well as after
@test "path answers on the flat layout" {
    plant "$LEGACY" 2026.01.01.1 aaaaaaaxxx
    run RT path
    [ "$status" -eq 0 ]
    [ "$output" = "$LEGACY" ]
}

@test "path answers on the store, with the build rather than the channel" {
    store
    run RT path
    [ "$status" -eq 0 ]
    [ "$output" = "$C/2026.06.01.1+bbbbbbb" ]
}

@test "path honours an explicit pin" {
    store
    ABLETON_WINE_ROOT="$BATS_TEST_TMPDIR/pinned" run RT path
    [ "$output" = "$BATS_TEST_TMPDIR/pinned" ]
}

# --- list ---------------------------------------------------------------------

@test "list marks the live build" {
    store
    run RT list
    [ "$status" -eq 0 ]
    [[ "$output" == *"* 2026.06.01.1+bbbbbbb"* ]]
    [[ "$output" == *"  2026.01.01.1+aaaaaaa"* ]]
}

# guards: names tie across nightlies, so ordering is by built-at
@test "list is newest first" {
    store
    run RT list
    [ "$(echo "$output" | grep -n '2026.06.01.1' | cut -d: -f1)" -lt \
      "$(echo "$output" | grep -n '2026.01.01.1' | cut -d: -f1)" ]
}

@test "list says so when there is no store yet" {
    plant "$LEGACY" 2026.01.01.1 aaaaaaaxxx
    run RT list
    [ "$status" -eq 0 ]
    [[ "$output" == *"predates it"* ]]
}

# guards: set-aside trees are not builds you can choose, but their existence is
# worth saying so nobody thinks the migration deleted something
@test "list does not offer quarantined trees, but mentions them" {
    store
    mkdir -p "$C/superseded-20260101T000000Z/old"
    run RT list
    [[ "$output" != *"superseded-20260101T000000Z "* ]]
    [[ "$output" == *"set-aside"* ]]
}

# --- use ----------------------------------------------------------------------

@test "use retargets the channel" {
    store
    run RT use 2026.01.01.1+aaaaaaa
    [ "$status" -eq 0 ]
    [ "$(readlink "$C/stable")" = "2026.01.01.1+aaaaaaa" ]
    [ "$(RT path)" = "$C/2026.01.01.1+aaaaaaa" ]
}

@test "use --previous picks the other build" {
    store
    run RT use --previous
    [ "$status" -eq 0 ]
    [ "$(readlink "$C/stable")" = "2026.01.01.1+aaaaaaa" ]
}

@test "use --previous refuses when only one build is installed" {
    plant "$C/2026.06.01.1+bbbbbbb" 2026.06.01.1 bbbbbbbxxx
    ln -s "2026.06.01.1+bbbbbbb" "$C/stable"
    run RT use --previous
    [ "$status" -ne 0 ]
    [[ "$output" == *"only one build"* ]]
}

# guards: the channel is what the launcher resolves through — pointing it at
# something unlaunchable is how you get an install that cannot start
@test "use refuses a name that is not installed" {
    store
    run RT use 2026.99.99.9+zzzzzzz
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such build"* ]]
    [ "$(readlink "$C/stable")" = "2026.06.01.1+bbbbbbb" ]
}

@test "use refuses a directory with no readable BUILD-INFO" {
    store
    mkdir -p "$C/notabuild/bin"
    run RT use notabuild
    [ "$status" -ne 0 ]
    [ "$(readlink "$C/stable")" = "2026.06.01.1+bbbbbbb" ]
}

@test "use refuses an entry with no wine binary" {
    store
    plant "$C/2026.07.01.1+ccccccc" 2026.07.01.1 cccccccxxx
    rm -f "$C/2026.07.01.1+ccccccc/bin/wine"
    run RT use 2026.07.01.1+ccccccc
    [ "$status" -ne 0 ]
    [[ "$output" == *"no bin/wine"* ]]
    [ "$(readlink "$C/stable")" = "2026.06.01.1+bbbbbbb" ]
}

@test "use refuses when there is no store" {
    plant "$LEGACY" 2026.01.01.1 aaaaaaaxxx
    run RT use anything
    [ "$status" -ne 0 ]
}


# --- the Wine base ------------------------------------------------------------
# A Wire is bound to a base: Wine re-bootstraps the prefix when the runtime's
# wine.inf and the prefix's .update-timestamp disagree, and it cannot go back.
# Switching between bases is a one-way door and nothing said so.

@test "list shows the Wine base each build carries" {
    store
    run RT list
    [[ "$output" == *"WINE"* ]]
    [[ "$output" == *"wine-11.13"* ]]
}

@test "use is silent when the base is unchanged" {
    store
    run RT use 2026.01.01.1+aaaaaaa
    [ "$status" -eq 0 ]
    [[ "$output" != *"different Wine base"* ]]
}

# guards: the prefix cannot be taken back, so this must not happen quietly
@test "use refuses a base change with no terminal to ask on" {
    store
    plant "$C/2026.07.01.1+ddddddd" 2026.07.01.1 dddddddxxx 2026-07-01T00:00:00Z wine-11.14
    run RT use 2026.07.01.1+ddddddd
    [ "$status" -ne 0 ]
    [[ "$output" == *"different Wine base"* ]]
    [[ "$output" == *"--force"* ]]
    [ "$(readlink "$C/stable")" = "2026.06.01.1+bbbbbbb" ]
}

@test "use --force accepts a base change deliberately" {
    store
    plant "$C/2026.07.01.1+ddddddd" 2026.07.01.1 dddddddxxx 2026-07-01T00:00:00Z wine-11.14
    run RT use 2026.07.01.1+ddddddd --force
    [ "$status" -eq 0 ]
    [ "$(readlink "$C/stable")" = "2026.07.01.1+ddddddd" ]
}

# guards: forward Wine supports, backward it does not - the wording has to differ
@test "a downgrade is named as a downgrade" {
    plant "$C/2026.07.01.1+ddddddd" 2026.07.01.1 dddddddxxx 2026-07-01T00:00:00Z wine-11.14
    plant "$C/2026.01.01.1+aaaaaaa" 2026.01.01.1 aaaaaaaxxx 2026-01-01T00:00:00Z wine-11.13
    ln -s "2026.07.01.1+ddddddd" "$C/stable"
    run RT use 2026.01.01.1+aaaaaaa
    [[ "$output" == *"DOWNGRADE"* ]]
    [[ "$output" == *"does not support"* ]]
}

# --- the picker ---------------------------------------------------------------

# guards: a script calling `use` with no argument must fail, not block forever
@test "use with no argument refuses when there is no terminal" {
    store
    run RT use
    [ "$status" -ne 0 ]
    [[ "$output" == *"no terminal"* ]]
    [[ "$output" == *"ableton-runtime use 2026"* ]]
}

@test "use with no argument leaves the channel alone" {
    store
    RT use || true
    [ "$(readlink "$C/stable")" = "2026.06.01.1+bbbbbbb" ]
}
