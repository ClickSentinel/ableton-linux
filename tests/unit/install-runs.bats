#!/usr/bin/env bats
#
# scripts/install.sh — does it run at all, and does it install what it claims?
#
# This file exists because nothing executed install.sh. The suite sourced
# runtime-env.sh directly and checked the resolvers, which is worth doing and
# says nothing about whether the script that uses them starts. On 2026-08-05 a
# merge reordered install.sh's head so it called wires_runtime_name eight
# lines before sourcing the file that defines it; under `set -euo pipefail` it
# aborted on that line. 172 tests passed for thirteen commits.
#
# The first test here is deliberately cheap and hermetic: it asserts only that
# the script gets past its own initialisation to the point where it looks for a
# tarball. That is the whole failure mode, and it needs no fixture.
#
# The second does a real install into a throwaway HOME, and skips when there is
# no tarball to install. That is not a gap that can be closed with a fixture:
# install.sh runs `readelf -d` against the packaged libusb and PipeASIO shims
# and greps for real DT_NEEDED entries, so a stand-in tree would either fail
# those checks or force them to be weakened, and weakening them is how a debug
# tree ships.
#
#   ./tests/run.sh tests/unit/install-runs.bats
#   WIRES_TEST_TARBALL=/path/to/runtime.tar.zst ./tests/run.sh tests/unit/install-runs.bats

bats_require_minimum_version 1.5.0

load ../helpers/common
load ../helpers/install-sandbox

setup() {
    install_sandbox
    . "$REPO/wires/runtime-env.sh"
}

# guards: install.sh aborting on its own first lines, which no resolver test can
# see because the resolvers themselves are fine
@test "install.sh gets past its own initialisation" {
    run env WIRES_RUNTIME="$BATS_TEST_TMPDIR/rt" \
        bash "$REPO/scripts/install.sh" --runtime-only
    # Deliberately indifferent to whether it succeeded: whether dist/ happens to
    # hold a tarball is not what this is about, and an earlier draft that
    # asserted failure passed alone and broke the moment a build left one there.
    # What must not appear is evidence it never started.
    [[ "$output" != *"command not found"* ]] || { echo "$output" >&2; false; }
    [[ "$output" != *"unbound variable"* ]] || { echo "$output" >&2; false; }
    # and it must have got as far as its own first step
    [[ "$output" == *"tar.zst"* || "$output" == *"verify checksum"* ]] || {
        echo "no sign it reached the tarball step:" >&2; echo "$output" >&2; false; }
}

@test "install.sh resolves its roots from the shared lib, not from its own copy" {
    # The pin has to reach the script, not just the library: install.sh snapshots
    # WINE_ROOT once and every later step follows it.
    run env WIRES_RUNTIME="$BATS_TEST_TMPDIR/pinned-root" \
        bash "$REPO/scripts/install.sh" --runtime-only
    [[ "$output" != *"command not found"* ]] || { echo "$output" >&2; false; }
    # whatever it did, it did not do it at the default location
    [ ! -e "$HOME/wires/$(wires_runtime_name)" ]
}

# guards: the whole install path — staging, the required-file gate, promote,
# the launcher, and the shared lib landing where the launcher can source it
@test "a real tarball installs, and the tree identifies itself" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"

    root="$BATS_TEST_TMPDIR/rt"
    run env WIRES_RUNTIME="$root" WIRES_RUNTIME_TARBALL="$tarball" \
        bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    [ -x "$root/bin/wine" ]
    [ -n "$(wires_runtime_id "$root")" ]
    # the launcher and the resolver it sources both land
    [ -x "$HOME/.local/bin/ableton-live" ]
    [ -f "$HOME/wires/lib/runtime-env.sh" ]
    # and nothing was written to the default location
    [ ! -e "$HOME/wires/$(wires_runtime_name)" ]
}

