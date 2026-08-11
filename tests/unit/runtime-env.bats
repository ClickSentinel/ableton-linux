#!/usr/bin/env bats
#
# wires/runtime-env.sh — the shared runtime and prefix resolution.
#
# Seven scripts resolved these paths independently until this existed. The
# resolvers are pure so they can be tested here rather than through a launcher
# sandbox, which is the whole reason they echo instead of assigning.
#
#   ./tests/run.sh tests/unit/runtime-env.bats

bats_require_minimum_version 1.5.0

load ../helpers/common

setup() {
    setup_stubs
    stub pgrep 1                # runtime_busy's fallback must not read the host
    HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset WIRES_RUNTIME WIRES_PLUG
    unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH WINEESYNC WINEFSYNC
    . "$REPO/wires/runtime-env.sh"
}

@test "runtime root: an unmigrated install still resolves where it actually is" {
    [ "$(wires_runtime_path)" = "$HOME/.local/opt/wine-d2d1-nspa-11.13" ]
}

@test "runtime root: WIRES_RUNTIME wins, so a bisect or VM run can pin one" {
    WIRES_RUNTIME=/tmp/altroot
    [ "$(wires_runtime_path)" = "/tmp/altroot" ]
}

@test "prefix: defaults to ~/wires/plugs/studio" {
    [ "$(wires_plug_path)" = "$HOME/wires/plugs/studio" ]
}

# guards: found in review. install.sh hands this to `wineserver -k` *before*
# wires_migrate_plug runs, so on an unmigrated machine wires_plug_path names a
# directory that does not exist yet while the real prefix is still at the legacy
# path. Stopping the wrong prefix is a no-op that reports success, and the
# SIGKILL that follows is the registry corruption the migration exists to avoid.
@test "live prefix: names the legacy path while the destination is absent" {
    mkdir -p "$HOME/.wine-ableton"
    [ "$(wires_plug_path_live)" = "$HOME/.wine-ableton" ]
}

@test "live prefix: names the container path once that exists" {
    mkdir -p "$HOME/.wine-ableton" "$HOME/wires/plugs/studio"
    [ "$(wires_plug_path_live)" = "$HOME/wires/plugs/studio" ]
}

@test "live prefix: with neither present it still names where the prefix will go" {
    [ "$(wires_plug_path_live)" = "$HOME/wires/plugs/studio" ]
}

# guards: the stop was gated on wires_runtime_busy, which resolves /proc/PID/exe
# under the runtime tree — strictly narrower than the environ match
# wires_migrate_plug guards with. A process that inherited WINEPREFIX without
# executing from the runtime (ableton-linkd is exactly that) was invisible to the
# kill and visible to the guard, so the install stopped cleanly and then refused,
# and no number of reruns cleared it.
@test "busy: a prefix holder that never executed from the runtime is still seen" {
    local plug="$HOME/wires/plugs/studio" pid i narrow wide
    mkdir -p "$plug"
    WINEPREFIX="$plug" sleep 30 &
    pid=$!
    for i in $(seq 1 40); do [ -e "/proc/$pid/environ" ] && break; sleep 0.05; done

    run wires_runtime_busy
    narrow="$status"
    run wires_anything_busy
    wide="$status"
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    [ "$narrow" -ne 0 ] || { echo "the runtime scan should not have matched it" >&2; false; }
    [ "$wide" -eq 0 ] || { echo "the union scan missed the prefix holder" >&2; false; }
}

# guards: found on two VMs. Wine writes #arch= into system.reg when it finishes
# creating a prefix; a wineboot that starts and does not finish leaves the
# skeleton without one, and Wine then reads the missing marker as win32 and
# refuses every 64-bit application - reporting a "32-bit installation" that was
# never 32-bit, only unfinished. system.reg on its own cannot tell them apart.
# guards: found on a VM after a fix that did not work. The architecture is
# declared in whichever of the three registry files says so, and they do not
# always agree - this prefix had an *empty* system.reg with #arch=win32 in
# user.reg and userdef.reg. Reading system.reg alone reported "no marker", so a
# genuinely 32-bit prefix was classified as unfinished and an attempt made to
# repair it. It is not repairable and it is not a stub.
@test "a 32-bit prefix declared only in user.reg is not mistaken for unfinished" {
    p="$BATS_TEST_TMPDIR/win32"
    mkdir -p "$p/drive_c/windows/system32"
    : > "$p/system.reg"                       # empty, as found in the field
    printf 'WINE REGISTRY Version 2\n\n#arch=win32\n' > "$p/user.reg"
    printf 'WINE REGISTRY Version 2\n\n#arch=win32\n' > "$p/userdef.reg"

    [ "$(wires_prefix_arch "$p")" = win32 ]
    ! wires_is_prefix "$p"     || { echo "a win32 prefix passed as usable" >&2; false; }
    ! wires_is_stub_prefix "$p" || { echo "a declared win32 prefix was called a stub" >&2; false; }
}

@test "a finished prefix and an unfinished one are told apart" {
    mk_prefix() {   # path, arch(y/n), extra dir
        mkdir -p "$1/drive_c/users" "$1/drive_c/windows" "$1/dosdevices"
        { echo "WINE REGISTRY Version 2"; [ "$2" = y ] && echo "#arch=win64"; } > "$1/system.reg"
        [ -z "${3:-}" ] || { mkdir -p "$1/drive_c/$3"; : > "$1/drive_c/$3/thing.dll"; }
    }
    mk_prefix "$BATS_TEST_TMPDIR/done" y
    mk_prefix "$BATS_TEST_TMPDIR/stub" n
    mk_prefix "$BATS_TEST_TMPDIR/used" n "Program Files"
    mkdir -p "$BATS_TEST_TMPDIR/bare"

    wires_is_prefix "$BATS_TEST_TMPDIR/done"
    ! wires_is_prefix "$BATS_TEST_TMPDIR/stub"
    ! wires_is_prefix "$BATS_TEST_TMPDIR/bare"

    wires_is_stub_prefix "$BATS_TEST_TMPDIR/stub"
    ! wires_is_stub_prefix "$BATS_TEST_TMPDIR/done"
    ! wires_is_stub_prefix "$BATS_TEST_TMPDIR/bare"
    # anything installed in it is somebody's work, whatever the marker says.
    # An empty directory is not an install: what makes this unsafe to clear is a
    # file, which is why the predicate counts files rather than directory names.
    ! wires_is_stub_prefix "$BATS_TEST_TMPDIR/used" \
        || { echo "a prefix with an install in it was called a stub" >&2; false; }

    # guards: the first version of this keyed on the top-level drive_c names, so
    # a set saved under drive_c/users read as an empty skeleton. The VM that
    # produced this bug had exactly one file in it, and clearing the directory
    # would have taken it.
    mk_prefix "$BATS_TEST_TMPDIR/hasset" n
    mkdir -p "$BATS_TEST_TMPDIR/hasset/drive_c/users/someone"
    printf 'a set\n' > "$BATS_TEST_TMPDIR/hasset/drive_c/users/someone/mine.als"
    ! wires_is_stub_prefix "$BATS_TEST_TMPDIR/hasset" \
        || { echo "a prefix holding a set was called a stub" >&2; false; }
}

