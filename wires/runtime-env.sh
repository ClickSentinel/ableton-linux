# shellcheck shell=bash
# Where the runtime and the prefix are, which tarball to act on, and what is
# running from either. Sourced, never executed.
#
# The resolvers print an answer and change nothing, so a caller sources this
# file and uses only the functions it needs. Binding the shell to a runtime is opt-in; only launchers need
# it. See README.md for why this file exists and what the words mean.
#
#   . "$here/runtime-env.sh"
#   WINE_ROOT="$(wires_runtime_path)"
#   wires_bind_runtime

# The compatibility contract, as a range; README.md has the rules.
#
#   compatible  <=>  WIRES_ABI_OLDEST <= WIRES_ABI_MIN <= WIRES_ABI
#
# This file carries no version of its own: install-wires.sh records the kit's
# at ~/wires/lib/VERSION.
#
# shellcheck disable=SC2034  # read from outside; nothing here consumes them
WIRES_ABI=1
# Policy: stays 1. Stranding an application is a breaking release, taken
# deliberately or not at all. If this line ever moves, install-wires.sh lists
# the installed applications that would stop launching.
# shellcheck disable=SC2034
WIRES_ABI_OLDEST=1

# --- de-Ableton inventory: see README.md. New mentions are regressions. ---

# ========================= TEMPORARY: RENAME COMPAT ==========================
# DELETE this whole fenced block, fences included, in the first release after
# one has shipped with the WIRES_* names.
#
# The two override names the released world documents: ABLETON_WINE_ROOT and
# ABLETON_WINEPREFIX shipped, are in users' profiles and in ableton-vm-tools,
# and are read for one release after the rename, with a single note. Only
# infrastructure renames belong here - ABLETON_DPI_MODE and the rest configure
# the application and keep their names.
wires_env_compat() {
    local _pair _old _new
    for _pair in \
        ABLETON_WINE_ROOT:WIRES_RUNTIME \
        ABLETON_WINEPREFIX:WIRES_PLUG
    do
        _old="${_pair%%:*}"; _new="${_pair##*:}"
        # The new name is preferred: both set means the caller has migrated and
        # left the old one in a shell profile.
        [ -n "${!_old:-}" ] && [ -z "${!_new:-}" ] || continue
        export "$_new=${!_old}"
        echo "   note: $_old is now $_new, and will stop being read after the next release" >&2
    done
}
wires_env_compat
# ======================= END TEMPORARY: RENAME COMPAT ========================

# The directory installs live under. A seam for the tests; nothing else sets it.
wires_home() {
    printf '%s\n' "${WIRES_HOME:-$HOME/wires}"
}

# The runtime's build name - the application's to declare, because the artifact
# is the application's. WIRES_RUNTIME_NAME is the seam; the default is the one
# application this repository ships, and is on the de-Ableton inventory below.
wires_runtime_name() {
    printf '%s\n' "${WIRES_RUNTIME_NAME:-wires}"
}


# A tree set aside rather than a build anyone can choose. Three names reach the
# store and only the first two were ever filtered: wires_store_absorb writes
# superseded-<stamp>/ and failed-<stamp>/ as prefixes, while a failed install
# leaves <id>.failed-<stamp> *beside* the entry it was replacing - a suffix, so
# a prefix match never saw it. It was offered as a selectable build, with an
# empty BUILT column and a name long enough to shove the table out of line.
wires_is_quarantine() {
    case "${1##*/}" in
        superseded-*|failed-*|*.failed-*|.replaced-*|*-rollback-*) return 0 ;;
    esac
    return 1
}

# The directory holding every installed runtime, one per build.
wires_runtime_store() {
    printf '%s\n' "$(wires_home)/runtimes"
}

# Where installs used to live. This is a fact about the past, not a path
# derived from where things live now: derive it from wires_home() and the
# migration looks inside ~/wires, finds nothing, and silently orphans every
# existing install instead of moving it. It stays frozen when the store moves.
wires_legacy_root() {
    # Spelled out, never derived from wires_runtime_name: that name grew a seam
    # (WIRES_RUNTIME_NAME), and a renamed artifact deriving this path would
    # un-find every existing install.
    printf '%s\n' "$HOME/.local/opt/wine-d2d1-nspa-11.13"
}

# Where the followed channel is recorded. One function, because a reader and a
# writer that spell this differently disagree silently until an update goes to
# the wrong channel.
wires_channel_file() {
    printf '%s\n' "${WIRES_CHANNEL_FILE:-$(wires_runtime_store)/.channel}"
}

# Which channel this machine follows. One word, validated against an allowlist
# rather than trusted: it selects a symlink name and, for the updater, part of a
# URL - and configuration the build does not control must not shape a request.
# That is the same constraint that ended the source-repo experiment.
wires_channel() {
    local _f _c
    _f="$(wires_channel_file)"
    _c="${WIRES_CHANNEL:-}"
    [ -n "$_c" ] || { [ -r "$_f" ] && _c="$(head -1 "$_f" 2>/dev/null | tr -d '[:space:]')"; }
    case "$_c" in
        stable|nightly) printf '%s\n' "$_c" ;;
        "")             printf 'stable\n' ;;
        *)              echo "!! unknown channel '$_c' in $_f; using stable" >&2
                        printf 'stable\n' ;;
    esac
}

# The installed runtime. WIRES_RUNTIME overrides it and stays the outermost say:
# the tests, the regression VMs and bisecting a build all rely on that.
#
# Returns what the channel points at, never the channel path. /proc/PID/exe
# reports symlinks already resolved, so a process launched through
# <container>/stable/bin/wine appears under the build's own name - compare
# against the channel and wires_runtime_pids matches nothing.
#
# A caller that resolved once keeps the build it resolved: a channel switch
# mid-session cannot move the runtime under a running process.
wires_runtime_path() {
    local _chan _target
    if [ -n "${WIRES_RUNTIME:-}" ]; then
        printf '%s\n' "$WIRES_RUNTIME"
        return
    fi
    _chan="$(wires_runtime_store)/$(wires_channel)"
    if [ -e "$_chan" ]; then
        _target="$(readlink -f "$_chan" 2>/dev/null || true)"
        if [ -n "$_target" ]; then
            printf '%s\n' "$_target"
            return
        fi
    fi
    # No container yet: an install that predates the migration still has to
    # resolve and launch.
    wires_legacy_root
}

# Where Plugs live. There is no registry: the directory is the list, so a Plug
# exists because its prefix does and stops existing when it is removed.
wires_plugs_dir() {
    printf '%s\n' "$(wires_home)/plugs"
}

# The Ableton prefix. Separate from the runtime on purpose: a channel switch
# would change both, but a test or a clone changes only this one.
#
# Selection is WIRES_PLUG, then the `default` symlink, then studio. The symlink
# is the one thing `wires plug use` writes; studio is the name the migration
# uses, so an install that predates Plugs still resolves without one.
wires_plug_path() {
    local _d _t
    if [ -n "${WIRES_PLUG:-}" ]; then printf '%s\n' "$WIRES_PLUG"; return; fi
    _d="$(wires_plugs_dir)"
    if [ -L "$_d/default" ]; then
        _t="$(readlink -f "$_d/default" 2>/dev/null || true)"
        # A dangling default is a Plug someone removed by hand. Falling back is
        # better than resolving to nothing, and `plug list` names the danglers.
        [ -n "$_t" ] && { printf '%s\n' "$_t"; return; }
    fi
    printf '%s\n' "$_d/studio"
}

