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
PAQET_SERVICE="paqet-test-codex"
AUTO_RESET_CONF="$PAQET_DIR/auto-reset.conf"
AUTO_RESET_SCRIPT="$PAQET_DIR/auto-reset.sh"
AUTO_RESET_SERVICE="paqet-auto-reset-test-codex"
AUTO_RESET_TIMER="paqet-auto-reset-test-codex"
OPTIMIZE_SYSCTL_FILE="/etc/sysctl.d/99-paqet-test-codex.conf"

output="$(
    create_systemd_service
    setup_iptables "19888"
    setup_iptables_client "203.0.113.10" "19888"
    remove_iptables_client "203.0.113.10" "19888"
    save_iptables
    apply_paqx_kernel_optimizations
    ensure_ip_forwarding
    write_auto_reset_config "true" "6" "hour"
    create_auto_reset_timer "6" "hour"
    remove_auto_reset_timer
)"

assert_contains "$output" "DRY-RUN" "dry-run output marker"
assert_contains "$output" "would write systemd service: /etc/systemd/system/paqet-test-codex.service" "systemd service write skipped"
assert_contains "$output" "would run: iptables -t raw -A OUTPUT -p tcp -d 203.0.113.10 --dport 19888 -j NOTRACK" "iptables command printed"
assert_contains "$output" "would ensure TCP MSS clamp rule" "MSS clamp is dry-run safe"
assert_contains "$output" "would write kernel optimization file: /etc/sysctl.d/99-paqet-test-codex.conf" "sysctl file write skipped"
assert_contains "$output" "would write auto-reset config:" "auto-reset config write skipped"
assert_contains "$output" "would write systemd timer: /etc/systemd/system/paqet-auto-reset-test-codex.timer" "auto-reset timer write skipped"

assert_not_exists "/etc/systemd/system/paqet-test-codex.service" "dry-run did not create systemd service"
assert_not_exists "/etc/systemd/system/paqet-auto-reset-test-codex.service" "dry-run did not create auto-reset service"
assert_not_exists "/etc/systemd/system/paqet-auto-reset-test-codex.timer" "dry-run did not create auto-reset timer"
assert_not_exists "/etc/sysctl.d/99-paqet-test-codex.conf" "dry-run did not create sysctl file"
assert_not_exists "$AUTO_RESET_CONF" "dry-run did not create auto-reset config"
assert_not_exists "$AUTO_RESET_SCRIPT" "dry-run did not create auto-reset script"

printf 'All dry-run tests passed (%s assertions).\n' "$pass_count"
