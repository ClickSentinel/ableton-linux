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

# NAME and pick_runtime_tarball are pulled out of install.sh rather than
# restated, so renaming either in the script fails these tests instead of
# leaving them quietly exercising a copy.
setup() {
    eval "$(grep -m1 '^NAME=' "$REPO/scripts/install.sh")"
    [ -n "${NAME:-}" ] || { echo "no NAME= assignment in install.sh" >&2; return 1; }
    local body
    body="$(sed -n '/^pick_runtime_tarball() {/,/^}/p' "$REPO/scripts/install.sh")"
    [ -n "$body" ] || { echo "pick_runtime_tarball is gone from install.sh" >&2; return 1; }
    eval "$body"
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

# --- migration ordering ------------------------------------------------------
# Deliberately a source-order assertion rather than a behavioural one. The
# ordering is the safety property, and checking it for real would mean a full
# install harness: a runtime tree, a prefix, live processes to stop. This
# catches the reordering; the migration's own behaviour is covered in
# migrate-layout.bats.

line_of() { grep -n "$1" "$REPO/scripts/install.sh" | head -1 | cut -d: -f1; }

# guards: the migration renames the directory running processes execute from,
# so it must not run until they have been stopped
@test "the layout migration runs after the process stop, not before" {
    stop="$(line_of 'ableton_runtime_pids | xargs -r kill -9')"
    migrate="$(line_of '^ableton_migrate_layout')"
    [ -n "$stop" ] && [ -n "$migrate" ]
    [ "$migrate" -gt "$stop" ] || {
        echo "migration at line $migrate precedes the stop at $stop" >&2; false; }
}

# guards: staging and promotion must target where the runtime now lives, not
# the pre-migration snapshot taken at the top of the script
@test "the runtime root is re-resolved after the migration, before staging" {
    migrate="$(line_of '^ableton_migrate_layout')"
    resolve="$(grep -n 'WINE_ROOT="$(ableton_wine_root)"' "$REPO/scripts/install.sh" | tail -1 | cut -d: -f1)"
    stage="$(line_of 'mktemp -d')"
    [ "$resolve" -gt "$migrate" ] || {
        echo "root resolved at $resolve, before the migration at $migrate" >&2; false; }
    [ "$stage" -gt "$resolve" ] || {
        echo "staging at $stage precedes the re-resolve at $resolve" >&2; false; }
}
