#!/usr/bin/env bash
# Run the test suite.
#
#   ./tests/run.sh                 # everything (~20s, no build, no prefix, no display)
#   ./tests/run.sh unit            # just the shell unit tests
#   ./tests/run.sh tests/patch-stack.bats tests/launcher-cli.bats
#
# bats is resolved in this order: $BATS, bats on PATH, then a pinned clone in
# .bats-core/ at the repo root (created on first run, gitignored). Nothing here
# needs the Wine build, a prefix, a display, or network access after that first
# clone.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

BATS_VERSION="v1.12.0"
# Deliberately NOT under tests/: bats-core ships its own .bats fixtures, some
# with intentionally duplicate test names, and a recursive run over tests/ would
# pick them up and abort.
VENDORED="$root/.bats-core"

find_bats() {
    if [ -n "${BATS:-}" ] && [ -x "$BATS" ]; then printf '%s\n' "$BATS"; return; fi
    if command -v bats >/dev/null 2>&1; then command -v bats; return; fi
    if [ ! -x "$VENDORED/bin/bats" ]; then
        echo "== fetching bats-core $BATS_VERSION (one-off; set \$BATS or install bats to skip) ==" >&2
        git -c advice.detachedHead=false clone -q --depth 1 --branch "$BATS_VERSION" \
            https://github.com/bats-core/bats-core.git "$VENDORED"
    fi
    printf '%s\n' "$VENDORED/bin/bats"
}

bats_bin="$(find_bats)"
echo "== bats: $("$bats_bin" --version) =="

# Explicit targets, never a bare directory walk — see VENDORED above.
targets=()
if [ $# -eq 0 ]; then
    for f in "$here"/*.bats "$here"/unit/*.bats; do
        [ -e "$f" ] && targets+=("$f")
    done
else
    for a in "$@"; do
        case "$a" in
            unit)  for f in "$here"/unit/*.bats; do [ -e "$f" ] && targets+=("$f"); done ;;
            /*)    targets+=("$a") ;;
            *)     targets+=("$root/$a") ;;
        esac
    done
fi
[ ${#targets[@]} -gt 0 ] || { echo "!! no test files matched" >&2; exit 1; }

exec "$bats_bin" --print-output-on-failure "${targets[@]}"
