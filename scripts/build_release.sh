#!/bin/bash
#===============================================================================
#  Recoba Tunnel — Release Build Script
#  Builds amd64 and arm64 binaries for GitHub Releases.
#
#  Usage: bash scripts/build_release.sh [version]
#     eg: bash scripts/build_release.sh v2.0.0
#
#  Prerequisites:
#    - Go 1.23+ installed
#    - Docker (for amd64 cross-compile on arm64 host)
#    - libpcap-dev (for native arm64 build)
#
#  Output:
#    build/recoba-tunnel-linux-amd64.tar.gz
#    build/recoba-tunnel-linux-arm64.tar.gz
#    build/SHA256SUMS
#===============================================================================

set -e

VERSION="${1:-v2.0.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
SRC_DIR="$PROJECT_DIR/../paqet-a"  # Path to the Go source (adjust as needed)

# Try common source locations
if [ ! -f "$SRC_DIR/go.mod" ]; then
    SRC_DIR="/Users/amin/Documents/Witamin-Game/Paqet Manager/scratch/paqet-a"
fi
if [ ! -f "$SRC_DIR/go.mod" ]; then
    echo "Error: Cannot find paqet Go source directory."
    echo "Please set SRC_DIR in this script or place the source at one of the expected paths."
    exit 1
fi

echo "=== Recoba Tunnel Release Build ==="
echo "Version: $VERSION"
echo "Source:  $SRC_DIR"
echo "Output:  $BUILD_DIR"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Build arm64 (native on Apple Silicon or aarch64 Linux) ---
echo "--- Building linux/arm64 ---"
cd "$SRC_DIR"
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go build -o "$BUILD_DIR/recoba-tunnel" ./cmd 2>&1 || {
    echo "arm64 native build failed. Trying with Docker..."
    docker run --platform linux/arm64 --rm \
        -v "$SRC_DIR:/src" -w /src \
        golang:1.23 sh -c "apt-get update -qq && apt-get install -y -qq libpcap-dev && CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go build -o /src/build/recoba-tunnel ./cmd" 2>&1
}
cd "$BUILD_DIR"
tar czf "recoba-tunnel-linux-arm64.tar.gz" recoba-tunnel
echo "  → recoba-tunnel-linux-arm64.tar.gz"
rm -f recoba-tunnel

# --- Build amd64 (via Docker cross-compile) ---
echo "--- Building linux/amd64 ---"
cd "$SRC_DIR"
docker run --platform linux/amd64 --rm \
    -v "$SRC_DIR:/src" -w /src \
    golang:1.23 sh -c "apt-get update -qq && apt-get install -y -qq libpcap-dev && CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -o build/recoba-tunnel ./cmd" 2>&1
cd "$BUILD_DIR"
tar czf "recoba-tunnel-linux-amd64.tar.gz" recoba-tunnel
echo "  → recoba-tunnel-linux-amd64.tar.gz"
rm -f recoba-tunnel

# --- Generate SHA256SUMS ---
echo "--- Generating SHA256SUMS ---"
cd "$BUILD_DIR"
shasum -a 256 recoba-tunnel-linux-*.tar.gz > SHA256SUMS
cat SHA256SUMS

echo ""
echo "=== Build Complete ==="
echo ""
echo "Files in $BUILD_DIR:"
ls -lh "$BUILD_DIR"
echo ""
echo "Upload these files to:"
echo "  https://github.com/Recoba86/recoba-tunnel/releases/new?tag=${VERSION}"
echo ""
echo "Release title:  Recoba Tunnel ${VERSION}"
echo "Binary names:   recoba-tunnel-linux-amd64.tar.gz"
echo "                recoba-tunnel-linux-arm64.tar.gz"
echo "                SHA256SUMS"
