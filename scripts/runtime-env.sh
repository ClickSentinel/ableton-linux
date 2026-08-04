# shellcheck shell=bash
# Where the patched Wine runtime and the Ableton prefix live, in one place.
#
# Sourced, never executed. Seven scripts resolved these paths independently
# before this existed, which was survivable while each was a single line with a
# default. It stops being survivable once the path depends on a release
# channel: the resolution grows a marker read, a validation, and two fallbacks,
# and seven copies of that will not stay in agreement. The collision is not
# hypothetical - PR #120 added a /proc scan and a wineserver stop that must
# scope to the same root install.sh is about to replace, and a resolver that
# disagrees there swaps a runtime out from under running processes.
#
# The resolvers are pure: they echo and touch nothing, so a caller takes only
# what it wants and they can be tested without a sandbox. Binding the current
# shell to the runtime is opt-in, because only three of the callers want it -
# the rest would be changed by an exported PATH or a cleared WINEDLLOVERRIDES.
#
#   . "$lib/runtime-env.sh"
#   WINE_ROOT="$(ableton_wine_root)"           # just the path
#   ableton_bind_runtime                       # the full launcher binding

# The installed runtime. ABLETON_WINE_ROOT overrides it - the tests, the
# regression VMs and anyone bisecting a build rely on that, so it stays the
# outermost say regardless of what channel support later resolves underneath.
# The directory installs live under. A seam for the tests; nothing else sets it.
ableton_opt_dir() {
    printf '%s\n' "${ABLETON_OPT_DIR:-$HOME/.local/opt}"
}

ableton_container_root() {
    printf '%s\n' "$(ableton_opt_dir)/ableton-wine"
}

# The runtime's build name. It carries the Wine version because the *artifact*
# does — a tarball identifies which build it is. Nothing about where a runtime
# is installed depends on it any more.
ableton_runtime_name() {
    printf '%s\n' "wine-d2d1-nspa-11.13"
}

# The pre-container install path. Carries the Wine version, which is exactly
# why it is being retired: a base bump moved every user's directory.
ableton_legacy_root() {
    printf '%s\n' "$(ableton_opt_dir)/$(ableton_runtime_name)"
}

# The newest runtime tarball in <dir>, or nothing. Shared because it was not:
# install.sh, make-installer.sh and build-audit.sh each had a copy, the same
# defect was in all three, and fixing one left a release assembled — and
# audited — from whatever `sort -V` put last.
#
# The glob cannot be the selector. The build also emits
# <name>-<version>-debug.tar.zst, and `sort -V` orders that suffix *after* the
# runtime, so a glob piped to `tail -1` picks the debug tree: bin/ and lib/ but
# no share/, passes `wine --version`, then fails at launch with "could not exec
# the wine loader". Match the dated release form only.
#
# Locals are underscore-prefixed because this is sourced into scripts that have
# their own $found and $target.
ableton_pick_tarball() {
    local _dir="$1" _nm _f _b
    _nm="$(ableton_runtime_name)"
    local _re="^${_nm//./\\.}-[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}\\.[0-9]+\\.tar\\.zst\$"
    local -a _found=()
    for _f in "$_dir"/"$_nm"-*.tar.zst; do
        [ -e "$_f" ] || continue          # no match: the glob came back literal
        _b="${_f##*/}"
        [[ "$_b" =~ $_re ]] || continue
        _found+=("$_f")
    done
    [ "${#_found[@]}" -gt 0 ] || return 0
    printf '%s\n' "${_found[@]}" | sort -V | tail -1
}

ableton_wine_root() {
    local container
    # An explicit pin always wins: the tests, the regression VMs and anyone
    # bisecting a build rely on it, and it is what tells the migration to leave
    # an install where its owner put it.
    if [ -n "${ABLETON_WINE_ROOT:-}" ]; then
        printf '%s\n' "$ABLETON_WINE_ROOT"
        return
    fi
    # Prefer the container once it exists. The legacy path survives as a
    # compatibility symlink, so resolving through it would still work — but it
    # would make the shim load-bearing rather than vestigial, and a later
    # release could not drop it without a second migration.
    container="$(ableton_container_root)/stable"
    if [ -d "$container" ]; then
        printf '%s\n' "$container"
        return
    fi
    ableton_legacy_root
}

# The Ableton prefix. Separate from the runtime on purpose: a channel switch
# changes both, but a test or a clone changes only this one.
ableton_wine_prefix() {
    printf '%s\n' "${ABLETON_WINEPREFIX:-$HOME/.wine-ableton}"
}

# Bind this shell to the runtime: drop inherited Wine settings that would
# reach the wrong build, then export what wine and its helpers read.
#
# The unset list is deliberately the four the launchers have always cleared.
# setup-prefix.sh additionally clears WINEESYNC and WINEFSYNC and keeps doing
# so at its own call site: folding them in here would silently start dropping a
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

# The process table to read. Only the tests set this, pointing it at a fixture
# tree of fake exe symlinks; /proc cannot be stubbed through PATH the way pgrep
# can, so without a seam the accurate implementation is the untestable one.
ableton_proc_root() {
    printf '%s\n' "${ABLETON_PROC_ROOT:-/proc}"
}