# guards: the promote step and its dated rollback, which is where the store's
# layout will later be maintained or broken
@test "a second install promotes and leaves the previous runtime behind" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"

    root="$BATS_TEST_TMPDIR/rt"
    env WIRES_RUNTIME="$root" WIRES_RUNTIME_TARBALL="$tarball" \
        bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    run env WIRES_RUNTIME="$root" WIRES_RUNTIME_TARBALL="$tarball" \
        bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    [ -x "$root/bin/wine" ]
    # exactly one dated rollback, beside the runtime
    n="$(find "$(dirname "$root")" -maxdepth 1 -name "$(basename "$root")-rollback-*" | wc -l)"
    [ "$n" -eq 1 ] || { echo "expected 1 rollback, found $n" >&2; false; }
}

# --- the store ----------------------------------------------------------------
# These are the ones that would have caught the promote defect: against a
# correctly shaped store, one ordinary install replaced the channel with a real
# directory, left a rollback symlink pointing into the store, and filed the new
# build under no name at all. The store survived no installs, and the migration
# read the result as already migrated.

@test "a fresh install lands in the store, not the flat path" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"

    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    container="$(wires_runtime_store)"
    [ -L "$container/stable" ]
    id="$(readlink "$container/stable")"
    [ -f "$container/$id/bin/wine" ]
    [ "$id" = "$(wires_runtime_id "$container/$id")" ]
    # a new user never sees the flat layout
    [ ! -e "$(wires_legacy_root)" ]
}

@test "the channel stays a symlink across a second install" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"

    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    container="$(wires_runtime_store)"
    [ -L "$container/stable" ] || { echo "the channel is no longer a symlink" >&2; false; }
    # and no rollback symlink was left pointing into the store
    [ -z "$(find "$container" -maxdepth 1 -name 'stable-rollback-*')" ]
    [ -z "$(find "$container" -maxdepth 1 -name '.replaced-*')" ]
}

# guards: the resolver, the process scan and the install must all name the same
# tree, which is what /proc/PID/exe reporting resolved paths makes non-obvious
@test "after installing, the resolver points at a real build directory" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"

    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    root="$(wires_runtime_path)"
    [ -d "$root" ] && [ ! -L "$root" ]
    [ -x "$root/bin/wine" ]
    [ "$root" = "$(readlink -f "$(wires_runtime_store)/stable")" ]
}

# guards: an existing flat install is what nearly every user has
@test "a flat install is migrated by the installer, not just by the library" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"

    legacy="$(wires_legacy_root)"
    mkdir -p "$legacy/bin"
    : > "$legacy/bin/wine"
    printf 'dist-version: 2026.01.01.1\npatch-stack:  0ldbui1daaa\n' \
        > "$legacy/ABLETON-WINE-BUILD-INFO.txt"

    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    container="$(wires_runtime_store)"
    [ ! -e "$legacy" ]
    [ -d "$container/2026.01.01.1+0ldbui1" ]   # the old build, now readable
    [ -L "$container/stable" ]
    [ "$(readlink "$container/stable")" != "2026.01.01.1+0ldbui1" ]  # channel moved on
}

# --- channels -----------------------------------------------------------------
# Which kit you download is the channel choice. install.sh must follow the kit,
# not the machine: installing a nightly while configured for stable would
# otherwise point `stable` at a nightly build.

@test "a kit declares its channel and the installer promotes into it" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    export XDG_CONFIG_HOME="$HOME/.config"
    printf 'stable\n' > "$BATS_TEST_TMPDIR/pretend-stable"

    # a checkout stands in for a kit: dist/channel is the same marker
    mkdir -p "$BATS_TEST_TMPDIR/dist" && printf 'nightly\n' > "$REPO/dist/channel"
    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    rm -f "$REPO/dist/channel"
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    container="$(wires_runtime_store)"
    [ -L "$container/nightly" ] || { echo "no nightly channel: $(ls -1 "$container")" >&2; false; }
    [ ! -e "$container/stable" ] || { echo "stable was pointed at a nightly build" >&2; false; }
}