# Which architecture a prefix declares, from whichever registry file says so.
# All three carry the marker and they do not always agree: a prefix has been
# seen with an empty system.reg and #arch=win32 in user.reg and userdef.reg,
# which reading system.reg alone reports as "no marker" and so as unfinished.
# It was not unfinished; it was 32-bit, and Wine refused it accordingly.
wires_prefix_arch() {
    local _p="${1%/}" _f _a
    for _f in system.reg user.reg userdef.reg; do
        _a="$(grep -m1 '^#arch=' "$_p/$_f" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
        [ -n "$_a" ] && { printf '%s\n' "$_a"; return 0; }
    done
    return 1
}

# A prefix Wine will open for a 64-bit application. Anything else - a declared
# win32 prefix, or one so incomplete that nothing declares an architecture at
# all - is not one, and the two are not the same problem.
wires_is_prefix() {
    [ "$(wires_prefix_arch "${1%/}" 2>/dev/null)" = win64 ]
}

# Never finished: no registry file declares an architecture, and nothing of
# anyone's is in it. The test is regular files, not directory names - wineboot's
# skeleton is directories only, so one file anywhere under drive_c means someone
# put it there. An earlier version keyed on the top-level names and would have
# deleted a set sitting in drive_c/users.
wires_is_stub_prefix() {
    local _p="${1%/}"
    [ -d "$_p" ] || return 1
    wires_prefix_arch "$_p" >/dev/null 2>&1 && return 1
    [ -e "$_p/system.reg" ] || return 1
    [ -z "$(find "$_p/drive_c" -type f -print -quit 2>/dev/null)" ]
}

# The pre-container prefix path, named once rather than spelled out at each use.
wires_legacy_plug() {
    printf '%s\n' "$HOME/.wine-ableton"
}

# The prefix as it stands *right now*, for anything acting on it before
# wires_migrate_plug has moved it. wires_plug_path names where the prefix will
# live; on an unmigrated machine that directory does not exist yet and the real
# one is still at the legacy path. Handing the wrong path to `wineserver -k` is
# a no-op that reports success, which is how a running Live is left running
# and then SIGKILLed - the registry corruption the migration exists to
# avoid.
wires_plug_path_live() {
    local _p
    _p="$(wires_plug_path)"
    if [ ! -d "$_p" ] && [ -d "$(wires_legacy_plug)" ]; then
        wires_legacy_plug
        return
    fi
    printf '%s\n' "$_p"
}

# Anything running at all, from either scan. wires_runtime_busy answers only for
# the runtime scan, which is strictly narrower than the guard wires_migrate_plug
# applies - so a stop gated on it finishes "successfully" while leaving exactly
# the process that then refuses the migration, and no number of reruns clears it.
wires_anything_busy() {
    [ -n "$(wires_all_pids 2>/dev/null | sort -un | head -1)" ]
}

# What a Plug is bound to. A symlink into the store at either a channel or a
# build: pointing it at the channel is how a Plug follows `wires runtime use`,
# pointing it at a build is how one stays where it is. Resolving either is the
# same readlink, which is also what retention walks.
wires_plug_binding() {
    local _p="${1:-}"
    [ -n "$_p" ] || _p="$(wires_plug_path)"
    printf '%s\n' "${_p%/}/.wires-runtime"
}

# The build a Plug resolves to, or nothing if it is unbound. Unbound is the
# normal state for every Plug that predates this, and means "follow the channel".
wires_plug_runtime() {
    local _b _t
    _b="$(wires_plug_binding "${1:-}")"
    [ -L "$_b" ] || return 1
    _t="$(readlink -f "$_b" 2>/dev/null || true)"
    [ -n "$_t" ] && [ -d "$_t" ] || return 1
    printf '%s\n' "$_t"
}

# --- which Wine base a Plug was bootstrapped against -------------------------
#
# Wine imposes one coupling between a runtime and a Plug, and it is asymmetric:
# it compares the prefix's .update-timestamp against the runtime's
# share/wine/wine.inf and runs `wineboot --update` when they differ. Forward it
# does; back it does not support.
#
# Reading those two is the same comparison Wine makes, so the granularity is
# right by construction: two builds whose wine.inf did not change compare equal,
# and Wine considers such a prefix current.
wires_plug_base() {
    local _p="${1:-}"; [ -n "$_p" ] || _p="$(wires_plug_path)"
    _p="${_p%/}"
    [ -r "$_p/.update-timestamp" ] || return 1
    # One line, an epoch second. Anything else means a prefix we cannot reason
    # about, and reasoning about it anyway is how a Plug gets taken backward.
    local _v
    _v="$(head -1 "$_p/.update-timestamp" 2>/dev/null | tr -d '[:space:]')"
    case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$_v"
}

wires_runtime_base() {
    local _r="${1:-}"; [ -n "$_r" ] || _r="$(wires_runtime_path)"
    _r="${_r%/}"
    # tar restores mtimes, so this is the same number on every machine that
    # unpacked the same tarball - which is what makes it an identity rather than
    # a local artefact.
    local _v
    _v="$(stat -c %Y "$_r/share/wine/wine.inf" 2>/dev/null)" || return 1
    case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$_v"
}

# Which Plugs a retarget of the channel actually moves. A Plug pinned to a build
# is not one of them - that is what pinning is for - and asking about it would
# warn people away from a switch that cannot reach them. Unbound follows the
# channel, because that is what unbound means.
#
# Here rather than in wires-runtime because install.sh needs the same set: the
# guard holds at every door, and two copies of this predicate is how the doors
# drift apart.
wires_plugs_following() {
    local _chan="${1:-}" _n _b
    [ -n "$_chan" ] || _chan="$(wires_channel)"
    while read -r _n; do
        [ -n "$_n" ] || continue
        _b="$(readlink "$(wires_plugs_dir)/$_n/.wires-runtime" 2>/dev/null || true)"
        [ -z "$_b" ] || [ "${_b##*/}" = "$_chan" ] || continue
        printf '%s\n' "$_n"
    done < <(wires_plug_names)
}

# The runtime that bootstrapped a Plug, recovered rather than recorded: the
# Plug's stamp is the mtime of the wine.inf that booted it, so the booter is
# whichever installed tree still carries that exact mtime. Walks the store and
# the legacy root; a booter that has been pruned or set aside is simply not
# found, and the caller falls back to strict.
wires_plug_base_runtime() {
    local _p="${1:-}" _pb _e _rb
    _pb="$(wires_plug_base "$_p")" || return 1
    for _e in "$(wires_runtime_store)"/* "$(wires_legacy_root)"; do
        [ -d "$_e" ] && [ ! -L "$_e" ] || continue
        wires_is_quarantine "$_e" && continue
        _rb="$(wires_runtime_base "$_e" 2>/dev/null)" || continue
        # Numeric, as in wires_base_move: these are mtimes, and comparing the
        # same value as text in one function and as a number in the other is
        # how the two drift apart.
        [ "$_rb" -eq "$_pb" ] || continue
        printf '%s\n' "$_e"
        return 0
    done
    return 1
}

# Where running <runtime> against <plug> would take the prefix: one word of
# fresh|same|refresh|rollback|forward|backward, rendered by the caller. See
# README.md for what each means and why severity cannot come from the stamp.
#
# The stamp gives direction; severity comes from comparing the candidate's
# wine: label against that of the runtime which booted the Plug. Unreadable
# either side stays forward/backward - an unanswerable question is a refusal.
#
# Returns 1 without printing when the candidate or the Plug cannot be read.
wires_base_move() {
    local _r="${1:-}" _p="${2:-}" _rb _pb _dir _boot _bl _cl
    [ -n "$_p" ] || _p="$(wires_plug_path)"
    _p="${_p%/}"
    _rb="$(wires_runtime_base "$_r")" || return 1
    if ! _pb="$(wires_plug_base "$_p")"; then
        # No stamp: fresh or tampered, told apart by -s, not -e. wineboot
        # writes registry content in its first moments, so an empty system.reg
        # means it never started, so fresh is correct; content
        # without a stamp stays a refusal. -e read the migration harness's
        # `: > system.reg` fixture as unanswerable and aborted a legacy
        # machine's first install.
        [ -s "$_p/system.reg" ] && return 1
        printf 'fresh\n'; return 0
    fi
    if [ "$_rb" -eq "$_pb" ]; then printf 'same\n'; return 0; fi
    [ "$_rb" -gt "$_pb" ] && _dir=forward || _dir=backward
    if _boot="$(wires_plug_base_runtime "$_p")"; then
        _bl="$(wires_buildinfo_field "$_boot/ABLETON-WINE-BUILD-INFO.txt" wine)"
        _cl="$(wires_buildinfo_field "${_r%/}/ABLETON-WINE-BUILD-INFO.txt" wine)"
        if [ -n "$_bl" ] && [ "$_bl" = "$_cl" ]; then
            [ "$_dir" = forward ] && printf 'refresh\n' || printf 'rollback\n'
            return 0
        fi
    fi
    printf '%s\n' "$_dir"
}

# Every Plug, by name. Two markers, because a Plug exists before Wine has ever
# run in it: system.reg is Wine's own "this is a prefix", and .wires-runtime is
# ours for one created but not yet booted. Requiring either keeps a stray
# directory under plugs/ from being offered as a Plug.
wires_plug_names() {
    local _d _p
    _d="$(wires_plugs_dir)"
    [ -d "$_d" ] || return 0
    for _p in "$_d"/*/; do
        _p="${_p%/}"
        [ -d "$_p" ] && [ ! -L "$_p" ] || continue     # skips the default link
        [ -e "$_p/system.reg" ] || [ -L "$_p/.wires-runtime" ] || continue
        printf '%s\n' "${_p##*/}"
    done
}