@test "prefix: WIRES_PLUG wins, which the clone workflow depends on" {
    WIRES_PLUG=/tmp/altpfx
    [ "$(wires_plug_path)" = "/tmp/altpfx" ]
}

@test "root and prefix are independent: overriding one leaves the other alone" {
    WIRES_RUNTIME=/tmp/altroot
    [ "$(wires_plug_path)" = "$HOME/wires/plugs/studio" ]
    unset WIRES_RUNTIME
    WIRES_PLUG=/tmp/altpfx
    [ "$(wires_runtime_path)" = "$HOME/.local/opt/wine-d2d1-nspa-11.13" ]
}

@test "the resolvers are pure: calling them exports and unsets nothing" {
    WINEDLLOVERRIDES=mscoree=n
    wires_runtime_path >/dev/null
    wires_plug_path >/dev/null
    [ "${WINEDLLOVERRIDES:-gone}" = "mscoree=n" ]
    [ -z "${WINEPREFIX:-}" ]
    [ -z "${WINESERVER:-}" ]
}

@test "binding exports the prefix, the server, and the runtime's bin on PATH" {
    WIRES_RUNTIME=/tmp/altroot
    wires_bind_runtime
    [ "$WINE_ROOT" = "/tmp/altroot" ]
    [ "$WINESERVER" = "/tmp/altroot/bin/wineserver" ]
    [ "${PATH%%:*}" = "/tmp/altroot/bin" ]
    [ "$WINEPREFIX" = "$HOME/wires/plugs/studio" ]
}

# guards: the four cleared here are the launchers' long-standing set
@test "binding clears inherited Wine settings that would reach the wrong build" {
    WINELOADER=/usr/bin/wine WINEDLLPATH=/usr/lib WINEDLLOVERRIDES=mscoree=n WINEARCH=win32
    wires_bind_runtime
    for v in WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH; do
        [ -z "${!v:-}" ] || { echo "$v survived binding as '${!v}'" >&2; false; }
    done
}

# guards: setup-prefix.sh clears these two itself; folding them in would drop a
# user's WINEESYNC on every launch, a behaviour change wearing a refactor's clothes
@test "binding leaves the sync backends alone, unlike setup-prefix.sh's own unset" {
    WINEESYNC=1 WINEFSYNC=1
    wires_bind_runtime
    [ "${WINEESYNC:-}" = "1" ]
    [ "${WINEFSYNC:-}" = "1" ]
}

# --- process detection -------------------------------------------------------
# /proc cannot be stubbed through PATH, so the lib reads WIRES_PROC_ROOT and
# these build a fixture tree instead of trusting whatever the machine is doing.

fake_proc() {   # fake_proc <pid> <exe-target> [cmdline]
    local d="$WIRES_PROC_ROOT/$1"
    mkdir -p "$d"
    ln -sfn "$2" "$d/exe"
    [ $# -lt 3 ] || printf '%s\0' "$3" > "$d/cmdline"
}

proc_setup() {
    export WIRES_PROC_ROOT="$BATS_TEST_TMPDIR/proc"
    export WIRES_RUNTIME="$BATS_TEST_TMPDIR/rt"
    mkdir -p "$WIRES_PROC_ROOT"
}

@test "runtime pids: a process running from the runtime is found" {
    proc_setup
    fake_proc 101 "$WIRES_RUNTIME/bin/wineserver"
    [ "$(wires_runtime_pids)" = "101" ]
}

# guards: scoping — a Live under an unrelated Wine is neither counted nor killed
@test "runtime pids: a process from another Wine install is ignored" {
    proc_setup
    fake_proc 202 "/usr/lib/wine/wine-preloader" "Ableton Live 12 Suite.exe"
    [ -z "$(wires_runtime_pids)" ]
}

@test "runtime pids: non-numeric entries in the tree are skipped" {
    proc_setup
    mkdir -p "$WIRES_PROC_ROOT/self" "$WIRES_PROC_ROOT/sys"
    ln -sfn "$WIRES_RUNTIME/bin/wine" "$WIRES_PROC_ROOT/self/exe"
    [ -z "$(wires_runtime_pids)" ]
}

@test "live pids: Live is told apart from the support processes around it" {
    proc_setup
    fake_proc 101 "$WIRES_RUNTIME/bin/wineserver" "wineserver"
    fake_proc 102 "$WIRES_RUNTIME/bin/wine-preloader" \
        'C:\ProgramData\Ableton\Live 12 Suite\Program\Ableton Live 12 Suite.exe'
    [ "$(ableton_live_pids)" = "102" ]
    ableton_live_running
}

# guards: the launcher's stale-wineserver kill — a lingering server must still
# read as "Live is down", or that kill never runs
@test "a lingering wineserver means busy, but not that Live is running" {
    proc_setup
    fake_proc 101 "$WIRES_RUNTIME/bin/wineserver" "wineserver"
    wires_runtime_busy
    ! ableton_live_running
}

@test "an idle machine is neither busy nor running Live" {
    proc_setup
    ! wires_runtime_busy
    ! ableton_live_running
}

# --- container vs legacy resolution ------------------------------------------
# The layout migration moves the runtime into a container directory. The
# resolver has to answer correctly on both sides of that move, because an
# install that has not migrated yet still has to launch.




@test "runtime root: an explicit pin beats the container" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$WIRES_HOME/runtimes/stable"
    WIRES_RUNTIME=/tmp/pinned
    [ "$(wires_runtime_path)" = "/tmp/pinned" ]
}

