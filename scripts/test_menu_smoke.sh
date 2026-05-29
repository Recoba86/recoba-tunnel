#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PAQET_TEST_MODE=1
export PAQET_DRY_RUN=1
# shellcheck source=../install.sh
source "$REPO_ROOT/install.sh"

pass_count=0

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'FAIL: %s\nMissing: %s\nOutput:\n%s\n' "$label" "$needle" "$haystack" >&2
        exit 1
    fi

    pass_count=$((pass_count + 1))
}

assert_not_exists() {
    local path="$1"
    local label="$2"

    if [ -e "$path" ]; then
        printf 'FAIL: %s\nUnexpected path exists: %s\n' "$label" "$path" >&2
        exit 1
    fi

    pass_count=$((pass_count + 1))
}

tmp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

PAQET_DIR="$tmp_dir/opt-paqet"
PAQET_CONFIG="$PAQET_DIR/config.yaml"
PAQET_BIN="$PAQET_DIR/paqet"
PAQET_SERVICE="paqet-menu-smoke"
CORE_META="$PAQET_DIR/core-metadata.env"
CORE_PROFILE_META="$PAQET_DIR/core-profile.env"
AUTO_RESET_CONF="$PAQET_DIR/auto-reset.conf"
AUTO_RESET_SCRIPT="$PAQET_DIR/auto-reset.sh"

mkdir -p "$PAQET_DIR"
cat > "$PAQET_CONFIG" <<'YAML'
role: "client"
forward:
  - listen: "0.0.0.0:1090"
    target: "127.0.0.1:443"
    protocol: "tcp"
network:
  interface: "eth0"
server:
  addr: "203.0.113.10:8888"
transport:
  protocol: "kcp"
  conn: 2
  kcp:
    mode: "fast"
    key: "test-key"
    mtu: 1300
    block: "aes"
YAML

set_current_profile_preset "default"

# Create minimal CORE_META so show_core_install_metadata renders details
mkdir -p "$PAQET_DIR"
cat > "$CORE_META" << 'EOF'
CORE_PROVIDER="recoba-enhanced"
CORE_VERSION="v2.0.0"
CORE_ARCHIVE="recoba-tunnel-linux-arm64.tar.gz"
CORE_ASSET_URL="https://github.com/Recoba86/recoba-tunnel/releases/download/v2.0.0/recoba-tunnel-linux-arm64.tar.gz"
CORE_ARCHIVE_PATH="/opt/recoba-tunnel/core-cache/v2.0.0/recoba-tunnel-linux-arm64.tar.gz"
CORE_ARCHIVE_SOURCE="download"
CORE_ARCHIVE_SHA256="abc123"
CORE_BINARY_PATH="/opt/recoba-tunnel/recoba-tunnel"
CORE_BINARY_SHA256="def456"
UPDATED_AT="2026-05-29T12:00:00+00:00"
EOF

output="$(
    show_core_management_status
    show_core_install_metadata
    view_current_auto_profile
    show_port_config
    create_systemd_service
    update_installer
    install_command
    download_paqet
)"

assert_contains "$output" "Core Provider:" "core status renders"
assert_contains "$output" "Installed Core Metadata" "metadata menu renders"
assert_contains "$output" "Asset URL:" "metadata details render"
assert_contains "$output" "Active KCP Profile Preview" "auto profile preview renders"
assert_contains "$output" "Current Port Configuration" "port/profile defaults render"
assert_contains "$output" "DRY-RUN: systemd service not created" "systemd write path is dry-run safe"
assert_contains "$output" "DRY-RUN: installer not updated" "installer update path is dry-run safe"
assert_contains "$output" "DRY-RUN: recoba-tunnel command not installed" "command install path is dry-run safe"
assert_contains "$output" "DRY-RUN: paqet binary not changed" "core download path is dry-run safe"

assert_not_exists "/etc/systemd/system/paqet-menu-smoke.service" "menu smoke did not create systemd service"

printf 'All menu smoke tests passed (%s assertions).\n' "$pass_count"
