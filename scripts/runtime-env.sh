# shellcheck shell=bash
# Where the runtime and the prefix are, which tarball to act on, and what is
# running from either.
#
# Sourced, never executed. This exists because each answer was written several
# times over — the tarball selector in install.sh, make-installer.sh and
# build-audit.sh, with the same defect in all three; the prefix default in
# install.sh twice and in the launcher again; and PR #120's process scan inline
# in install.sh, where nothing else could reach it. Copies of a path do not stay
# in agreement, and the failure when they diverge is not cosmetic: #120's scan
# and the directory install.sh is about to replace have to name the same tree,
# or a runtime is swapped out from under running processes.
#
# The resolvers are pure: they echo and touch nothing, so a caller takes only
# what it wants and they can be tested without a sandbox. Binding the current
# shell to the runtime is opt-in, because only the launchers want it.
#
#   . "$here/runtime-env.sh"
#   WINE_ROOT="$(ableton_wine_root)"           # just the path
#   ableton_bind_runtime                       # the full launcher binding

# The directory installs live under. A seam for the tests; nothing else sets it.
ableton_opt_dir() {
    printf '%s\n' "${ABLETON_OPT_DIR:-$HOME/.local/opt}"
}

# The runtime's build name. It carries the Wine version because the artifact
# does: a tarball identifies which build it is.
ableton_runtime_name() {
    printf '%s\n' "wine-d2d1-nspa-11.13"
}

# The directory holding every installed runtime, one per build.
ableton_container_root() {
    printf '%s\n' "$(ableton_opt_dir)/ableton-wine"
}

# The pre-container install path. Carries the Wine version, which is exactly why
# it is being retired: a base bump moved every user's directory.
ableton_legacy_root() {
    printf '%s\n' "$(ableton_opt_dir)/$(ableton_runtime_name)"
}

# The installed runtime. ABLETON_WINE_ROOT overrides it — the tests, the
# regression VMs and anyone bisecting a build rely on that, so it stays the
# outermost say.
#
# Returns what the channel points at, never the channel path itself. Two things
# turn on that, and both were measured rather than argued:
#
# /proc/PID/exe reports a path with symlinks already resolved, so a process
# launched through <container>/stable/bin/wine appears under the build's own
# name. Compare against the channel and ableton_runtime_pids matches nothing:
# the confirmation before force-closing Live never fires, the targeted kills
# reach nothing, and only the pgrep fallback PR #120 added the scan to replace
# still works — while install.sh goes on to rename the directory.
#
# And a caller that resolved once keeps the build it resolved. A channel switch
# part-way through a session cannot move the runtime under a process already
# executing from it.
ableton_wine_root() {
    local _chan _target
    if [ -n "${ABLETON_WINE_ROOT:-}" ]; then
        printf '%s\n' "$ABLETON_WINE_ROOT"
        return
    fi
    _chan="$(ableton_container_root)/stable"
    if [ -e "$_chan" ]; then
        _target="$(readlink -f "$_chan" 2>/dev/null || true)"
        if [ -n "$_target" ]; then
            printf '%s\n' "$_target"
            return
        fi
    fi
    # No container yet: an install that predates the migration still has to
    # resolve and launch.
    ableton_legacy_root
}

# The Ableton prefix. Separate from the runtime on purpose: a channel switch
# would change both, but a test or a clone changes only this one.
ableton_wine_prefix() {
    printf '%s\n' "${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
}

# Bind this shell to the runtime: drop inherited Wine settings that would reach
# the wrong build, then export what wine and its helpers read.
#
# The unset list is deliberately the four the launchers have always cleared.
# setup-prefix.sh additionally clears WINEESYNC and WINEFSYNC and keeps doing so
# at its own call site: folding them in here would silently start dropping a
# user's WINEESYNC on every launch, which is a behaviour change wearing a
# refactor's clothes.
ableton_bind_runtime() {
    unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH
    WINE_ROOT="$(ableton_wine_root)"
    WINEPREFIX="$(ableton_wine_prefix)"
    WINESERVER="$WINE_ROOT/bin/wineserver"
    PATH="$WINE_ROOT/bin:$PATH"
    export WINEPREFIX WINESERVER PATH
}

