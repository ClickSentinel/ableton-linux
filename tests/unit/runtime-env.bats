#!/usr/bin/env bats
#
# scripts/runtime-env.sh — the shared runtime-tarball selection.
#
# Three scripts carried their own copy of the selector until this existed, with
# the same defect in all three. The functions are pure so they can be tested
# here rather than through a launcher sandbox, which is the whole reason they
# echo instead of assigning.
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

# --- runtime tarball selection -----------------------------------------------
# Shared because it was not: install.sh, make-installer.sh and build-audit.sh
# each carried a copy and the same defect was in all three — a release both
# assembled and audited from whatever sort -V put last.

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

# New on the integration branch: the predicate the selector and make-installer
# share. Its own tests, because make-installer is the caller that packaging
# defects reach through, and "the selector still works" does not cover it.

# guards: a kit packed around a name the installer cannot select builds cleanly
# and fails on the user's machine — reproduced 2026-08-05
@test "tarball predicate: the dated release form is accepted" {
    ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst"
}

@test "tarball predicate: a full path is judged by its basename" {
    ableton_is_runtime_tarball "/any/where/wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst"
}

# guards: bin/ and lib/ with no share/ — passes `wine --version`, then fails at
# launch with "could not exec the wine loader"
@test "tarball predicate: a debug tree is refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1-debug.tar.zst"
}

# guards: this is the only runtime artifact the nightly channel publishes, so
# refusing it left that channel with nothing installable
@test "tarball predicate: a nightly label is accepted" {
    ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+nightly.bf76bb2.tar.zst"
}

# guards: a label is a suffix on the release form, not a licence to accept any
# trailing text — `-debug` must keep falling out
@test "tarball predicate: a labelled debug tree is still refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+nightly.bf76bb2-debug.tar.zst"
}

@test "tarball predicate: an empty label is refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+.tar.zst"
}

# guards: both in one directory is the nightly builder's own dist/, and the
# labelled build must not become what an unqualified install picks up
@test "tarball selector: the plain release wins over a labelled one beside it" {
    local d="$BATS_TEST_TMPDIR/dist"; mkdir -p "$d"
    local nm; nm="$(ableton_runtime_name)"
    : > "$d/${nm}-2026.08.04.1.tar.zst"
    : > "$d/${nm}-2026.08.04.1+nightly.bf76bb2.tar.zst"
    [ "$(basename "$(ableton_pick_tarball "$d")")" = "${nm}-2026.08.04.1.tar.zst" ]
}

@test "tarball selector: a labelled build alone is selectable" {
    local d="$BATS_TEST_TMPDIR/dist"; mkdir -p "$d"
    local nm; nm="$(ableton_runtime_name)"
    : > "$d/${nm}-2026.08.04.1+nightly.bf76bb2.tar.zst"
    [ -n "$(ableton_pick_tarball "$d")" ]
}

@test "tarball predicate: another Wine base is refused" {
    # Derived, never spelled out. A second Wine version written literally here is
    # a second place the runtime name lives, which repo-hygiene refuses - and
    # rightly: a base bump would leave the literal behind.
    local nm base; nm="$(ableton_runtime_name)"
    base="${nm%.*}.$(( ${nm##*.} + 1 ))"
    ! ableton_is_runtime_tarball "${base}-2026.08.04.1.tar.zst"
}

@test "tarball predicate: an undated artifact is refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-release.tar.zst"
}

# guards: the same-day counter must not be read as a date component
@test "tarball predicate: a partial download is refused" {
    ! ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst.part"
}

@test "tarball predicate: the nightly artifact name is accepted" {
    ableton_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.06.1+nightly.badafaf.tar.zst"
}