# Every application installed on this machine. The directory is the list: an
# application exists because its payload directory does. No registry, for the
# same reason Plugs have none - a list beside the filesystem is a list that can
# disagree with it.
wires_app_names() {
    local _d _a
    _d="$(wires_home)/apps"
    [ -d "$_d" ] || return 0
    for _a in "$_d"/*/; do
        _a="${_a%/}"
        [ -d "$_a" ] && [ ! -L "$_a" ] || continue
        printf '%s\n' "${_a##*/}"
    done
}

# A WIRES_ABI* declaration read out of a file without sourcing it. The reader
# usually holds one generation of this library in scope already and is asking
# about another; sourcing the other would execute the file under evaluation.
#
# The whole value must be digits, and one that is not is refused rather than
# reduced to the digits inside it. Stripping reads 1.0 as ten and "1 # note 2"
# as twelve, and a generation ten from a library that means one freezes the
# gate: every real kit then looks older than what is installed.
wires_abi_field() {
    local _v
    _v="$(sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1)"
    _v="${_v%"${_v##*[![:space:]]}"}"          # trailing space only; the rest must be digits
    case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$_v"
}

# The applications an infrastructure with this OLDEST would strand: everyone
# whose declared floor is below it. The launcher is the file asked - it is named
# after its directory, which is the convention install.sh creates - and an
# application that declares nothing is treated as MIN=1, the first generation,
# because that is when it must have been written. So while OLDEST stays 1
# nothing can ever appear here, which is the point: raising OLDEST is the only
# act that can stop an installed application launching, and this lists which
# ones before it happens rather than after.
wires_apps_below_min() {
    local _oldest="$1" _a _l _m
    while read -r _a; do
        [ -n "$_a" ] || continue
        _l="$(wires_home)/apps/$_a/$_a"
        _m="$(wires_abi_field "$_l" WIRES_ABI_MIN 2>/dev/null)" || _m=1
        [ "$_m" -lt "$_oldest" ] && printf '%s\n' "$_a"
    done < <(wires_app_names)
    return 0
}

# What is installed in a Plug. Windows holds two disjoint answers and the census
# is their union: HKLM\Software\RegisteredApplications is the Default Programs
# index, written by installers that register; the Uninstall keys are the
# Add/Remove index, written by nearly every installer and the only trace of one
# that never registers. An application can appear in either alone.
#
# Two subtractions: entries marked SystemComponent=1, the Windows convention for
# hidden support packages, and the platform runtime components below, which
# carry no such marker. Those are the runtime's own payloads, not tenants.
wires_plug_tenants() {
    local _p _f
    _p="${1:-}"; [ -n "$_p" ] || _p="$(wires_plug_path)"
    _p="${_p%/}"
    {
        for _f in system.reg user.reg; do
            [ -r "$_p/$_f" ] || continue
            awk '
                {
                    if ($0 ~ /^\[/) {
                        if (dn != "" && sc == 0) print dn
                        dn = ""; sc = 0
                        ra = ($0 ~ /^\[Software\\\\RegisteredApplications\]/)
                        un = ($0 ~ /CurrentVersion\\\\Uninstall\\\\/)
                        next
                    }
                    if (ra && $0 ~ /^"[^"]*"="/) {
                        nm = $0; sub(/^"/, "", nm); sub(/"=".*$/, "", nm)
                        if (nm != "") print nm
                    }
                    if (un && $0 ~ /^"DisplayName"="/) {
                        dn = $0; sub(/^"DisplayName"="/, "", dn); sub(/"$/, "", dn)
                    }
                    if (un && $0 ~ /^"SystemComponent"=dword:00000001/) sc = 1
                }
                END { if (dn != "" && sc == 0) print dn }
            ' "$_p/$_f" 2>/dev/null
        done
    } | grep -vE '^(Wine Mono|Microsoft Visual C\+\+|Microsoft Edge WebView2|Microsoft \.NET)'       | sort -u
}

# Bind this shell to the runtime: drop inherited Wine settings that would reach
# the wrong build, then export what wine and its helpers read.
#
# The unset list is deliberately the four the launchers have always cleared.
# setup-prefix.sh additionally clears WINEESYNC and WINEFSYNC and keeps doing so
# at its own call site: folding them in here would silently start dropping a
# user's WINEESYNC on every launch, which is a behaviour change wearing a
# refactor's clothes.
wires_bind_runtime() {
    unset WINELOADER WINEDLLPATH WINEDLLOVERRIDES WINEARCH
    WINEPREFIX="$(wires_plug_path)"
    # A Plug's own binding wins over the channel: that is what lets two Plugs on
    # one machine run different builds. WIRES_RUNTIME still wins over both, as
    # the outermost say the VMs and anyone bisecting depend on. Deliberately
    # only here and not in wires_runtime_path - install.sh resolves the runtime
    # it is installing *into* through that, and a Plug's binding must not move
    # it.
    if [ -n "${WIRES_RUNTIME:-}" ]; then
        WINE_ROOT="$WIRES_RUNTIME"
    else
        WINE_ROOT="$(wires_plug_runtime "$WINEPREFIX" 2>/dev/null || wires_runtime_path)"
    fi
    WINESERVER="$WINE_ROOT/bin/wineserver"
    PATH="$WINE_ROOT/bin:$PATH"
    export WINEPREFIX WINESERVER PATH
}

# Is this a runtime tarball an install will select? The name is the whole test.
#
# The glob cannot be the selector: the build also emits
# <name>-<version>-debug.tar.zst, which `sort -V` orders after the runtime, so a
# glob piped to `tail -1` picks the debug tree - bin/ and lib/ but no share/,
# passes `wine --version`, then fails at launch with "could not exec the wine
# loader".
#
# A `+<label>` suffix is part of the release form: the nightly channel publishes
# <name>-<version>+nightly.<sha>.tar.zst. `-debug` stays refused - a different
# tree, not a label.
wires_is_runtime_tarball() {
    local _b="${1##*/}" _nm _re
    _nm="$(wires_runtime_name)"
    _re="^${_nm//./\\.}-[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}\\.[0-9]+(\\+[A-Za-z0-9][A-Za-z0-9.]*)?\\.tar\\.zst\$"
    [[ "$_b" =~ $_re ]]
}

# The newest runtime tarball in <dir>, or nothing.
#
# Locals are underscore-prefixed: this is sourced into scripts with their own
# $found and $target.
#
# Labelled builds are held separately and used only when there is no plain
# release, because `sort -V` orders `2026.08.04.1+nightly.bf76bb2` *after*
# `2026.08.04.1` — so a directory holding a release and a nightly would hand
# back the nightly, which is the same way round the `-debug` defect went. A
# labelled build is opt-in, and WIRES_RUNTIME_TARBALL is how you opt in.
wires_pick_tarball() {
    local _dir="$1" _nm _f
    _nm="$(wires_runtime_name)"
    local -a _found=() _labelled=()
    for _f in "$_dir"/"$_nm"-*.tar.zst; do
        [ -e "$_f" ] || continue          # no match: the glob came back literal
        wires_is_runtime_tarball "$_f" || continue
        case "${_f##*/}" in
            *+*) _labelled+=("$_f") ;;
            *)   _found+=("$_f") ;;
        esac
    done
    [ "${#_found[@]}" -gt 0 ] || _found=("${_labelled[@]}")
    [ "${#_found[@]}" -gt 0 ] || return 0
    printf '%s\n' "${_found[@]}" | sort -V | tail -1
}