# Is this a runtime tarball an install will select? The name is the whole test.
#
# The glob cannot be the selector. The build also emits
# <name>-<version>-debug.tar.zst, and `sort -V` orders that suffix *after* the
# runtime, so a glob piped to `tail -1` picks the debug tree — which carries
# bin/ and lib/ but no share/, passes `wine --version`, and then fails at launch
# with "could not exec the wine loader". Match the dated release form only and
# let every suffixed variant fall out.
#
# A predicate rather than the regex inlined at one call site, because there are
# two: the selector below, and make-installer.sh checking the tarball it was
# told to pack. Those disagreeing is not hypothetical — a name this rejects
# packs into a kit perfectly well, and the failure surfaces on the user's
# machine, where the kit's own install.sh finds nothing to install.
ableton_is_runtime_tarball() {
    local _b="${1##*/}" _nm _re
    _nm="$(ableton_runtime_name)"
    _re="^${_nm//./\\.}-[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}\\.[0-9]+\\.tar\\.zst\$"
    [[ "$_b" =~ $_re ]]
}

# The newest runtime tarball in <dir>, or nothing.
#
# Locals are underscore-prefixed: this is sourced into scripts with their own
# $found and $target.
ableton_pick_tarball() {
    local _dir="$1" _nm _f
    _nm="$(ableton_runtime_name)"
    local -a _found=()
    for _f in "$_dir"/"$_nm"-*.tar.zst; do
        [ -e "$_f" ] || continue          # no match: the glob came back literal
        ableton_is_runtime_tarball "$_f" || continue
        _found+=("$_f")
    done
    [ "${#_found[@]}" -gt 0 ] || return 0
    printf '%s\n' "${_found[@]}" | sort -V | tail -1
}

# --- what is running from the runtime ----------------------------------------

# The process table to read. Only the tests set this, pointing it at a fixture
# tree of fake exe symlinks; /proc cannot be stubbed through PATH the way pgrep
# can, so without a seam the accurate implementation is the untestable one.
ableton_proc_root() {
    printf '%s\n' "${ABLETON_PROC_ROOT:-/proc}"
}

# Every pid whose binary lives under the runtime. From PR #120, which found the
# reason a command line cannot answer this: Wine's in-prefix helpers show a
# Windows path in argv (C:\windows\system32\...), so no pattern reaches them,
# and a pattern also catches unrelated processes that merely mention the path.
# The exe link is the real binary — bin/wineserver, or the wine-preloader every
# in-prefix process runs from — so the match is exact and scoped to this
# runtime rather than any Wine on the machine.
ableton_runtime_pids() {
    local proc root d
    root="$(ableton_wine_root)"
    proc="$(ableton_proc_root)"
    for d in "$proc"/[0-9]*; do
        case "$(readlink "$d/exe" 2>/dev/null)" in
            "$root"/*) printf '%s\n' "${d##*/}" ;;
        esac
    done
}

# Anything at all using the runtime: the predicate to ask before replacing its
# files. The name match stays as a second opinion because failing open here
# means installing over a running runtime.
ableton_runtime_busy() {
    [ -n "$(ableton_runtime_pids)" ] || \
        pgrep -f '[A]bleton Live.*\.exe|[P]ush2DisplayProcess.exe' >/dev/null 2>&1
}

# Live itself, as opposed to the support processes around it. The install
# prompt is about unsaved work, and only Live has any.
ableton_live_pids() {
    local proc p cmd
    proc="$(ableton_proc_root)"
    for p in $(ableton_runtime_pids); do
        # A process can exit between the scan above and this read — during an
        # install that is common, because the stop is what made them exit. The
        # shell reports a failed redirection itself, before tr ever runs, so
        # tr's own 2>/dev/null cannot suppress it. Check first instead.
        [ -r "$proc/$p/cmdline" ] || continue
        cmd="$(tr -s '\0' ' ' < "$proc/$p/cmdline" 2>/dev/null)" || continue
        case "$cmd" in
            *"Ableton Live"*.exe*) printf '%s\n' "$p" ;;
        esac
    done
}

