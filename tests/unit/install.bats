#!/usr/bin/env bats
#
# scripts/install.sh — ordering that cannot be checked from output.
#
# Tarball selection moved to scripts/runtime-env.sh and is tested with the rest
# of that lib; it was duplicated in three scripts and the same defect was in all
# of them, which is why it now lives in one.
#
#   ./tests/run.sh tests/unit/install.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

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