# --- asking, and saying where things are -------------------------------------

# Consent. /dev/tty is the terminal test: a redirected stdin is not the caller,
# and stdin may be what is being read.
#
#   wires_ask_tty <prompt> [default]     default n unless given as y
#
#   0  yes     1  no     2  no terminal to ask on
#
# 1 and 2 are separate because the caller says different things: one person
# declined, the other was never asked and needs the flag that answers ahead of
# time. The default answers the silences - bare Enter, timeout, EOF. Callers
# that would discard work pass no; the base-change prompt passes yes.
wires_ask_tty() {
    local _prompt="$1" _default="${2:-n}" _ans=""
    { : >/dev/tty; } 2>/dev/null || return 2
    printf '%s' "$_prompt" > /dev/tty
    read -r -t 60 _ans < /dev/tty || { printf '\n' > /dev/tty 2>/dev/null || true; _ans=""; }
    [ -n "$_ans" ] || _ans="$_default"
    case "$_ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# The user's login shell, or nothing when it cannot be established.
#
# $SHELL first. It is set at login and is not changed by running a subshell, so
# it names the shell whose startup files this user actually loads - which is the
# question, since that is the file a PATH entry would go in. The passwd entry is
# the fallback for a context that never went through login (a service, cron,
# sudo without -i), where $SHELL is unset or inherited from somewhere else.
wires_login_shell() {
    local _s="${SHELL:-}"
    [ -x "$_s" ] || _s="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"
    [ -x "$_s" ] || return 1
    printf '%s\n' "$_s"
}

# The file this user's *interactive* shells read, or nothing when the shell is
# one we should not be guessing about.
#
# ~/.bashrc, not ~/.profile: the login file is read once by the session, so an
# entry there does not appear until the user logs out. Login shells are covered
# anyway - Debian's ~/.profile and Fedora's and Arch's ~/.bash_profile all
# source ~/.bashrc.
#
# Not reached: non-interactive shells (`ssh host wires ...`, cron, systemd),
# where the distro rc files return early. Automation uses an absolute path.
wires_path_rc() {
    local _sh
    _sh="$(wires_login_shell)" || return 1
    case "${_sh##*/}" in
        fish)    printf '%s\n' "$HOME/.config/fish/conf.d/wires.fish" ;;
        zsh)     printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
        bash)    printf '%s\n' "$HOME/.bashrc" ;;
        *)       return 1 ;;
    esac
}

# The block wires_path_register writes, fenced so it can be found again and
# removed exactly. Nothing else in this project edits a user's shell files, and
# an unfenced append cannot be undone without guessing.
WIRES_PATH_MARK_OPEN='# >>> wires >>>'
WIRES_PATH_MARK_CLOSE='# <<< wires <<<'

wires_path_block() {
    local _sh _kind
    _sh="$(wires_login_shell)" || _sh="sh"
    _kind="${_sh##*/}"
    printf '%s\n' "$WIRES_PATH_MARK_OPEN"
    printf '%s\n' "# Added by the Wires installer. Delete this block to undo it."
    if [ "$_kind" = fish ]; then
        printf '%s\n' 'fish_add_path -g $HOME/.local/bin'
    else
        printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
        printf '%s\n' 'export PATH'
    fi
    printf '%s\n' "$WIRES_PATH_MARK_CLOSE"
}

# Put ~/.local/bin on the PATH of this user's future shells. Takes the command
# names to use in the message.
#
# Unconditional and idempotent: the block goes in unless it is already there.
# The interactive rc, not ~/.profile - that is read once by the session, so a
# PATH entry written there does not appear until the user logs out.
#
# It cannot change the calling shell: a child process cannot change its
# parent's environment, so the message says to start a new one.
wires_path_register() {
    local _bin="$HOME/.local/bin" _names="${*:-wires}" _rc _now=1
    case ":${PATH:-}:" in *":$_bin:"*) _now=0 ;; esac

    _rc="$(wires_path_rc)" || {
        echo "!! $_names is in $(wires_abbrev_home "$_bin"), and your login shell is not one"
        echo "   this installer will edit. Add the equivalent of this to the file"
        echo "   your interactive shells read:"
        echo "     PATH=\"\$HOME/.local/bin:\$PATH\""
        return 0; }

    if [ -f "$_rc" ] && grep -qF "$WIRES_PATH_MARK_OPEN" "$_rc" 2>/dev/null; then
        # Already registered. Silent unless this shell is the one left out.
        if [ "$_now" = 1 ]; then
            echo "   $(wires_abbrev_home "$_rc") already puts $(wires_abbrev_home "$_bin") on PATH."
            echo "   This shell started before that; open a new terminal, or run:"
            echo "     . $(wires_abbrev_home "$_rc")"
        fi
        return 0
    fi

    mkdir -p "$(dirname "$_rc")"
    { if [ -s "$_rc" ]; then printf '\n'; fi; wires_path_block; } >> "$_rc"
    echo "   put $(wires_abbrev_home "$_bin") on PATH via $(wires_abbrev_home "$_rc")"
    if [ "$_now" = 1 ]; then
        echo "   For this shell, open a new terminal or run:  . $(wires_abbrev_home "$_rc")"
    fi
    return 0
}

# Take the block back out, exactly. Deletes between the fences inclusive and
# leaves everything else in the file alone, including a second copy if some
# earlier version of this ever wrote one.
#
# Silent when there is nothing to remove: uninstall runs on machines that were
# installed before this existed.
wires_path_unregister() {
    local _rc _tmp
    _rc="${1:-}"; [ -n "$_rc" ] || _rc="$(wires_path_rc)" || return 0
    [ -f "$_rc" ] || return 0
    grep -qF "$WIRES_PATH_MARK_OPEN" "$_rc" 2>/dev/null || return 0
    _tmp="$_rc.wires-tmp.$$"
    # sed over awk: the range form is exactly "these two lines and what is
    # between them", which is what the fence means.
    sed "/^${WIRES_PATH_MARK_OPEN}\$/,/^${WIRES_PATH_MARK_CLOSE}\$/d" "$_rc" > "$_tmp" \
        && cat "$_tmp" > "$_rc"
    rm -f "$_tmp"
    echo "removed the PATH block from $(wires_abbrev_home "$_rc")"
}

