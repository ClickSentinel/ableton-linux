#!/usr/bin/env bats
#
# scripts/runtime-env.sh — the shared runtime-tarball selection.
#
# Three scripts resolved the tarball independently until this existed, and each
# resolved it with `ls | sort -V | tail -1`, which orders the -debug suffix last
# and so installs a tree with bin/ and lib/ but no share/. A wrong answer here
# is silent: the debug tree passes `wine --version` and only fails at launch
# with "could not exec the wine loader", which reads as a broken build rather
# than a mis-picked file. A second release channel puts more artifacts in the
# same directory, so the selector has to be right before that lands.
#
# The selector is pure, so these source runtime-env.sh directly rather than
# extracting a function body out of install.sh as the earlier copy of these
# tests did — renaming it fails these tests instead of silently exercising a
# stale copy.
#
#   ./tests/run.sh tests/unit/runtime-env.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    setup_stubs
    HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset ABLETON_WINE_ROOT ABLETON_WINEPREFIX
    . "$REPO/scripts/runtime-env.sh"
}

setup_dist() {
    DIST="$BATS_TEST_TMPDIR/dist"
    mkdir -p "$DIST"
    NAME="$(ableton_runtime_name)"
}

# guards: sort -V orders the -debug suffix last, so glob+tail installs a tree with no share/
@test "the runtime wins over a debug tree sitting beside it" {
    setup_dist; : > "$DIST/$NAME-2026.08.01.1.tar.zst"
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ "$(basename "$(ableton_pick_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "the newest dated runtime wins when several are present" {
    setup_dist; for v in 2026.07.29.1 2026.08.01.1 2026.07.23.1; do : > "$DIST/$NAME-$v.tar.zst"; done
    [ "$(basename "$(ableton_pick_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

# guards: a nightly cadence passes .9 within a single day, and lexical order puts .2 last
@test "the same-day counter orders numerically, not lexically" {
    setup_dist; for n in 1 2 10; do : > "$DIST/$NAME-2026.08.01.$n.tar.zst"; done
    [ "$(basename "$(ableton_pick_tarball "$DIST")")" = "$NAME-2026.08.01.10.tar.zst" ]
}

@test "a debug tree on its own selects nothing, so the caller fails loudly" {
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ -z "$(ableton_pick_tarball "$DIST")" ]
}

# guards: the beta channel — a nightly artifact must never be taken for the stable runtime
@test "an undated or suffixed artifact is not mistaken for the runtime" {
    setup_dist; : > "$DIST/$NAME-nightly.tar.zst"
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-rc2.tar.zst"
    [ -z "$(ableton_pick_tarball "$DIST")" ]
}

# guards: a half-downloaded artifact is a file, and the caller must not unpack it
@test "a partial download is not selected" {
    setup_dist; : > "$DIST/$NAME-2026.08.01.1.tar.zst"
    setup_dist; : > "$DIST/$NAME-2026.12.01.1.tar.zst.part"
    [ "$(basename "$(ableton_pick_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "an empty directory selects nothing rather than erroring" {
    setup_dist; run ableton_pick_tarball "$DIST"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a missing directory selects nothing rather than erroring" {
    setup_dist; run ableton_pick_tarball "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
