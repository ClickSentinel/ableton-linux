#!/usr/bin/env bats
#
# scripts/runtime-env.sh — the flat-to-container layout migration.
#
# This renames the directory an existing user's Wine runs from, so every row of
# the decision table gets a test, including the ones that must refuse. The rule
# throughout is that ambiguity is an error: two real trees, or a link pointing
# somewhere unexpected, mean the script cannot know which install is live, and
# guessing wrong swaps a runtime out from under a running Live.
#
# Nothing here touches a real install: ABLETON_OPT_DIR points the resolvers at
# a throwaway tree.
#
#   ./tests/run.sh tests/unit/migrate-layout.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    HOME="$BATS_TEST_TMPDIR/home"
    export ABLETON_OPT_DIR="$BATS_TEST_TMPDIR/opt"
    unset ABLETON_WINE_ROOT
    mkdir -p "$HOME" "$ABLETON_OPT_DIR"
    . "$REPO/scripts/runtime-env.sh"
    # Derived, never spelled out: a literal here would be a second place the
    # runtime name lives, which repo-hygiene rightly refuses.
    LEGACY="$(ableton_legacy_root)"
    NAME="${LEGACY##*/}"
    TARGET="$(ableton_container_root)/stable"
}

# A runtime tree is recognisable by shape, so the tests plant one rather than
# an empty directory: a bare mkdir would pass assertions a real move would not.
plant_runtime() {
    mkdir -p "$1/bin" "$1/share/wine"
    : > "$1/bin/wine"
    printf 'dist-version: 2026.08.01.1\n' > "$1/ABLETON-WINE-BUILD-INFO.txt"
}

# --- the migrating case ------------------------------------------------------

@test "a flat install moves into the container and keeps a compatibility link" {
    plant_runtime "$LEGACY"
    run ableton_migrate_layout
    [ "$status" -eq 0 ]
    [ -f "$TARGET/bin/wine" ]
    [ -f "$TARGET/ABLETON-WINE-BUILD-INFO.txt" ]
    [ -L "$LEGACY" ]
    [ -f "$LEGACY/bin/wine" ]                    # resolves through the link
}

@test "the compatibility link is relative, so it survives a moved home" {
    plant_runtime "$LEGACY"
    ableton_migrate_layout
    [ "$(readlink "$LEGACY")" = "ableton-wine/stable" ]
}

# guards: uninstall.sh cleans by sibling glob; rollbacks left outside the
# container are invisible to it and orphan several GB apiece
@test "dated rollback and failed-install directories move with the runtime" {
    plant_runtime "$LEGACY"
    plant_runtime "$LEGACY-rollback-20260802T194734Z"
    plant_runtime "$LEGACY.failed-20260801T101010Z"
    ableton_migrate_layout
    [ -f "$ABLETON_OPT_DIR/ableton-wine/stable-rollback-20260802T194734Z/bin/wine" ]
    [ -f "$ABLETON_OPT_DIR/ableton-wine/stable.failed-20260801T101010Z/bin/wine" ]
    [ -z "$(find "$ABLETON_OPT_DIR" -maxdepth 1 -name "$NAME-rollback-*")" ]
}

# guards: 11.11 and 11.14 trees coexist on the maintainer's machine and are not
# the installer's to move
@test "runtimes from other Wine bases are left alone" {
    plant_runtime "$LEGACY"
    older="$ABLETON_OPT_DIR/${NAME%.*}.11"
    newer="$ABLETON_OPT_DIR/${NAME%.*}.14"
    plant_runtime "$older"
    plant_runtime "$newer"
    ableton_migrate_layout
    [ -f "$older/bin/wine" ]
    [ -f "$newer/bin/wine" ]
    [ ! -L "$older" ]
}

# --- the no-op cases ---------------------------------------------------------

@test "a fresh install migrates nothing and leaves no compatibility link" {
    run ableton_migrate_layout
    [ "$status" -eq 0 ]
    [ ! -e "$LEGACY" ]
}