# Every pid whose binary lives under the runtime. From PR #120, which found the
# reason a command line cannot answer this: Wine's in-prefix helpers show a
# Windows path in argv (C:\windows\system32\...), so no pattern reaches them.
# The exe link is the real binary - bin/wineserver, or the wine-preloader every
# in-prefix process runs from - so the match is exact rather than a guess, and
# is scoped to this runtime instead of any Wine on the machine.
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
        pgrep -af '[A]bleton Live.*\.exe|[P]ush2DisplayProcess.exe' >/dev/null 2>&1
}

# Live itself, as opposed to the support processes around it. A launcher wants
# this and not runtime_busy: a wineserver lingering after Live exits must still
# count as "Live is down", or the stale-server kill never runs.
ableton_live_pids() {
    local proc p
    proc="$(ableton_proc_root)"
    local cmd
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

# --- layout migration --------------------------------------------------------
# One-time move from the flat layout (~/.local/opt/wine-d2d1-nspa-11.13) to the
# container (~/.local/opt/ableton-wine/<channel>). Only install.sh calls this;
# it is here because it has to agree with the resolvers above about where a
# runtime lives, and those two drifting apart is the failure this whole file
# exists to prevent.

_ableton_same_path() {
    [ "$(realpath -m "$1" 2>/dev/null)" = "$(realpath -m "$2" 2>/dev/null)" ]
}

# Migrate, or explain why not. Idempotent, and refuses rather than guessing
# whenever both locations hold a real tree and either could be the live one.
#
# The caller must already have established that nothing is running from the
# runtime: this renames the directory a running Wine is executing from.
ableton_migrate_layout() {
    local legacy container target link d base
    legacy="$(ableton_legacy_root)"
    container="$(ableton_container_root)"
    target="$container/stable"

    if [ -n "${ABLETON_WINE_ROOT:-}" ]; then
        echo "   layout: ABLETON_WINE_ROOT is set; leaving the install where it is"
        return 0
    fi

    if [ -d "$target" ] && [ ! -L "$target" ]; then
        if [ -L "$legacy" ]; then
            link="$(readlink "$legacy")"
            _ableton_same_path "$(dirname "$legacy")/$link" "$target" || {
                echo "!! $legacy points at $link, not the installed runtime;" \
                     "remove it and rerun" >&2; return 1; }
            return 0                                   # steady state
        fi
        [ ! -e "$legacy" ] || {
            echo "!! both $target and $legacy hold a runtime; cannot tell which" \
                 "is live. Remove whichever is stale and rerun" >&2; return 1; }
        ln -s "ableton-wine/stable" "$legacy"          # link lost, put it back
        echo "   layout: restored the compatibility link at $legacy"
        return 0
    fi

    # -e follows symlinks, so a dangling link reads as absent here and would
    # fall through to a silent no-op. Test both, and let the check below name it.
    if [ ! -e "$legacy" ] && [ ! -L "$legacy" ]; then
        return 0                                       # fresh install, nothing to move
    fi
    [ ! -L "$legacy" ] || {
        echo "!! $legacy is a symlink but there is no runtime at $target;" \
             "remove it and rerun" >&2; return 1; }

    mkdir -p "$container"
    mv "$legacy" "$target"
    # The dated rollbacks travel too. Left behind they are invisible to the
    # container-scoped uninstall and orphan several GB apiece.
    for d in "$legacy"-rollback-* "$legacy".failed-*; do
        [ -e "$d" ] || continue
        base="${d##*/}"
        mv "$d" "$container/stable${base#"${legacy##*/}"}"
    done
    ln -s "ableton-wine/stable" "$legacy"
    echo "   layout: moved the runtime to $target (compatibility link kept)"
}

# Remove every runtime this installer owns. Lives here rather than in
# uninstall.sh because it has to agree with the resolvers above about where
# runtimes are, and because deleting trees is worth testing — which needs it to
# be a function with a seam, not inline in a script that also stops systemd
# units and rewrites the desktop database.
ableton_remove_runtimes() {
    local container legacy d
    if [ -n "${ABLETON_WINE_ROOT:-}" ]; then
        # The user pinned a path; remove that and nothing else.
        rm -rf "$ABLETON_WINE_ROOT" && echo "removed $ABLETON_WINE_ROOT"
    else
        # One directory holds every channel and every dated rollback, so this is a
        # single removal rather than a sibling glob. That glob is what would orphan
        # multi-GB rollback directories the moment a suffix joined the runtime name.
        container="$(ableton_container_root)"
        [ ! -e "$container" ] || { rm -rf "$container" && echo "removed $container"; }

        # An install that never migrated still has the flat layout, and a migrated
        # one leaves the compatibility symlink behind. rm -rf on a symlink removes
        # the link, not its target — which the container removal above already took.
        legacy="$(ableton_legacy_root)"
        if [ -e "$legacy" ] || [ -L "$legacy" ]; then
            rm -rf "$legacy" && echo "removed $legacy"
        fi
        for d in "$legacy"-rollback-* "$legacy".failed-*; do
            [ -e "$d" ] || continue     # unmatched glob stays literal; skip, don't abort
            rm -rf "$d" && echo "removed $d"
        done
    fi
}
