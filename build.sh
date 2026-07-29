#!/usr/bin/env bash
#
#   ./build.sh                # build the runtime and Link helper with Podman
#   JOBS=8 ./build.sh         # limit parallelism
#   INSTALL_PREFIX=/target/path/wine-d2d1-nspa-11.13 ./build.sh
#                             # strict path-identity build; normally unnecessary
#                             # the tarball self-locates (relocation gate proves it)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

ENGINE="${ENGINE:-podman}"
IMAGE="${IMAGE:-ableton-wine-build:22.04}"
JOBS="${JOBS:-$(nproc)}"
# Wine locates bin/ -> lib/wine -> share/wine relative to the running binary.
# One tarball can serve any user and any $HOME. 
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/wine-d2d1-nspa-11.13}"

command -v "$ENGINE" >/dev/null || {
    echo "!! Podman command '$ENGINE' not found; install Podman or set ENGINE" >&2
    exit 1
}

echo "== [0/4] verify vendored inputs against pinned checksums =="
( cd vendor && sha256sum -c wine-base.sha256 pipeasio.sha256 pipewire-sdk.sha256 ntsync-uapi.sha256 link.sha256 )

echo "== [1/4] build container image ($IMAGE) =="
$ENGINE build -t "$IMAGE" -f Containerfile .

echo "== [2/4] build Wine + PipeASIO in the container (JOBS=$JOBS) =="
mkdir -p dist "${ABLETON_CCACHE_DIR:-/mnt/storage-2tb/.ableton-wine-ccache}"
relabel=""
if [ -f /sys/fs/selinux/enforce ]; then relabel=",Z"; fi
$ENGINE run --rm \
    -v "$here:/src:ro$relabel" \
    -v "$here/dist:/out:rw$relabel" \
    -v "${ABLETON_CCACHE_DIR:-/mnt/storage-2tb/.ableton-wine-ccache}:/ccache:rw$relabel" \
    -e JOBS="$JOBS" \
    -e "INSTALL_PREFIX=$INSTALL_PREFIX" \
    -e "ABLETON_KEEP_SYMBOLS=${ABLETON_KEEP_SYMBOLS:-}" \
    "$IMAGE" \
    /src/scripts/container-build.sh

echo "== [3/4] build ableton-linkd with the configured Podman image =="
ENGINE="$ENGINE" IMAGE="$IMAGE" ./scripts/build-ableton-linkd.sh

echo "== [4/4] done: artifacts in dist/ =="
ls -lh dist/
echo
echo "Next:  ./scripts/install.sh   then   ./scripts/setup-prefix.sh"