# guards: observed during the first real migration — six "/proc/PID/cmdline:
# No such file or directory" lines, because the processes exited between the
# scan and the read. tr's 2>/dev/null cannot suppress that: the shell reports a
# failed redirection itself, before tr runs. Same bug is in install.sh on main.
@test "live pids: a process that exits mid-scan is skipped, not an error" {
    proc_setup
    fake_proc 101 "$WIRES_RUNTIME/bin/wine-preloader"   # exe, but no cmdline
    run ableton_live_pids
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr$output" != *"No such file"* ]]
}

# --- runtime tarball selection -----------------------------------------------
# Shared because it was not: install.sh, make-installer.sh and build-audit.sh
# each carried a copy and the same defect was in all three — a release both
# assembled and audited from whatever sort -V put last.

setup_dist() {
    DIST="$BATS_TEST_TMPDIR/dist"
    mkdir -p "$DIST"
    NAME="$(wires_runtime_name)"
}

# guards: sort -V orders the -debug suffix last, so glob+tail installs a tree with no share/
@test "the runtime wins over a debug tree sitting beside it" {
    setup_dist; : > "$DIST/$NAME-2026.08.01.1.tar.zst"
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ "$(basename "$(wires_pick_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "the newest dated runtime wins when several are present" {
    setup_dist; for v in 2026.07.29.1 2026.08.01.1 2026.07.23.1; do : > "$DIST/$NAME-$v.tar.zst"; done
    [ "$(basename "$(wires_pick_tarball "$DIST")")" = "$NAME-2026.08.01.1.tar.zst" ]
}

@test "the same-day counter orders numerically, not lexically" {
    setup_dist; for n in 1 2 10; do : > "$DIST/$NAME-2026.08.01.$n.tar.zst"; done
    [ "$(basename "$(wires_pick_tarball "$DIST")")" = "$NAME-2026.08.01.10.tar.zst" ]
}

@test "a debug tree on its own selects nothing, so the caller fails loudly" {
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-debug.tar.zst"
    [ -z "$(wires_pick_tarball "$DIST")" ]
}

# guards: the beta channel — a nightly artifact must never be taken for the stable runtime
@test "an undated or suffixed artifact is not mistaken for the runtime" {
    setup_dist; : > "$DIST/$NAME-nightly.tar.zst"
    setup_dist; : > "$DIST/$NAME-2026.08.01.1-rc2.tar.zst"
    [ -z "$(wires_pick_tarball "$DIST")" ]
}

@test "an empty directory selects nothing rather than erroring" {
    setup_dist; run wires_pick_tarball "$DIST"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a missing directory selects nothing rather than erroring" {
    setup_dist; run wires_pick_tarball "$BATS_TEST_TMPDIR/nope"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}


# --- naming an installed runtime ---------------------------------------------

# <dir> holding a BUILD-INFO with the given body, so a test names only the
# fields it cares about. Values are column-padded exactly as the build writes
# them, because the separator the parser has to cope with is the padding.
make_tree() {
    TREE="$BATS_TEST_TMPDIR/tree$RANDOM"
    mkdir -p "$TREE"
    printf '%s\n' "$@" > "$TREE/ABLETON-WINE-BUILD-INFO.txt"
}

# guards: no released runtime carries source-commit — measured across all 11 trees on the dev machine 2026-08-04
@test "a runtime without source-commit is named from its patch stack" {
    make_tree 'dist-version: 2026.08.04.1' \
              'patch-stack:  9e48edd6b39579d6bd70e73ab1a049d50d7e972a'
    [ "$(wires_runtime_id "$TREE")" = "2026.08.04.1+9e48edd" ]
}

@test "source-commit is preferred over the patch stack when both are present" {
    make_tree 'dist-version: 2026.08.04.1' \
              'source-commit: 7193ece0f1a2b3c4' \
              'patch-stack:  9e48edd6b39579d6'
    [ "$(wires_runtime_id "$TREE")" = "2026.08.04.1+7193ece" ]
}

# guards: 2026.07.29.1 appears four times on the dev machine under two patch stacks
@test "two builds of one version under different patch stacks get different ids" {
    make_tree 'dist-version: 2026.07.29.1' 'patch-stack:  237e53c65485761f'
    a="$(wires_runtime_id "$TREE")"
    make_tree 'dist-version: 2026.07.29.1' 'patch-stack:  9614003b3a6394c2'
    [ "$a" != "$(wires_runtime_id "$TREE")" ]
}

@test "the same build named twice collapses to one id, so duplicates merge" {
    make_tree 'dist-version: 2026.07.29.1' 'patch-stack:  237e53c65485761f'
    a="$(wires_runtime_id "$TREE")"
    make_tree 'dist-version: 2026.07.29.1' 'patch-stack:  237e53c65485761f'
    [ "$a" = "$(wires_runtime_id "$TREE")" ]
}

@test "a tree with no BUILD-INFO cannot be named, and says so by echoing nothing" {
    run wires_runtime_id "$BATS_TEST_TMPDIR/absent"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a version with no discriminator at all cannot be named" {
    make_tree 'dist-version: 2026.08.04.1'
    [ -z "$(wires_runtime_id "$TREE")" ]
}

@test "a discriminator with no version cannot be named" {
    make_tree 'patch-stack:  9e48edd6b39579d6'
    [ -z "$(wires_runtime_id "$TREE")" ]
}

# guards: the id becomes a directory name, and a BUILD-INFO is just text in a tarball
@test "a BUILD-INFO carrying path traversal is refused, not turned into a path" {
    make_tree 'dist-version: ../../../etc' 'patch-stack:  9e48edd6b39579d6'
    [ -z "$(wires_runtime_id "$TREE")" ]
}

@test "a BUILD-INFO carrying a slash is refused" {
    make_tree 'dist-version: 2026.08.04.1' 'patch-stack:  9e48/edd6b39579d6'
    [ -z "$(wires_runtime_id "$TREE")" ]
}

# --- resolution across the two layouts ---------------------------------------
# The store moves the runtime into a container with a channel symlink at the
# live build. The resolver has to answer on both sides of that move, because an
# install that has not migrated yet still has to launch.

# guards: an install that predates the migration must still resolve and launch
@test "runtime root: falls back to the legacy path before migrating" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$WIRES_HOME"
    [ "$(wires_runtime_path)" = "$(wires_legacy_root)" ]
}

# guards: /proc/PID/exe reports resolved paths, so a channel-path root matches no
# process and the busy guard fails open while install.sh renames the directory
@test "runtime root: resolves to the build, not to the channel link" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    entry="$WIRES_HOME/runtimes/2026.08.05.1+abc1234"
    mkdir -p "$entry"
    ln -s "2026.08.05.1+abc1234" "$WIRES_HOME/runtimes/stable"
    [ "$(wires_runtime_path)" = "$entry" ] || {
        echo "resolved to $(wires_runtime_path), wanted $entry" >&2; false; }
}

