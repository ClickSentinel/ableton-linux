#!/usr/bin/env bats
#
# scripts/install.sh — which tarball an install actually unpacks.
#
# Everything else install.sh does needs a real tree to stage and promote. This
# one decision is pure string work, and it is the one place where a wrong
# answer is silent: the debug tree passes `wine --version` and then fails at
# launch with "could not exec the wine loader", which reads as a broken build
# rather than a mis-picked file. A second release channel puts more artifacts
# in the same directory, so the selector has to be right before that lands.
#
#   ./tests/run.sh tests/unit/install.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

# NAME and the tarball selector are pulled out of the implementation rather
# than restated, so renaming either fails these tests instead of leaving them
# quietly exercising a copy.
#
# Which file holds them is deliberately not asserted. install.sh carried both
# until the shared resolver landed and scripts/runtime-env.sh carries them
# after, so resolving from whichever is present keeps this file green on both
# sides of that change. Scraping `^NAME=` out of install.sh cannot: the
# assignment becomes a call into the resolver, and `eval` of it in a shell that
# has not sourced the resolver exits 127 and takes every test here with it.
setup() {
    if [ -r "$REPO/scripts/runtime-env.sh" ]; then
        . "$REPO/scripts/runtime-env.sh"
        NAME="$(ableton_runtime_name)"
        pick_runtime_tarball() { ableton_pick_tarball "$@"; }
    else
        eval "$(grep -m1 '^NAME=' "$REPO/scripts/install.sh")"
        local body
        body="$(sed -n '/^pick_runtime_tarball() {/,/^}/p' "$REPO/scripts/install.sh")"
        [ -n "$body" ] || { echo "pick_runtime_tarball is gone from install.sh" >&2; return 1; }
        eval "$body"
    fi
    [ -n "${NAME:-}" ] || { echo "no runtime name resolved" >&2; return 1; }
    DIST="$BATS_TEST_TMPDIR/dist"
    mkdir -p "$DIST"
}

# guards: sort -V orders the -debug suffix last, so glob+tail installs a tree with no share/
@test "the runtime wins over a debug tree sitting beside it" {
    : > "$DIST/$NAME-2026.08.01.1.tar.zst"
    : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ "$(basename "$(pick_runtime_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "the newest dated runtime wins when several are present" {
    for v in 2026.07.29.1 2026.08.01.1 2026.07.23.1; do : > "$DIST/$NAME-$v.tar.zst"; done
    [ "$(basename "$(pick_runtime_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "the same-day counter orders numerically, not lexically" {
    for n in 1 2 10; do : > "$DIST/$NAME-2026.08.01.$n.tar.zst"; done
    [ "$(basename "$(pick_runtime_tarball "$DIST")")" = "$NAME-2026.08.01.10.tar.zst" ]
}

@test "a debug tree on its own selects nothing, so the caller fails loudly" {
    : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ -z "$(pick_runtime_tarball "$DIST")" ]
}

# guards: the beta channel — a nightly artifact must never be taken for the stable runtime
@test "an undated or suffixed artifact is not mistaken for the runtime" {
    : > "$DIST/$NAME-nightly.tar.zst"
    : > "$DIST/$NAME-2026.08.01.1-rc2.tar.zst"
    [ -z "$(pick_runtime_tarball "$DIST")" ]
}

@test "an empty directory selects nothing rather than erroring" {
    run pick_runtime_tarball "$DIST"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a missing directory selects nothing rather than erroring" {
    run pick_runtime_tarball "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
