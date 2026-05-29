#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2329
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PAQET_TEST_MODE=1
# shellcheck source=../install.sh
source "$REPO_ROOT/install.sh"

pass_count=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s\n--- expected ---\n%s\n--- actual ---\n%s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi

    pass_count=$((pass_count + 1))
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'FAIL: %s\nMissing: %s\nIn:\n%s\n' "$label" "$needle" "$haystack" >&2
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
CORE_PROFILE_META="$PAQET_DIR/core-profile.env"
CORE_PROVIDER_META="$PAQET_DIR/core-provider.env"
CORE_INSTALLED_META="$PAQET_DIR/core-installed.env"

assert_eq "recoba-enhanced" "$(get_current_core_provider)" "golden single-core provider"

forward_config=""
build_forward_config_from_mappings_csv "443" forward_config
expected_tcp=$'
  - listen: "0.0.0.0:443"
    target: "127.0.0.1:443"
    protocol: "tcp"'
assert_eq "$expected_tcp" "$forward_config" "golden TCP-only forward block"

forward_config=""
build_forward_config_from_mappings_csv "51820/udp" forward_config
expected_udp=$'
  - listen: "0.0.0.0:51820"
    target: "127.0.0.1:51820"
    protocol: "udp"'
assert_eq "$expected_udp" "$forward_config" "golden UDP-only forward block"

forward_config=""
build_forward_config_from_mappings_csv "1090:443,51820/udp" forward_config
expected_mixed=$'
  - listen: "0.0.0.0:1090"
    target: "127.0.0.1:443"
    protocol: "tcp"
  - listen: "0.0.0.0:51820"
    target: "127.0.0.1:51820"
    protocol: "udp"'
assert_eq "$expected_mixed" "$forward_config" "golden mixed TCP/UDP forward block"

set_current_profile_preset "default"
AUTO_TUNE_RCVWND="2048"
AUTO_TUNE_SNDWND="2048"
AUTO_TUNE_SMUXBUF="4194304"
AUTO_TUNE_STREAMBUF="2097152"
default_extra=""
build_profile_kcp_extra_fragment default_extra
expected_default_extra=$'    nodelay: 1
    interval: 10
    resend: 2
    nocongestion: 0
    wdelay: false
    acknodelay: true
    rcvwnd: 2048
    sndwnd: 2048
    smuxbuf: 4194304
    streambuf: 2097152
    dshard: 10
    pshard: 3'
assert_eq "$expected_default_extra" "$default_extra" "golden default KCP extra fragment"

assert_eq "aes" "$(get_effective_profile_kcp_block)" "golden iran-optimized block"
assert_eq "1300" "$(get_effective_profile_kcp_mtu)" "golden iran-optimized MTU"

client_yaml=$(cat <<YAML
role: "client"
forward:${expected_mixed}

transport:
  protocol: "kcp"
  conn: 2
  kcp:
    mode: "fast"
    key: "secret"
    mtu: 1300
    block: "aes"
${expected_default_extra}
YAML
)
assert_contains "$client_yaml" 'forward:
  - listen: "0.0.0.0:1090"' "golden assembled client forward header"
assert_contains "$client_yaml" '    protocol: "udp"' "golden assembled client UDP entry"
assert_contains "$client_yaml" '    dshard: 10' "golden assembled default KCP tuning"

detect_interface_mtu() { [ "${1:-}" = "eth0" ] && echo "1300"; }

sample_config="$tmp_dir/sample.yaml"
cat > "$sample_config" <<'YAML'
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
  conn: 4
  kcp:
    mode: "fast"
    key: "secret"
    mtu: 1300
    block: "aes"
    sndwnd: 2048
    rcvwnd: 2048
    dshard: 10
    pshard: 3
YAML

detect_total_mem_mb() { echo "1024"; }
detect_cpu_cores() { echo "1"; }

apply_profile_preset_to_config_file "$sample_config" "iran-optimized"
applied_yaml="$(cat "$sample_config")"
assert_contains "$applied_yaml" '  - listen: "0.0.0.0:1090"' "profile apply preserves listen mapping"
assert_contains "$applied_yaml" 'server:
  addr: "203.0.113.10:8888"' "profile apply preserves server address"
assert_contains "$applied_yaml" '  conn: 2' "profile apply writes iran-optimized conn=2"
assert_contains "$applied_yaml" '    block: "aes"' "profile apply writes iran-optimized block aes"
assert_contains "$applied_yaml" '    dshard: 0' "profile apply writes FEC off dshard=0"
assert_contains "$applied_yaml" '    pshard: 0' "profile apply writes FEC off pshard=0"

default_config="$tmp_dir/default.yaml"
cat > "$default_config" <<'YAML'
role: "client"
network:
  interface: "eth0"
transport:
  protocol: "kcp"
  conn: 4
  kcp:
    mode: "fast"
    key: "secret"
    mtu: 1300
    block: "aes"
    nodelay: 1
    interval: 10
    resend: 2
    nocongestion: 0
    wdelay: false
    acknodelay: true
    rcvwnd: 1024
    sndwnd: 1024
    smuxbuf: 4194304
    streambuf: 2097152
    dshard: 10
    pshard: 3
YAML

detect_total_mem_mb() { echo "8192"; }
detect_cpu_cores() { echo "4"; }
apply_profile_preset_to_config_file "$default_config" "default"
applied_default_yaml="$(cat "$default_config")"
assert_contains "$applied_default_yaml" '  conn: 2' "default profile caps low-MTU conn"
assert_contains "$applied_default_yaml" '    mtu: 1200' "default profile applies safe interface MTU headroom"
assert_contains "$applied_default_yaml" '    rcvwnd: 1536' "default profile caps low-MTU receive window"
assert_contains "$applied_default_yaml" '    sndwnd: 1536' "default profile caps low-MTU send window"
assert_contains "$applied_default_yaml" '    smuxbuf: 4194304' "default profile caps low-MTU smux buffer"
assert_contains "$applied_default_yaml" '    streambuf: 2097152' "default profile caps low-MTU stream buffer"
assert_contains "$applied_default_yaml" '    nocongestion: 0' "default profile enables congestion control"

printf 'All golden config tests passed (%s assertions).\n' "$pass_count"
