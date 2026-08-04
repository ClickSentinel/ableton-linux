# shellcheck shell=bash
# Which runtime tarball a script should act on.
#
# Sourced, never executed. This exists because the answer was written three
# times — install.sh, make-installer.sh and build-audit.sh each had a copy, and
# the same defect was in all three.

# The runtime's build name. It carries the Wine version because the artifact
# does: a tarball identifies which build it is.
ableton_runtime_name() {
    printf '%s\n' "wine-d2d1-nspa-11.13"
}

# The newest runtime tarball in <dir>, or nothing.
#
# The glob cannot be the selector. The build also emits
# <name>-<version>-debug.tar.zst, and `sort -V` orders that suffix *after* the
# runtime, so a glob piped to `tail -1` picks the debug tree — which carries
# bin/ and lib/ but no share/, passes `wine --version`, and then fails at launch
# with "could not exec the wine loader". Match the dated release form only and
# let every suffixed variant fall out.
#
# Locals are underscore-prefixed: this is sourced into scripts with their own
# $found and $target.
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