@test "installing records the channel, so the updater follows it" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    export XDG_CONFIG_HOME="$HOME/.config"
    printf 'nightly\n' > "$REPO/dist/channel"
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    rm -f "$REPO/dist/channel"
    [ "$(cat "$HOME/wires/runtimes/.channel")" = "nightly" ]
}

@test "a kit with no channel marker is stable, as every older kit was" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    export XDG_CONFIG_HOME="$HOME/.config"
    rm -f "$REPO/dist/channel"
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    [ -L "$(wires_runtime_store)/stable" ]
}

# guards: install.sh writes the channel file, so "removed everything install.sh
# added" has to include it — left behind, a later install is followed by an
# `wires-update` pointed at a channel nothing on the machine chose
@test "uninstalling takes the recorded channel back" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    export XDG_CONFIG_HOME="$HOME/.config"
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    [ -r "$HOME/wires/runtimes/.channel" ]

    run setsid --wait bash "$REPO/scripts/uninstall.sh" --yes
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ ! -e "$HOME/wires/runtimes/.channel" ]
}

# guards: the config directory is not ours to clear out — only the one file is
# guards: the Plug holds Live, its authorisation and the user's sets — the one
# thing here that cannot be reinstalled, so removal must be asked for
@test "uninstalling keeps the Plug, and the work inside it" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    plug="$HOME/wires/plugs/studio"
    mkdir -p "$plug/drive_c"
    printf 'my set\n' > "$plug/drive_c/mine.als"

    setsid --wait bash "$REPO/scripts/uninstall.sh" --yes >/dev/null 2>&1
    [ "$(cat "$plug/drive_c/mine.als")" = "my set" ]
}

@test "uninstalling takes the shared toolkit only when no application is left" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    [ -r "$HOME/wires/lib/runtime-env.sh" ]

    mkdir -p "$HOME/wires/apps/another-app"      # a second tenant, mid-uninstall
    setsid --wait bash "$REPO/scripts/uninstall.sh" --yes >/dev/null 2>&1
    [ -r "$HOME/wires/lib/runtime-env.sh" ] || { echo "the toolkit went while another app still needs it" >&2; false; }

    rmdir "$HOME/wires/apps/another-app"
    setsid --wait bash "$REPO/scripts/uninstall.sh" --yes >/dev/null 2>&1
    [ ! -e "$HOME/wires/lib" ]
}

# --- setup-prefix.sh's own guard ----------------------------------------------
# Through the .run this never fires, because install.sh stops everything first.
# Standalone it is the only guard there is -- and install.sh's last line tells
# you to run it standalone, so that path is the documented one.

# guards: `wineboot -u` rewriting the registry under a live wineserver
@test "setup-prefix refuses while something runs from the runtime" {
    root="$BATS_TEST_TMPDIR/rt"; mkdir -p "$root/bin"
    export WIRES_RUNTIME="$root"
    cp "$(command -v sleep)" "$root/bin/wineserver"
    "$root/bin/wineserver" 30 &
    local pid=$!
    run bash "$REPO/scripts/setup-prefix.sh"
    kill "$pid" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"Close Live"* ]]
}

# guards: the refusal must not depend on a terminal -- an unattended run is
# exactly when nobody notices the prefix being rewritten
@test "setup-prefix refuses with no terminal too" {
    root="$BATS_TEST_TMPDIR/rt"; mkdir -p "$root/bin"
    export WIRES_RUNTIME="$root"
    cp "$(command -v sleep)" "$root/bin/wineserver"
    "$root/bin/wineserver" 30 &
    local pid=$!
    run setsid --wait bash "$REPO/scripts/setup-prefix.sh"
    kill "$pid" 2>/dev/null || true
    [ "$status" -ne 0 ]
}