# A path as a person would write it. Everything these commands list is under
# $HOME, and the width is better spent on the part that differs.
wires_abbrev_home() {
    case "$1" in "$HOME"/*) printf '~%s\n' "${1#"$HOME"}" ;; *) printf '%s\n' "$1" ;; esac
}

# A numbered choice, read from a menu the caller has already printed. The menu
# itself is not shared - a build and a Plug have nothing in common to show -
# but the reading of the answer is, down to the 120-second timeout and what
# counts as cancelling.
#
# Prints the chosen number. Prints nothing and returns 0 when the answer was a
# cancellation, so the caller can tell "nobody chose" from "the choice was
# refused" without a second exit code:
#
#   n="$(wires_ask_choice "$prompt" "${#names[@]}")" || return 1
#   [ -n "$n" ] || { echo "cancelled"; return 0; }
wires_ask_choice() {
    local _prompt="$1" _count="$2" _ans=""
    printf '%s' "$_prompt" > /dev/tty
    read -r -t 120 _ans < /dev/tty || _ans=q
    case "$_ans" in
        q|Q|"")   return 0 ;;
        *[!0-9]*) echo "!! not a number: $_ans" >&2; return 1 ;;
    esac
    [ "$_ans" -ge 1 ] && [ "$_ans" -le "$_count" ] || {
        echo "!! out of range: $_ans" >&2; return 1; }
    printf '%s\n' "$_ans"
}

# The arguments every `rm` verb takes: one name, and -y for consent given in
# advance. Prints the name on line one, and `1` on line two when -y was given;
# either may be empty. Returns 2 on a usage error.
#
#   parsed="$(wires_rm_args "$@")" || return $?
#   { IFS= read -r want; IFS= read -r yes; } <<<"$parsed"
#
# Two lines rather than two tab-separated fields: a tab is IFS whitespace, so
# `IFS=$'\t' read -r a b` drops a leading empty field and shifts the rest left -
# an unnamed Plug arrived as a name of "1".
wires_rm_args() {
    local _name="" _yes=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes) _yes=1 ;;
            -*)       echo "!! unknown option: $1" >&2; return 2 ;;
            *)        [ -z "$_name" ] || {
                          echo "!! one name at a time: $1" >&2; return 2; }
                      _name="$1" ;;
        esac
        shift
    done
    printf '%s\n%s\n' "$_name" "$_yes"
}

# --- what is running from the runtime ----------------------------------------

# The process table to read. Only the tests set this, pointing it at a fixture
# tree of fake exe symlinks; /proc cannot be stubbed through PATH the way pgrep
# can, so without a seam the accurate implementation is the untestable one.
wires_proc_root() {
    printf '%s\n' "${WIRES_PROC_ROOT:-/proc}"
}

# Every pid whose binary lives under the runtime. From PR #120, which found the
# reason a command line cannot answer this: Wine's in-prefix helpers show a
# Windows path in argv (C:\windows\system32\...), so no pattern reaches them,
# and a pattern also catches unrelated processes that merely mention the path.
# The exe link is the real binary — bin/wineserver, or the wine-preloader every
# in-prefix process runs from — so the match is exact and scoped to this
# runtime rather than any Wine on the machine.
wires_runtime_pids() {
    local proc root d
    root="$(wires_runtime_path)"
    proc="$(wires_proc_root)"
    for d in "$proc"/[0-9]*; do
        case "$(readlink "$d/exe" 2>/dev/null)" in
            "$root"/*) printf '%s\n' "${d##*/}" ;;
        esac
    done
}

# Anything at all using the runtime: the predicate to ask before replacing its
# files. The name match stays as a second opinion because failing open here
# means installing over a running runtime.
wires_runtime_busy() {
    [ -n "$(wires_runtime_pids)" ] || \
        pgrep -f '[A]bleton Live.*\.exe|[P]ush2DisplayProcess.exe' >/dev/null 2>&1
}

