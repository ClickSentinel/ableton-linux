#!/usr/bin/env bash
# Publish the current VERSION as a GitHub release.
#
#   GH_TOKEN=<fine-grained PAT, contents read/write> ./scripts/release.sh
#   GH_TOKEN=... ./scripts/release.sh --notes-file notes.md
#
# --notes-file takes a hand-written markdown summary of the release and puts
# it at the top of the release body, above the install instructions and build
# provenance the workflow generates. The file is read at publish time and is
# not committed anywhere; write it wherever is convenient. Without the flag
# the body is exactly what the workflow drafted, as before.
#
# Verifies the locally built dist/ artifacts, pushes the v<VERSION> tag (the
# release workflow then drafts the release with notes from BUILD-INFO),
# uploads the assets, and publishes. Alongside the versioned installer it
# uploads a stable-named copy, install-ableton-latest.run, so
#   https://github.com/<repo>/releases/latest/download/install-ableton-latest.run
# always serves the newest build. CI never rebuilds Wine; the bits released
# are the bits verified here.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

notes=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notes-file)
            [ $# -ge 2 ] || { echo "!! --notes-file needs a path" >&2; exit 1; }
            notes="$2"; shift 2 ;;
        *) echo "!! unknown argument: $1 (see the header of $0)" >&2; exit 1 ;;
    esac
done

NAME="wine-d2d1-nspa-11.13"
VERSION="$(cat VERSION)"
TAG="v$VERSION"
run="dist/ableton-wine-setup-${VERSION}.run"
tarball="dist/${NAME}-${VERSION}.tar.zst"
info="dist/BUILD-INFO-${VERSION}.txt"

command -v jq >/dev/null || { echo "!! jq is required" >&2; exit 1; }
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$token" ] || { echo "!! set GH_TOKEN (fine-grained PAT with contents read/write)" >&2; exit 1; }
repo="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
api="https://api.github.com/repos/$repo"
gh_api() { curl -fsS -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" "$@"; }

echo "== [0/4] verify the $VERSION artifacts =="
# fail on a bad --notes-file now, not after the tag is pushed and 112M uploaded
if [ -n "$notes" ]; then
    [ -f "$notes" ] || { echo "!! no such notes file: $notes" >&2; exit 1; }
    grep -q '[^[:space:]]' "$notes" || { echo "!! notes file is empty: $notes" >&2; exit 1; }
fi
for f in "$run" "$run.sha256" "$tarball" "$tarball.sha256" "$info"; do
    [ -f "$f" ] || { echo "!! missing $f: run ./build.sh and ./scripts/make-installer.sh first" >&2; exit 1; }
done
( cd dist && sha256sum -c "$(basename "$run").sha256" "$(basename "$tarball").sha256" )
sh "$run" --help >/dev/null
git ls-files --error-unmatch "$info" >/dev/null 2>&1 \
    || { echo "!! $info is not committed: the release workflow needs it at the tag" >&2; exit 1; }
git diff --quiet HEAD -- VERSION "$info" \
    || { echo "!! VERSION or $info has uncommitted changes: commit them first" >&2; exit 1; }

echo "== [1/4] push tag $TAG =="
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "$VERSION"
git push origin "$TAG"

echo "== [2/4] wait for the draft release (created by the release workflow) =="
rid=""
for _ in $(seq 1 30); do
    rid="$(gh_api "$api/releases?per_page=30" \
        | jq -r --arg t "$TAG" '.[] | select(.tag_name == $t) | .id' | head -1)"
    [ -n "$rid" ] && break
    sleep 5
done
[ -n "$rid" ] || { echo "!! no release for $TAG after 150s: check the repo's Actions tab, then rerun" >&2; exit 1; }

echo "== [3/4] upload assets =="
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp "$run" "$stage/install-ableton-latest.run"
( cd "$stage" && sha256sum install-ableton-latest.run > install-ableton-latest.run.sha256 )

upload() {
    local f="$1" name old
    name="$(basename "$f")"
    # replace a leftover asset of the same name from an earlier attempt
    old="$(gh_api "$api/releases/$rid/assets?per_page=100" \
        | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1)"
    [ -z "$old" ] || gh_api -X DELETE "$api/releases/assets/$old"
    echo "   $name"
    gh_api -X POST -H "Content-Type: application/octet-stream" --data-binary "@$f" \
        "https://uploads.github.com/repos/$repo/releases/$rid/assets?name=$name" >/dev/null
}
for f in "$run" "$run.sha256" "$tarball" "$tarball.sha256" "$info" \
         "$stage/install-ableton-latest.run" "$stage/install-ableton-latest.run.sha256"; do
    upload "$f"
done

echo "== [4/4] publish =="
if [ -n "$notes" ]; then
    # Strip any block an earlier run left, so re-running after a failed upload
    # replaces the summary rather than stacking a second copy. The second sed
    # drops the blank line that block leaves behind, which would otherwise add
    # a line to the body on every run.
    body="$(gh_api "$api/releases/$rid" | jq -r '.body // ""' \
        | sed '/<!-- release-notes:start -->/,/<!-- release-notes:end -->/d' \
        | sed '/./,$!d')"
    jq -n --rawfile n "$notes" --arg b "$body" \
        '{body: ("<!-- release-notes:start -->\n" + $n
                 + "\n<!-- release-notes:end -->\n\n" + $b), draft: false}' \
        | gh_api -X PATCH "$api/releases/$rid" -d @- >/dev/null
else
    gh_api -X PATCH "$api/releases/$rid" -d '{"draft": false}' >/dev/null
fi
echo
echo "OK: https://github.com/$repo/releases/tag/$TAG"
echo "Latest installer: https://github.com/$repo/releases/latest/download/install-ableton-latest.run"
