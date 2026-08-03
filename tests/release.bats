#!/usr/bin/env bats
#
# Release-time invariants. NOT part of the per-PR gate.
#
# Everything here is true of a tagged release and false at plenty of legitimate
# points in between. e221cc4 ("Changelog for 2026.07.29.1") landed the changelog
# entry while VERSION still read 2026.07.23.1 — correct work, and a per-PR
# version-consistency gate would have blocked it. So these run on the tag, where
# they are unambiguous, and where failing still beats finding out from a
# half-published release.
#
#   ./tests/run.sh tests/release.bats

bats_require_minimum_version 1.5.0

load helpers/common

# guards: commit e221cc4 — the changelog lands before the VERSION bump, so this cannot gate a PR
@test "VERSION has a matching CHANGELOG entry at the top" {
    ver="$(cat "$REPO/VERSION")"
    top="$(grep -m1 '^## ' "$REPO/CHANGELOG.md" | sed 's/^## //')"
    [ "$top" = "$ver" ] || {
        echo "VERSION is $ver but the newest CHANGELOG entry is '$top'" >&2; false; }
}

@test "VERSION has a committed BUILD-INFO, as release.yml's draft job demands" {
    ver="$(cat "$REPO/VERSION")"
    [ -f "$REPO/dist/BUILD-INFO-$ver.txt" ] || {
        echo "dist/BUILD-INFO-$ver.txt is missing; the draft job would reject this tag" >&2
        false; }
}

@test "the BUILD-INFO for this VERSION names the patch count the series holds" {
    ver="$(cat "$REPO/VERSION")"
    info="$REPO/dist/BUILD-INFO-$ver.txt"
    [ -f "$info" ] || skip "no BUILD-INFO for $ver"
    n="$(grep -c . "$REPO/patches/SERIES.sha256")"
    grep -qE "^patches: +$n$" "$info" || {
        echo "BUILD-INFO says '$(grep -E '^patches:' "$info")' but the series holds $n" >&2
        false; }
}

@test "README points at the stable installer asset release.sh actually uploads" {
    # README tells every user to download install-ableton-latest.run. If
    # release.sh ever renames that stable copy, the README's download link and
    # every command under it 404 — for new users only, so nobody notices.
    asset=install-ableton-latest.run
    grep -qF "$asset" "$REPO/scripts/release.sh" || {
        echo "release.sh no longer uploads $asset" >&2; false; }
    grep -qF "$asset" "$REPO/README.md" || {
        echo "README no longer mentions $asset" >&2; false; }
    grep -qF "$asset" "$REPO/.github/workflows/release.yml" || {
        echo "release.yml no longer verifies $asset" >&2; false; }
}