ableton_live_running() {
    [ -n "$(ableton_live_pids)" ]
}

# --- identifying an installed runtime ----------------------------------------

# One field out of a tree's ABLETON-WINE-BUILD-INFO.txt. The file pads its
# values to a column, so the separator is a colon followed by any amount of
# space, not ": ".
ableton_buildinfo_field() {
    local _file="$1" _key="$2" _v
    [ -r "$_file" ] || return 0
    _v="$(sed -n "s/^${_key}:[[:space:]]*//p" "$_file" | head -1)"
    printf '%s\n' "${_v%"${_v##*[![:space:]]}"}"   # strip any trailing space
}

# The identity of an installed runtime: <dist-version>+<discriminator>.
# Echoes nothing when the tree cannot be named; a caller must treat that as a
# refusal, never as a default.
#
# The discriminator is source-commit where the file has one and the first seven
# characters of patch-stack where it does not. That fallback is not defensive:
# measured 2026-08-04, none of the eleven runtimes on the development machine
# carries source-commit, because the commit that writes it is not released. So
# requiring it would refuse every runtime installed anywhere today.
#
# dist-version alone cannot serve. On that machine 2026.07.29.1 appears four
# times under two different patch stacks, and 2026.07.23.1 covers both the 11.11
# and the 11.14 tree — keyed on version they would collide.
ableton_runtime_id() {
    local _dir="$1" _info _ver _disc
    _info="$_dir/ABLETON-WINE-BUILD-INFO.txt"
    [ -r "$_info" ] || return 0

    _ver="$(ableton_buildinfo_field "$_info" dist-version)"
    [ -n "$_ver" ] || return 0

    _disc="$(ableton_buildinfo_field "$_info" source-commit)"
    [ -n "$_disc" ] || _disc="$(ableton_buildinfo_field "$_info" patch-stack)"
    [ -n "$_disc" ] || return 0
    _disc="${_disc:0:7}"

    # The id becomes a directory name, so it is validated rather than trusted: a
    # BUILD-INFO is plain text inside a tarball and nothing upstream of here
    # constrains what it holds.
    case "$_ver$_disc" in
        *[!0-9A-Za-z._-]*|*..*) return 0 ;;
    esac
    printf '%s+%s\n' "$_ver" "$_disc"
}

# --- layout migration --------------------------------------------------------
# One-time move from the flat layout to the store: one directory per build,
# named from its own BUILD-INFO, with a channel symlink at the live one. Only
# install.sh calls this. It lives here because it has to agree with the
# resolvers above about where a runtime is, and those drifting apart is the
# failure this whole file exists to prevent.

# Is <a> a newer build than <b>? built-at where both carry it, dist-version
# otherwise. Runtimes built before built-at existed have only the version, which
# ties across every nightly between two releases — that is why the field was
# added, and why this answers "no" rather than guessing when it cannot tell.
ableton_build_is_newer() {
    local _a="$1" _b="$2" _av _bv
    _av="$(ableton_buildinfo_field "$_a/ABLETON-WINE-BUILD-INFO.txt" built-at)"
    _bv="$(ableton_buildinfo_field "$_b/ABLETON-WINE-BUILD-INFO.txt" built-at)"
    if [ -z "$_av" ] || [ -z "$_bv" ]; then
        _av="$(ableton_buildinfo_field "$_a/ABLETON-WINE-BUILD-INFO.txt" dist-version)"
        _bv="$(ableton_buildinfo_field "$_b/ABLETON-WINE-BUILD-INFO.txt" dist-version)"
    fi
    [ -n "$_av" ] && [ -n "$_bv" ] || return 1
    [ "$_av" != "$_bv" ] || return 1
    [ "$(printf '%s\n%s\n' "$_av" "$_bv" | sort -V | tail -1)" = "$_av" ]
}