# Live itself, as opposed to the support processes around it. The install
# prompt is about unsaved work, and only Live has any.
ableton_live_pids() {
    local proc p cmd
    proc="$(wires_proc_root)"
    for p in $(wires_runtime_pids); do
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
wires_buildinfo_field() {
    local _file="$1" _key="$2" _v
    [ -r "$_file" ] || return 0
    _v="$(sed -n "s/^${_key}:[[:space:]]*//p" "$_file" | head -1)"
    printf '%s\n' "${_v%"${_v##*[![:space:]]}"}"   # strip any trailing space
}

# The identity of an installed runtime: <dist-version>+<discriminator>. Prints
# nothing when the tree cannot be named; a caller must treat that as a refusal,
# never as a default.
#
# The discriminator is source-commit where the file has one, and the first seven
# characters of patch-stack where it does not. Requiring source-commit would
# refuse every runtime installed today, since the commit that writes it is not
# released.
#
# dist-version alone collides: one version can cover several patch stacks, and
# one has covered two different Wine trees.
wires_runtime_id() {
    local _dir="$1" _info _ver _disc _kind
    _info="$_dir/ABLETON-WINE-BUILD-INFO.txt"
    [ -r "$_info" ] || return 0

    _ver="$(wires_buildinfo_field "$_info" dist-version)"
    [ -n "$_ver" ] || return 0

    _disc="$(wires_buildinfo_field "$_info" source-commit)"
    [ -n "$_disc" ] || _disc="$(wires_buildinfo_field "$_info" patch-stack)"
    [ -n "$_disc" ] || return 0
    # A nightly says so here rather than in dist-version. That field is the date
    # the build happened, for every build, which is the one question a directory
    # name has to answer -- putting the kind there too would mean either a second
    # date or a second separator, and the id is <version>+<discriminator> with
    # exactly one. So: 2026.08.06.1+nightly.badafaf.
    _kind="$(wires_buildinfo_field "$_info" build-kind)"
    wires_compose_id "$_ver" "$_disc" "$_kind"
}

# version, discriminator, kind -> the id, or nothing.
#
# Split out because two things compose one: a store entry, from a tree's own
# BUILD-INFO, and the updater's report of what a channel is offering, from a
# manifest. Those disagreeing would mean the updater naming a directory other
# than the one the install produces.
wires_compose_id() {
    local _ver="$1" _disc="${2:0:7}" _kind="${3:-}"
    [ -n "$_ver" ] && [ -n "$_disc" ] || return 0
    [ -z "$_kind" ] || _disc="$_kind.$_disc"
    # The id becomes a directory name, so it is validated rather than trusted: a
    # BUILD-INFO is plain text inside a tarball, and a manifest arrives over the
    # network. Nothing upstream of here constrains what either holds.
    case "$_ver$_disc" in
        *[!0-9A-Za-z._-]*|*..*) return 0 ;;
    esac
    printf '%s+%s\n' "$_ver" "$_disc"
}

# --- layout migration --------------------------------------------------------
# One-time move from the flat layout to the store: one directory per build,
# named from its own BUILD-INFO, with a channel symlink at the live one. Only
# install.sh calls this.

# Is <a> a later version stamp than <b>? Equal is not later.
#
# sort -V, because these are release stamps and not integers. A labelled build
# sorts after the plain release of the same date, which is what later means
# here; wires_pick_tarball orders the other way, choosing what to offer rather
# than what came last.
wires_version_newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# Is <a> a newer build than <b>? built-at where both carry it, dist-version
# otherwise. Runtimes built before built-at existed have only the version, which
# ties across every nightly between two releases — that is why the field was
# added, and why this returns 1 rather than guessing when neither can be read.
wires_build_is_newer() {
    local _a="$1" _b="$2" _av _bv
    _av="$(wires_buildinfo_field "$_a/ABLETON-WINE-BUILD-INFO.txt" built-at)"
    _bv="$(wires_buildinfo_field "$_b/ABLETON-WINE-BUILD-INFO.txt" built-at)"
    if [ -z "$_av" ] || [ -z "$_bv" ]; then
        _av="$(wires_buildinfo_field "$_a/ABLETON-WINE-BUILD-INFO.txt" dist-version)"
        _bv="$(wires_buildinfo_field "$_b/ABLETON-WINE-BUILD-INFO.txt" dist-version)"
    fi
    [ -n "$_av" ] && [ -n "$_bv" ] || return 1
    wires_version_newer "$_av" "$_bv"
}

# Move <dir> into the store under its own id. A tree that cannot be named, or
# whose name is already taken, is set aside under <container>/<kind>-<stamp>/
# rather than deleted — these are multi-gigabyte runtimes and nothing here
# removes one behind the user's back.
wires_store_absorb() {
    local _dir="$1" _stamp="$2" _container _id _aside
    _container="$(wires_runtime_store)"
    _id="$(wires_runtime_id "$_dir")"
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



# What is holding it, for a refusal that can be acted on rather than puzzled at.
# Every pid Wires is running, from either direction. The two scans genuinely
# differ: the runtime scan resolves /proc/PID/exe, so it cannot see a process
# whose runtime directory has since been removed, and the Plug scan reads
# WINEPREFIX out of the environment, so it finds exactly those orphans. Wine
# leaves services.exe, rpcss.exe and friends behind under names no `pkill
# wineserver` will ever match, and they hold the prefix until something asks.
wires_all_pids() {
    local _p _d
    wires_runtime_pids 2>/dev/null || true
    for _d in "$(wires_home)"/plugs/*/ "$(wires_legacy_plug)"; do
        [ -d "$_d" ] || continue
        wires_plug_holders "${_d%/}" 2>/dev/null | awk '{print $1}'
    done
}



# Is anything running out of this Plug? The runtime scan cannot answer it: a
# process can hold a prefix while running from another Wine entirely, and
# renaming a prefix out from under a live wineserver corrupts its registry.
# Wine puts WINEPREFIX in the environment of everything it starts, so the
# environment is where the answer is.
wires_plug_busy() {
    local _plug _p
    _plug="${1:-$(wires_plug_path)}"
    _plug="${_plug%/}"
    for _p in "$(wires_proc_root)"/[0-9]*; do
        # Unlike cmdline, environ is mode 400 *and* gated by ptrace_may_access,
        # so `[ -r ]` passes on our own processes where the read still fails -
        # systemd --user is one. The shell reports a failed redirection itself,
        # before tr runs, so tr's own 2>/dev/null cannot suppress it and the
        # group is what silences it. Same trap as ableton_live_pids, one file
        # further along.
        { tr '\0' '\n' < "$_p/environ" | grep -qxF "WINEPREFIX=$_plug"; } 2>/dev/null \
            && return 0
    done
    return 1
}

wires_plug_holders() {
    local _plug _p _cmd
    _plug="${1:-$(wires_plug_path)}"
    _plug="${_plug%/}"
    for _p in "$(wires_proc_root)"/[0-9]*; do
        { tr '\0' '\n' < "$_p/environ" | grep -qxF "WINEPREFIX=$_plug"; } 2>/dev/null || continue
        _cmd="$( { tr -s '\0' ' ' < "$_p/cmdline"; } 2>/dev/null )" || continue
        printf '%s  %s\n' "${_p##*/}" "${_cmd:0:70}"
    done
}

# Move a flat prefix into the Plug store. A prefix cannot be re-downloaded, so
# any branch here that is not certain refuses.
#
# A plain rename needs no repair: Wine resolves everything relative to
# $WINEPREFIX, which is supplied per launch. A used prefix holds no absolute
# host path in its registry, dosdevices/c: is relative, and the symlinks under
# drive_c/users point at the real home, which is not moving.
wires_migrate_plug() {
    local legacy dest
    legacy="$(wires_legacy_plug)"
    dest="$(wires_plug_path)"

    if [ -n "${WIRES_PLUG:-}" ]; then
        echo "   plug: WIRES_PLUG is set; leaving the prefix where it is"
        return 0
    fi
    [ "$legacy" != "$dest" ] || return 0

    # A symlink at the legacy path is someone else's arrangement, not ours.
    if [ -L "$legacy" ]; then
        echo "!! $legacy is a symlink, not a prefix; remove it and rerun" >&2
        return 1
    fi
    [ -d "$legacy" ] || return 0        # nothing to move

    # Before anything moves. install.sh stops what runs from the runtime, which
    # is not the same set: this catches a Live started from another build, or a
    # bare wine pointed at the prefix.
    if wires_plug_busy "$legacy"; then
        echo "!! something is still running from $legacy, so moving it now would" \
             "corrupt its registry. Close it, or run \`wires stop\`, then rerun:" >&2
        wires_plug_holders "$legacy" | sed 's/^/     /' >&2
        return 1
    fi

    # A prefix already at the destination means this machine is on the new
    # layout: wires_plug_path resolves there, the launcher opens it, and what is
    # still sitting at the legacy path is not being used by anything. There is
    # nothing to migrate, so say what is there and carry on - refusing would
    # abort an install over a directory nothing reads. This matches how the
    # runtime migration treats the same shape: an older installer writing to the
    # old path is a normal action on a machine holding an older installer, not
    # corruption.
    if wires_is_prefix "$dest"; then
        echo "   plug: already at $dest; $legacy is left over from before the" \
             "move and is not in use - remove it when you like"
        return 0
    fi

    # There is something at the destination that is not a prefix. An empty
    # directory is mkdir debris and can go; anything else is genuinely ambiguous
    # and is not ours to delete.
    if [ -e "$dest" ]; then
        if [ -d "$dest" ] && [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
            rmdir "$dest" 2>/dev/null || true
        elif wires_is_stub_prefix "$dest"; then
            # Set aside, never removed. The store does the same with a runtime
            # it cannot use, and a prefix is worth more than a runtime: one can
            # be downloaded again and the other cannot.
            echo "   plug: an unfinished prefix is at $dest; setting it aside as" \
                 "$dest.unfinished-$(date -u +%Y%m%dT%H%M%SZ) so the one at $legacy can move there"
            mv "$dest" "$dest.unfinished-$(date -u +%Y%m%dT%H%M%SZ)"
        else
            echo "!! $dest already exists and is not a prefix, so the one at" \
                 "$legacy cannot move there; move or remove it, then rerun" >&2
            return 1
        fi
    fi

    mkdir -p "$(dirname "$dest")"

    # Within one filesystem this is a rename: atomic, instant, and no free space
    # required whatever the prefix weighs. Across filesystems mv copies and then
    # deletes, so a 16G prefix needs 16G free and minutes of I/O - and a failure
    # halfway leaves a partial copy that would read as "a prefix at both paths"
    # on the next run. Check first, and clean up after ourselves if it fails.
    if [ "$(stat -c %d "$legacy" 2>/dev/null)" != "$(stat -c %d "$(dirname "$dest")" 2>/dev/null)" ]; then
        local _need _free
        _need="$(du -sk "$legacy" 2>/dev/null | cut -f1)"
        _free="$(df -Pk "$(dirname "$dest")" 2>/dev/null | awk 'NR==2 {print $4}')"
        if [ -n "$_need" ] && [ -n "$_free" ] && [ "$_free" -le "$_need" ]; then
            echo "!! $dest is on another filesystem and moving the prefix there needs" \
                 "$((_need / 1024)) MB, with $((_free / 1024)) MB free" >&2
            return 1
        fi
        echo "   plug: $dest is on another filesystem, so this is a copy, not a rename"
    fi

    if ! mv "$legacy" "$dest"; then
        # Only ever the destination: the source is what we failed to move.
        [ -e "$dest" ] && [ -e "$legacy" ] && rm -rf "$dest"
        echo "!! moving the prefix to $dest failed; it is still at $legacy" >&2
        return 1
    fi
    echo "   plug: moved the prefix to $dest"
}

# Migrate a flat runtime into the store. Idempotent; refuses rather than
# guessing when the live tree cannot be identified.
#
# Nothing is left at the legacy path: an older .run does not read it, it
# overwrites it.
#
# The caller must already know nothing is running from the runtime - this
# renames the directory a running Wine executes from.
wires_migrate_layout() {
    local legacy container chan stamp id other d absorbed
    legacy="$(wires_legacy_root)"
    container="$(wires_runtime_store)"
    chan="$container/$(wires_channel)"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"

    if [ -n "${WIRES_RUNTIME:-}" ]; then
        echo "   layout: WIRES_RUNTIME is set; leaving the install where it is"
        return 0
    fi

    # Already migrated. A real tree at the legacy path beside it is not
    # corruption: an older .run does not read the store and writes one
    # there. That is a normal action on a machine holding an older installer, so
    # recover rather than refuse — identify both and keep the newer live.
    if [ -L "$chan" ]; then
        if [ -d "$legacy" ] && [ ! -L "$legacy" ]; then
            other="$(readlink -f "$chan" 2>/dev/null || true)"
            if [ -z "$(wires_runtime_id "$legacy")" ] && \
               { [ -z "$other" ] || [ -z "$(wires_runtime_id "$other")" ]; }; then
                echo "!! neither $legacy nor $chan can be identified from its" \
                     "BUILD-INFO; remove whichever is stale and rerun" >&2
                return 1
            fi
            id="$(wires_store_absorb "$legacy" "$stamp")"
            if [ -n "$id" ] && [ -n "$other" ] && wires_build_is_newer "$container/$id" "$other"; then
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

    id="$(wires_runtime_id "$legacy")"
    [ -n "$id" ] || {
        echo "!! $legacy carries no readable ABLETON-WINE-BUILD-INFO.txt, so it" \
             "cannot be named; installing over it would be a guess" >&2
        return 1; }

    mkdir -p "$container"
    # Never a bare mv. When an entry of this id is already in the store - which
    # happens whenever the channel symlink is genuinely absent rather than
    # dangling - mv moves the legacy tree *inside* it, where retention and the
    # container-scoped uninstall both stop seeing it while the channel quietly
    # points at the incumbent. wires_store_absorb is the guard the already-
    # migrated branch above and install.sh both already use.
    absorbed="$(wires_store_absorb "$legacy" "$stamp")"
    ln -sfn "$id" "$chan"

    # The dated rollbacks move too, and become readable in the process: each
    # carries its own BUILD-INFO, so a timestamp that recorded when a runtime
    # was replaced becomes a name that says which build it holds. Left behind
    # they are invisible to the container-scoped uninstall and orphan several
    # gigabytes apiece.
    for d in "$legacy"-rollback-* "$legacy".failed-*; do
        [ -e "$d" ] || continue
        wires_store_absorb "$d" "$stamp" >/dev/null
    done
    if [ -n "$absorbed" ]; then
        echo "   layout: moved the runtime to $container/$id"
    else
        echo "   layout: the store already held an entry named $id, so the tree at" \
             "$legacy was set aside under superseded-$stamp; the channel points at" \
             "the entry that was already there"
    fi
}

# --- retention ---------------------------------------------------------------

# Keep this many entries per channel. A count rather than a policy: a channel
# that turns over nightly needs a smaller one than a channel that turns over
# monthly, and an unpacked runtime is ~392M against a 40-minute rebuild.
wires_runtime_keep() {
    local _n="${WIRES_RUNTIME_KEEP:-10}"
    case "$_n" in ''|*[!0-9]*) _n=10 ;; esac      # nonsense reverts to the default
    [ "$_n" -ge 1 ] || _n=1                       # never prune to nothing
    printf '%s\n' "$_n"
}

# Drop the oldest entries past the limit. Called after a successful install,
# never before, so a failure cannot leave a user with neither the new runtime
# nor the old one.
#
# Ordering is by built-at, not by the version in the name. Names tie: every
# nightly between two releases carries the same dist-version, so sorting on the
# name falls through to comparing hashes - deterministic, and unrelated to age.
# Entries predating built-at sort oldest as a group, which they are.
#
# What the channel points at is never removed, whatever the count says. A
# channel pointing at a pruned entry is a broken install produced by
# housekeeping.
wires_prune_runtimes() {
    local _container _keep _live _e _id _at _ver _key
    _container="$(wires_runtime_store)"
    [ -d "$_container" ] || return 0
    _keep="$(wires_runtime_keep)"
    # Every channel's target, not just this machine's. A second channel pointing
    # at an entry pruned on behalf of the first is a broken install produced by
    # housekeeping - the rule has to hold for all of them.
    local -a _pinned=()
    for _e in "$_container"/*; do
        [ -L "$_e" ] || continue
        _live="$(readlink -f "$_e" 2>/dev/null || true)"
        [ -n "$_live" ] && _pinned+=("$_live")
    done
    # And, per Plug, two builds rather than one.
    #
    # The build it is bound to. A Plug held deliberately on an older build is
    # precisely what the count prunes first, and removing it breaks that Plug
    # rather than tidying anything. The binding is a symlink, so this is the
    # same readlink the channels above get.
    #
    # And the build that last booted it, which the base guard recovers to
    # a same-base refresh from a base change. That recovery is a search of this
    # store for the build whose wine.inf matches the prefix's stamp, so pruning
    # the answer turns the guard's severity question unanswerable and a routine
    # update reports itself as an irreversible base change. Nothing above pins
    # it: the case is a Plug that follows a channel - no binding at all - and
    # goes unlaunched while the channel moves on past the retention count.
    local _pl _plug
    while read -r _pl; do
        [ -n "$_pl" ] || continue
        _plug="$(wires_plugs_dir)/$_pl"
        _live="$(wires_plug_runtime "$_plug" 2>/dev/null || true)"
        [ -n "$_live" ] && _pinned+=("$_live")
        _live="$(wires_plug_base_runtime "$_plug" 2>/dev/null || true)"
        [ -n "$_live" ] && _pinned+=("$_live")
    done < <(wires_plug_names)

    local -a _victims=()
    while IFS=$'\t' read -r _key _e; do
        [ -n "$_e" ] || continue
        _victims+=("$_e")
    done < <(
        for _e in "$_container"/*; do
            [ -d "$_e" ] && [ ! -L "$_e" ] || continue
            _id="$(wires_runtime_id "$_e")"
            [ -n "$_id" ] || continue        # quarantine directories are not entries
            _at="$(wires_buildinfo_field "$_e/ABLETON-WINE-BUILD-INFO.txt" built-at)"
            _ver="$(wires_buildinfo_field "$_e/ABLETON-WINE-BUILD-INFO.txt" dist-version)"
            if [ -n "$_at" ]; then printf '1 %s\t%s\n' "$_at" "$_e"
            else                   printf '0 %s\t%s\n' "$_ver" "$_e"; fi
        done | sort -V | head -n -"$_keep"
    )

    # Compared through readlink on both sides: the channel pins arrive already
    # resolved and the victims do not, so a symlink anywhere above the store -
    # a symlinked home is the ordinary one - would make a pinned entry fail to
    # match itself and be pruned.
    local _p _keepit _er
    for _e in ${_victims+"${_victims[@]}"}; do
        _keepit=""
        _er="$(readlink -f "$_e" 2>/dev/null || printf '%s' "$_e")"
        for _p in ${_pinned+"${_pinned[@]}"}; do
            [ "$_er" = "$(readlink -f "$_p" 2>/dev/null || printf '%s' "$_p")" ] \
                && { _keepit=1; break; }
        done
        [ -z "$_keepit" ] || continue
        rm -rf "$_e" && echo "   pruned $(basename "$_e")"
    done
}

# --- removal -----------------------------------------------------------------

# Remove every runtime this installer owns. Lives here rather than in
# uninstall.sh because it has to agree with the resolvers above about where
# runtimes are, and because deleting trees is worth testing - which needs a
# function with a seam, not inline code in a script that also stops systemd
# units and rewrites the desktop database.
wires_remove_runtimes() {
    local _container _legacy _d
    if [ -n "${WIRES_RUNTIME:-}" ]; then
        # The user pinned a path; remove that and nothing else - but check what
        # it names first. This runs `rm -rf` on a variable, and a stale exported
        # value left from a test session would otherwise remove whatever it
        # happens to point at.
        case "$WIRES_RUNTIME" in
            ""|/|"$HOME"|"$HOME"/)
                echo "!! WIRES_RUNTIME is '$WIRES_RUNTIME'; refusing to remove that" >&2
                return 1 ;;
        esac
        [ -d "$WIRES_RUNTIME/bin" ] || {
            echo "!! $WIRES_RUNTIME has no bin/ and does not look like a runtime;" \
                 "refusing to remove it" >&2
            return 1; }
        rm -rf "$WIRES_RUNTIME" && echo "removed $WIRES_RUNTIME"
        return 0
    fi

    # One directory holds every entry, every channel and every set-aside tree, so
    # this is a single removal rather than a sibling glob. That glob is what
    # would orphan multi-gigabyte directories the moment any suffix joined the
    # runtime name - and the store's names are nothing but suffixes.
    _container="$(wires_runtime_store)"
    [ ! -e "$_container" ] || { rm -rf "$_container" && echo "removed $_container"; }

    # An install that never migrated still has the flat layout. -L as well as
    # -e so a dangling link from an older layout is cleared rather than left;
    # rm -rf on a symlink removes the link, never its target.
    _legacy="$(wires_legacy_root)"
    if [ -e "$_legacy" ] || [ -L "$_legacy" ]; then
        rm -rf "$_legacy" && echo "removed $_legacy"
    fi
    for _d in "$_legacy"-rollback-* "$_legacy".failed-*; do
        [ -e "$_d" ] || continue    # unmatched glob stays literal; skip, don't abort
        rm -rf "$_d" && echo "removed $_d"
    done
}

# --- the manifest ------------------------------------------------------------
# A channel publishes one small document saying what it currently points at.
# Same `key: value` shape as BUILD-INFO, so wires_buildinfo_field reads it and
# nothing needs jq:
#
#   channel:       stable
#   dist-version:  2026.08.04.1
#   installer:     install-ableton-latest.run
#   sha256:        …
#   source-commit: …
#   built-at:      2026-08-04T13:49:38Z
#   wine:          wine-11.13

# Where a channel's manifest lives. A table rather than string-building from the
# channel name: the value is user configuration, and the one thing it must never
# do is choose a host. WIRES_MANIFEST_URL overrides it for testing.
wires_manifest_url() {
    local _c="${1:-$(wires_channel)}"
    [ -z "${WIRES_MANIFEST_URL:-}" ] || { printf '%s\n' "$WIRES_MANIFEST_URL"; return; }
    # Both point at the project, never at a fork. A fork is where nightlies are
    # tested, and pointing the shipped default there would send every user's
    # daily channel to whoever happened to build it. WIRES_MANIFEST_URL is how
    # a fork tests its own; that override is deliberately not a channel.
    #
    # stable resolves through /releases/latest/, which excludes prereleases, so
    # the nightly prerelease cannot become what a stable machine follows.
    case "$_c" in
        stable)  printf '%s\n' "https://github.com/shibco/ableton-linux/releases/latest/download/manifest.txt" ;;
        nightly) printf '%s\n' "https://github.com/shibco/ableton-linux/releases/download/nightly/manifest.txt" ;;
        *)       return 1 ;;
    esac
}

# The installer a manifest names, resolved against the manifest's own location.
# Relative, so moving a release does not strand it.
wires_manifest_installer_url() {
    local _manifest="$1" _name="$2"
    printf '%s/%s\n' "${_manifest%/*}" "$_name"
}

# The runtime's own BUILD-INFO, read out of a tarball without unpacking it.
#
# This, not dist/BUILD-INFO-<version>.txt, is what a manifest must be written
# from. They are different documents: the committed one is the release's
# declared provenance; the tarball's is installed as
# $root/ABLETON-WINE-BUILD-INFO.txt, which is what the updater compares the
# manifest against. Writing from the other compares two documents that can
# differ without detection.
#
# Half a second on a 60 MB tarball, at package time only.
wires_tarball_buildinfo() {
    local _t="$1"
    [ -f "$_t" ] || return 1
    zstd -dc --long=27 "$_t" 2>/dev/null \
        | tar -xO --wildcards '*/ABLETON-WINE-BUILD-INFO.txt' 2>/dev/null
}

# Write one. Called by the publish step; kept here so the writer and the reader
# cannot drift apart.
wires_manifest_write() {
    local _channel="$1" _info="$2" _installer="$3" _sha="$4" _runtime="${5:-}" _runtime_sha="${6:-}" _k
    [ -r "$_info" ] || { echo "!! no BUILD-INFO at $_info" >&2; return 1; }
    printf 'channel:        %s\n' "$_channel"
    printf 'dist-version:   %s\n' "$(wires_buildinfo_field "$_info" dist-version)"
    printf 'installer:      %s\n' "$_installer"
    printf 'sha256:         %s\n' "$_sha"
    # Optional: the runtime tarball published beside the installer, for
    # runtime-only installs. Absent from older manifests, and the consumer
    # says so rather than guessing at asset names.
    if [ -n "$_runtime" ]; then
        printf 'runtime:        %s\n' "$_runtime"
        printf 'runtime-sha256: %s\n' "$_runtime_sha"
    fi
    printf 'source-commit:  %s\n' "$(wires_buildinfo_field "$_info" source-commit)"
    printf 'built-at:       %s\n' "$(wires_buildinfo_field "$_info" built-at)"
    # Optional, and absent for a release. Carried so the updater can report the
    # id a build is stored under rather than only its version.
    _k="$(wires_buildinfo_field "$_info" build-kind)"
    [ -z "$_k" ] || printf 'build-kind:     %s\n' "$_k"
    printf 'wine:           %s\n' "$(wires_buildinfo_field "$_info" wine)"
}

# Is a manifest usable? Refuses rather than half-applying: a field missing here
# means the updater cannot answer "is this newer" or "will this change the Wine
# base", which are the two questions it exists to answer.
wires_manifest_valid() {
    local _f="$1" _k
    [ -r "$_f" ] || return 1
    # `wine` is required because a safety refusal reads it: wires-update compares
    # bases and declines a one-way re-bootstrap, but guards that on the field
    # being non-empty. A manifest published without it turns that refusal off
    # rather than tripping it, and this is the gate standing in front of users.
    for _k in channel dist-version installer sha256 source-commit built-at wine; do
        [ -n "$(wires_buildinfo_field "$_f" "$_k")" ] || return 1
    done
    # The installer name reaches a URL and a filename. Nothing else in it.
    case "$(wires_buildinfo_field "$_f" installer)" in
        */*|*..*|"") return 1 ;;
    esac
    return 0
}