# guards: the guard must not block the .run, where install.sh has already
# stopped everything -- getting past it is the whole requirement
@test "setup-prefix gets past the guard when nothing is running" {
    root="$BATS_TEST_TMPDIR/rt"; mkdir -p "$root/bin"
    export WIRES_RUNTIME="$root"
    run bash "$REPO/scripts/setup-prefix.sh"
    [[ "$output" != *"Close Live"* ]]
}

# guards: the app directory must contain the app — a launcher that lives only on
# PATH means backing up ~/wires misses the entry point, and removing the app
# leaves a working command pointing at nothing
@test "the launcher lives with the application, and PATH holds a link to it" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    [ -x "$HOME/wires/apps/ableton-live/ableton-live" ]
    [ -L "$HOME/.local/bin/ableton-live" ]
    [ "$(readlink "$HOME/.local/bin/ableton-live")" = "$HOME/wires/apps/ableton-live/ableton-live" ]
}

# guards: one dated copy per install, on the PATH, pruned by nothing — the
# defect the version store exists to end, in a second place
@test "installing leaves no dated launcher copies behind" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    mkdir -p "$HOME/.local/bin"
    : > "$HOME/.local/bin/ableton-live.rollback-20260101T000000Z"   # litter from an older installer
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    n=$(find "$HOME/.local/bin" -name 'ableton-live.rollback-*' | wc -l)
    [ "$n" = 0 ] || { echo "$n dated launcher copies survived" >&2; false; }
}

@test "the wires command lives outside any application, with its verbs beside the library" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    [ -x "$HOME/wires/bin/wires" ]
    [ -x "$HOME/wires/lib/wires-runtime" ]
    [ ! -e "$HOME/wires/apps/ableton-live/wires" ]
    [ -L "$HOME/.local/bin/wires" ]
    # the verbs implement the command; they are not commands
    [ ! -e "$HOME/.local/bin/wires-runtime" ]
    # Through the link, which is the only way a person invokes it: $0 is then
    # the link's path, and ../lib from there is not where the verbs live.
    "$HOME/.local/bin/wires" runtime path >/dev/null
    "$HOME/wires/bin/wires" runtime path >/dev/null
}

# --- the infrastructure gate ----------------------------------------------------
# Every kit carries its own copy of the Wires infrastructure, so every install is
# also a write onto a machine other applications may already depend on. The gate
# arbitrates that write by the ABI range. The strand-prompt branch cannot be
# reached here — this kit's OLDEST is 1 and nothing can be below it — so the
# census behind it is pinned at unit level in runtime-env.bats, and the prompt
# itself becomes reachable the first time OLDEST moves.

@test "a fresh install stamps the infrastructure contract" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    grep -q '^WIRES_ABI=' "$HOME/wires/lib/runtime-env.sh"
    grep -q '^WIRES_ABI_OLDEST=' "$HOME/wires/lib/runtime-env.sh"
}

# guards: unguarded, whichever kit ran last owned ~/wires/lib — installing an
# older application silently downgraded the infrastructure under every other
# application on the machine
@test "a newer installed infrastructure is kept, not overwritten" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    mkdir -p "$HOME/wires/lib"
    printf '# SENTINEL-NEWER-GENERATION\nWIRES_ABI=99\nWIRES_ABI_OLDEST=1\n' \
        > "$HOME/wires/lib/runtime-env.sh"

    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"keeping the installed infrastructure"* ]]
    grep -q 'SENTINEL-NEWER-GENERATION' "$HOME/wires/lib/runtime-env.sh" \
        || { echo "the newer library was overwritten by an older kit" >&2; false; }
    # the application itself still installed — that is the point of the split
    [ -x "$HOME/wires/apps/ableton-live/ableton-live" ]
}

