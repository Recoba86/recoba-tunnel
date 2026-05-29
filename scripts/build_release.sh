#!/bin/bash
#===============================================================================
#  Recoba Tunnel — Release Build Script
#  Builds amd64 and arm64 binaries from ./core for GitHub Releases.
#
#  Usage: bash scripts/build_release.sh [version]
#     eg: bash scripts/build_release.sh v2.0.0
#
#  Prerequisites:
#    - Docker (all builds use golang:1.26 images with CGo + libpcap)
#
#  Output:
#    build/recoba-tunnel-linux-amd64.tar.gz
#    build/recoba-tunnel-linux-arm64.tar.gz
#    build/SHA256SUMS
#===============================================================================

set -euo pipefail

VERSION="${1:-v2.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
SRC_DIR="$PROJECT_DIR/core"
GO_IMAGE="golang:1.26"

if [ ! -f "$SRC_DIR/go.mod" ]; then
    echo "Error: Cannot find core/go.mod in $SRC_DIR"
    echo "Run this script from the repository root."
    exit 1
fi

echo "=== Recoba Tunnel Release Build ==="
echo "Version: $VERSION"
echo "Source:  $SRC_DIR"
echo "Output:  $BUILD_DIR"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
GIT_TAG=$(git describe --tags --always 2>/dev/null || echo unknown)

build_in_docker() {
    local arch="$1"
    local out_name="$2"
    echo "--- Building linux/${arch} ---"
    docker run --platform "linux/${arch}" --rm \
        -v "$SRC_DIR:/src" -v "$BUILD_DIR:/out" \
        "$GO_IMAGE" sh -c "
            apt-get update -qq 2>/dev/null
            apt-get install -y -qq libpcap-dev 2>/dev/null
            cd /src
            CGO_ENABLED=1 GODEBUG=asyncpreemptoff=1 GOOS=linux GOARCH=${arch} go build -trimpath -ldflags=\"-s -w -X paqet/cmd/version.Version=${VERSION} -X paqet/cmd/version.GitCommit=${GIT_COMMIT} -X paqet/cmd/version.GitTag=${GIT_TAG} -X paqet/cmd/version.BuildTime=\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" -o /out/recoba-tunnel ./cmd
        "

    cd "$BUILD_DIR"
    if [ -f recoba-tunnel ]; then
        tar czf "${out_name}" recoba-tunnel
        rm -f recoba-tunnel
        echo "  -> ${out_name}"
    else
        echo "  ERROR: linux/${arch} build failed"
        exit 1
    fi
}

build_in_docker "amd64" "recoba-tunnel-linux-amd64.tar.gz"
build_in_docker "arm64" "recoba-tunnel-linux-arm64.tar.gz"

# --- Generate SHA256SUMS ---
echo "--- Generating SHA256SUMS ---"
cd "$BUILD_DIR"
shasum -a 256 recoba-tunnel-linux-*.tar.gz > SHA256SUMS
cat SHA256SUMS

echo ""
echo "=== Build Complete ==="
echo ""
ls -lh "$BUILD_DIR"
echo ""
echo "Upload with:"
echo "  gh release create ${VERSION} build/recoba-tunnel-linux-*.tar.gz build/SHA256SUMS \\"
echo "    --title \"Recoba Tunnel ${VERSION}\""