# Move <dir> into the store under its own id. A tree that cannot be named, or
# whose name is already taken, is set aside under <container>/<kind>-<stamp>/
# rather than deleted — these are multi-gigabyte runtimes and nothing here
# removes one behind the user's back.
ableton_store_absorb() {
    local _dir="$1" _stamp="$2" _container _id _aside
    _container="$(ableton_container_root)"
    _id="$(ableton_runtime_id "$_dir")"
    if [ -n "$_id" ] && [ ! -e "$_container/$_id" ]; then
        mv "$_dir" "$_container/$_id"
        printf '%s\n' "$_id"
        return 0
    fi
    # unnameable, or a name already held by an identical build
    _aside="$_container/$([ -n "$_id" ] && echo superseded || echo failed)-$_stamp"
    mkdir -p "$_aside"
    mv "$_dir" "$_aside/${_dir##*/}"
    return 0
}

# Migrate, or explain why not. Idempotent, and refuses rather than guessing when
# the live tree cannot be identified — installing over an unidentifiable runtime
# is the ambiguous case the store exists to prevent.
#
# Nothing is left at the legacy path. An earlier design kept a compatibility
# symlink there and it did not survive examination: the case it was chiefly
# justified by, an older .run, does not read that path, it overwrites it.
#
# The caller must already have established that nothing is running from the
# runtime: this renames the directory a running Wine executes from.
ableton_migrate_layout() {
    local legacy container chan stamp id other d
    legacy="$(ableton_legacy_root)"
    container="$(ableton_container_root)"
    chan="$container/stable"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"

    if [ -n "${ABLETON_WINE_ROOT:-}" ]; then
        echo "   layout: ABLETON_WINE_ROOT is set; leaving the install where it is"
        return 0
    fi

    # Already migrated. A real tree at the legacy path beside it is not
    # corruption: an older .run knows nothing about the store and writes one
    # there. That is a normal action on a machine holding an older installer, so
    # recover rather than refuse — identify both and keep the newer live.
    if [ -L "$chan" ]; then
        if [ -d "$legacy" ] && [ ! -L "$legacy" ]; then
            other="$(readlink -f "$chan" 2>/dev/null || true)"
            if [ -z "$(ableton_runtime_id "$legacy")" ] && \
               { [ -z "$other" ] || [ -z "$(ableton_runtime_id "$other")" ]; }; then
                echo "!! neither $legacy nor $chan can be identified from its" \
                     "BUILD-INFO; remove whichever is stale and rerun" >&2
                return 1
            fi
            id="$(ableton_store_absorb "$legacy" "$stamp")"
            if [ -n "$id" ] && [ -n "$other" ] && ableton_build_is_newer "$container/$id" "$other"; then
                ln -sfn "$id" "$chan"
                echo "   layout: adopted the newer $id from $legacy"
            else
                echo "   layout: kept $legacy as a store entry; the channel stays where it was"
            fi
        fi
        return 0
    fi

    # Nothing installed: install.sh creates the store itself.
    if [ ! -e "$legacy" ] && [ ! -L "$legacy" ]; then
        return 0
    fi

    # -L as well as -e: a dangling link from an older layout reads as absent to
    # -e alone and would fall through to a silent no-op.
    if [ -L "$legacy" ]; then
        echo "!! $legacy is a symlink, not a runtime; remove it and rerun" >&2
        return 1
    fi

    id="$(ableton_runtime_id "$legacy")"
    [ -n "$id" ] || {
        echo "!! $legacy carries no readable ABLETON-WINE-BUILD-INFO.txt, so it" \
             "cannot be named; installing over it would be a guess" >&2
        return 1; }

    mkdir -p "$container"
    mv "$legacy" "$container/$id"
    ln -sfn "$id" "$chan"

    # The dated rollbacks travel too, and become readable in the process: each
    # carries its own BUILD-INFO, so a timestamp that recorded when a runtime
    # was replaced becomes a name that says which build it holds. Left behind
    # they are invisible to the container-scoped uninstall and orphan several
    # gigabytes apiece.
    for d in "$legacy"-rollback-* "$legacy".failed-*; do
        [ -e "$d" ] || continue
        ableton_store_absorb "$d" "$stamp" >/dev/null
    done
    echo "   layout: moved the runtime to $container/$id"
}