# guards: the other direction of the same promise — an installed infrastructure
# that has dropped this kit's generation cannot run this kit's application, and
# finding that out at install time beats finding it out as a launch failure
@test "a kit below the installed OLDEST is refused whole" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    mkdir -p "$HOME/wires/lib"
    printf 'WIRES_ABI=99\nWIRES_ABI_OLDEST=99\n' > "$HOME/wires/lib/runtime-env.sh"

    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -ne 0 ]
    [[ "$output" == *"This kit is too old"* ]]
    # refused before anything landed: no store, no launcher
    [ ! -e "$HOME/wires/runtimes/stable" ]
    [ ! -e "$HOME/wires/apps/ableton-live/ableton-live" ]
}

# guards: uninstalling one application used to run wires_remove_runtimes and take
# ~/wires/bin/wires unconditionally — so removing app A broke app B's launches
# and deleted runtimes its Plugs were pinned to. The exact dependency between
# applications the bundled model exists to prevent, created by the uninstaller.
@test "uninstalling one application keeps the runtimes another still needs" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only >/dev/null 2>&1
    [ -L "$HOME/wires/runtimes/stable" ]
    mkdir -p "$HOME/wires/apps/another-app"

    run setsid --wait bash "$REPO/scripts/uninstall.sh" --yes
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"kept the runtimes"* ]]
    [ -L "$HOME/wires/runtimes/stable" ] || { echo "the channel went with the wrong app" >&2; false; }
    [ -x "$HOME/wires/bin/wires" ]       || { echo "the wires command went with the wrong app" >&2; false; }
    [ ! -e "$HOME/wires/apps/ableton-live" ]

    # and with the last application, everything shared goes too
    rmdir "$HOME/wires/apps/another-app"
    setsid --wait bash "$REPO/scripts/uninstall.sh" --yes >/dev/null 2>&1
    [ ! -e "$HOME/wires/runtimes" ]
    [ ! -e "$HOME/wires/bin" ]
}

# --- the runtime install verb ---------------------------------------------------
# The store lifecycle out of the application's installer: `wires runtime
# install` owns stop, migrate, stage, guard, promote and prune, and the caller
# vouches for the build through --validate, run against the staged tree before
# anything is promoted.

@test "the verb installs into the store and honours --channel" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    run bash "$REPO/wires/wires-runtime" install "$tarball" --channel nightly
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    container="$(wires_runtime_store)"
    [ -L "$container/nightly" ]
    [ -x "$container/$(readlink "$container/nightly")/bin/wine" ]
    [ "$(cat "$container/.channel")" = nightly ]
    [ ! -e "$container/stable" ]
}

# guards: the voucher runs before promote, and its refusal aborts with the
# machine unchanged - a validator that ran after promote would be an autopsy
@test "a refusing validator stops the verb before anything is promoted" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    v="$BATS_TEST_TMPDIR/refuse.sh"
    printf '#!/bin/sh\necho "!! vouch refused: $1" >&2\nexit 1\n' > "$v"; chmod +x "$v"
    run bash "$REPO/wires/wires-runtime" install "$tarball" --validate "$v"
    [ "$status" -ne 0 ]
    [[ "$output" == *"vouch refused"* ]]
    [ ! -e "$(wires_runtime_store)/stable" ]
    [ -z "$(find "$(wires_runtime_store)" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)" ]
}

@test "the verb honours a pinned WIRES_RUNTIME with a dated rollback" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    root="$BATS_TEST_TMPDIR/rt"
    env WIRES_RUNTIME="$root" bash "$REPO/wires/wires-runtime" install "$tarball" >/dev/null 2>&1
    run env WIRES_RUNTIME="$root" bash "$REPO/wires/wires-runtime" install "$tarball"
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [ -x "$root/bin/wine" ]
    [ "$(find "$(dirname "$root")" -maxdepth 1 -name "$(basename "$root")-rollback-*" | wc -l)" -eq 1 ]
    [ ! -e "$HOME/wires/runtimes/stable" ]
}