@test "running it twice is a no-op, not a second move" {
    plant_runtime "$LEGACY"
    ableton_migrate_layout
    run ableton_migrate_layout
    [ "$status" -eq 0 ]
    [ -f "$TARGET/bin/wine" ]
    [ "$(readlink "$LEGACY")" = "ableton-wine/stable" ]
    [ ! -e "$ABLETON_OPT_DIR/ableton-wine/stable/ableton-wine" ]
}

@test "a lost compatibility link is put back rather than reported as migrating" {
    plant_runtime "$TARGET"
    run ableton_migrate_layout
    [ "$status" -eq 0 ]
    [[ "$output" == *"restored the compatibility link"* ]]
    [ -f "$LEGACY/bin/wine" ]
}

@test "an overridden runtime root is left exactly where the user pinned it" {
    plant_runtime "$LEGACY"
    ABLETON_WINE_ROOT="$BATS_TEST_TMPDIR/pinned"
    run ableton_migrate_layout
    [ "$status" -eq 0 ]
    [ ! -L "$LEGACY" ]
    [ ! -e "$TARGET" ]
}

# --- the refusing cases ------------------------------------------------------

# guards: the destructive row of the decision table — guessing here swaps a
# runtime out from under a running Live
@test "two real runtimes refuse, naming both, rather than guessing" {
    plant_runtime "$LEGACY"
    plant_runtime "$TARGET"
    run ableton_migrate_layout
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"cannot tell which"* ]]
    [ -f "$LEGACY/bin/wine" ]                    # both still intact
    [ -f "$TARGET/bin/wine" ]
}

@test "a compatibility link pointing somewhere unexpected refuses" {
    plant_runtime "$TARGET"
    plant_runtime "$ABLETON_OPT_DIR/elsewhere"
    ln -s "elsewhere" "$LEGACY"
    run ableton_migrate_layout
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"points at"* ]]
}

@test "a dangling link with no runtime behind it refuses instead of migrating" {
    ln -s "ableton-wine/stable" "$LEGACY"
    run ableton_migrate_layout
    [ "$status" -eq 1 ]
    [[ "$stderr$output" == *"symlink"* ]]
    [ ! -e "$TARGET" ]
}

# --- removal -----------------------------------------------------------------
# The other half of the layout: uninstall has to find everything the container
# holds, and nothing it does not own.

@test "removal takes the container and everything inside it" {
    plant_runtime "$TARGET"
    plant_runtime "$ABLETON_OPT_DIR/ableton-wine/stable-rollback-20260802T194734Z"
    plant_runtime "$ABLETON_OPT_DIR/ableton-wine/beta"
    ableton_remove_runtimes
    [ ! -e "$ABLETON_OPT_DIR/ableton-wine" ]
}

# guards: rm -rf on a symlink takes the link, not the tree — the container
# removal above is what takes the tree
@test "removal takes the compatibility symlink without following it" {
    plant_runtime "$TARGET"
    ln -s "ableton-wine/stable" "$LEGACY"
    ableton_remove_runtimes
    [ ! -e "$LEGACY" ] && [ ! -L "$LEGACY" ]
}

# guards: an install that never migrated has no container at all
@test "removal handles a flat install that never migrated" {
    plant_runtime "$LEGACY"
    plant_runtime "$LEGACY-rollback-20260802T194734Z"
    plant_runtime "$LEGACY.failed-20260801T101010Z"
    ableton_remove_runtimes
    [ ! -e "$LEGACY" ]
    [ -z "$(find "$ABLETON_OPT_DIR" -maxdepth 1 -name "$NAME*")" ]
}

# guards: 11.11 and 11.14 trees are not this installer's to delete
@test "removal leaves runtimes from other Wine bases alone" {
    plant_runtime "$TARGET"
    other="$ABLETON_OPT_DIR/${NAME%.*}.11"
    plant_runtime "$other"
    ableton_remove_runtimes
    [ -f "$other/bin/wine" ]
}

@test "removal with a pinned root takes only that root" {
    plant_runtime "$TARGET"
    pinned="$BATS_TEST_TMPDIR/pinned"
    plant_runtime "$pinned"
    ABLETON_WINE_ROOT="$pinned" ableton_remove_runtimes
    [ ! -e "$pinned" ]
    [ -f "$TARGET/bin/wine" ]
}