# guards: the same resolution a running process reports, so the two can be
# compared at all
@test "runtime root: matches what /proc would report for a process under it" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    entry="$WIRES_HOME/runtimes/2026.08.05.1+abc1234"
    mkdir -p "$entry/bin"
    : > "$entry/bin/wine"
    ln -s "2026.08.05.1+abc1234" "$WIRES_HOME/runtimes/stable"
    # what the kernel would show for a binary launched through the channel
    resolved="$(readlink -f "$WIRES_HOME/runtimes/stable/bin/wine")"
    case "$resolved" in
        "$(wires_runtime_path)"/*) ;;
        *) echo "$resolved does not sit under $(wires_runtime_path)" >&2; false ;;
    esac
}

# guards: the container winning over a stale legacy tree left beside it
@test "runtime root: the container wins over a legacy tree still present" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    entry="$WIRES_HOME/runtimes/2026.08.05.1+abc1234"
    mkdir -p "$entry" "$(wires_legacy_root)"
    ln -s "2026.08.05.1+abc1234" "$WIRES_HOME/runtimes/stable"
    [ "$(wires_runtime_path)" = "$entry" ]
}

# guards: a dangling channel must not resolve to nothing and strand the launcher
@test "runtime root: a dangling channel falls back rather than resolving empty" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    mkdir -p "$WIRES_HOME/runtimes"
    ln -s "gone" "$WIRES_HOME/runtimes/stable"
    [ -n "$(wires_runtime_path)" ]
    [ "$(wires_runtime_path)" = "$(wires_legacy_root)" ]
}

# One test is still held back with the version store: the migration's own
# behaviour, in migrate-layout.bats. wires_runtime_path resolves one
# way today because there is only one layout; both tests return when there
# are two.

# New on the integration branch: the predicate the selector and make-installer
# share. Its own tests, because make-installer is the caller that packaging
# defects reach through, and "the selector still works" does not cover it.

# guards: a kit packed around a name the installer cannot select builds cleanly
# and fails on the user's machine — reproduced 2026-08-05
@test "tarball predicate: the dated release form is accepted" {
    wires_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst"
}

@test "tarball predicate: a full path is judged by its basename" {
    wires_is_runtime_tarball "/any/where/wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst"
}

# guards: bin/ and lib/ with no share/ — passes `wine --version`, then fails at
# launch with "could not exec the wine loader"
@test "tarball predicate: a debug tree is refused" {
    ! wires_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1-debug.tar.zst"
}

# guards: this is the only runtime artifact the nightly channel publishes, so
# refusing it left that channel with nothing installable
@test "tarball predicate: a nightly label is accepted" {
    wires_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+nightly.bf76bb2.tar.zst"
}

# guards: a label is a suffix on the release form, not a licence to accept any
# trailing text — `-debug` must keep falling out
@test "tarball predicate: a labelled debug tree is still refused" {
    ! wires_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+nightly.bf76bb2-debug.tar.zst"
}

@test "tarball predicate: an empty label is refused" {
    ! wires_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1+.tar.zst"
}

# guards: both in one directory is the nightly builder's own dist/, and the
# labelled build must not become what an unqualified install picks up
@test "tarball selector: the plain release wins over a labelled one beside it" {
    local d="$BATS_TEST_TMPDIR/dist"; mkdir -p "$d"
    local nm; nm="$(wires_runtime_name)"
    : > "$d/${nm}-2026.08.04.1.tar.zst"
    : > "$d/${nm}-2026.08.04.1+nightly.bf76bb2.tar.zst"
    [ "$(basename "$(wires_pick_tarball "$d")")" = "${nm}-2026.08.04.1.tar.zst" ]
}

@test "tarball selector: a labelled build alone is selectable" {
    local d="$BATS_TEST_TMPDIR/dist"; mkdir -p "$d"
    local nm; nm="$(wires_runtime_name)"
    : > "$d/${nm}-2026.08.04.1+nightly.bf76bb2.tar.zst"
    [ -n "$(wires_pick_tarball "$d")" ]
}

@test "tarball predicate: another Wine base is refused" {
    # Derived, never spelled out. A second Wine version written literally here is
    # a second place the runtime name lives, which repo-hygiene refuses - and
    # rightly: a base bump would leave the literal behind.
    local nm base; nm="$(wires_runtime_name)"
    base="${nm%.*}.$(( ${nm##*.} + 1 ))"
    ! wires_is_runtime_tarball "${base}-2026.08.04.1.tar.zst"
}

@test "tarball predicate: an undated artifact is refused" {
    ! wires_is_runtime_tarball "wine-d2d1-nspa-11.13-release.tar.zst"
}

# guards: the same-day counter must not be read as a date component
@test "tarball predicate: a partial download is refused" {
    ! wires_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.04.1.tar.zst.part"
}

# --- channels -----------------------------------------------------------------
# One channel was assumed throughout: `stable` was hardcoded in six places and
# retention protected only that one. A second channel needs both generalised.

@test "channel: defaults to stable with nothing configured" {
    export WIRES_CHANNEL_FILE="$BATS_TEST_TMPDIR/none"
    [ "$(wires_channel)" = "stable" ]
}

@test "channel: reads the configured file" {
    export WIRES_CHANNEL_FILE="$BATS_TEST_TMPDIR/chan"
    printf 'nightly\n' > "$WIRES_CHANNEL_FILE"
    [ "$(wires_channel)" = "nightly" ]
}

@test "channel: tolerates trailing whitespace" {
    export WIRES_CHANNEL_FILE="$BATS_TEST_TMPDIR/chan"
    printf '  nightly  \n' > "$WIRES_CHANNEL_FILE"
    [ "$(wires_channel)" = "nightly" ]
}

# guards: the value names a symlink and, for the updater, part of a URL —
# configuration the build does not control must not shape a request
@test "channel: an unknown value falls back to stable and says so" {
    export WIRES_CHANNEL_FILE="$BATS_TEST_TMPDIR/chan"
    printf 'https://evil.example/x\n' > "$WIRES_CHANNEL_FILE"
    run wires_channel
    [ "$output" != "https://evil.example/x" ]
    [[ "$output" == *"stable"* ]]
}

@test "channel: the environment overrides the file" {
    export WIRES_CHANNEL_FILE="$BATS_TEST_TMPDIR/chan"
    printf 'stable\n' > "$WIRES_CHANNEL_FILE"
    WIRES_CHANNEL=nightly
    export WIRES_CHANNEL
    [ "$(wires_channel)" = "nightly" ]
}

@test "runtime root: resolves through the configured channel" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    export WIRES_CHANNEL=nightly
    mkdir -p "$WIRES_HOME/runtimes/2026.08.05.1+abc1234"
    ln -s "2026.08.05.1+abc1234" "$WIRES_HOME/runtimes/nightly"
    [ "$(wires_runtime_path)" = "$WIRES_HOME/runtimes/2026.08.05.1+abc1234" ]
}

# guards: pruning on behalf of one channel must not strand another
@test "retention never removes what a DIFFERENT channel points at" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    C="$WIRES_HOME/runtimes"
    for v in 2026.01.01.1 2026.02.01.1 2026.03.01.1; do
        mkdir -p "$C/$v+aaaaaaa"
        printf 'dist-version: %s\npatch-stack:  aaaaaaaxx\nbuilt-at:     %sT00:00:00Z\n' \
            "$v" "${v//./-}" > "$C/$v+aaaaaaa/ABLETON-WINE-BUILD-INFO.txt"
    done
    ln -s "2026.03.01.1+aaaaaaa" "$C/stable"
    ln -s "2026.01.01.1+aaaaaaa" "$C/nightly"    # nightly pinned to the OLDEST
    WIRES_RUNTIME_KEEP=1 wires_prune_runtimes
    [ -d "$C/2026.03.01.1+aaaaaaa" ] || { echo "stable's target went" >&2; false; }
    [ -d "$C/2026.01.01.1+aaaaaaa" ] || { echo "nightly's target was pruned" >&2; false; }
    [ ! -e "$C/2026.02.01.1+aaaaaaa" ]           # the unpinned one goes
}


# guards: found in review. Retention protected what a channel points at and what
# a Plug is bound to, but not the build that last booted a Plug - which is what
# wires_base_move recovers to tell a same-base refresh from a base change. A
# Plug that follows a channel has no binding, so nothing pinned its booter;
# pruned, the guard loses the comparison and reports a routine update as an
# irreversible base change. That is the severity bug arriving by a second door.
@test "retention never removes the build a Plug was last booted by" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/opt"
    C="$WIRES_HOME/runtimes"
    for v in 2026.01.01.1 2026.02.01.1 2026.03.01.1; do
        mkdir -p "$C/$v+aaaaaaa/share/wine"
        printf 'dist-version: %s\npatch-stack:  aaaaaaaxx\nbuilt-at:     %sT00:00:00Z\n' \
            "$v" "${v//./-}" > "$C/$v+aaaaaaa/ABLETON-WINE-BUILD-INFO.txt"
        : > "$C/$v+aaaaaaa/share/wine/wine.inf"
        # A distinct base per build: wires_runtime_base is wine.inf's mtime, and
        # three files touched in the same instant are one base, not three.
        d="${v%.*}"; touch -d "${d//./-}T00:00:00Z" "$C/$v+aaaaaaa/share/wine/wine.inf"
    done
    ln -s "2026.03.01.1+aaaaaaa" "$C/stable"

    # The Plug follows the channel - no .wires-runtime at all - and was booted
    # by the oldest build, which the count would otherwise take first.
    mkdir -p "$WIRES_HOME/plugs/studio"
    : > "$WIRES_HOME/plugs/studio/system.reg"
    stat -c %Y "$C/2026.01.01.1+aaaaaaa/share/wine/wine.inf" \
        > "$WIRES_HOME/plugs/studio/.update-timestamp"
    [ "$(wires_plug_base_runtime "$WIRES_HOME/plugs/studio")" \
        = "$C/2026.01.01.1+aaaaaaa" ] || { echo "fixture does not resolve a booter" >&2; false; }

    WIRES_RUNTIME_KEEP=1 wires_prune_runtimes
    [ -d "$C/2026.01.01.1+aaaaaaa" ] || {
        echo "the build that booted the Plug was pruned; the base guard is now blind" >&2; false; }
    [ -d "$C/2026.03.01.1+aaaaaaa" ]      # the channel target stays, as before
    [ ! -e "$C/2026.02.01.1+aaaaaaa" ]    # and the one nothing needs still goes
}

# --- how a nightly is named ---------------------------------------------------
# dist-version is the date the build happened, for every build. `nightly` rides
# in the discriminator, so the date is written once and the id keeps its single
# separator. Putting the kind in dist-version instead would need either a second
# date or a second `+`, and the id is <version>+<discriminator>.

id_of() {   # id_of <build-info lines...>
    local d="$BATS_TEST_TMPDIR/rt"; mkdir -p "$d"
    printf '%s\n' "$@" > "$d/ABLETON-WINE-BUILD-INFO.txt"
    wires_runtime_id "$d"
}

@test "runtime id: a nightly says so, once, after the date" {
    [ "$(id_of 'dist-version: 2026.08.06.1' 'source-commit: badafaf995572b26' 'build-kind:   nightly')" \
      = "2026.08.06.1+nightly.badafaf" ]
}

@test "runtime id: a release carries no kind at all" {
    [ "$(id_of 'dist-version: 2026.08.04.1' 'source-commit: b0d847af6fcc7ab9')" \
      = "2026.08.04.1+b0d847a" ]
}

# guards: every runtime installed anywhere today predates source-commit
@test "runtime id: the patch-stack fallback still works with a kind" {
    [ "$(id_of 'dist-version: 2026.07.29.1' 'patch-stack:  9614003aabb' 'build-kind:   nightly')" \
      = "2026.07.29.1+nightly.9614003" ]
}

# guards: build-kind becomes a directory name like everything else in the id
@test "runtime id: a kind with a path separator is refused, not sanitised" {
    [ -z "$(id_of 'dist-version: 2026.08.06.1' 'source-commit: badafaf9' 'build-kind:   ../evil')" ]
}

# guards: this is the whole point -- the directory name answers "when"
@test "runtime id: dates order correctly across both channels" {
    run bash -c "printf '%s\n' '2026.08.04.1+b0d847a' '2026.08.06.1+nightly.badafaf' '2026.08.09.1+ddddddd' | sort -V | tail -1"
    [ "$output" = "2026.08.09.1+ddddddd" ]
}

@test "tarball predicate: the nightly artifact name is accepted" {
    wires_is_runtime_tarball "wine-d2d1-nspa-11.13-2026.08.06.1+nightly.badafaf.tar.zst"
}

# --- the names this library used to answer to ---------------------------------
# The rename arrives with a migration that moves every path as well; honouring
# the old names for a release means a person adjusts once, not twice. The VM
# harness alone sets ABLETON_WINEPREFIX in seven places.

@test "compat: an old infrastructure name is honoured, and says so once" {
    run env -u WIRES_PLUG ABLETON_WINEPREFIX=/tmp/oldpfx bash -c \
        '. "$REPO/wires/runtime-env.sh"; wires_plug_path'
    [ "$status" -eq 0 ]
    [[ "$output" == *"/tmp/oldpfx"* ]]
    [[ "$stderr$output" == *"now WIRES_PLUG"* ]]
}

# guards: someone with both set has already migrated and left the old one in a
# shell profile — the new name is the deliberate one
@test "compat: the new name wins when both are set" {
    run env ABLETON_WINEPREFIX=/tmp/oldpfx WIRES_PLUG=/tmp/newpfx bash -c \
        '. "$REPO/wires/runtime-env.sh"; wires_plug_path'
    [ "$output" = "/tmp/newpfx" ] || [[ "$output" == *"/tmp/newpfx"* ]]
}

@test "compat: an application's own settings are not renamed" {
    run env ABLETON_DPI_MODE=dpi120 bash -c \
        '. "$REPO/wires/runtime-env.sh"; printf "%s|%s\n" "${ABLETON_DPI_MODE:-}" "${WIRES_DPI_MODE:-unset}"'
    [[ "$output" == *"dpi120|unset"* ]]
}

@test "compat: nothing is said when no old name is set" {
    run env -u ABLETON_WINEPREFIX -u ABLETON_WINE_ROOT bash -c \
        '. "$REPO/wires/runtime-env.sh"; wires_plug_path >/dev/null'
    [ -z "$stderr" ] || [[ "$stderr" != *"will stop being read"* ]]
}

# --- the ABI range ------------------------------------------------------------
# The compatibility contract is three integers compared, so the readers that
# feed the comparison are worth pinning: a reader that sources the file it is
# judging would let that file rewrite the judge, and a reader that trusts a
# non-numeric value turns the gate off.

@test "abi field: reads a declaration without sourcing the file" {
    f="$BATS_TEST_TMPDIR/lib.sh"
    printf 'WIRES_ABI=7\nWIRES_ABI_OLDEST=3\necho SIDE-EFFECT\n' > "$f"
    [ "$(wires_abi_field "$f" WIRES_ABI)" = 7 ]
    [ "$(wires_abi_field "$f" WIRES_ABI_OLDEST)" = 3 ]
    # and nothing executed: sed read it, bash did not
    run wires_abi_field "$f" WIRES_ABI
    [[ "$output" != *"SIDE-EFFECT"* ]]
}

@test "abi field: a missing or non-numeric declaration is no value, not zero" {
    f="$BATS_TEST_TMPDIR/lib.sh"
    printf 'WIRES_ABI=$(rm -rf /)\n' > "$f"
    run wires_abi_field "$f" WIRES_ABI
    [ "$status" -ne 0 ]
    run wires_abi_field "$BATS_TEST_TMPDIR/absent" WIRES_ABI
    [ "$status" -ne 0 ]
}

# guards: found in review. The reader stripped non-digits rather than refusing a
# value that had any, so a version-shaped 1.0 read as generation TEN. Every real
# kit then looks older than what is installed, decide() keeps the installed
# library for good, and it says so in the words it uses when nothing is wrong -
# a gate that has turned itself off and reports success.
@test "abi field: a value that is not all digits is refused, not reduced to its digits" {
    f="$BATS_TEST_TMPDIR/lib.sh"
    for bad in '1.0' '2.5' 'v3' '1abc' '1 # note 2' '0x10'; do
        printf 'WIRES_ABI=%s\n' "$bad" > "$f"
        run wires_abi_field "$f" WIRES_ABI
        [ "$status" -ne 0 ] || {
            echo "'$bad' was accepted as '$output'" >&2; false; }
    done
    # and a plain number still reads, with trailing space tolerated
    printf 'WIRES_ABI=7  \n' > "$f"
    [ "$(wires_abi_field "$f" WIRES_ABI)" = 7 ]
}

# guards: raising OLDEST is the one act that can strand an application, and this
# is the census that names the casualties before it happens. An application that
# declares nothing is generation 1 — that is when it must have been written — so
# while OLDEST stays 1 this can never name anyone.
@test "apps below min: names exactly the applications an OLDEST would strand" {
    export WIRES_HOME="$BATS_TEST_TMPDIR/wires"
    mkdir -p "$WIRES_HOME/apps/old-app" "$WIRES_HOME/apps/new-app" "$WIRES_HOME/apps/mute-app"
    printf '#!/bin/sh\nWIRES_ABI_MIN=1\n' > "$WIRES_HOME/apps/old-app/old-app"
    printf '#!/bin/sh\nWIRES_ABI_MIN=4\n' > "$WIRES_HOME/apps/new-app/new-app"
    # mute-app has no launcher at all: treated as generation 1
    [ -z "$(wires_apps_below_min 1)" ]
    [ "$(wires_apps_below_min 2 | sort | tr '\n' ' ')" = "mute-app old-app " ]
    [ -z "$(wires_apps_below_min 2 | grep -x new-app || true)" ]
    [ "$(wires_apps_below_min 5 | grep -cx new-app)" = 1 ]
}

# ---------------------------------------------------------------------------
# Putting the installed commands on PATH.
#
# The defect behind these, reported off a rebuilt VM: the kit installed,
# ~/.local/bin/wires existed, and `wires` was not found. ~/.profile is read once
# by the session at login and adds ~/.local/bin only `if [ -d ]` - and the
# directory is created by the installer, after that. A terminal opened next is
# an interactive non-login shell, which never reads ~/.profile again, so the
# command stays missing until the user logs out of their desktop.
#
# Hence: write the *interactive* rc, unconditionally, and say what to do about
# the shell you are standing in.
# ---------------------------------------------------------------------------

a_login_shell() {               # [shell-name] -> path to a fake shell
    local sh="$BATS_TEST_TMPDIR/${1:-bash}"
    printf '#!/bin/sh\nexit 0\n' > "$sh"
    chmod +x "$sh"
    printf '%s\n' "$sh"
}

@test "path rc: the interactive file, not the login file" {
    SHELL="$(a_login_shell bash)"; export SHELL
    [ "$(wires_path_rc)" = "$HOME/.bashrc" ]
    # even when a login file exists, which is the trap this replaced
    printf '\n' > "$HOME/.bash_profile"; printf '\n' > "$HOME/.profile"
    [ "$(wires_path_rc)" = "$HOME/.bashrc" ]
    SHELL="$(a_login_shell zsh)"; export SHELL
    [ "$(wires_path_rc)" = "$HOME/.zshrc" ]
    SHELL="$(a_login_shell fish)"; export SHELL
    [ "$(wires_path_rc)" = "$HOME/.config/fish/conf.d/wires.fish" ]
    SHELL="$(a_login_shell nushell)"; export SHELL
    ! wires_path_rc
}

@test "path register: writes the block, fenced, and says how to get it now" {
    SHELL="$(a_login_shell bash)"; export SHELL
    printf 'original line\n' > "$HOME/.bashrc"
    run wires_path_register wires
    [ "$status" -eq 0 ]
    grep -qF 'original line' "$HOME/.bashrc"
    grep -qF '# >>> wires >>>' "$HOME/.bashrc"
    grep -qF '# <<< wires <<<' "$HOME/.bashrc"
    grep -qF '.local/bin' "$HOME/.bashrc"
    [[ "$output" == *".bashrc"* ]]
}

# guards: unconditional means it runs on every install, so running twice must
# not leave two blocks - the fence is what makes that checkable.
@test "path register: twice leaves one block" {
    SHELL="$(a_login_shell bash)"; export SHELL
    wires_path_register wires >/dev/null
    wires_path_register wires >/dev/null
    [ "$(grep -c '>>> wires >>>' "$HOME/.bashrc")" = 1 ]
    [ "$(grep -c '<<< wires <<<' "$HOME/.bashrc")" = 1 ]
}

# guards: the block has to be a no-op when the entry is already there, or every
# nested shell prepends another copy and PATH grows without bound.
@test "path register: the block it writes does not duplicate an existing entry" {
    SHELL="$(a_login_shell bash)"; export SHELL
    wires_path_register wires >/dev/null
    local out
    out="$(PATH="$HOME/.local/bin:/usr/bin" bash -c ". '$HOME/.bashrc'; echo \$PATH")"
    [ "$(printf '%s\n' "$out" | tr ':' '\n' | grep -cx "$HOME/.local/bin")" = 1 ]
}

# guards: and it has to actually put it there when it is absent
@test "path register: the block it writes does add the entry" {
    SHELL="$(a_login_shell bash)"; export SHELL
    wires_path_register wires >/dev/null
    local out
    out="$(PATH=/usr/bin bash -c ". '$HOME/.bashrc'; echo \$PATH")"
    [ "$(printf '%s\n' "$out" | tr ':' '\n' | grep -cx "$HOME/.local/bin")" = 1 ]
}

@test "path register: an unknown shell is told what to add, and nothing is written" {
    SHELL="$(a_login_shell nushell)"; export SHELL
    run wires_path_register wires
    [ "$status" -eq 0 ]
    [[ "$output" == *'PATH="$HOME/.local/bin:$PATH"'* ]]
    [ ! -e "$HOME/.bashrc" ]
}

@test "path register: already registered and already on PATH says nothing" {
    SHELL="$(a_login_shell bash)"; export SHELL
    wires_path_register wires >/dev/null
    PATH="$HOME/.local/bin:$PATH"
    run wires_path_register wires
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "path register: already registered but missing from this shell says how" {
    SHELL="$(a_login_shell bash)"; export SHELL
    wires_path_register wires >/dev/null
    run wires_path_register wires
    [ "$status" -eq 0 ]
    [[ "$output" == *"already puts"* ]]
    [[ "$output" == *".bashrc"* ]]
}

@test "path unregister: takes the block out and leaves the rest" {
    SHELL="$(a_login_shell bash)"; export SHELL
    printf 'before\n' > "$HOME/.bashrc"
    wires_path_register wires >/dev/null
    printf 'after\n' >> "$HOME/.bashrc"
    run wires_path_unregister
    [ "$status" -eq 0 ]
    grep -qx 'before' "$HOME/.bashrc"
    grep -qx 'after' "$HOME/.bashrc"
    ! grep -q 'wires >>>' "$HOME/.bashrc"
    ! grep -q '.local/bin' "$HOME/.bashrc"
}

# guards: uninstall runs on machines installed before this existed
@test "path unregister: silent with nothing to remove" {
    SHELL="$(a_login_shell bash)"; export SHELL
    printf 'untouched\n' > "$HOME/.bashrc"
    run wires_path_unregister
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$HOME/.bashrc")" = "untouched" ]
    run wires_path_unregister
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The Uninstall index as records.
#
# Shapes taken from ~/.wine-ableton rather than invented: the doubled
# backslashes, the ",0" icon index, the GUID keys, and the fact that a real
# Live prefix's Uninstall index holds nothing but platform runtimes.
# ---------------------------------------------------------------------------

# Writes the .reg on stdin into a fresh Plug and names it. The heredoc goes
# inside the command substitution, not beside it: `$(f <<'X')` on one line
# leaves bash parsing the body outside the substitution and warning about it.
a_prefix() {
    local p="$BATS_TEST_TMPDIR/plug"
    mkdir -p "$p"
    cat > "$p/system.reg"
    printf '%s\n' "$p"
}

@test "entries: one record per Uninstall key, fields in order" {
    local p key disp icon ver loc un
    p="$(a_prefix <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Notepad++] 1784299416
"DisplayName"="Notepad++ (64-bit x64)"
"DisplayIcon"="C:\\Program Files\\Notepad++\\notepad++.exe"
"DisplayVersion"="8.9.7"
"InstallLocation"="C:\\Program Files\\Notepad++"
"QuietUninstallString"="\"C:\\Program Files\\Notepad++\\uninstall.exe\" /S"
REG
)"
    IFS="$WIRES_FS" read -r key disp icon ver loc un < <(wires_plug_entries "$p")
    [ "$key"  = "Notepad++" ]
    [ "$disp" = 'Notepad++ (64-bit x64)' ]
    [ "$ver"  = "8.9.7" ]
    [ "$(wires_reg_unescape "$icon")" = 'C:\Program Files\Notepad++\notepad++.exe' ]
    [ "$(wires_reg_unescape "$loc")"  = 'C:\Program Files\Notepad++' ]
    [[ "$(wires_reg_unescape "$un")" == *"/S" ]]
}

# guards: the defect that made this a named constant. InstallLocation is empty
# more often than not, and with a tab the empty field vanishes and the
# uninstall command arrives in the location variable.
@test "entries: an empty middle field stays empty and shifts nothing" {
    local p key disp icon ver loc un
    p="$(a_prefix <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Thing] 1784299416
"DisplayName"="Thing"
"DisplayIcon"="C:\\thing\\thing.exe"
"DisplayVersion"="1.0"
"UninstallString"="C:\\thing\\uninst.exe"
REG
)"
    IFS="$WIRES_FS" read -r key disp icon ver loc un < <(wires_plug_entries "$p")
    [ -z "$loc" ]
    [ "$(wires_reg_unescape "$un")" = 'C:\thing\uninst.exe' ]
    [ "$ver" = "1.0" ]
}

@test "entries: QuietUninstallString wins over UninstallString" {
    local p key disp icon ver loc un
    p="$(a_prefix <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Thing] 1784299416
"DisplayName"="Thing"
"UninstallString"="C:\\thing\\uninst.exe"
"QuietUninstallString"="C:\\thing\\uninst.exe /S"
REG
)"
    IFS="$WIRES_FS" read -r key disp icon ver loc un < <(wires_plug_entries "$p")
    [[ "$(wires_reg_unescape "$un")" == *"/S" ]]
}

@test "entries: SystemComponent and nameless keys are dropped" {
    local p
    p="$(a_prefix <<'REG'
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Hidden] 1784299416
"DisplayName"="Hidden Support Package"
"SystemComponent"=dword:00000001
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Nameless] 1784299416
"DisplayVersion"="2.0"
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Real] 1784299416
"DisplayName"="Real Thing"
REG
)"
    [ "$(wires_plug_entries "$p" | wc -l)" = 1 ]
    [[ "$(wires_plug_entries "$p")" == *"Real Thing"* ]]
}

# guards: measured on ~/.wine-ableton, where Live is in RegisteredApplications
# alone and every one of the ten Uninstall entries is a platform runtime. The
# reader is the Uninstall index only, so it must come back empty here rather
# than appear to have looked everywhere.
@test "entries: an application that registers only in RegisteredApplications is absent" {
    local p
    p="$(a_prefix <<'REG'
[Software\\RegisteredApplications] 1784299416
"Ableton Live 12 Suite"="SOFTWARE\\Ableton\\LiveSuite.12\\Capabilities"
[Software\\Ableton\\LiveSuite.12\\Capabilities] 1784299416
"ApplicationName"="Ableton Live 12 Suite"
REG
)"
    [ -z "$(wires_plug_entries "$p")" ]
    # ...while the census, which reads the union, does see it
    [ "$(wires_plug_tenants "$p")" = "Ableton Live 12 Suite" ]
}

@test "win path: drive letter dropped, separators flipped, icon index stripped" {
    [ "$(wires_win_path /p 'C:\Program Files\App\app.exe')" = '/p/drive_c/Program Files/App/app.exe' ]
    [ "$(wires_win_path /p 'C:\App\app.exe,0')"             = '/p/drive_c/App/app.exe' ]
    [ "$(wires_win_path /p/ '"C:\App\app.exe"')"            = '/p/drive_c/App/app.exe' ]
}

@test "reg unescape: doubled backslashes halve, escaped quotes survive" {
    [ "$(wires_reg_unescape 'C:\\Program Files\\A')" = 'C:\Program Files\A' ]
    [ "$(wires_reg_unescape '\"C:\\a.exe\" /S')"     = '"C:\a.exe" /S' ]
}

@test "platform runtimes: every DisplayName a real Live prefix carries is matched" {
    local n
    for n in "Wine Mono Runtime" "Wine Mono Windows Support" \
             "Microsoft Edge WebView2 Runtime" \
             "Microsoft Visual C++ 2022 X64 Minimum Runtime - 14.44.35211" \
             "Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.44.35211" \
             "Microsoft Windows Desktop Runtime - 8.0.0"; do
        printf '%s\n' "$n" | grep -qE "$(wires_platform_runtimes)" \
            || { echo "unmatched: $n"; return 1; }
    done
    # and an application is not a platform runtime
    printf 'Notepad++ (64-bit x64)\n' | grep -qvE "$(wires_platform_runtimes)"
}