# guards: found in review. The ABI answers compatibility, not recency - two kits
# both speaking ABI 1 carry different libraries, and comparing only the ABI made
# equal-ABI installs last-writer-wins, so an older kit silently replaced a newer
# library and took its fixes with it. The shipment's own version orders them,
# recorded at ~/wires/lib/VERSION when it was installed.
@test "an older implementation at the same ABI does not replace a newer one" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    mkdir -p "$HOME/wires/lib"
    printf '# SENTINEL-NEWER-IMPLEMENTATION\nWIRES_ABI=1\nWIRES_ABI_OLDEST=1\n' \
        > "$HOME/wires/lib/runtime-env.sh"
    printf '2099.01.01.1\n' > "$HOME/wires/lib/VERSION"

    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"keeping the installed infrastructure"* ]]
    grep -q 'SENTINEL-NEWER-IMPLEMENTATION' "$HOME/wires/lib/runtime-env.sh" \
        || { echo "an older implementation overwrote a newer one at equal ABI" >&2; false; }
    # and the application still installed, which is the point of keeping going
    [ -x "$HOME/wires/apps/ableton-live/ableton-live" ]
}

# guards: the interface must never go backward even when the kit is newer by
# version - applications may declare a floor the installed ABI satisfies and
# this kit's does not
@test "a higher installed ABI is kept even against a newer implementation" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    mkdir -p "$HOME/wires/lib"
    printf '# SENTINEL-HIGHER-ABI\nWIRES_ABI=99\nWIRES_ABI_OLDEST=1\n' \
        > "$HOME/wires/lib/runtime-env.sh"
    printf '2000.01.01.1\n' > "$HOME/wires/lib/VERSION"
    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    grep -q 'SENTINEL-HIGHER-ABI' "$HOME/wires/lib/runtime-env.sh"
}

# guards: found on the fedora rig. The preserve rule asked only whether a file
# existed and did not route through the launcher, so a zero-byte entry left by
# an interrupted install satisfied it - and was preserved across every later
# install, leaving that machine with a desktop entry that launches nothing. An
# entry nobody wrote is not an entry to protect.
@test "an empty desktop entry is replaced, not mistaken for a hand-made one" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    : > "$HOME/.local/share/applications/ableton-live.desktop"

    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" != *"preserving existing"*"ableton-live.desktop"* ]] \
        || { echo "an empty entry was treated as hand-made" >&2; false; }
    grep -qF "$HOME/.local/bin/ableton-live" \
        "$HOME/.local/share/applications/ableton-live.desktop"
}

# guards: the other half of the same rule - the protection it exists for must
# survive the fix. A real entry pointing somewhere else is someone's choice.
@test "a hand-made desktop entry is still preserved" {
    tarball="$(sandbox_tarball)"
    [ -n "$tarball" ] || skip "no runtime tarball; set WIRES_TEST_TARBALL to run this"
    printf '[Desktop Entry]\nType=Application\nName=Mine\nExec=/usr/bin/true\n' \
        > "$HOME/.local/share/applications/ableton-live.desktop"

    run env WIRES_RUNTIME_TARBALL="$tarball" bash "$REPO/scripts/install.sh" --runtime-only
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *"preserving existing"*"ableton-live.desktop"* ]]
    grep -qF 'Exec=/usr/bin/true' "$HOME/.local/share/applications/ableton-live.desktop"
}

# guards: found in review. --app-min silently became 1 when it was not a number,
# and 1 is the most permissive floor there is - so a mistyped floor turned the
# stranding gate down instead of tripping it. This argument comes from an
# installer, not a person, and a wrong one is a bug to surface.
@test "install-wires refuses an --app-min that is not a number" {
    run bash "$REPO/wires/install-wires.sh" check --app-min abc
    [ "$status" -eq 2 ]
    [[ "$output" == *"takes a number"* ]]
    run bash "$REPO/wires/install-wires.sh" check --app-min 2
    [ "$status" -ne 2 ]
}
