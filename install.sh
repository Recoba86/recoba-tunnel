#!/bin/bash
#===============================================================================
#  Recoba Tunnel — Raw Packet Tunnel Installer & Manager
#  Optimised for Iran entry → abroad exit paths with ENOBUFS recovery.
#
#  Usage: bash <(curl -fsSL https://raw.githubusercontent.com/Recoba86/recoba-tunnel/main/install.sh)
#
#  This project is based on the open-source Paqet core and has been
#  independently modified and optimised for production tunnel stability.
#===============================================================================

set -e

# --- Project Identity ---
PROJECT_NAME="Recoba Tunnel"
INSTALLER_VERSION="2.0.0"
GITHUB_REPO="Recoba86/recoba-tunnel"
INSTALLER_REPO="$GITHUB_REPO"
RELEASE_TAG="v2.1.0"
INSTALLER_CMD="/usr/local/bin/recoba-tunnel"

# --- Paths ---
PAQET_DIR="/opt/recoba-tunnel"
PAQET_CONFIG="$PAQET_DIR/config.yaml"
PAQET_BIN="$PAQET_DIR/recoba-tunnel"
PAQET_SERVICE="recoba-tunnel"
AUTO_RESET_CONF="$PAQET_DIR/auto-reset.conf"
AUTO_RESET_SCRIPT="$PAQET_DIR/auto-reset.sh"
AUTO_RESET_SERVICE="recoba-tunnel-auto-reset"
AUTO_RESET_TIMER="recoba-tunnel-auto-reset"
CORE_META="$PAQET_DIR/core-metadata.env"
CORE_CACHE_DIR="$PAQET_DIR/core-cache"
CORE_CACHE_ARCHIVE_DIR="$CORE_CACHE_DIR/archives"
DEFAULT_CORE_PROFILE_PRESET="iran-optimized"

# --- Default KCP / Transport Profile ---
DEFAULT_PAQET_PORT="8888"
DEFAULT_FORWARD_PORTS="1090"
DEFAULT_KCP_MODE="fast"
DEFAULT_KCP_CONN="2"
DEFAULT_KCP_MTU="1300"
KCP_MTU_HEADROOM="100"
KCP_MTU_MIN="900"
KCP_MTU_MAX="1450"
LOW_MTU_PROFILE_THRESHOLD="1300"
LOW_MTU_PROFILE_CONN="2"
LOW_MTU_PROFILE_SNDWND="1536"
LOW_MTU_PROFILE_RCVWND="1536"
LOW_MTU_PROFILE_SMUXBUF="4194304"
LOW_MTU_PROFILE_STREAMBUF="2097152"
DEFAULT_KCP_DSHARD="10"
DEFAULT_KCP_PSHARD="3"
OPTIMIZED_KCP_DSHARD="0"
OPTIMIZED_KCP_PSHARD="0"
OPTIMIZED_IFACE_MTU="1492"
OPTIMIZED_TXQUEUELEN="4000"
OPTIMIZED_FQ_FLOW_LIMIT="500"
OPTIMIZE_SYSCTL_FILE="/etc/sysctl.d/99-recoba-tunnel.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_banner_line() {
    printf "║ %-45s ║\n" "$1"
}

print_banner() {
    clear 2>/dev/null || true
    echo -e "${MAGENTA}"
    echo "╔═══════════════════════════════════════════════╗"
    print_banner_line ""
    print_banner_line "██████╗ ███████╗ ██████╗ ██████╗ ██████╗  █████╗ "
    print_banner_line "██╔══██╗██╔════╝██╔════╝██╔═══██╗██╔══██╗██╔══██╗"
    print_banner_line "██████╔╝█████╗  ██║     ██║   ██║██████╔╝███████║"
    print_banner_line "██╔══██╗██╔══╝  ██║     ██║   ██║██╔══██╗██╔══██║"
    print_banner_line "██║  ██║███████╗╚██████╗╚██████╔╝██████╔╝██║  ██║"
    print_banner_line "╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝"
    print_banner_line ""
    print_banner_line "${PROJECT_NAME} — Raw Packet Tunnel Manager"
    print_banner_line "Version: v${INSTALLER_VERSION}"
    print_banner_line "Based on open-source Paqet with optimisations"
    print_banner_line ""
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }

is_valid_shell_var_name() {
    [[ "${1:-}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

assign_var() {
    local varname="$1"
    local value="${2:-}"

    if ! is_valid_shell_var_name "$varname"; then
        print_error "Internal error: invalid variable name '$varname'"
        return 1
    fi

    printf -v "$varname" '%s' "$value"
}

ensure_paqet_dir_permissions() {
    mkdir -p "$PAQET_DIR"
    chmod 755 "$PAQET_DIR" 2>/dev/null || true
}

secure_file_permissions() {
    local path="$1"
    local mode="$2"
    [ -e "$path" ] || return 0
    chmod "$mode" "$path" 2>/dev/null || true
}

secure_paqet_sensitive_files() {
    ensure_paqet_dir_permissions
    local file=""
    for file in "$PAQET_DIR"/config*.yaml "$PAQET_DIR"/*.env "$AUTO_RESET_CONF"; do
        [ -e "$file" ] && secure_file_permissions "$file" 600
    done
    secure_file_permissions "$AUTO_RESET_SCRIPT" 700
}

sha256_file() {
    local path="$1"
    [ -f "$path" ] || return 0
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        echo ""
    fi
}

env_quote_value() {
    local value="${1:-}"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

sed_inplace() {
    if sed --version >/dev/null 2>&1; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

is_dry_run() {
    [ "${PAQET_DRY_RUN:-0}" = "1" ]
}

dry_run_notice() {
    print_info "DRY-RUN: $*"
}

run_or_dry_run() {
    if is_dry_run; then
        dry_run_notice "would run: $*"
        return 0
    fi
    "$@"
}

systemctl_or_dry_run() {
    run_or_dry_run systemctl "$@"
}

iptables_or_dry_run() {
    run_or_dry_run iptables "$@"
}

sysctl_or_dry_run() {
    run_or_dry_run sysctl "$@"
}

write_file_or_dry_run() {
    local path="$1"
    local content="$2"
    local mode="${3:-}"

    if is_dry_run; then
        dry_run_notice "would write file: $path"
        [ -n "$mode" ] && dry_run_notice "would chmod $mode: $path"
        return 0
    fi

    printf '%s\n' "$content" > "$path"
    [ -n "$mode" ] && secure_file_permissions "$path" "$mode"
}

#===============================================================================
# Core Provider + Profile Preset Metadata
#===============================================================================

PROFILE_PRESET_NAME="$DEFAULT_CORE_PROFILE_PRESET"
PROFILE_PRESET_LABEL="Current Default (PaqX-style)"
PROFILE_PRESET_KCP_BLOCK="aes"
PROFILE_PRESET_KCP_MTU="$DEFAULT_KCP_MTU"
PROFILE_PRESET_TRANSPORT_TCPBUF=""
PROFILE_PRESET_TRANSPORT_UDPBUF=""
PROFILE_PRESET_PCAP_SOCKBUF_SERVER=""
PROFILE_PRESET_PCAP_SOCKBUF_CLIENT=""

get_current_core_provider() {
    echo "recoba-enhanced"
}

get_core_provider_label() {
    echo "Recoba Enhanced Core"
}

set_current_core_provider() {
    # Single-core model — always recoba-enhanced.
    return 0
}

get_installed_core_meta_field() {
    local field="$1"
    if [ ! -f "$CORE_META" ]; then
        echo ""
        return 0
    fi
    grep "^${field}=" "$CORE_META" 2>/dev/null | head -1 | cut -d'"' -f2
}

set_installed_core_metadata() {
    local provider="$1"
    local version="$2"
    local archive_name="$3"
    local asset_url="${4:-}"
    local archive_path="${5:-}"
    local archive_source="${6:-}"
    local binary_path="${7:-$PAQET_BIN}"
    local archive_sha256=""
    local binary_sha256=""

    archive_sha256=$(sha256_file "$archive_path")
    binary_sha256=$(sha256_file "$binary_path")

    ensure_paqet_dir_permissions
    cat > "$CORE_META" << EOF
# recoba-tunnel installed core metadata
CORE_PROVIDER="$(env_quote_value "$provider")"
CORE_VERSION="$(env_quote_value "$version")"
CORE_ARCHIVE="$(env_quote_value "$archive_name")"
CORE_ASSET_URL="$(env_quote_value "$asset_url")"
CORE_ARCHIVE_PATH="$(env_quote_value "$archive_path")"
CORE_ARCHIVE_SOURCE="$(env_quote_value "$archive_source")"
CORE_ARCHIVE_SHA256="$(env_quote_value "$archive_sha256")"
CORE_BINARY_PATH="$(env_quote_value "$binary_path")"
CORE_BINARY_SHA256="$(env_quote_value "$binary_sha256")"
UPDATED_AT="$(date -Iseconds 2>/dev/null || date)"
EOF
    secure_file_permissions "$CORE_META" 600
}

# shellcheck disable=SC2329
get_current_profile_preset() {
    local preset="$DEFAULT_CORE_PROFILE_PRESET"
    if [ -f "$CORE_PROFILE_META" ]; then
        local meta_preset=""
        meta_preset=$(grep '^CORE_PROFILE_PRESET=' "$CORE_PROFILE_META" 2>/dev/null | head -1 | cut -d'"' -f2)
        [ -n "$meta_preset" ] && preset="$meta_preset"
    fi
    case "$preset" in
        default|iran-optimized) ;;
        *) preset="$DEFAULT_CORE_PROFILE_PRESET" ;;
    esac
    echo "$preset"
}

# shellcheck disable=SC2329
get_profile_preset_label() {
    local preset="${1:-$(get_current_profile_preset)}"
    case "$preset" in
        default) echo "Current Default (PaqX-style baseline)" ;;
        iran-optimized) echo "Iran Optimized (ENOBUFS recovery, FEC off, MTU 1300, window 1536)" ;;
        *) echo "Unknown ($preset)" ;;
    esac
}

# shellcheck disable=SC2329
set_current_profile_preset() {
    local preset="$1"
    ensure_paqet_dir_permissions
    cat > "$CORE_PROFILE_META" << EOF
# recoba-tunnel profile preset metadata
CORE_META_UPDATED_AT="$(date -Iseconds 2>/dev/null || date)"
EOF
    secure_file_permissions "$CORE_META" 600
}

sanitize_cache_component() {
    local value="$1"
    value=${value//\//_}
    value=${value// /_}
    value=${value//:/_}
    printf '%s\n' "$value"
}

get_core_archive_cache_path() {
    local version="$1"
    local archive_name="$2"
    local safe_version=""
    safe_version=$(sanitize_cache_component "$version")
    printf '%s/%s/%s\n' "$CORE_CACHE_ARCHIVE_DIR" "$safe_version" "$archive_name"
}

# shellcheck disable=SC2329
get_current_profile_preset() {
    local preset="$DEFAULT_CORE_PROFILE_PRESET"
    if [ -f "$CORE_PROFILE_META" ]; then
        local meta_preset=""
        meta_preset=$(grep '^CORE_PROFILE_PRESET=' "$CORE_PROFILE_META" 2>/dev/null | head -1 | cut -d'"' -f2)
        [ -n "$meta_preset" ] && preset="$meta_preset"
    fi
    case "$preset" in
        default|iran-optimized) ;;
        *) preset="$DEFAULT_CORE_PROFILE_PRESET" ;;
    esac
    echo "$preset"
}

# shellcheck disable=SC2329
get_profile_preset_label() {
    local preset="${1:-$(get_current_profile_preset)}"
    case "$preset" in
        default) echo "Default (auto-tuned)" ;;
        iran-optimized) echo "Iran Optimized (FEC off, MTU 1300, window 1536)" ;;
        *) echo "Unknown ($preset)" ;;
    esac
}

# shellcheck disable=SC2329
set_current_profile_preset() {
    local preset="$1"
    ensure_paqet_dir_permissions
    cat > "$CORE_PROFILE_META" << EOF
# recoba-tunnel profile preset metadata
CORE_PROFILE_PRESET="${preset}"
UPDATED_AT="$(date -Iseconds 2>/dev/null || date)"
EOF
    secure_file_permissions "$CORE_PROFILE_META" 600
}

load_active_profile_preset_defaults() {
    local preset="${1:-}"
    [ -z "$preset" ] && preset=$(get_current_profile_preset)

    PROFILE_PRESET_NAME="$preset"
    PROFILE_PRESET_LABEL="$(get_profile_preset_label "$preset")"
    PROFILE_PRESET_KCP_BLOCK="aes"
    PROFILE_PRESET_KCP_MTU="$DEFAULT_KCP_MTU"
    PROFILE_PRESET_TRANSPORT_TCPBUF=""
    PROFILE_PRESET_TRANSPORT_UDPBUF=""
    PROFILE_PRESET_PCAP_SOCKBUF_SERVER=""
    PROFILE_PRESET_PCAP_SOCKBUF_CLIENT=""

    case "$preset" in
        iran-optimized)
            PROFILE_PRESET_KCP_BLOCK="aes"
            PROFILE_PRESET_KCP_MTU="$DEFAULT_KCP_MTU"
            PROFILE_PRESET_TRANSPORT_TCPBUF=""
            PROFILE_PRESET_TRANSPORT_UDPBUF=""
            PROFILE_PRESET_PCAP_SOCKBUF_SERVER=""
            PROFILE_PRESET_PCAP_SOCKBUF_CLIENT=""
            ;;
    esac
}

build_profile_transport_buffer_fragment() {
    local varname="$1"
    load_active_profile_preset_defaults

    local fragment=""
    [ -n "$PROFILE_PRESET_TRANSPORT_TCPBUF" ] && fragment="${fragment}
  tcpbuf: ${PROFILE_PRESET_TRANSPORT_TCPBUF}"
    [ -n "$PROFILE_PRESET_TRANSPORT_UDPBUF" ] && fragment="${fragment}
  udpbuf: ${PROFILE_PRESET_TRANSPORT_UDPBUF}"

    printf -v "$varname" '%s' "$fragment"
}

build_profile_network_pcap_fragment() {
    local role="$1"   # server or client
    local varname="$2"
    load_active_profile_preset_defaults

    local sockbuf=""
    if [ "$role" = "server" ]; then
        sockbuf="$PROFILE_PRESET_PCAP_SOCKBUF_SERVER"
    else
        sockbuf="$PROFILE_PRESET_PCAP_SOCKBUF_CLIENT"
    fi

    local fragment=""
    if [ -n "$sockbuf" ]; then
        fragment="  pcap:
    sockbuf: ${sockbuf}"
    fi

    printf -v "$varname" '%s' "$fragment"
}

get_effective_profile_kcp_block() {
    load_active_profile_preset_defaults
    echo "$PROFILE_PRESET_KCP_BLOCK"
}

get_effective_profile_kcp_mtu() {
    load_active_profile_preset_defaults
    if true && [ -n "$AUTO_TUNE_KCP_MTU" ]; then
        echo "$AUTO_TUNE_KCP_MTU"
        return 0
    fi
    echo "$PROFILE_PRESET_KCP_MTU"
}

get_effective_profile_kcp_mode() {
    load_active_profile_preset_defaults
    if true && [ -n "$AUTO_TUNE_KCP_MODE" ]; then
        echo "$AUTO_TUNE_KCP_MODE"
        return 0
    fi
    echo "$DEFAULT_KCP_MODE"
}


get_effective_profile_conn_value() {
    load_active_profile_preset_defaults
    if false; then
        echo "${AUTO_TUNE_CONN:-$(calculate_minimal_preset_adaptive_conn "$(detect_total_mem_mb)" "$(detect_cpu_cores)")}"
    else
        echo "$AUTO_TUNE_CONN"
    fi
}

build_profile_kcp_extra_fragment() {
    local varname="$1"
    load_active_profile_preset_defaults

    # Behzad preset intentionally keeps KCP config minimal (mode/key/block/mtu + conn)
    # and avoids PaqX CPU/RAM window/FEC/smux auto tuning.
    if false; then
        printf -v "$varname" '%s' ""
        return 0
    fi

    local fragment="    nodelay: 1
    interval: 10
    resend: 2
    nocongestion: 0
    wdelay: false
    acknodelay: true
    rcvwnd: ${AUTO_TUNE_RCVWND}
    sndwnd: ${AUTO_TUNE_SNDWND}
    smuxbuf: ${AUTO_TUNE_SMUXBUF}
    streambuf: ${AUTO_TUNE_STREAMBUF}
    dshard: ${DEFAULT_KCP_DSHARD}
    pshard: ${DEFAULT_KCP_PSHARD}"
    printf -v "$varname" '%s' "$fragment"
}

remove_paqx_kcp_tuning_keys() {
    local config_file="$1"

    # Remove PaqX-specific KCP tuning keys so non-PaqX presets (e.g., Behzad) stay clean/minimal.
    sed_inplace \
        -e '/^[[:space:]]*nodelay:[[:space:]]*/d' \
        -e '/^[[:space:]]*interval:[[:space:]]*/d' \
        -e '/^[[:space:]]*resend:[[:space:]]*/d' \
        -e '/^[[:space:]]*nocongestion:[[:space:]]*/d' \
        -e '/^[[:space:]]*wdelay:[[:space:]]*/d' \
        -e '/^[[:space:]]*acknodelay:[[:space:]]*/d' \
        -e '/^[[:space:]]*rcvwnd:[[:space:]]*/d' \
        -e '/^[[:space:]]*sndwnd:[[:space:]]*/d' \
        -e '/^[[:space:]]*smuxbuf:[[:space:]]*/d' \
        -e '/^[[:space:]]*streambuf:[[:space:]]*/d' \
        -e '/^[[:space:]]*dshard:[[:space:]]*/d' \
        -e '/^[[:space:]]*pshard:[[:space:]]*/d' \
        "$config_file"
}

#===============================================================================
# PaqX-style Auto Tuning (CPU/RAM + kernel sysctl)
#===============================================================================

AUTO_TUNE_CPU_CORES="1"
AUTO_TUNE_MEM_MB="0"
AUTO_TUNE_HW_CLASS="unknown"
AUTO_TUNE_CONN="$DEFAULT_KCP_CONN"
AUTO_TUNE_SNDWND="1024"
AUTO_TUNE_RCVWND="1024"
AUTO_TUNE_SMUXBUF="4194304"
AUTO_TUNE_STREAMBUF="2097152"
AUTO_TUNE_KCP_MODE="$DEFAULT_KCP_MODE"
AUTO_TUNE_KCP_MTU="$DEFAULT_KCP_MTU"

detect_total_mem_mb() {
    local total_mem=""
    if command -v free >/dev/null 2>&1; then
        total_mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    fi
    if [ -z "$total_mem" ] && [ -r /proc/meminfo ]; then
        total_mem=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    fi
    [ -z "$total_mem" ] && total_mem="0"
    echo "$total_mem"
}

detect_cpu_cores() {
    local cpu_cores=""
    if command -v nproc >/dev/null 2>&1; then
        cpu_cores=$(nproc 2>/dev/null)
    fi
    [ -z "$cpu_cores" ] && cpu_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    [ -z "$cpu_cores" ] && cpu_cores="1"
    echo "$cpu_cores"
}

is_positive_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

detect_interface_mtu() {
    local iface="${1:-}"
    [ -z "$iface" ] && return 1
    ip -o link show dev "$iface" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") {print $(i+1); exit}}'
}

calculate_safe_kcp_mtu() {
    local profile_mtu="${1:-$DEFAULT_KCP_MTU}"
    local interface_mtu="${2:-}"

    if ! is_positive_integer "$profile_mtu"; then
        profile_mtu="$DEFAULT_KCP_MTU"
    fi

    local safe_mtu="$profile_mtu"
    if is_positive_integer "$interface_mtu"; then
        local interface_ceiling=$((interface_mtu - KCP_MTU_HEADROOM))
        if [ "$interface_ceiling" -lt "$safe_mtu" ]; then
            safe_mtu="$interface_ceiling"
        fi
    fi

    if [ "$safe_mtu" -gt "$KCP_MTU_MAX" ]; then
        safe_mtu="$KCP_MTU_MAX"
    fi
    if [ "$safe_mtu" -lt "$KCP_MTU_MIN" ]; then
        safe_mtu="$KCP_MTU_MIN"
    fi

    echo "$safe_mtu"
}

cap_positive_integer_value() {
    local value="${1:-}"
    local cap="${2:-}"

    if ! is_positive_integer "$value"; then
        echo "$cap"
        return 0
    fi

    if is_positive_integer "$cap" && [ "$value" -gt "$cap" ]; then
        echo "$cap"
        return 0
    fi

    echo "$value"
}

apply_low_mtu_upload_stability_profile() {
    local interface_mtu="${1:-}"

    if false; then
        return 0
    fi

    if ! is_positive_integer "$interface_mtu" || [ "$interface_mtu" -gt "$LOW_MTU_PROFILE_THRESHOLD" ]; then
        return 0
    fi

    AUTO_TUNE_CONN=$(cap_positive_integer_value "${AUTO_TUNE_CONN:-$DEFAULT_KCP_CONN}" "$LOW_MTU_PROFILE_CONN")
    AUTO_TUNE_SNDWND=$(cap_positive_integer_value "${AUTO_TUNE_SNDWND:-$LOW_MTU_PROFILE_SNDWND}" "$LOW_MTU_PROFILE_SNDWND")
    AUTO_TUNE_RCVWND=$(cap_positive_integer_value "${AUTO_TUNE_RCVWND:-$LOW_MTU_PROFILE_RCVWND}" "$LOW_MTU_PROFILE_RCVWND")
    AUTO_TUNE_SMUXBUF=$(cap_positive_integer_value "${AUTO_TUNE_SMUXBUF:-$LOW_MTU_PROFILE_SMUXBUF}" "$LOW_MTU_PROFILE_SMUXBUF")
    AUTO_TUNE_STREAMBUF=$(cap_positive_integer_value "${AUTO_TUNE_STREAMBUF:-$LOW_MTU_PROFILE_STREAMBUF}" "$LOW_MTU_PROFILE_STREAMBUF")
}

get_effective_profile_kcp_mtu_for_interface() {
    local iface="${1:-}"
    local profile_mtu
    local interface_mtu=""

    profile_mtu=$(get_effective_profile_kcp_mtu)
    if [ -n "$iface" ]; then
        interface_mtu=$(detect_interface_mtu "$iface" 2>/dev/null || true)
    fi

    calculate_safe_kcp_mtu "$profile_mtu" "$interface_mtu"
}

classify_server_hardware() {
    local mem_mb="${1:-0}"
    local cpu_cores="${2:-1}"

    if [ "$cpu_cores" -le 1 ] || [ "$mem_mb" -le 1024 ]; then
        echo "low"
    elif [ "$cpu_cores" -le 2 ] || [ "$mem_mb" -le 4096 ]; then
        echo "mid"
    else
        echo "high"
    fi
}

calculate_minimal_preset_adaptive_conn() {
    local mem_mb="${1:-0}"
    local cpu_cores="${2:-1}"

    # Minimal presets (e.g., Behzad) still need hardware-aware concurrency.
    # Weak VPSes choke under burst traffic with conn=4.
    if [ "$cpu_cores" -le 1 ] || [ "$mem_mb" -le 1536 ]; then
        echo "1"
    elif [ "$cpu_cores" -le 2 ] || [ "$mem_mb" -le 4096 ]; then
        echo "2"
    else
        echo "4"
    fi
}


calculate_auto_kcp_profile() {
    if false; then
        # Behzad preset stays minimal/no-mixing, but conn should still be
        # hardware-aware so weak VPSes don't get overloaded.
        true # behzad removed
        return 0
    fi

    calculate_paqx_auto_kcp_profile
}

calculate_paqx_auto_kcp_profile() {
    AUTO_TUNE_MEM_MB=$(detect_total_mem_mb)
    AUTO_TUNE_CPU_CORES=$(detect_cpu_cores)
    AUTO_TUNE_HW_CLASS=$(classify_server_hardware "$AUTO_TUNE_MEM_MB" "$AUTO_TUNE_CPU_CORES")

    # Hardware-aware defaults (favor stability on low-end VPS, throughput on larger boxes).
    AUTO_TUNE_CONN="$DEFAULT_KCP_CONN"
    AUTO_TUNE_SNDWND="1024"
    AUTO_TUNE_RCVWND="1024"
    AUTO_TUNE_SMUXBUF="4194304"
    AUTO_TUNE_STREAMBUF="2097152"
    AUTO_TUNE_KCP_MODE="$DEFAULT_KCP_MODE"
    AUTO_TUNE_KCP_MTU="$DEFAULT_KCP_MTU"

    if [ "$AUTO_TUNE_CPU_CORES" -le 1 ] || [ "$AUTO_TUNE_MEM_MB" -le 1024 ]; then
        # Low-end VPS profile: favor stability under burst traffic while keeping
        # usable throughput. This matches the live-tested behavior on 1c/1GB nodes.
        AUTO_TUNE_CONN="2"
        AUTO_TUNE_SNDWND="1024"
        AUTO_TUNE_RCVWND="1024"
        AUTO_TUNE_SMUXBUF="4194304"
        AUTO_TUNE_STREAMBUF="2097152"
        AUTO_TUNE_KCP_MODE="normal"
        AUTO_TUNE_KCP_MTU="1200"

        if [ "$AUTO_TUNE_MEM_MB" -le 768 ]; then
            AUTO_TUNE_CONN="1"
            AUTO_TUNE_SNDWND="256"
            AUTO_TUNE_RCVWND="256"
            AUTO_TUNE_SMUXBUF="1048576"
            AUTO_TUNE_STREAMBUF="524288"
            AUTO_TUNE_KCP_MTU="1150"
        fi
    elif [ "$AUTO_TUNE_CPU_CORES" -le 2 ] || [ "$AUTO_TUNE_MEM_MB" -le 4096 ]; then
        AUTO_TUNE_CONN="2"
        AUTO_TUNE_SNDWND="2048"
        AUTO_TUNE_RCVWND="2048"
        AUTO_TUNE_SMUXBUF="4194304"
        AUTO_TUNE_STREAMBUF="2097152"
        AUTO_TUNE_KCP_MODE="fast"
        AUTO_TUNE_KCP_MTU="1250"
    else
        AUTO_TUNE_CONN="4"
        AUTO_TUNE_SNDWND="4096"
        AUTO_TUNE_RCVWND="4096"
        AUTO_TUNE_SMUXBUF="4194304"
        AUTO_TUNE_STREAMBUF="2097152"
        AUTO_TUNE_KCP_MODE="fast"
        AUTO_TUNE_KCP_MTU="$DEFAULT_KCP_MTU"
    fi

    return 0
}

show_auto_kcp_profile() {
    load_active_profile_preset_defaults
    echo -e "${YELLOW}Active KCP Profile Preview:${NC}"
    echo -e "  Profile preset:    ${CYAN}${PROFILE_PRESET_NAME}${NC} (${PROFILE_PRESET_LABEL})"
    echo -e "  CPU cores:        ${CYAN}${AUTO_TUNE_CPU_CORES}${NC}"
    echo -e "  RAM:              ${CYAN}${AUTO_TUNE_MEM_MB} MB${NC}"
    echo -e "  HW class:         ${CYAN}${AUTO_TUNE_HW_CLASS}${NC}"
    if false; then
        echo -e "  KCP mode:         ${CYAN}${DEFAULT_KCP_MODE}${NC}"
    else
        echo -e "  KCP mode:         ${CYAN}${AUTO_TUNE_KCP_MODE:-$DEFAULT_KCP_MODE}${NC}"
    fi
    if false; then
        echo -e "  KCP conn:         ${CYAN}${AUTO_TUNE_CONN}${NC} (Behzad minimal + hardware-adaptive)"
    else
        echo -e "  KCP conn:         ${CYAN}${AUTO_TUNE_CONN}${NC} (PaqX CPU/RAM auto-tune)"
    fi
    if false; then
        echo -e "  KCP mtu:          ${CYAN}${PROFILE_PRESET_KCP_MTU}${NC}"
    else
        echo -e "  KCP mtu:          ${CYAN}${AUTO_TUNE_KCP_MTU:-$PROFILE_PRESET_KCP_MTU}${NC}"
    fi
    echo -e "  KCP block:        ${CYAN}${PROFILE_PRESET_KCP_BLOCK}${NC}"
    if false; then
        echo -e "  KCP rcvwnd/sndwnd ${CYAN}paqet core defaults (not forced)${NC}"
    else
        echo -e "  KCP rcvwnd/sndwnd ${CYAN}${AUTO_TUNE_RCVWND}/${AUTO_TUNE_SNDWND}${NC}"
    fi
    echo ""
}

apply_paqx_kernel_optimizations() {
    print_step "Applying PaqX-style kernel optimization (BBR/TFO/socket buffers)..."

    # RAM-aware kernel tuning to reduce ENOBUFS/burst drops without overcommitting
    # small VPS instances. These are generic transport-level improvements and do
    # not change tunnel ports/IPs/config mappings.
    calculate_auto_kcp_profile >/dev/null 2>&1 || true
    local mem_mb="${AUTO_TUNE_MEM_MB:-0}"
    local netdev_backlog="65536"
    local sock_max="33554432"
    local sock_default="16777216"
    local tcp_buf_max="33554432"
    local udp_mem_triplet="32768 49152 65536"
    local udp_min="16384"
    local optmem_max="8388608"
    local netdev_budget="300"
    local netdev_budget_usecs="2000"
    local tcp_limit_output_bytes="1048576"
    local tcp_notsent_lowat="4294967295"
    local fq_limit="10000"
    local fq_flow_limit="$OPTIMIZED_FQ_FLOW_LIMIT"

    if [ "$mem_mb" -ge 4096 ]; then
        netdev_backlog="250000"
        sock_max="134217728"
        sock_default="33554432"
        tcp_buf_max="134217728"
        udp_mem_triplet="90219 120292 180438"
        udp_min="65536"
        optmem_max="25165824"
        netdev_budget="800"
        netdev_budget_usecs="8000"
        tcp_limit_output_bytes="1048576"
        tcp_notsent_lowat="262144"
        fq_limit="50000"
        fq_flow_limit="1000"
    elif [ "$mem_mb" -ge 2048 ]; then
        netdev_backlog="131072"
        sock_max="67108864"
        sock_default="16777216"
        tcp_buf_max="67108864"
        udp_mem_triplet="65536 98304 131072"
        udp_min="65536"
        optmem_max="16777216"
        netdev_budget="700"
        netdev_budget_usecs="8000"
        tcp_limit_output_bytes="524288"
        tcp_notsent_lowat="131072"
        fq_limit="50000"
        fq_flow_limit="1000"
    else
        # Small VPS burst-smoothing defaults (validated on 1c/1GB nodes).
        netdev_budget="600"
        netdev_budget_usecs="8000"
        tcp_limit_output_bytes="262144"
        tcp_notsent_lowat="65536"
        fq_limit="50000"
        fq_flow_limit="1000"
    fi

    if is_dry_run; then
        dry_run_notice "would write kernel optimization file: $OPTIMIZE_SYSCTL_FILE"
        dry_run_notice "would run: sysctl --system"
        dry_run_notice "would run: tc qdisc replace dev <default-interface> root fq limit ${fq_limit} flow_limit ${fq_flow_limit}"
        print_success "DRY-RUN: kernel optimization not applied"
        return 0
    fi

    mkdir -p /etc/sysctl.d
    cat > "$OPTIMIZE_SYSCTL_FILE" << EOF
# paqet-tunnel kernel optimizations (PaqX-style) - safe to remove
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
fs.file-max=1000000
net.core.netdev_max_backlog=${netdev_backlog}
net.core.optmem_max=${optmem_max}
net.core.rmem_max=${sock_max}
net.core.wmem_max=${sock_max}
net.core.rmem_default=${sock_default}
net.core.wmem_default=${sock_default}
net.ipv4.tcp_rmem=4096 87380 ${tcp_buf_max}
net.ipv4.tcp_wmem=4096 65536 ${tcp_buf_max}
net.core.netdev_budget=${netdev_budget}
net.core.netdev_budget_usecs=${netdev_budget_usecs}
net.ipv4.tcp_limit_output_bytes=${tcp_limit_output_bytes}
net.ipv4.tcp_notsent_lowat=${tcp_notsent_lowat}
net.ipv4.udp_mem=${udp_mem_triplet}
net.ipv4.udp_rmem_min=${udp_min}
net.ipv4.udp_wmem_min=${udp_min}
EOF

    if sysctl --system >/dev/null 2>&1; then
        print_success "Kernel optimization applied via $OPTIMIZE_SYSCTL_FILE"
        print_info "Kernel burst profile: RAM=${mem_mb}MB backlog=${netdev_backlog} sockmax=${sock_max} udp_mem='${udp_mem_triplet}'"
    else
        print_warning "sysctl reload reported an issue (file was still written to $OPTIMIZE_SYSCTL_FILE)"
    fi

    if command -v tc >/dev/null 2>&1; then
        local qdisc_if=""
        qdisc_if=$(get_default_interface 2>/dev/null || true)
        if [ -n "$qdisc_if" ]; then
            if tc qdisc replace dev "$qdisc_if" root fq limit "${fq_limit}" flow_limit "${fq_flow_limit}" >/dev/null 2>&1; then
                print_info "Applied fq burst queue tuning on ${qdisc_if} (limit=${fq_limit}, flow_limit=${fq_flow_limit})"
            else
                print_warning "Could not apply fq burst queue tuning on ${qdisc_if} (tc qdisc replace failed)"
            fi
        fi
    fi
}

#===============================================================================
# Interface-Level Tuning Persistence (MTU, txqueuelen, flow_limit, MSS clamp)
#===============================================================================

apply_optimized_interface_tuning() {
    local iface="$1"
    local target_mtu="${2:-$OPTIMIZED_IFACE_MTU}"
    local target_txqueuelen="${3:-$OPTIMIZED_TXQUEUELEN}"
    local target_flow_limit="${4:-$OPTIMIZED_FQ_FLOW_LIMIT}"

    [ -z "$iface" ] && iface=$(get_default_interface 2>/dev/null || true)
    [ -z "$iface" ] && { print_warning "No interface detected for tuning"; return 1; }

    if is_dry_run; then
        dry_run_notice "would apply interface tuning on $iface: MTU=${target_mtu} txqueuelen=${target_txqueuelen} flow_limit=${target_flow_limit}"
        dry_run_notice "would persist settings via /etc/rc.local"
        return 0
    fi

    local current_mtu=""
    current_mtu=$(detect_interface_mtu "$iface" 2>/dev/null || true)

    # Validate PMTU before applying if target > current
    if [ -n "$current_mtu" ] && [ "$target_mtu" -gt "$current_mtu" ]; then
        print_step "PMTU validation for MTU ${target_mtu} on ${iface}..."
        # Quick PMTU check against gateway
        local gw=""
        gw=$(ip route get 8.8.8.8 2>/dev/null | grep -oE 'via [0-9.]+' | awk '{print $2}' | head -1 || true)
        if [ -n "$gw" ]; then
            local pmtu_opt="do"
            if ping -4 -M "${pmtu_opt}" -c 1 -W 2 -s $((target_mtu - 28)) "$gw" >/dev/null 2>&1; then
                print_success "PMTU ${target_mtu} verified on ${iface}"
            else
                print_warning "PMTU ${target_mtu} may not be supported (path blocked larger MTU)"
                print_info "Falling back to safer MTU 1300"
                target_mtu=1300
            fi
        else
            print_info "No gateway detected; applying MTU ${target_mtu} (verify manually if needed)"
        fi
    fi

    # Apply MTU
    if ip link set dev "$iface" mtu "$target_mtu" 2>/dev/null; then
        print_success "Interface MTU set to ${target_mtu} on ${iface}"
    else
        print_warning "Could not set MTU ${target_mtu} on ${iface}"
    fi

    # Apply txqueuelen
    if ip link set dev "$iface" txqueuelen "$target_txqueuelen" 2>/dev/null; then
        print_success "txqueuelen set to ${target_txqueuelen} on ${iface}"
    fi

    # Apply fq flow_limit
    if command -v tc >/dev/null 2>&1; then
        if tc qdisc replace dev "$iface" root fq flow_limit "${target_flow_limit}" >/dev/null 2>&1; then
            print_success "fq flow_limit set to ${target_flow_limit}p on ${iface}"
        fi
    fi

    # Apply MSS clamp
    apply_mss_clamp_rule
    print_success "MSS clamp applied"

    # Persist via rc.local
    persist_interface_tuning "$iface" "$target_mtu" "$target_txqueuelen" "$target_flow_limit"

    return 0
}

persist_interface_tuning() {
    local iface="$1"
    local mtu="$2"
    local txqueuelen="$3"
    local flow_limit="$4"

    if is_dry_run; then
        dry_run_notice "would persist interface tuning to /etc/rc.local"
        return 0
    fi

    if [ ! -f /etc/rc.local ]; then
        echo "#!/bin/bash" | tee /etc/rc.local >/dev/null 2>&1 || {
            print_warning "Cannot create /etc/rc.local (permission denied)"
            return 1
        }
        chmod +x /etc/rc.local 2>/dev/null || true
    fi

    local need_update=false
    grep -q "ip link set dev ${iface} mtu" /etc/rc.local 2>/dev/null || need_update=true
    grep -q "ip link set dev ${iface} txqueuelen" /etc/rc.local 2>/dev/null || need_update=true
    grep -q "tc qdisc replace dev ${iface} root fq" /etc/rc.local 2>/dev/null || need_update=true

    if [ "$need_update" = true ]; then
        # Remove any previous entries for this interface to avoid duplication
        sed -i "/ip link set dev ${iface} mtu/d" /etc/rc.local 2>/dev/null || true
        sed -i "/ip link set dev ${iface} txqueuelen/d" /etc/rc.local 2>/dev/null || true
        sed -i "/tc qdisc replace dev ${iface} root fq/d" /etc/rc.local 2>/dev/null || true

        cat >> /etc/rc.local << EOF
# paqet-tunnel: persist interface tuning for ${iface}
ip link set dev ${iface} mtu ${mtu}
ip link set dev ${iface} txqueuelen ${txqueuelen}
tc qdisc replace dev ${iface} root fq flow_limit ${flow_limit} 2>/dev/null || true
EOF
        print_success "Interface tuning persisted in /etc/rc.local"
    else
        print_info "Interface tuning already persisted in /etc/rc.local"
    fi
}

#===============================================================================
# Input Validation Functions (with retry on invalid input)
#===============================================================================

# Read required input - keeps asking until valid input is provided
# Usage: read_required "prompt" "variable_name" ["default_value"]
read_required() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        read -r -p "> " value < /dev/tty
        
        # Use default if provided and input is empty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        
        # Validate non-empty
        if [ -n "$value" ]; then
            assign_var "$varname" "$value"
            return 0
        else
            print_error "This field is required. Please enter a value."
            echo ""
        fi
    done
}

# Read IP address with validation
# Usage: read_ip "prompt" "variable_name" ["default_value"]
read_ip() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        read -r -p "> " value < /dev/tty
        
        # Use default if provided and input is empty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        
        # Validate IP format
        if [ -z "$value" ]; then
            print_error "IP address is required. Please enter a valid IP."
            echo ""
        elif ! [[ "$value" =~ $ip_regex ]]; then
            print_error "Invalid IP format. Please enter a valid IPv4 address (e.g., 192.168.1.1)"
            echo ""
        else
            assign_var "$varname" "$value"
            return 0
        fi
    done
}

# Read port number with validation
# Usage: read_port "prompt" "variable_name" ["default_value"]
read_port() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        read -r -p "> " value < /dev/tty
        
        # Use default if provided and input is empty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        
        # Validate port number
        if [ -z "$value" ]; then
            print_error "Port number is required."
            echo ""
        elif ! [[ "$value" =~ ^[0-9]+$ ]]; then
            print_error "Invalid port. Please enter a number."
            echo ""
        elif [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
            print_error "Port must be between 1 and 65535."
            echo ""
        else
            assign_var "$varname" "$value"
            return 0
        fi
    done
}

# Read port list with validation (comma-separated)
# Usage: read_ports "prompt" "variable_name" ["default_value"]
read_ports() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        read -r -p "> " value < /dev/tty
        
        # Use default if provided and input is empty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        
        # Validate port list
        if [ -z "$value" ]; then
            print_error "At least one port is required."
            echo ""
            continue
        fi
        
        # Validate each port in the comma-separated list
        local valid=true
        IFS=',' read -ra ports <<< "$value"
        for port in "${ports[@]}"; do
            port=$(echo "$port" | tr -d ' ')
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                print_error "Invalid port: $port. Each port must be a number between 1-65535."
                valid=false
                break
            fi
        done
        
        if [ "$valid" = true ]; then
            assign_var "$varname" "$value"
            return 0
        fi
        echo ""
    done
}

# Parse and validate forward mapping list (Server A)
# Supports:
#   443                -> listen 443, target 443, tcp
#   8443:443           -> listen 8443, target 443, tcp
#   51820/udp          -> listen 51820, target 51820, udp
#   1090:443/tcp       -> listen 1090, target 443, tcp
#   1090:443/udp       -> listen 1090, target 443, udp
#   443,51820/udp      -> mixed entries
# Returns normalized CSV (duplicates removed by validation):
#   443,51820/udp,8443:443/udp
normalize_forward_mappings_input() {
    local raw_input="$1"
    local varname="$2"
    local default_protocol="${3:-tcp}"
    local normalized_input=""
    local normalized_output=""

    # Accept commas and/or spaces as separators
    normalized_input=$(echo "$raw_input" | tr '[:space:]' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')

    if [ -z "$normalized_input" ]; then
        print_error "At least one forward port or mapping is required."
        return 1
    fi

    local seen_keys=""
    local item=""

    IFS=',' read -ra items <<< "$normalized_input"
    for item in "${items[@]}"; do
        item=$(echo "$item" | tr -d ' ')
        [ -z "$item" ] && continue

        local listen_port=""
        local target_port=""
        local protocol="$default_protocol"

        # Optional protocol suffix (/tcp or /udp)
        if [[ "$item" =~ ^(.+)/(tcp|udp)$ ]]; then
            item="${BASH_REMATCH[1]}"
            protocol="${BASH_REMATCH[2]}"
        fi

        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            listen_port="${BASH_REMATCH[1]}"
            target_port="${BASH_REMATCH[2]}"
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            listen_port="$item"
            target_port="$item"
        else
            print_error "Invalid mapping: $item (use PORT or LISTEN:TARGET, optionally /tcp or /udp)"
            return 1
        fi

        if [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then
            print_error "Invalid listen port: $listen_port (must be 1-65535)"
            return 1
        fi
        if [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
            print_error "Invalid target port: $target_port (must be 1-65535)"
            return 1
        fi

        local seen_key="${protocol}:${listen_port}"
        if echo " $seen_keys " | grep -qw "$seen_key"; then
            print_error "Duplicate listen/protocol pair: ${listen_port}/${protocol}"
            return 1
        fi
        seen_keys="${seen_keys} ${seen_key}"

        local spec="$listen_port"
        [ "$listen_port" != "$target_port" ] && spec="${listen_port}:${target_port}"
        [ "$protocol" = "udp" ] && spec="${spec}/udp"
        normalized_output="${normalized_output:+$normalized_output,}$spec"
    done

    if [ -z "$normalized_output" ]; then
        print_error "No valid forward ports/mappings were provided."
        return 1
    fi

    printf -v "$varname" '%s' "$normalized_output"
    return 0
}

read_forward_mappings() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local default_protocol="${4:-tcp}"
    local value=""

    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        if [ "$default_protocol" = "udp" ]; then
            echo -e "${CYAN}Format:${NC} 51820 (same UDP), 1090:443, or 1090:443/udp"
        else
            echo -e "${CYAN}Format:${NC} 443 (same TCP), 8443:443, 8443:443/tcp, or append /udp for UDP"
        fi
        read -r -p "> " value < /dev/tty

        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi

        local normalized_mappings=""
        if normalize_forward_mappings_input "$value" normalized_mappings "$default_protocol"; then
            if [ -z "$normalized_mappings" ]; then
                print_error "Internal error: normalized forward mappings are empty."
                echo ""
                continue
            fi
            printf -v "$varname" '%s' "$normalized_mappings"
            return 0
        fi
        echo ""
    done
}

mapping_listen_port() {
    local spec="$1"
    spec="${spec%%/*}"
    echo "${spec%%:*}"
}

mapping_target_port() {
    local spec="$1"
    spec="${spec%%/*}"
    if [[ "$spec" == *:* ]]; then
        echo "${spec##*:}"
    else
        echo "${spec%%:*}"
    fi
}

mapping_protocol() {
    local spec="$1"
    if [[ "$spec" == */udp ]]; then
        echo "udp"
    else
        echo "tcp"
    fi
}

build_forward_config_from_mappings_csv() {
    local mappings_csv="$1"
    local varname="$2"
    local rendered_forward_config=""
    local spec=""

    IFS=',' read -ra mapping_specs <<< "$mappings_csv"
    for spec in "${mapping_specs[@]}"; do
        spec=$(echo "$spec" | tr -d ' ')
        [ -z "$spec" ] && continue

        local listen_port
        local target_port
        local protocol
        listen_port=$(mapping_listen_port "$spec")
        target_port=$(mapping_target_port "$spec")
        protocol=$(mapping_protocol "$spec")

        rendered_forward_config="${rendered_forward_config}
  - listen: \"0.0.0.0:${listen_port}\"
    target: \"127.0.0.1:${target_port}\"
    protocol: \"${protocol}\""
    done

    if [ -z "$rendered_forward_config" ]; then
        return 1
    fi

    printf -v "$varname" '%s' "$rendered_forward_config"
    return 0
}

# Read MAC address with validation
# Usage: read_mac "prompt" "variable_name" ["default_value"]
read_mac() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    local mac_regex='^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
    
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        read -r -p "> " value < /dev/tty
        
        # Use default if provided and input is empty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        
        # Validate MAC format
        if [ -z "$value" ]; then
            print_error "MAC address is required."
            echo ""
        elif ! [[ "$value" =~ $mac_regex ]]; then
            print_error "Invalid MAC format. Please use format: aa:bb:cc:dd:ee:ff"
            echo ""
        else
            assign_var "$varname" "$value"
            return 0
        fi
    done
}

# Read yes/no confirmation
# Usage: read_confirm "prompt" "variable_name" ["default_y_or_n"]
read_confirm() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    
    while true; do
        if [ "$default" = "y" ]; then
            echo -e "${YELLOW}${prompt} (Y/n):${NC}"
        elif [ "$default" = "n" ]; then
            echo -e "${YELLOW}${prompt} (y/N):${NC}"
        else
            echo -e "${YELLOW}${prompt} (y/n):${NC}"
        fi
        read -r -p "> " value < /dev/tty
        
        # Use default if input is empty and default is provided
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        
        case "$value" in
            [Yy]|[Yy][Ee][Ss]) assign_var "$varname" "true"; return 0 ;;
            [Nn]|[Nn][Oo]) assign_var "$varname" "false"; return 0 ;;
            *) print_error "Please enter 'y' for yes or 'n' for no."; echo "" ;;
        esac
    done
}

# Read optional input - allows empty value
# Usage: read_optional "prompt" "variable_name" ["default_value"]
read_optional() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    
    if [ -n "$default" ]; then
        echo -e "${YELLOW}${prompt} [${default}]:${NC}"
    else
        echo -e "${YELLOW}${prompt} (optional):${NC}"
    fi
    read -r -p "> " value < /dev/tty
    
    # Use default if input is empty
    if [ -z "$value" ] && [ -n "$default" ]; then
        value="$default"
    fi
    
    assign_var "$varname" "$value"
}

#===============================================================================
# Multi-Tunnel Helper Functions
#===============================================================================

is_valid_tunnel_name() {
    local value="$1"
    local name_regex='^[a-z0-9][a-z0-9-]*$'

    [ -n "$value" ] || return 1
    [[ "$value" =~ $name_regex ]] || return 1
    [ "${#value}" -le 32 ] || return 1
}

# Read and validate tunnel name
# Usage: read_tunnel_name "prompt" "variable_name" ["default_value"]
read_tunnel_name() {
    local prompt="$1"
    local varname="$2"
    local default="$3"
    local value=""
    
    while true; do
        if [ -n "$default" ]; then
            echo -e "${YELLOW}${prompt} [${default}]:${NC}"
        else
            echo -e "${YELLOW}${prompt}:${NC}"
        fi
        echo -e "${CYAN}(lowercase, alphanumeric and hyphens only, e.g., usa, germany, server-1)${NC}"
        read -r -p "> " value < /dev/tty
        
        # Use default if provided and input is empty
        if [ -z "$value" ] && [ -n "$default" ]; then
            value="$default"
        fi
        
        # Validate
        if [ -z "$value" ]; then
            print_error "Tunnel name is required."
            echo ""
        elif ! is_valid_tunnel_name "$value"; then
            print_error "Invalid name. Use lowercase letters, numbers, and hyphens only."
            echo ""
        elif [ -f "$PAQET_DIR/config-${value}.yaml" ]; then
            print_error "Tunnel '$value' already exists. Choose a different name."
            echo ""
        else
            assign_var "$varname" "$value"
            return 0
        fi
    done
}

# Get list of all tunnel config files (legacy + named)
get_tunnel_configs() {
    # Legacy config first
    if [ -f "$PAQET_DIR/config.yaml" ]; then
        local role
        role=$(grep "^role:" "$PAQET_DIR/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"')
        # Only include legacy if it's a client config (Server A)
        # Server B configs are single-instance and don't need tunnel management
        if [ "$role" = "client" ]; then
            echo "$PAQET_DIR/config.yaml"
        fi
    fi
    # Named tunnel configs
    for f in "$PAQET_DIR"/config-*.yaml; do
        [ -f "$f" ] && echo "$f"
    done
    return 0
}

# Get ALL config files including server configs (for status/uninstall)
get_all_configs() {
    if [ -f "$PAQET_DIR/config.yaml" ]; then
        echo "$PAQET_DIR/config.yaml"
    fi
    for f in "$PAQET_DIR"/config-*.yaml; do
        [ -f "$f" ] && echo "$f"
    done
    return 0
}

# Extract tunnel name from config path
# Returns "default" for legacy config.yaml, or the name for config-<name>.yaml
get_tunnel_name() {
    local config_path="$1"
    local filename
    filename=$(basename "$config_path")
    if [ "$filename" = "config.yaml" ]; then
        echo "default"
    else
        echo "$filename" | sed 's/^config-//; s/\.yaml$//'
    fi
}

# Get service name for a tunnel
get_tunnel_service() {
    local config_path="$1"
    local name
    name=$(get_tunnel_name "$config_path")
    if [ "$name" = "default" ]; then
        echo "paqet"
    else
        echo "paqet-${name}"
    fi
}

# Count total number of tunnel configs (client tunnels only)
get_tunnel_count() {
    local count=0
    local configs
    configs=$(get_tunnel_configs)
    if [ -n "$configs" ]; then
        count=$(echo "$configs" | wc -l)
    fi
    echo "$count"
}

# List all tunnels with status
list_tunnels() {
    local configs
    configs=$(get_all_configs)
    
    if [ -z "$configs" ]; then
        print_info "No tunnels configured"
        return 1
    fi
    
    local idx=0
    while IFS= read -r config_file; do
        idx=$((idx + 1))
        local name
        name=$(get_tunnel_name "$config_file")
        local service
        service=$(get_tunnel_service "$config_file")
        local role
        role=$(grep "^role:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')
        
        # Get status
        local status="${RED}Stopped${NC}"
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            status="${GREEN}Running${NC}"
        fi
        
        # Get details based on role
        local details=""
        if [ "$role" = "client" ]; then
            local server_addr
            server_addr=$(grep -A1 "^server:" "$config_file" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"')
            local forward_ports
            forward_ports=$(grep 'listen:' "$config_file" 2>/dev/null | grep -oE ':[0-9]+"' | tr -d ':"' | tr '\n' ',' | sed 's/,$//')
            details="-> ${server_addr}  ports: ${forward_ports}"
        elif [ "$role" = "server" ]; then
            local listen_addr
            listen_addr=$(grep -A1 "^listen:" "$config_file" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"')
            details="listening on ${listen_addr}"
        fi
        
        echo -e "  ${CYAN}${idx})${NC} ${YELLOW}${name}${NC} [${status}] (${role}) ${details}"
    done <<< "$configs"
}

# Select a tunnel interactively, sets PAQET_CONFIG and PAQET_SERVICE globals
# Returns 0 on success, 1 if no tunnels or user cancelled
select_tunnel() {
    local prompt="${1:-Select tunnel}"
    local configs
    configs=$(get_all_configs)
    local count=0
    if [ -n "$configs" ]; then
        count=$(echo "$configs" | wc -l)
    fi
    
    if [ -z "$configs" ] || [ "$count" -eq 0 ]; then
        print_error "No tunnels configured"
        return 1
    fi
    
    # If only one tunnel, auto-select it
    if [ "$count" -eq 1 ]; then
        local config_file
        config_file=$(echo "$configs" | head -1)
        PAQET_CONFIG="$config_file"
        PAQET_SERVICE=$(get_tunnel_service "$config_file")
        local name
        name=$(get_tunnel_name "$config_file")
        print_info "Using tunnel: $name"
        return 0
    fi
    
    # Multiple tunnels - show list and ask
    echo ""
    echo -e "${YELLOW}${prompt}:${NC}"
    echo ""
    list_tunnels
    echo ""
    
    read -r -p "Choice: " tunnel_choice < /dev/tty
    
    # Validate choice
    if ! [[ "$tunnel_choice" =~ ^[0-9]+$ ]] || [ "$tunnel_choice" -lt 1 ] || [ "$tunnel_choice" -gt "$count" ]; then
        print_error "Invalid choice"
        return 1
    fi
    
    local config_file
    config_file=$(echo "$configs" | sed -n "${tunnel_choice}p")
    PAQET_CONFIG="$config_file"
    PAQET_SERVICE=$(get_tunnel_service "$config_file")
    local name
    name=$(get_tunnel_name "$config_file")
    print_info "Selected tunnel: $name"
    return 0
}

#===============================================================================
# System Detection Functions
#===============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root"
        exit 1
    fi
}

detect_os() {
    local os
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        os=$ID
    elif [ -f /etc/redhat-release ]; then
        os="rhel"
    else
        os=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    echo "$os"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm" ;;
        *)       echo "$arch" ;;
    esac
}

get_public_ip() {
    local ip=""
    ip=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null) || \
    ip=$(curl -4 -s --max-time 3 icanhazip.com 2>/dev/null) || \
    ip=$(curl -4 -s --max-time 3 api.ipify.org 2>/dev/null) || \
    ip=$(hostname -I | awk '{print $1}')
    
    if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "$ip"
    else
        hostname -I | awk '{print $1}'
    fi
}

is_private_or_nonpublic_ipv4() {
    local ip="$1"
    # RFC1918 + loopback + link-local + CGNAT
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^127\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
    return 1
}

get_local_ip() {
    local interface=$1
    ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
}

get_default_interface() {
    ip route | grep default | awk '{print $5}' | head -1
}

get_gateway_ip() {
    ip route | grep default | awk '{print $3}' | head -1
}

get_gateway_mac() {
    local gateway_ip
    gateway_ip=$(get_gateway_ip)
    if [ -n "$gateway_ip" ]; then
        # Ping to populate neighbor cache
        ping -c 1 -W 1 "$gateway_ip" >/dev/null 2>&1 || true
        
        # Try ip neigh first (modern method)
        local mac
        mac=$(ip neigh show "$gateway_ip" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
        
        # Fallback to arp if ip neigh fails
        if [ -z "$mac" ] && command -v arp >/dev/null 2>&1; then
            mac=$(arp -n "$gateway_ip" 2>/dev/null | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1)
        fi
        
        echo "$mac"
    fi
}

check_port_conflict() {
    local port=$1
    local pid=""
    
    if ss -tuln | grep -q ":${port} "; then
        print_warning "Port $port is already in use!"
        
        pid=$(lsof -t -i:"$port" 2>/dev/null | head -1)
        if [ -n "$pid" ]; then
            local pname
            pname=$(ps -p "$pid" -o comm= 2>/dev/null)
            echo -e "  Process: ${CYAN}$pname${NC} (PID: $pid)"
            echo ""
            echo -e "${YELLOW}Kill this process? (y/n)${NC}"
            read -r -p "> " kill_choice < /dev/tty
            
            if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
                kill -9 "$pid" 2>/dev/null || true
                sleep 1
                pkill -9 -f ".*:${port}" 2>/dev/null || true
                print_success "Process killed"
            else
                print_error "Cannot continue with port in use. Please free the port or choose another."
                return 1
            fi
        fi
    fi
}

check_port_conflict_proto() {
    local port=$1
    local proto="${2:-tcp}"

    local ss_args="-tln"
    [ "$proto" = "udp" ] && ss_args="-uln"

    if ss "$ss_args" 2>/dev/null | grep -q ":${port} "; then
        print_warning "Port $port/$proto is already in use!"
        local pid=""
        pid=$(lsof -t -i"${proto}":"$port" 2>/dev/null | head -1)
        if [ -n "$pid" ]; then
            local pname
            pname=$(ps -p "$pid" -o comm= 2>/dev/null)
            echo -e "  Process: ${CYAN}$pname${NC} (PID: $pid)"
        fi
        print_error "Please free the port or choose another."
        return 1
    fi
    return 0
}

#===============================================================================
# Installation Functions
#===============================================================================

# Iran server network optimization (DNS + apt mirror selection)
run_iran_optimizations() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}          Iran Server Network Optimization                  ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}These scripts can help optimize your Iran server:${NC}"
    echo -e "  ${YELLOW}1.${NC} DNS Finder - Find the best DNS servers for Iran"
    echo -e "  ${YELLOW}2.${NC} Mirror Selector - Find the fastest apt repository mirror"
    echo ""
    echo -e "${CYAN}This can significantly improve download speeds and reliability.${NC}"
    echo ""
    
    local run_optimize=false
    read_confirm "Run network optimization scripts before installation?" run_optimize "y"
    
    if [ "$run_optimize" = true ]; then
        echo ""
        
        # Run DNS optimization
        print_step "Running DNS Finder..."
        print_info "This will find and configure the best DNS for Iran"
        echo ""
        if bash <(curl -Ls https://github.com/alinezamifar/IranDNSFinder/raw/refs/heads/main/dns.sh); then
            print_success "DNS optimization completed"
        else
            print_warning "DNS optimization failed or was skipped"
        fi
        
        echo ""
        
        # Run apt mirror optimization (only for Debian/Ubuntu)
        local os
        os=$(detect_os)
        if [[ "$os" == "ubuntu" ]] || [[ "$os" == "debian" ]]; then
            print_step "Running Ubuntu/Debian Mirror Selector..."
            print_info "This will find the fastest apt repository mirror"
            echo ""
            if bash <(curl -Ls https://github.com/alinezamifar/DetectUbuntuMirror/raw/refs/heads/main/DUM.sh); then
                print_success "Mirror optimization completed"
            else
                print_warning "Mirror optimization failed or was skipped"
            fi
        else
            print_info "Mirror selector is only available for Ubuntu/Debian"
        fi
        
        echo ""
        print_success "Network optimization completed!"
        echo ""
    else
        print_info "Skipping network optimization"
    fi
}

install_dependencies() {
    print_step "Installing dependencies..."
    
    echo -e "${YELLOW}Install dependencies? (y/n/s to skip)${NC}"
    echo -e "${CYAN}Required: libpcap-dev, iptables, curl${NC}"
    read -r -t 10 -p "> " install_deps < /dev/tty || install_deps="y"
    
    if [[ "$install_deps" =~ ^[Ss]$ ]]; then
        print_warning "Skipping dependency installation"
        print_info "Make sure these are installed: libpcap-dev iptables curl"
        return 0
    fi
    
    if [[ ! "$install_deps" =~ ^[Yy]$ ]] && [ -n "$install_deps" ]; then
        print_warning "Skipping dependency installation"
        return 0
    fi
    
    local os
    os=$(detect_os)
    case $os in
        ubuntu|debian)
            print_info "Running apt update (may take time)..."
            timeout 30 apt update -qq 2>/dev/null || {
                print_warning "apt update timed out or failed"
                print_info "Continuing anyway..."
            }
            
            print_info "Installing packages..."
            apt install -y -qq curl wget libpcap-dev iptables lsof > /dev/null 2>&1 || {
                print_warning "Some packages may have failed to install"
                print_info "Continuing anyway..."
            }
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y -q curl wget libpcap-devel iptables lsof > /dev/null 2>&1 || {
                print_warning "Some packages may have failed to install"
            }
            ;;
        *)
            print_warning "Unknown OS. Please install libpcap manually."
            ;;
    esac
    
    print_success "Dependency installation completed"
}

PAQET_DL_PROVIDER=""
PAQET_DL_VERSION=""
PAQET_DL_ARCHIVE_NAME=""
PAQET_DL_URL=""
PAQET_DL_RELEASE_PAGE=""

get_latest_paqet_release_tag_for_provider() {
    echo "$RELEASE_TAG"
}

resolve_recoba_core_asset() {
    local arch="$1"
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${RELEASE_TAG}"
    local api_json=""
    api_json=$(curl -s --max-time 15 "$api_url" 2>/dev/null)

    if [ -z "$api_json" ]; then
        print_error "Failed to fetch release metadata from ${GITHUB_REPO}"
        print_info "Check connectivity to GitHub API or try again later"
        return 1
    fi

    case "$arch" in
        amd64|arm64) ;;
        *)
            print_error "Recoba Enhanced Core is not available for architecture: $arch"
            print_info "Supported architectures: amd64, arm64"
            return 1
            ;;
    esac

    # Match: recoba-tunnel-linux-<arch>.tar.gz
    local asset_pair=""
    asset_pair=$(printf '%s\n' "$api_json" | awk -v target_arch="$arch" '
        BEGIN { current_name="" }
        /"name"[[:space:]]*:/ {
            line=$0
            sub(/^.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            current_name=line
        }
        /"browser_download_url"[[:space:]]*:/ {
            line=$0
            sub(/^.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            if (current_name ~ /recoba-tunnel/ && current_name ~ /tar\.gz/ && current_name ~ target_arch) {
                print current_name "|" line
                exit
            }
        }
    ')

    if [ -z "$asset_pair" ] || [[ "$asset_pair" != *"|"* ]]; then
        print_error "Could not locate core asset for architecture: $arch"
        print_info "Release page: https://github.com/${GITHUB_REPO}/releases/tag/${RELEASE_TAG}"
        return 1
    fi

    PAQET_DL_PROVIDER="recoba-enhanced"
    PAQET_DL_VERSION="$RELEASE_TAG"
    PAQET_DL_ARCHIVE_NAME="${asset_pair%%|*}"
    PAQET_DL_URL="${asset_pair#*|}"
    PAQET_DL_RELEASE_PAGE="https://github.com/${GITHUB_REPO}/releases/tag/${RELEASE_TAG}"
    return 0
}

resolve_paqet_download_source() {
    local provider="${1:-$(get_current_core_provider)}"
    local arch="$2"
    local os="${3:-linux}"

    PAQET_DL_PROVIDER=""
    PAQET_DL_VERSION=""
    PAQET_DL_ARCHIVE_NAME=""
    PAQET_DL_URL=""
    PAQET_DL_RELEASE_PAGE=""

    resolve_recoba_core_asset "$arch" || return 1
    return 0
}

download_paqet() {
    print_step "Downloading paqet binary..."
    
    local arch
    arch=$(detect_arch)
    local os="linux"
    local provider
    provider=$(get_current_core_provider)
    
    if is_dry_run; then
        print_info "Core provider: $(get_core_provider_label "$provider")"
        dry_run_notice "would detect latest core release for architecture: $arch"
        dry_run_notice "would download or reuse cached archive under $PAQET_DIR/core-cache"
        dry_run_notice "would replace core binary: $PAQET_BIN"
        dry_run_notice "would update metadata: $CORE_META"
        print_success "DRY-RUN: paqet binary not changed"
        return 0
    fi

    ensure_paqet_dir_permissions

    if ! resolve_paqet_download_source "$provider" "$arch" "$os"; then
        return 1
    fi

    local version="$PAQET_DL_VERSION"
    local archive_name="$PAQET_DL_ARCHIVE_NAME"
    local download_url="$PAQET_DL_URL"
    local cache_archive=""
    cache_archive=$(get_core_archive_cache_path "$version" "$archive_name")

    print_info "Core provider: $(get_core_provider_label "$provider")"
    print_info "Downloading version/tag: $version"
    print_info "URL: $download_url"
    
    # Check for local file in /root/paqet first
    local local_dir="/root/paqet"
    local local_archive="$local_dir/$archive_name"
    
    # Download and extract
    local temp_archive
    temp_archive=$(mktemp /tmp/paqet.XXXXXX)
    local download_success=false
    local archive_source=""
    local should_cache_archive=false
    
    if [ -f "$cache_archive" ]; then
        print_success "Using cached core archive: $cache_archive"
        cp "$cache_archive" "$temp_archive"
        download_success=true
        archive_source="cache"
    elif [ -f "$local_archive" ]; then
        print_success "Found local file: $local_archive"
        cp "$local_archive" "$temp_archive"
        download_success=true
        archive_source="local-exact"
    elif [ -d "$local_dir" ] && compgen -G "$local_dir/*.tar.gz" >/dev/null; then
        # Found some tar.gz in /root/paqet, ask user
        print_info "Found archives in $local_dir:"
        ls -1 "$local_dir"/*.tar.gz 2>/dev/null
        echo ""
        echo -e "${YELLOW}Use one of these files? (y/n)${NC}"
        read -r -p "> " use_local < /dev/tty
        
        if [[ "$use_local" =~ ^[Yy]$ ]]; then
            while true; do
                echo -e "${YELLOW}Enter the filename (or full path). Press Enter to cancel:${NC}"
                read -r -p "> " user_file < /dev/tty
                [ -z "$user_file" ] && break
                if [ -f "$user_file" ]; then
                    local_archive="$user_file"
                    cp "$local_archive" "$temp_archive"
                    download_success=true
                    archive_source="local-manual"
                    print_success "Using local file: $local_archive"
                    break
                elif [ -f "$local_dir/$user_file" ]; then
                    local_archive="$local_dir/$user_file"
                    cp "$local_archive" "$temp_archive"
                    download_success=true
                    archive_source="local-manual"
                    print_success "Using local file: $local_archive"
                    break
                else
                    print_error "File not found: $user_file. Try again or press Enter to cancel."
                fi
            done
        fi
    fi
    
    # Try downloading if no local file was used
    if [ "$download_success" = false ]; then
        print_info "Attempting download..."
        if timeout 30 curl -fsSL "$download_url" -o "$temp_archive" 2>/dev/null; then
            download_success=true
            archive_source="download"
            print_success "Download completed"
        else
            print_error "Failed to download paqet binary"
            print_warning "Download blocked or network issue detected"
            echo ""
            echo -e "${YELLOW}Do you have a local copy of the paqet archive? (y/n)${NC}"
            read -r -p "> " has_local < /dev/tty
            
            if [[ "$has_local" =~ ^[Yy]$ ]]; then
                while true; do
                    echo -e "${YELLOW}Enter the full path to the paqet tar.gz file. Press Enter to cancel:${NC}"
                    echo -e "${CYAN}Example: /root/paqet/${archive_name}${NC}"
                    read -r -p "> " local_archive < /dev/tty
                    [ -z "$local_archive" ] && break
                    if [ -f "$local_archive" ]; then
                        cp "$local_archive" "$temp_archive"
                        download_success=true
                        archive_source="local-manual"
                        print_success "Using local file: $local_archive"
                        break
                    else
                        print_error "File not found: $local_archive. Try again or press Enter to cancel."
                    fi
                done
            fi
            if [ "$download_success" = false ]; then
                print_info "Please download manually from: ${PAQET_DL_RELEASE_PAGE:-https://github.com/${GITHUB_REPO}/releases}"
                print_info "Save to: $local_dir/"
                print_info "Then run this installer again (you will return to the main menu now)."
                return 1
            fi
        fi
    fi

    if [ "$download_success" = true ] && [ "$archive_source" != "cache" ]; then
        should_cache_archive=true
    fi
    
    if [ "$download_success" = true ]; then
        # Extract into a temp directory first (more robust to upstream archive layout changes)
        local temp_extract_dir=""
        temp_extract_dir=$(mktemp -d /tmp/paqet-extract.XXXXXX)
        mkdir -p "$temp_extract_dir"

        tar -xzf "$temp_archive" -C "$temp_extract_dir" 2>/dev/null || {
            print_error "Failed to extract archive"
            rm -rf "$temp_extract_dir" 2>/dev/null || true
            rm -f "$temp_archive"
            return 1
        }

        # Try known/expected names first, then fall back to auto-detection
        local extracted_binary=""
        local candidate=""
        for candidate in \
            "$temp_extract_dir/paqet_${os}_${arch}" \
            "$temp_extract_dir/paqet" \
            "$temp_extract_dir/paqet-${os}-${arch}" \
            "$temp_extract_dir/paqet_${arch}" \
            "$temp_extract_dir/paqet-${arch}"; do
            if [ -f "$candidate" ]; then
                extracted_binary="$candidate"
                break
            fi
        done

        if [ -z "$extracted_binary" ]; then
            extracted_binary=$(find "$temp_extract_dir" -type f \( -iname 'paqet' -o -iname 'paqet_*' -o -iname 'paqet-*' -o -iname '*paqet*' \) \
                ! -name '*.tar.gz' ! -name '*.txt' ! -name '*.md' | head -n 1)
        fi

        if [ -n "$extracted_binary" ] && [ -f "$extracted_binary" ]; then
            mv "$extracted_binary" "$PAQET_BIN"
            chmod 755 "$PAQET_BIN" 2>/dev/null || chmod +x "$PAQET_BIN"
            if [ "$should_cache_archive" = true ]; then
                mkdir -p "$(dirname "$cache_archive")" 2>/dev/null || true
                if cp "$temp_archive" "$cache_archive" 2>/dev/null; then
                    chmod 600 "$cache_archive" 2>/dev/null || true
                    print_info "Cached core archive: $cache_archive"
                else
                    print_warning "Could not save core archive to cache (continuing)"
                fi
            fi
            local metadata_archive_path="$temp_archive"
            case "$archive_source" in
                cache) metadata_archive_path="$cache_archive" ;;
                local-exact|local-manual) metadata_archive_path="$local_archive" ;;
                download)
                    if [ -f "$cache_archive" ]; then
                        metadata_archive_path="$cache_archive"
                    fi
                    ;;
            esac
            set_installed_core_metadata "$PAQET_DL_PROVIDER" "$version" "$archive_name" "$download_url" "$metadata_archive_path" "$archive_source" "$PAQET_BIN"
            secure_paqet_sensitive_files
            rm -rf "$temp_extract_dir" 2>/dev/null || true
            rm -f "$temp_archive"
            print_success "paqet binary installed successfully"
        else
            print_error "Binary not found in archive"
            print_info "Archive contents (top level):"
            ls -la "$temp_extract_dir" 2>/dev/null || true
            rm -rf "$temp_extract_dir" 2>/dev/null || true
            rm -f "$temp_archive"
            return 1
        fi
    fi
    if [ "$download_success" != true ]; then
        return 1
    fi
}

generate_secret_key() {
    # Generate a random 32-character key
    if command -v openssl &> /dev/null; then
        openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32
    else
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32
    fi
}

setup_iptables() {
    local port=$1
    print_step "Configuring iptables for port $port..."
    
    # Remove existing rules if any
    iptables_or_dry_run -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || true
    iptables_or_dry_run -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || true
    iptables_or_dry_run -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    iptables_or_dry_run -t mangle -D PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    
    # Add new rules
    iptables_or_dry_run -t raw -A PREROUTING -p tcp --dport "$port" -j NOTRACK
    iptables_or_dry_run -t raw -A OUTPUT -p tcp --sport "$port" -j NOTRACK
    # Block outgoing RST from kernel (prevents kernel interference with raw sockets)
    iptables_or_dry_run -t mangle -A OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP
    # Block incoming fake RST packets (some ISPs inject spoofed RSTs to kill tunnels)
    iptables_or_dry_run -t mangle -A PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -j DROP
    
    save_iptables
    print_success "iptables configured"
}

# Setup iptables for Server A (client) - targets Server B's IP:port
# Server A uses ephemeral ports, so rules must match by destination (Server B)
setup_iptables_client() {
    local server_ip=$1
    local server_port=$2
    print_step "Configuring iptables for tunnel to $server_ip:$server_port..."
    
    # Remove existing rules if any
    iptables_or_dry_run -t raw -D OUTPUT -p tcp -d "$server_ip" --dport "$server_port" -j NOTRACK 2>/dev/null || true
    iptables_or_dry_run -t raw -D PREROUTING -p tcp -s "$server_ip" --sport "$server_port" -j NOTRACK 2>/dev/null || true
    iptables_or_dry_run -t mangle -D OUTPUT -p tcp -d "$server_ip" --dport "$server_port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    iptables_or_dry_run -t mangle -D PREROUTING -p tcp -s "$server_ip" --sport "$server_port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    
    # Bypass kernel connection tracking for tunnel traffic
    iptables_or_dry_run -t raw -A OUTPUT -p tcp -d "$server_ip" --dport "$server_port" -j NOTRACK
    iptables_or_dry_run -t raw -A PREROUTING -p tcp -s "$server_ip" --sport "$server_port" -j NOTRACK
    # Block outgoing RST from kernel to Server B (prevents kernel from killing raw socket connections)
    iptables_or_dry_run -t mangle -A OUTPUT -p tcp -d "$server_ip" --dport "$server_port" --tcp-flags RST RST -j DROP
    # Block incoming fake RST from middleboxes (ISPs inject spoofed RSTs appearing to come from Server B)
    iptables_or_dry_run -t mangle -A PREROUTING -p tcp -s "$server_ip" --sport "$server_port" --tcp-flags RST RST -j DROP
    
    apply_mss_clamp_rule
    save_iptables
    print_success "iptables configured (connection protection + MSS clamp active)"
}

# Remove iptables client rules for a specific Server B target
remove_iptables_client() {
    local server_ip=$1
    local server_port=$2
    iptables_or_dry_run -t raw -D OUTPUT -p tcp -d "$server_ip" --dport "$server_port" -j NOTRACK 2>/dev/null || true
    iptables_or_dry_run -t raw -D PREROUTING -p tcp -s "$server_ip" --sport "$server_port" -j NOTRACK 2>/dev/null || true
    iptables_or_dry_run -t mangle -D OUTPUT -p tcp -d "$server_ip" --dport "$server_port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    iptables_or_dry_run -t mangle -D PREROUTING -p tcp -s "$server_ip" --sport "$server_port" --tcp-flags RST RST -j DROP 2>/dev/null || true
}

apply_mss_clamp_rule() {
    if is_dry_run; then
        dry_run_notice "would ensure TCP MSS clamp rule: iptables -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
        return 0
    fi

    iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
        || iptables_or_dry_run -t mangle -I POSTROUTING 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

remove_mss_clamp_rule() {
    iptables_or_dry_run -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
}

# Save iptables rules to persistent storage
save_iptables() {
    if is_dry_run; then
        dry_run_notice "would persist iptables rules"
        return 0
    fi
    if command -v iptables-save &> /dev/null; then
        if [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        elif [ -f /etc/sysconfig/iptables ]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        fi
    fi
}

#===============================================================================
# IPTables NAT Port Forwarding
# Kernel-level port forwarding via iptables NAT rules.
# Useful for independently managing which ports go to which destination,
# testing backup tunnels without service restarts, and relay setups.
#===============================================================================

ensure_ip_forwarding() {
    local current
    current=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    if [ "$current" != "1" ]; then
        print_step "Enabling IP forwarding..."
        if is_dry_run; then
            dry_run_notice "would write file: /etc/sysctl.d/30-ip_forward.conf"
            dry_run_notice "would run: sysctl -w net.ipv4.ip_forward=1"
            dry_run_notice "would run: sysctl --system"
            print_success "DRY-RUN: IP forwarding not changed"
            return 0
        fi
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/30-ip_forward.conf
        sysctl_or_dry_run -w net.ipv4.ip_forward=1 > /dev/null 2>&1
        sysctl_or_dry_run --system > /dev/null 2>&1
        print_success "IP forwarding enabled"
    fi
}

add_nat_forward_multi_port() {
    echo ""
    echo -e "${YELLOW}Multi-Port NAT Forward${NC}"
    echo -e "${CYAN}Forward specific ports (TCP+UDP) to a destination server via iptables NAT${NC}"
    echo ""
    
    local dest_ip
    while true; do
        echo -e "${YELLOW}Enter destination server IP (e.g. 1.2.3.4). Press Enter to cancel:${NC}"
        read -r -p "> " dest_ip < /dev/tty
        [ -z "$dest_ip" ] && { print_info "Cancelled."; return 0; }
        if [[ "$dest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        print_error "Invalid IP address format. Try again or press Enter to cancel."
    done
    
    local ports
    while true; do
        echo -e "${YELLOW}Enter ports to forward (comma-separated, e.g. 443,8443,2053). Press Enter to cancel:${NC}"
        read -r -p "> " ports < /dev/tty
        [ -z "$ports" ] && { print_info "Cancelled."; return 0; }
        ports=$(echo "$ports" | tr -d ' ')
        if [[ "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            break
        fi
        print_error "Invalid port format. Use comma-separated numbers (e.g. 443,8443). Try again or press Enter to cancel."
    done
    
    ensure_ip_forwarding
    
    print_step "Adding NAT forwarding rules: ports $ports -> $dest_ip ..."
    
    # TCP
    iptables_or_dry_run -t nat -A PREROUTING -p tcp --match multiport --dports "$ports" -j DNAT --to-destination "$dest_ip"
    iptables_or_dry_run -t nat -A POSTROUTING -p tcp --match multiport --dports "$ports" -j MASQUERADE
    # UDP
    iptables_or_dry_run -t nat -A PREROUTING -p udp --match multiport --dports "$ports" -j DNAT --to-destination "$dest_ip"
    iptables_or_dry_run -t nat -A POSTROUTING -p udp --match multiport --dports "$ports" -j MASQUERADE
    
    save_iptables
    print_success "NAT forwarding added: ports $ports -> $dest_ip (TCP+UDP)"
}

add_nat_forward_all_ports() {
    echo ""
    echo -e "${YELLOW}All-Ports NAT Forward${NC}"
    echo -e "${CYAN}Forward ALL ports to a destination, except specified exclusions${NC}"
    echo ""
    
    local relay_ip
    while true; do
        echo -e "${YELLOW}Enter THIS server's IP (relay IP). Press Enter to cancel:${NC}"
        read -r -p "> " relay_ip < /dev/tty
        [ -z "$relay_ip" ] && { print_info "Cancelled."; return 0; }
        if [[ "$relay_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        print_error "Invalid IP address format. Try again or press Enter to cancel."
    done
    
    local dest_ip
    while true; do
        echo -e "${YELLOW}Enter destination server IP. Press Enter to cancel:${NC}"
        read -r -p "> " dest_ip < /dev/tty
        [ -z "$dest_ip" ] && { print_info "Cancelled."; return 0; }
        if [[ "$dest_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        print_error "Invalid IP address format. Try again or press Enter to cancel."
    done
    
    local exclude_ports
    while true; do
        echo -e "${YELLOW}Enter ports to EXCLUDE (comma-separated, e.g. 22,80). Press Enter to cancel:${NC}"
        read -r -p "> " exclude_ports < /dev/tty
        [ -z "$exclude_ports" ] && { print_info "Cancelled."; return 0; }
        exclude_ports=$(echo "$exclude_ports" | tr -d ' ')
        if [[ "$exclude_ports" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            break
        fi
        print_error "Invalid port format. Use comma-separated numbers (e.g. 22,80). Try again or press Enter to cancel."
    done
    
    # Warn about SSH
    if ! echo ",$exclude_ports," | grep -q ",22,"; then
        print_warning "Port 22 (SSH) is NOT in your exclusion list!"
        echo -e "${RED}You may lose SSH access if port 22 is forwarded.${NC}"
        local skip_ssh_warn=false
        read_confirm "Continue without excluding port 22?" skip_ssh_warn "n"
        if [ "$skip_ssh_warn" != true ]; then
            print_info "Cancelled. Add port 22 to your exclusion list."
            return 1
        fi
    fi
    
    ensure_ip_forwarding
    
    print_step "Adding all-ports NAT forwarding to $dest_ip (excluding $exclude_ports)..."
    
    # First: redirect excluded ports back to this server (keeps them local)
    iptables_or_dry_run -t nat -A PREROUTING -p tcp --match multiport --dports "$exclude_ports" -j DNAT --to-destination "$relay_ip"
    iptables_or_dry_run -t nat -A PREROUTING -p udp --match multiport --dports "$exclude_ports" -j DNAT --to-destination "$relay_ip"
    # Then: catch-all forward everything else to destination
    iptables_or_dry_run -t nat -A PREROUTING -p tcp -j DNAT --to-destination "$dest_ip"
    iptables_or_dry_run -t nat -A PREROUTING -p udp -j DNAT --to-destination "$dest_ip"
    iptables_or_dry_run -t nat -A POSTROUTING -j MASQUERADE
    
    save_iptables
    print_success "All-ports NAT forwarding added to $dest_ip (excluding $exclude_ports)"
}

view_nat_rules() {
    echo ""
    echo -e "${YELLOW}Current NAT Table Rules:${NC}"
    echo -e "${GREEN}─────────────────────────────────────────────────────────────${NC}"
    iptables -t nat -L -v --line-numbers 2>/dev/null || print_error "Failed to read NAT rules"
    echo -e "${GREEN}─────────────────────────────────────────────────────────────${NC}"
}

remove_nat_forward_by_dest() {
    echo ""
    echo -e "${YELLOW}Remove NAT Forwarding Rules by Destination${NC}"
    echo ""
    
    view_nat_rules
    echo ""
    
    echo -e "${YELLOW}Enter destination IP to remove rules for. Press Enter to cancel:${NC}"
    read -r -p "> " dest_ip < /dev/tty
    if [ -z "$dest_ip" ]; then
        print_info "Cancelled."
        return 0
    fi
    
    print_step "Removing NAT rules targeting $dest_ip..."
    
    local removed=0
    
    # Remove PREROUTING rules targeting this IP (reverse order to preserve line numbers)
    local pre_rules
    pre_rules=$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | grep "to:${dest_ip}" | awk '{print $1}' | sort -rn)
    for num in $pre_rules; do
        iptables_or_dry_run -t nat -D PREROUTING "$num" 2>/dev/null && removed=$((removed + 1))
    done
    
    # Remove POSTROUTING rules that reference this IP (if any)
    local post_rules
    post_rules=$(iptables -t nat -L POSTROUTING --line-numbers -n 2>/dev/null | grep "to:${dest_ip}" | awk '{print $1}' | sort -rn)
    for num in $post_rules; do
        iptables_or_dry_run -t nat -D POSTROUTING "$num" 2>/dev/null && removed=$((removed + 1))
    done
    
    if [ "$removed" -gt 0 ]; then
        save_iptables
        print_success "Removed $removed NAT rule(s) targeting $dest_ip"
        print_info "POSTROUTING MASQUERADE rules (which don't reference a specific IP) may remain."
        print_info "Use 'View NAT Rules' to verify, or 'Flush All' for a clean slate."
    else
        print_warning "No NAT rules found targeting $dest_ip"
    fi
}

flush_nat_rules() {
    echo ""
    echo -e "${RED}WARNING: This will flush ALL iptables NAT rules!${NC}"
    echo -e "${YELLOW}Connection protection rules (raw/mangle) will NOT be affected.${NC}"
    echo ""
    
    local do_flush=false
    read_confirm "Flush all NAT rules?" do_flush "n"
    
    if [ "$do_flush" = true ]; then
        print_step "Flushing NAT table..."
        iptables_or_dry_run -t nat -F
        iptables_or_dry_run -t nat -X 2>/dev/null || true
        
        save_iptables
        print_success "All NAT rules flushed"
        
        echo ""
        local disable_fwd=false
        read_confirm "Also disable IP forwarding?" disable_fwd "n"
        if [ "$disable_fwd" = true ]; then
            if is_dry_run; then
                dry_run_notice "would write file: /etc/sysctl.d/30-ip_forward.conf"
                dry_run_notice "would run: sysctl -w net.ipv4.ip_forward=0"
                dry_run_notice "would run: sysctl --system"
            else
                echo "net.ipv4.ip_forward=0" > /etc/sysctl.d/30-ip_forward.conf
                sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1
                sysctl --system > /dev/null 2>&1
            fi
            print_success "IP forwarding disabled"
        fi
    else
        print_info "Flush cancelled"
    fi
}

create_systemd_service() {
    print_step "Creating systemd service..."

    if is_dry_run; then
        dry_run_notice "would write systemd service: /etc/systemd/system/${PAQET_SERVICE}.service"
        dry_run_notice "would run: systemctl daemon-reload"
        print_success "DRY-RUN: systemd service not created"
        return 0
    fi
    
    cat > "/etc/systemd/system/${PAQET_SERVICE}.service" << EOF
[Unit]
Description=paqet Raw Packet Tunnel
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${PAQET_BIN} run -c ${PAQET_CONFIG}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl_or_dry_run daemon-reload
    print_success "Systemd service created"
}

#===============================================================================
# Server B Setup (Abroad - VPN Server with paqet server)
#===============================================================================

setup_server_b() {
    print_banner
    echo -e "${GREEN}Setting up Server B (Abroad - VPN Server)${NC}"
    echo -e "${CYAN}This server runs your V2Ray/X-UI and the paqet server${NC}"
    echo ""
    
    # Detect network configuration
    local interface
    interface=$(get_default_interface)
    local local_ip
    local_ip=$(get_local_ip "$interface")
    local public_ip
    public_ip=$(get_public_ip)
    local gateway_mac
    gateway_mac=$(get_gateway_mac)
    
    echo -e "${YELLOW}Network Configuration Detected:${NC}"
    echo -e "  Interface:   ${CYAN}$interface${NC}"
    echo -e "  Local IP:    ${CYAN}$local_ip${NC}"
    echo -e "  Public IP:   ${CYAN}$public_ip${NC}"
    echo -e "  Gateway MAC: ${CYAN}$gateway_mac${NC}"
    echo ""
    
    # Confirm or modify interface (with validation)
    read_required "Network interface" interface "$interface"
    
    # Get local IP for that interface (with validation)
    local_ip=$(get_local_ip "$interface")
    if [ -z "$local_ip" ]; then
        read_ip "Could not detect IP. Enter local IP" local_ip
    else
        read_optional "Local IP" local_ip "$local_ip"
    fi
    
    # Confirm gateway MAC (with validation)
    if [ -z "$gateway_mac" ]; then
        read_mac "Could not detect gateway MAC. Enter gateway MAC address" gateway_mac
    else
        read_optional "Gateway MAC" input_mac "$gateway_mac"
        [ -n "$input_mac" ] && gateway_mac="$input_mac"
    fi
    
    # paqet listen port (with validation)
    echo ""
    echo -e "${CYAN}Enter paqet listen port (for tunnel, NOT your V2Ray ports)${NC}"
    local PAQET_PORT=""
    read_port "paqet listen port" PAQET_PORT "$DEFAULT_PAQET_PORT"
    
    # Check port conflict
    check_port_conflict "$PAQET_PORT" || return 0
    
    # Backend service ports (informational only; not stored in paqet server config)
    echo ""
    echo -e "${CYAN}These are the backend service ports on Server B (V2Ray/X-UI/WireGuard/Hysteria)${NC}"
    echo -e "${YELLOW}Informational only:${NC} this is shown in the final summary and is ${YELLOW}not${NC} written into the paqet server config."
    read_ports "Enter backend service ports (comma-separated)" INBOUND_PORTS "$DEFAULT_FORWARD_PORTS"
    
    # Generate or input secret key
    echo ""
    local secret_key
    secret_key=$(generate_secret_key)
    echo -e "${CYAN}Generated secret key: $secret_key${NC}"
    read_required "Secret key (press Enter to use generated)" secret_key "$secret_key"

    # PaqX-style automatic profile (CPU/RAM-aware)
    echo ""
    calculate_auto_kcp_profile
    apply_low_mtu_upload_stability_profile "$(detect_interface_mtu "$interface" 2>/dev/null || true)"
    show_auto_kcp_profile
    
    # Download paqet
    download_paqet || return 0
    
    # Setup iptables
    setup_iptables "$PAQET_PORT"
    apply_paqx_kernel_optimizations
    
    # Create config file
    print_step "Creating configuration..."

    local profile_network_pcap_fragment=""
    local profile_transport_buf_fragment=""
    local profile_kcp_extra_fragment=""
    local profile_conn_value=""
    local profile_kcp_block=""
    local profile_kcp_mtu=""
    local profile_kcp_mode=""
    build_profile_network_pcap_fragment "server" profile_network_pcap_fragment
    build_profile_transport_buffer_fragment profile_transport_buf_fragment
    build_profile_kcp_extra_fragment profile_kcp_extra_fragment
    profile_conn_value=$(get_effective_profile_conn_value)
    profile_kcp_block=$(get_effective_profile_kcp_block)
    profile_kcp_mtu=$(get_effective_profile_kcp_mtu_for_interface "$interface")
    profile_kcp_mode=$(get_effective_profile_kcp_mode)
    
    cat > "$PAQET_CONFIG" << EOF
# paqet Server Configuration
# Generated by installer on $(date)
role: "server"

log:
  level: "info"

listen:
  addr: ":${PAQET_PORT}"

network:
  interface: "${interface}"
  ipv4:
    addr: "${local_ip}:${PAQET_PORT}"
    router_mac: "${gateway_mac}"
  tcp:
    local_flag: ["PA"]
${profile_network_pcap_fragment}

transport:
  protocol: "kcp"${profile_transport_buf_fragment}
  conn: ${profile_conn_value}
  kcp:
    mode: "${profile_kcp_mode}"
    key: "${secret_key}"
    mtu: ${profile_kcp_mtu}
    block: "${profile_kcp_block}"
${profile_kcp_extra_fragment}
EOF
    secure_file_permissions "$PAQET_CONFIG" 600
    
    print_success "Configuration created"
    
    # Create systemd service
    create_systemd_service
    
    # Start service
    systemctl_or_dry_run enable --now "$PAQET_SERVICE"
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                 Server B Ready!                            ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}Public IP:${NC}     ${CYAN}$public_ip${NC}"
    echo -e "  ${YELLOW}paqet Port:${NC}    ${CYAN}$PAQET_PORT${NC}"
    echo -e "  ${YELLOW}V2Ray Ports:${NC}   ${CYAN}$INBOUND_PORTS${NC}"
    echo ""
    echo -e "${YELLOW}Secret Key (save this for Server A):${NC}"
    echo -e "${CYAN}$secret_key${NC}"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Make sure V2Ray/X-UI is running on ports: ${CYAN}$INBOUND_PORTS${NC}"
    echo -e "  2. Run this installer on Server A with same secret key"
    echo -e "  3. Open port ${CYAN}$PAQET_PORT${NC} in cloud firewall (if any)"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  Status:  ${CYAN}systemctl status $PAQET_SERVICE${NC}"
    echo -e "  Logs:    ${CYAN}journalctl -u $PAQET_SERVICE -f${NC}"
    echo -e "  Restart: ${CYAN}systemctl restart $PAQET_SERVICE${NC}"
    echo ""
}

#===============================================================================
# Server A Setup (Entry Point - paqet client with port forwarding)
#===============================================================================

setup_server_a() {
    print_banner
    echo -e "${GREEN}Setting up Server A (Entry Point)${NC}"
    echo -e "${CYAN}This server accepts client connections and tunnels to Server B${NC}"
    echo ""
    
    # Ask for tunnel name
    echo -e "${CYAN}Each tunnel needs a unique name to identify the Server B it connects to.${NC}"
    echo -e "${CYAN}Examples: usa, germany, server-1${NC}"
    echo ""
    read_tunnel_name "Enter tunnel name" TUNNEL_NAME
    
    # Set per-tunnel config and service paths
    PAQET_CONFIG="$PAQET_DIR/config-${TUNNEL_NAME}.yaml"
    PAQET_SERVICE="paqet-${TUNNEL_NAME}"
    
    echo ""
    print_info "Tunnel '${TUNNEL_NAME}' will use:"
    echo -e "  Config:  ${CYAN}$PAQET_CONFIG${NC}"
    echo -e "  Service: ${CYAN}$PAQET_SERVICE${NC}"
    echo ""
    
    # Detect network configuration
    local interface
    interface=$(get_default_interface)
    local local_ip
    local_ip=$(get_local_ip "$interface")
    local public_ip
    public_ip=$(get_public_ip)
    local advertised_host="$public_ip"
    local gateway_mac
    gateway_mac=$(get_gateway_mac)
    
    echo -e "${YELLOW}Network Configuration Detected:${NC}"
    echo -e "  Interface:   ${CYAN}$interface${NC}"
    echo -e "  Local IP:    ${CYAN}$local_ip${NC}"
    echo -e "  Public IP:   ${CYAN}$public_ip${NC}"
    echo -e "  Gateway MAC: ${CYAN}$gateway_mac${NC}"
    echo ""

    if is_private_or_nonpublic_ipv4 "$public_ip"; then
        print_warning "Detected a private/non-public IP for this server ($public_ip)."
        print_info "This does NOT break the paqet tunnel to Server B (outbound tunnel can still work)."
        print_info "If clients connect from outside your LAN, use your router WAN IP / DDNS and port forwarding."
        echo ""
        read_optional "Advertised client IP/hostname for examples (optional)" advertised_override
        [ -n "$advertised_override" ] && advertised_host="$advertised_override"
        echo ""
    fi
    
    # Get Server B details (with validation - keeps asking until valid)
    echo -e "${CYAN}Enter Server B (Abroad) connection details for tunnel '${TUNNEL_NAME}'${NC}"
    read_ip "Server B public IP address" SERVER_B_IP
    
    echo ""
    read_port "paqet port on Server B" SERVER_B_PORT "$DEFAULT_PAQET_PORT"
    
    echo ""
    local SECRET_KEY=""
    read_required "Secret key (from Server B setup)" SECRET_KEY
    
    # Confirm or modify interface (with validation)
    echo ""
    read_required "Network interface" interface "$interface"
    
    # Get local IP for that interface (with validation)
    local_ip=$(get_local_ip "$interface")
    if [ -z "$local_ip" ]; then
        read_ip "Could not detect IP. Enter local IP" local_ip
    else
        read_optional "Local IP" local_ip "$local_ip"
    fi
    
    # Confirm gateway MAC (with validation)
    if [ -z "$gateway_mac" ]; then
        read_mac "Could not detect gateway MAC. Enter gateway MAC address" gateway_mac
    else
        read_optional "Gateway MAC" input_mac "$gateway_mac"
        [ -n "$input_mac" ] && gateway_mac="$input_mac"
    fi
    
    # Ports/mappings to forward (with validation)
    echo ""
    echo -e "${CYAN}These will be accessible on this server and forwarded to Server B${NC}"
    echo -e "${YELLOW}Forward protocol mode:${NC}"
    echo -e "  ${CYAN}1)${NC} TCP only (VLESS/V2Ray TCP)"
    echo -e "  ${CYAN}2)${NC} UDP only (WireGuard/Hysteria)"
    echo -e "  ${CYAN}3)${NC} Both TCP and UDP"
    read -r -p "Select [1]: " FORWARD_MODE_CHOICE < /dev/tty
    FORWARD_MODE_CHOICE=${FORWARD_MODE_CHOICE:-1}

    local FORWARD_MAPPINGS=""
    local FORWARD_TCP_MAPPINGS=""
    local FORWARD_UDP_MAPPINGS=""

    case "$FORWARD_MODE_CHOICE" in
        1)
            echo -e "${CYAN}Use same TCP port:${NC} ${YELLOW}443${NC}   ${CYAN}or map different TCP port:${NC} ${YELLOW}8443:443${NC}"
            read_forward_mappings "Enter TCP forward ports/mappings (comma-separated)" FORWARD_TCP_MAPPINGS "$DEFAULT_FORWARD_PORTS" "tcp"
            FORWARD_MAPPINGS="$FORWARD_TCP_MAPPINGS"
            ;;
        2)
            echo -e "${CYAN}Use same UDP port:${NC} ${YELLOW}51820${NC}   ${CYAN}or map different UDP port:${NC} ${YELLOW}1090:443/udp${NC}"
            read_forward_mappings "Enter UDP forward ports/mappings (comma-separated)" FORWARD_UDP_MAPPINGS "" "udp"
            FORWARD_MAPPINGS="$FORWARD_UDP_MAPPINGS"
            ;;
        3)
            echo -e "${CYAN}TCP mappings (examples):${NC} ${YELLOW}443${NC}, ${YELLOW}8443:443${NC}"
            read_forward_mappings "Enter TCP forward ports/mappings (comma-separated)" FORWARD_TCP_MAPPINGS "$DEFAULT_FORWARD_PORTS" "tcp"
            echo ""
            echo -e "${CYAN}UDP mappings (examples):${NC} ${YELLOW}51820/udp${NC}, ${YELLOW}1090:443/udp${NC}"
            read_forward_mappings "Enter UDP forward ports/mappings (comma-separated)" FORWARD_UDP_MAPPINGS "" "udp"
            if [ -n "$FORWARD_TCP_MAPPINGS" ] && [ -n "$FORWARD_UDP_MAPPINGS" ]; then
                FORWARD_MAPPINGS="${FORWARD_TCP_MAPPINGS},${FORWARD_UDP_MAPPINGS}"
            elif [ -n "$FORWARD_TCP_MAPPINGS" ]; then
                FORWARD_MAPPINGS="$FORWARD_TCP_MAPPINGS"
            elif [ -n "$FORWARD_UDP_MAPPINGS" ]; then
                FORWARD_MAPPINGS="$FORWARD_UDP_MAPPINGS"
            else
                print_error "No valid TCP/UDP forward mappings were provided."
                return 1
            fi
            ;;
        *)
            print_error "Invalid selection"
            return 1
            ;;
    esac
    
    # Check port conflicts
    echo ""
    IFS=',' read -ra MAPPING_SPECS <<< "$FORWARD_MAPPINGS"
    for spec in "${MAPPING_SPECS[@]}"; do
        spec=$(echo "$spec" | tr -d ' ')
        local listen_port
        local listen_proto
        listen_port=$(mapping_listen_port "$spec")
        listen_proto=$(mapping_protocol "$spec")
        check_port_conflict_proto "$listen_port" "$listen_proto" || return 0
    done

    # PaqX-style automatic profile (CPU/RAM-aware)
    echo ""
    calculate_auto_kcp_profile
    apply_low_mtu_upload_stability_profile "$(detect_interface_mtu "$interface" 2>/dev/null || true)"
    show_auto_kcp_profile
    
    # Download paqet (only if binary doesn't exist yet)
    if [ ! -f "$PAQET_BIN" ]; then
        download_paqet || return 0
    else
        print_success "paqet binary already installed"
    fi
    
    # Create forward configuration
    print_step "Creating configuration..."
    
    # Build forward section
    local forward_config=""
    if ! build_forward_config_from_mappings_csv "$FORWARD_MAPPINGS" forward_config; then
        print_error "Failed to build forward configuration from mappings: $FORWARD_MAPPINGS"
        return 1
    fi

    local profile_network_pcap_fragment=""
    local profile_transport_buf_fragment=""
    local profile_kcp_extra_fragment=""
    local profile_conn_value=""
    local profile_kcp_block=""
    local profile_kcp_mtu=""
    local profile_kcp_mode=""
    build_profile_network_pcap_fragment "client" profile_network_pcap_fragment
    build_profile_transport_buffer_fragment profile_transport_buf_fragment
    build_profile_kcp_extra_fragment profile_kcp_extra_fragment
    profile_conn_value=$(get_effective_profile_conn_value)
    profile_kcp_block=$(get_effective_profile_kcp_block)
    profile_kcp_mtu=$(get_effective_profile_kcp_mtu_for_interface "$interface")
    profile_kcp_mode=$(get_effective_profile_kcp_mode)
    
    cat > "$PAQET_CONFIG" << EOF
# paqet Client Configuration (Port Forwarding Mode)
# Tunnel: ${TUNNEL_NAME}
# Generated by installer on $(date)
role: "client"

log:
  level: "info"

# Port forwarding - accepts connections and forwards through tunnel
forward:${forward_config}

network:
  interface: "${interface}"
  ipv4:
    addr: "${local_ip}:0"
    router_mac: "${gateway_mac}"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
${profile_network_pcap_fragment}

server:
  addr: "${SERVER_B_IP}:${SERVER_B_PORT}"

transport:
  protocol: "kcp"${profile_transport_buf_fragment}
  conn: ${profile_conn_value}
  kcp:
    mode: "${profile_kcp_mode}"
    key: "${SECRET_KEY}"
    mtu: ${profile_kcp_mtu}
    block: "${profile_kcp_block}"
${profile_kcp_extra_fragment}
EOF
    secure_file_permissions "$PAQET_CONFIG" 600
    
    print_success "Configuration created: $PAQET_CONFIG"
    
    # Setup iptables protection rules for tunnel to Server B
    setup_iptables_client "$SERVER_B_IP" "$SERVER_B_PORT"
    apply_paqx_kernel_optimizations
    
    # Create systemd service
    create_systemd_service
    
    # Start service
    systemctl_or_dry_run enable --now "$PAQET_SERVICE"
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}          Server A Tunnel '${TUNNEL_NAME}' Ready!              ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${YELLOW}Tunnel Name:${NC}   ${CYAN}$TUNNEL_NAME${NC}"
    echo -e "  ${YELLOW}This Server:${NC}   ${CYAN}$public_ip${NC}"
    echo -e "  ${YELLOW}Server B:${NC}      ${CYAN}$SERVER_B_IP:$SERVER_B_PORT${NC}"
    echo -e "  ${YELLOW}Forwarding:${NC}    ${CYAN}$FORWARD_MAPPINGS${NC}"
    echo ""
    echo -e "${YELLOW}Client Connection:${NC}"
    echo -e "  Clients should connect to: ${CYAN}$advertised_host${NC}"
    local listen_ports_summary=""
    local listen_ports_summary_tcp=""
    local listen_ports_summary_udp=""
    for spec in "${MAPPING_SPECS[@]}"; do
        spec=$(echo "$spec" | tr -d ' ')
        local lp
        local proto
        lp=$(mapping_listen_port "$spec")
        proto=$(mapping_protocol "$spec")
        listen_ports_summary="${listen_ports_summary}${listen_ports_summary:+,}${lp}/${proto}"
        if [ "$proto" = "udp" ]; then
            listen_ports_summary_udp="${listen_ports_summary_udp}${listen_ports_summary_udp:+,}${lp}"
        else
            listen_ports_summary_tcp="${listen_ports_summary_tcp}${listen_ports_summary_tcp:+,}${lp}"
        fi
    done
    echo -e "  On ports: ${CYAN}$listen_ports_summary${NC}"
    [ -n "$listen_ports_summary_tcp" ] && echo -e "  TCP ports: ${CYAN}$listen_ports_summary_tcp${NC}"
    [ -n "$listen_ports_summary_udp" ] && echo -e "  UDP ports: ${CYAN}$listen_ports_summary_udp${NC}"
    if [ "$advertised_host" != "$public_ip" ]; then
        echo -e "  ${YELLOW}(Detected local IP was:${NC} ${CYAN}$public_ip${NC}${YELLOW})${NC}"
    fi
    echo ""
    echo -e "${YELLOW}Example endpoint updates:${NC}"
    for spec in "${MAPPING_SPECS[@]}"; do
        spec=$(echo "$spec" | tr -d ' ')
        local listen_port target_port proto
        listen_port=$(mapping_listen_port "$spec")
        target_port=$(mapping_target_port "$spec")
        proto=$(mapping_protocol "$spec")
        echo -e "  ${CYAN}[${proto}]${NC} ${RED}${SERVER_B_IP}:${target_port}${NC}  ->  ${GREEN}${advertised_host}:${listen_port}${NC}"
    done
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  Status:  ${CYAN}systemctl status $PAQET_SERVICE${NC}"
    echo -e "  Logs:    ${CYAN}journalctl -u $PAQET_SERVICE -f${NC}"
    echo -e "  Restart: ${CYAN}systemctl restart $PAQET_SERVICE${NC}"
    echo ""
    echo -e "${YELLOW}To add another tunnel, run setup again and choose a different name.${NC}"
    echo ""

    # Print Passwall client recommendation
    print_passwall_recommendation "$advertised_host" "$listen_ports_summary_tcp" "$SECRET_KEY"
}

#===============================================================================
# Passwall / Client Recommendation Output
#===============================================================================

print_passwall_recommendation() {
    local host="${1:-SERVER_A_IP}"
    local ports="${2:-1090}"
    local secret="${3:-}"
    local first_port=""
    first_port=$(echo "$ports" | cut -d',' -f1 | tr -d ' ')
    [ -z "$first_port" ] && first_port="1090"

    # Generate a deterministic UUID from the secret if provided
    local uuid="3f06bf23-25e7-441c-aff1-f2eb8eeb5916"
    if [ -n "$secret" ]; then
        uuid=$(echo -n "$secret" | md5sum 2>/dev/null | awk '{printf "%.8s-%.4s-%.4s-%.4s-%.12s", substr($1,1,8), substr($1,9,4), substr($1,13,4), substr($1,17,4), substr($1,21,12)}' || echo "$uuid")
    fi

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Passwall / Client Recommendation                    ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Recommended Passwall Settings:${NC}"
    echo -e "  ${CYAN}Mux:${NC}              ${GREEN}OFF${NC}"
    echo -e "  ${CYAN}TCP Fast Open:${NC}    ${GREEN}ON${NC}"
    echo -e "  ${CYAN}TLS:${NC}              ${GREEN}OFF${NC}"
    echo -e "  ${CYAN}Transport:${NC}        ${GREEN}TCP RAW${NC}"
    echo -e "  ${CYAN}MPTCP:${NC}           ${GREEN}OFF${NC}"
    echo -e "  ${CYAN}Pre-connections:${NC}  ${GREEN}0${NC}"
    echo ""
    echo -e "${YELLOW}Client URI (VLESS + TCP RAW):${NC}"
    echo -e "  ${CYAN}vless://${uuid}@${host}:${first_port}?headerType=none&type=tcp&encryption=none#Paqet-${TUNNEL_NAME:-Local}${NC}"
    echo ""

    local second_port=""
    second_port=$(echo "$ports" | cut -d',' -f2 | tr -d ' ' 2>/dev/null || true)
    if [ -n "$second_port" ]; then
        echo -e "${YELLOW}Additional ports available:${NC}"
        for port in $(echo "$ports" | tr ',' ' '); do
            port=$(echo "$port" | tr -d ' ')
            [ "$port" = "$first_port" ] && continue
            echo -e "  ${CYAN}vless://${uuid}@${host}:${port}?headerType=none&type=tcp&encryption=none#Paqet-${TUNNEL_NAME:-Local}-${port}${NC}"
        done
        echo ""
    fi

    echo -e "${YELLOW}Monitoring Commands:${NC}"
    echo -e "  ${CYAN}# Check ENOBUFS/retry metrics${NC}"
    echo -e "  journalctl -u ${PAQET_SERVICE:-paqet} --no-pager -n 100 | grep -E 'raw_packet|tcp_write|ENOBUFS|retry'"
    echo ""
    echo -e "  ${CYAN}# Live throughput${NC}"
    echo -e "  iftop -i $(get_default_interface 2>/dev/null || echo eth0)"
    echo ""
    echo -e "${YELLOW}Rollback:${NC}"
    echo -e "  ${CYAN}sudo cp ${PAQET_DIR:-/opt/paqet}/paqet.v1.bak ${PAQET_BIN:-/opt/paqet/paqet}${NC}"
    echo -e "  ${CYAN}sudo systemctl restart ${PAQET_SERVICE:-paqet}${NC}"
    echo ""
}

#===============================================================================
# Status Check
#===============================================================================

check_status() {
    print_banner
    echo -e "${YELLOW}paqet Status${NC}"
    echo ""
    
    local configs
    configs=$(get_all_configs)
    
    if [ -z "$configs" ]; then
        print_error "No paqet configurations found"
        print_info "Run setup first"
        return 1
    fi
    
    # Show status of each tunnel
    while IFS= read -r config_file; do
        local name
        name=$(get_tunnel_name "$config_file")
        local service
        service=$(get_tunnel_service "$config_file")
        local role
        role=$(grep "^role:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')
        
        echo -e "${YELLOW}── Tunnel: ${CYAN}${name}${YELLOW} (${role}) ──${NC}"
        
        # Service status
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo -e "  Service: ${GREEN}● Running${NC}"
            local uptime
            uptime=$(systemctl show "$service" --property=ActiveEnterTimestamp 2>/dev/null | cut -d'=' -f2)
            [ -n "$uptime" ] && echo -e "  Started: ${CYAN}$uptime${NC}"
        else
            echo -e "  Service: ${RED}● Stopped${NC}"
        fi
        
        # Details
        if [ "$role" = "server" ]; then
            local listen
            listen=$(grep -A1 "^listen:" "$config_file" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"')
            echo -e "  Listen:  ${CYAN}$listen${NC}"
        else
            local server
            server=$(grep -A1 "^server:" "$config_file" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"')
            local forward_ports
            forward_ports=$(grep 'listen:' "$config_file" 2>/dev/null | grep -oE ':[0-9]+"' | tr -d ':"' | tr '\n' ',' | sed 's/,$//')
            echo -e "  Server B: ${CYAN}$server${NC}"
            echo -e "  Ports:   ${CYAN}$forward_ports${NC}"
        fi
        
        # Recent logs (last 3 lines)
        local recent
        recent=$(journalctl -u "$service" -n 3 --no-pager 2>/dev/null | tail -3)
        if [ -n "$recent" ]; then
            echo -e "  ${YELLOW}Recent logs:${NC}"
            echo "$recent" | while IFS= read -r line; do
                echo "    $line"
            done
        fi
        
        echo ""
    done <<< "$configs"
    
    # Listening ports
    echo -e "${YELLOW}Listening Ports:${NC}"
    ss -tuln 2>/dev/null | grep -E "LISTEN" | awk '{print "  "$5}' | head -10 || echo "  None"
    
    echo ""
}

#===============================================================================
# Uninstall
#===============================================================================

get_active_binary_path() {
    local svc="$1"
    local bin_path=""
    bin_path=$(systemctl cat "$svc" 2>/dev/null | grep "^ExecStart=" | head -1 | sed 's/ExecStart=//' | awk '{print $1}')
    if [ -z "$bin_path" ]; then
        bin_path=$(systemctl show -p ExecStart "$svc" 2>/dev/null | grep -o 'path=[^;]*' | cut -d= -f2 | head -1)
    fi
    echo "$bin_path"
}

health_check_tunnel() {
    local config_file="$1"
    local name
    name=$(get_tunnel_name "$config_file")
    local service
    service=$(get_tunnel_service "$config_file")
    local role
    role=$(grep "^role:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')

    local status="OK"
    local reason=""
    
    local active_binary
    active_binary=$(get_active_binary_path "$service")

    if [ -z "$active_binary" ] || [ ! -x "$active_binary" ]; then
        status="FAIL"
        reason="binary missing"
    elif ! systemctl is-active --quiet "$service" 2>/dev/null; then
        status="FAIL"
        reason="service inactive"
    elif [ ! -f "$config_file" ]; then
        status="FAIL"
        reason="config missing"
    fi

    local listen_port=""
    local server_port=""
    if [ "$role" = "server" ]; then
        listen_port=$(grep -A1 "^listen:" "$config_file" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"' | cut -d: -f2)
    else
        listen_port=$(grep -oE ':[0-9]+"' "$config_file" 2>/dev/null | head -1 | tr -d ':"')
    fi

    if [ "$status" = "OK" ] && [ -n "$listen_port" ]; then
        if [ "$role" != "server" ]; then
            if ! ss -tuln 2>/dev/null | grep -q ":$listen_port "; then
                status="FAIL"
                reason="port $listen_port missing"
            fi
        fi
    fi

    local panic_cnt=0
    local retry_failed_cnt=0
    local msg_large_cnt=0
    local conn_lost_cnt=0
    local enobufs_cnt=0

    if [ "$status" = "OK" ] || [ "$status" = "WARN" ]; then
        local logs
        logs=$(journalctl -u "$service" -n 100 --no-pager 2>/dev/null | grep -v "metrics initialized:" || true)

        panic_cnt=$(echo "$logs" | grep -i "panic" -c || true)
        retry_failed_cnt=$(echo "$logs" | grep -i "retry_failed" -c || true)
        msg_large_cnt=$(echo "$logs" | grep -i "Message too large" -c || true)
        conn_lost_cnt=$(echo "$logs" | grep -i "connection lost" -c || true)
        enobufs_cnt=$(echo "$logs" | grep -i "ENOBUFS" -c || true)

        if [ "$panic_cnt" -gt 0 ]; then
            status="FAIL"
            reason="panic found ($panic_cnt)"
        elif [ "$msg_large_cnt" -gt 0 ]; then
            status="FAIL"
            reason="Message too large ($msg_large_cnt)"
        elif [ "$retry_failed_cnt" -gt 0 ]; then
            status="FAIL"
            reason="retry_failed > 0 ($retry_failed_cnt)"
        elif [ "$conn_lost_cnt" -gt 5 ]; then
            status="WARN"
            reason="high connection_lost ($conn_lost_cnt)"
        elif [ "$conn_lost_cnt" -gt 0 ]; then
            status="WARN"
            reason="connection_lost ($conn_lost_cnt)"
        elif [ "$enobufs_cnt" -gt 0 ]; then
            status="WARN"
            reason="ENOBUFS recovered"
        fi
    fi

    local mem_rss=0
    local restarts=0
    if [ "$status" != "FAIL" ]; then
        local pid
        pid=$(systemctl show -p MainPID "$service" 2>/dev/null | cut -d= -f2)
        if [ -n "$pid" ] && [ "$pid" -gt 0 ]; then
            mem_rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)
            if [ -n "$mem_rss" ] && [ "$mem_rss" -gt 0 ]; then
                mem_rss=$((mem_rss / 1024))
            else
                mem_rss=0
            fi
            
            if [ "$mem_rss" -gt 150 ] && [ "$status" = "OK" ]; then
                status="WARN"
                reason="high memory (${mem_rss}MB)"
            fi
        fi
        
        restarts=$(systemctl show -p NRestarts "$service" 2>/dev/null | cut -d= -f2)
        if [ -n "$restarts" ] && [ "$restarts" -gt 0 ] && [ "$status" = "OK" ]; then
            status="WARN"
            reason="restarts=$restarts"
        fi
    fi

    if [ -z "$reason" ]; then
        reason="port=$listen_port retry_failed=0 mem=${mem_rss}MB"
    fi

    if [ "$status" = "OK" ]; then
        printf "%-15s ${GREEN}%-6s${NC} %s\n" "$name" "$status" "$reason"
    elif [ "$status" = "WARN" ]; then
        printf "%-15s ${YELLOW}%-6s${NC} %s\n" "$name" "$status" "$reason"
    else
        printf "%-15s ${RED}%-6s${NC} %s\n" "$name" "$status" "$reason"
    fi
}

health_check_all_tunnels() {
    print_banner
    echo -e "${YELLOW}Health Check Report${NC}"
    echo ""
    local configs
    configs=$(get_all_configs)
    
    if [ -z "$configs" ]; then
        print_error "No configurations found"
        return 1
    fi
    
    while IFS= read -r config_file; do
        health_check_tunnel "$config_file"
    done <<< "$configs"
    echo ""
}

health_check_menu() {
    health_check_all_tunnels
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r < /dev/tty
}

download_recoba_core() {
    local target_version="$1"
    local arch
    arch=$(detect_arch)
    
    local base_url="https://github.com/Recoba86/recoba-tunnel/releases/download/${target_version}"
    local tarball="recoba-tunnel-linux-${arch}.tar.gz"
    local checksums="SHA256SUMS"
    
    local temp_dir
    temp_dir=$(mktemp -d /tmp/recoba_update.XXXXXX)
    
    print_step "Downloading $tarball..."
    if ! curl -fsSL --max-time 30 "${base_url}/${tarball}" -o "${temp_dir}/${tarball}"; then
        print_error "Failed to download core tarball"
        rm -rf "$temp_dir"
        return 1
    fi
    
    print_step "Downloading SHA256SUMS..."
    if ! curl -fsSL --max-time 15 "${base_url}/${checksums}" -o "${temp_dir}/${checksums}"; then
        print_error "Failed to download SHA256SUMS"
        rm -rf "$temp_dir"
        return 1
    fi
    
    print_step "Verifying checksums..."
    if ! (
        cd "$temp_dir" || exit 1
        # Extract the specific line for our tarball from SHA256SUMS and verify it
        if grep "$tarball" "$checksums" > "local_${checksums}"; then
            if ! sha256sum -c "local_${checksums}" --status; then
                exit 1
            fi
        else
            exit 1
        fi
    ); then
        print_error "Checksum verification failed! Aborting."
        rm -rf "$temp_dir"
        return 1
    fi
    print_success "Checksum verified successfully."
    
    print_step "Extracting binary..."
    if ! tar -xzf "${temp_dir}/${tarball}" -C "$temp_dir" recoba-tunnel 2>/dev/null; then
        print_error "Failed to extract tarball"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if [ ! -x "${temp_dir}/recoba-tunnel" ]; then
        print_error "Extracted binary not found or not executable"
        rm -rf "$temp_dir"
        return 1
    fi
    
    local ext_ver
    ext_ver=$("${temp_dir}/recoba-tunnel" version 2>/dev/null | grep -i version || true)
    if [ -n "$ext_ver" ]; then
        print_info "Extracted: $ext_ver"
    fi
    
    # Return the temp dir to the caller
    echo "$temp_dir"
    return 0
}

safe_update_core() {
    print_banner
    echo -e "${YELLOW}Safe Auto-Update: Recoba Tunnel Core${NC}"
    echo ""
    
    local installed_ver
    installed_ver=$(get_installed_paqet_version_text)
    
    # Discover active binary from the first tunnel service (or default legacy)
    local configs
    configs=$(get_all_configs)
    local sample_service="paqet.service"
    if [ -n "$configs" ]; then
        local first_cfg
        first_cfg=$(echo "$configs" | head -1)
        sample_service=$(get_tunnel_service "$first_cfg")
    fi
    
    local active_binary
    active_binary=$(get_active_binary_path "$sample_service")
    if [ -z "$active_binary" ] || [ ! -f "$active_binary" ]; then
        active_binary="/opt/paqet/paqet" # fallback
        if [ ! -f "$active_binary" ]; then
            active_binary="/opt/recoba-tunnel/recoba-tunnel"
        fi
    fi
    
    print_info "Active binary path: ${CYAN}${active_binary}${NC}"
    print_info "Installed version:  ${CYAN}${installed_ver}${NC}"
    
    print_step "Querying latest release from GitHub..."
    local release_info
    release_info=$(curl -s --max-time 10 "https://api.github.com/repos/Recoba86/recoba-tunnel/releases/latest" 2>/dev/null)
    local latest_tag
    latest_tag=$(echo "$release_info" | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
    
    if [ -z "$latest_tag" ]; then
        print_error "Could not fetch latest release"
        return 1
    fi
    
    # Ensure tag starts with v
    if [[ ! "$latest_tag" == v* ]]; then
        latest_tag="v$latest_tag"
    fi
    print_info "Latest release:     ${CYAN}${latest_tag}${NC}"
    
    # Simple check if already up to date (this handles basic vX.Y.Z matches)
    local old_ver
    old_ver=$(extract_recoba_version_from_text "$installed_ver")
    local current_cleaned="${old_ver#v}"
    local latest_cleaned="${latest_tag#v}"
    
    if [ "$current_cleaned" = "$latest_cleaned" ]; then
        print_success "Already up to date."
        return 0
    fi
    
    local do_update=false
    read_confirm "Update core binary to ${latest_tag}?" do_update "y"
    [ "$do_update" != true ] && return 0
    
    if is_dry_run; then
        dry_run_notice "would download $latest_tag and verify SHA256SUMS"
        dry_run_notice "would backup $active_binary"
        dry_run_notice "would install new binary to $active_binary"
        dry_run_notice "would restart all active tunnel services"
        dry_run_notice "would run health check"
        dry_run_notice "would rollback if health check fails"
        print_success "DRY-RUN: core not updated"
        return 0
    fi
    
    local temp_dir
    temp_dir=$(download_recoba_core "$latest_tag" | tail -1)
    if [ ! -d "$temp_dir" ]; then
        return 1
    fi
    
    local new_binary="${temp_dir}/recoba-tunnel"
    
    print_step "Backing up current binary..."
    local timestamp
    timestamp=$(date +%Y-%m-%d-%H%M%S 2>/dev/null || date +%Y%m%d%H%M%S)
    local backup_path="${active_binary}.from-${old_ver}.to-${latest_tag}.${timestamp}.bak"
    if ! cp "$active_binary" "$backup_path" 2>/dev/null; then
        print_error "Failed to create backup at $backup_path"
        rm -rf "$temp_dir"
        return 1
    fi
    print_success "Backup created: $backup_path"
    
    print_step "Installing new binary..."
    if ! cp "$new_binary" "${active_binary}.tmp" 2>/dev/null || ! chmod +x "${active_binary}.tmp" || ! mv -f "${active_binary}.tmp" "$active_binary" 2>/dev/null; then
        print_error "Failed to replace binary"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Keep track of updated version in metadata if applicable
    # We do not strictly need to update CORE_VERSION because get_installed_paqet_version_text runs the binary itself.
    
    print_step "Restarting active services..."
    restart_paqet_services_after_core_update
    
    print_step "Running health check on all tunnels..."
    # We will capture the output and count FAILS.
    local health_out
    health_out=$(health_check_all_tunnels)
    echo "$health_out"
    
    if echo "$health_out" | grep -q "FAIL"; then
        print_error "Health check FAILED for one or more tunnels!"
        print_warning "Initiating automatic rollback..."
        
        if cp "$backup_path" "${active_binary}.tmp" 2>/dev/null && chmod +x "${active_binary}.tmp" && mv -f "${active_binary}.tmp" "$active_binary" 2>/dev/null; then
            print_success "Binary restored from backup."
            restart_paqet_services_after_core_update
            print_info "Rollback complete. System returned to ${old_ver}."
        else
            print_error "CRITICAL: Rollback failed. Manual intervention required!"
            print_error "Backup is at: $backup_path"
        fi
        rm -rf "$temp_dir"
        return 1
    elif echo "$health_out" | grep -q "WARN"; then
        print_warning "Update succeeded, but health check returned WARN."
        print_warning "Review the health report above. No automatic rollback performed."
    else
        print_success "Update successful! All tunnels reported OK."
    fi
    
    rm -rf "$temp_dir"
    return 0
}


uninstall() {
    print_banner
    echo -e "${YELLOW}Uninstalling paqet...${NC}"
    echo ""
    
    local configs
    configs=$(get_all_configs)
    
    if [ -n "$configs" ]; then
        echo -e "${YELLOW}Active tunnels:${NC}"
        echo ""
        list_tunnels
        echo ""
    fi

    if is_dry_run; then
        dry_run_notice "would stop and disable paqet services"
        dry_run_notice "would remove paqet systemd units and auto-reset units"
        dry_run_notice "would remove iptables/raw/mangle rules"
        dry_run_notice "would optionally remove $PAQET_DIR and $INSTALLER_CMD after confirmation"
        dry_run_notice "would remove kernel optimization file: $OPTIMIZE_SYSCTL_FILE"
        print_success "DRY-RUN: uninstall did not modify the host"
        return 0
    fi
    
    # Stop and disable ALL tunnel services
    print_step "Stopping all paqet services..."
    
    if [ -n "$configs" ]; then
        while IFS= read -r config_file; do
            local service
            service=$(get_tunnel_service "$config_file")
            local name
            name=$(get_tunnel_name "$config_file")
            systemctl stop "$service" 2>/dev/null || true
            systemctl disable "$service" 2>/dev/null || true
            rm -f "/etc/systemd/system/${service}.service"
            print_success "  Stopped: $name ($service)"
        done <<< "$configs"
    fi
    
    # Also try legacy service in case it wasn't in configs
    systemctl stop paqet 2>/dev/null || true
    systemctl disable paqet 2>/dev/null || true
    rm -f /etc/systemd/system/paqet.service
    
    # Remove auto-reset timer
    systemctl stop ${AUTO_RESET_TIMER}.timer 2>/dev/null || true
    systemctl disable ${AUTO_RESET_TIMER}.timer 2>/dev/null || true
    rm -f /etc/systemd/system/${AUTO_RESET_TIMER}.timer
    rm -f /etc/systemd/system/${AUTO_RESET_SERVICE}.service
    
    systemctl daemon-reload
    print_success "All services removed"
    
    # Remove iptables rules
    print_step "Removing iptables rules..."
    
    # Remove Server B rules (try common ports)
    for port in 8888 9999 8080; do
        iptables_or_dry_run -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || true
        iptables_or_dry_run -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || true
        iptables_or_dry_run -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
        iptables_or_dry_run -t mangle -D PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    done
    
    # Remove Server A (client) rules by reading existing configs
    if [ -n "$configs" ]; then
        while IFS= read -r config_file; do
            local role
            role=$(grep "^role:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')
            if [ "$role" = "client" ]; then
                local server_addr
                server_addr=$(grep -A1 "^server:" "$config_file" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"')
                local s_ip
                s_ip=$(echo "$server_addr" | cut -d':' -f1)
                local s_port
                s_port=$(echo "$server_addr" | cut -d':' -f2)
                if [ -n "$s_ip" ] && [ -n "$s_port" ]; then
                    remove_iptables_client "$s_ip" "$s_port"
                fi
            fi
        done <<< "$configs"
    fi
    remove_mss_clamp_rule
    
    save_iptables
    print_success "iptables rules removed"
    
    # Ask about config preservation
    echo ""
    local remove_all=false
    read_confirm "Remove all configurations and binary?" remove_all "n"
    
    if [ "$remove_all" = true ]; then
        rm -rf "$PAQET_DIR"
        print_success "All paqet files removed"
    else
        print_warning "Configurations preserved at: $PAQET_DIR/"
    fi

    if [ -f "$OPTIMIZE_SYSCTL_FILE" ]; then
        rm -f "$OPTIMIZE_SYSCTL_FILE"
        sysctl --system >/dev/null 2>&1 || true
        print_success "Removed kernel optimization file: $OPTIMIZE_SYSCTL_FILE"
    fi
    
    # Ask about removing the command
    if is_command_installed; then
        echo ""
        local remove_cmd=false
        read_confirm "Also remove 'paqet-tunnel' command?" remove_cmd "n"
        if [ "$remove_cmd" = true ]; then
            uninstall_command
        fi
    fi
    
    echo ""
    print_success "paqet uninstalled"
    echo ""
}

#===============================================================================
# View/Edit Configuration
#===============================================================================

view_config() {
    print_banner
    echo -e "${YELLOW}View Configuration${NC}"
    echo ""
    
    # Select tunnel if multiple exist
    select_tunnel "Select tunnel to view" || return 1
    
    echo ""
    local name
    name=$(get_tunnel_name "$PAQET_CONFIG")
    echo -e "${YELLOW}Configuration for tunnel '${name}':${NC}"
    echo ""
    
    if [ -f "$PAQET_CONFIG" ]; then
        cat "$PAQET_CONFIG"
    else
        print_error "Configuration not found at $PAQET_CONFIG"
    fi
    
    echo ""
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r < /dev/tty
}

#===============================================================================
# Edit Configuration
#===============================================================================

edit_config() {
    print_banner
    echo -e "${YELLOW}Edit Configuration${NC}"
    echo ""
    
    # Select tunnel if multiple exist
    select_tunnel "Select tunnel to edit" || return 1
    
    # Detect current role
    local role
    role=$(grep "^role:" "$PAQET_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"')
    local name
    name=$(get_tunnel_name "$PAQET_CONFIG")
    
    echo ""
    echo -e "Tunnel: ${CYAN}$name${NC}  Role: ${CYAN}$role${NC}"
    echo ""
    echo -e "${YELLOW}What would you like to edit?${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} Port Settings (V2Ray/paqet ports)"
    echo -e "  ${CYAN}2)${NC} Change secret key"
    echo -e "  ${CYAN}3)${NC} Change KCP settings"
    echo -e "  ${CYAN}4)${NC} Change network interface"
    if [ "$role" = "client" ]; then
        echo -e "  ${CYAN}5)${NC} Change Server B address"
    fi
    echo -e "  ${CYAN}6)${NC} Manual edit config file (advanced)"
    echo -e "  ${CYAN}0)${NC} Back to main menu"
    echo ""
    
    read -r -p "Choice: " edit_choice < /dev/tty
    
    case $edit_choice in
        1) port_settings_menu ;;
        2) edit_secret_key ;;
        3) edit_kcp_settings ;;
        4) edit_interface ;;
        5) 
            if [ "$role" = "client" ]; then
                edit_server_address
            else
                print_error "Invalid choice"
            fi
            ;;
        6)
            manual_edit_config_file
            ;;
        0) return 0 ;;
        *) print_error "Invalid choice" ;;
    esac
}

get_preferred_text_editor() {
    if [ -n "$EDITOR" ]; then
        echo "$EDITOR"
        return 0
    fi
    if command -v nano >/dev/null 2>&1; then
        echo "nano"
        return 0
    fi
    if command -v vim >/dev/null 2>&1; then
        echo "vim"
        return 0
    fi
    if command -v vi >/dev/null 2>&1; then
        echo "vi"
        return 0
    fi
    return 1
}

manual_edit_config_file() {
    echo ""
    echo -e "${YELLOW}Manual Config Edit (Advanced)${NC}"
    echo -e "${CYAN}File:${NC} $PAQET_CONFIG"
    echo ""
    print_warning "You are about to edit the raw YAML config manually."
    print_warning "Invalid YAML or wrong values can prevent the service from starting."
    echo ""

    if [ ! -f "$PAQET_CONFIG" ]; then
        print_error "Configuration file not found: $PAQET_CONFIG"
        return 1
    fi

    local editor_cmd=""
    if ! editor_cmd=$(get_preferred_text_editor); then
        print_error "No editor found (set \$EDITOR or install nano/vim/vi)."
        return 1
    fi

    local backup_file
    backup_file="${PAQET_CONFIG}.manualedit.bak.$(date +%s)"
    if is_dry_run; then
        dry_run_notice "would create manual-edit backup: $backup_file"
        dry_run_notice "would open editor '$editor_cmd' for: $PAQET_CONFIG"
        print_success "DRY-RUN: config not edited"
        return 0
    fi
    if cp "$PAQET_CONFIG" "$backup_file" 2>/dev/null; then
        secure_file_permissions "$backup_file" 600
        print_info "Backup created: $backup_file"
    else
        print_warning "Could not create backup file before editing"
    fi

    echo -e "${CYAN}Opening with:${NC} $editor_cmd"
    echo ""

    # Support simple EDITOR values with arguments (e.g. "vim -u NONE") without
    # evaluating shell syntax as root. Complex shell wrappers should be exposed
    # through a real executable on PATH instead.
    if [[ "$editor_cmd" =~ [\;\&\|\>\<\`\$\(] ]]; then
        print_error "Refusing unsafe EDITOR value with shell metacharacters: $editor_cmd"
        print_info "Use a direct editor command such as nano, vim, vi, or an executable wrapper script."
        return 1
    fi

    local editor_args=()
    read -r -a editor_args <<< "$editor_cmd"
    if [ "${#editor_args[@]}" -eq 0 ] || ! command -v "${editor_args[0]}" >/dev/null 2>&1; then
        print_error "Editor command not found: ${editor_args[0]:-$editor_cmd}"
        return 1
    fi

    if ! "${editor_args[@]}" "$PAQET_CONFIG" < /dev/tty > /dev/tty 2>&1; then
        print_warning "Editor exited with a non-zero status"
    fi

    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply manual changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        if systemctl restart "$PAQET_SERVICE" >/dev/null 2>&1; then
            print_success "Service restarted"
        else
            print_error "Service failed to restart"
            print_info "Check logs: journalctl -u $PAQET_SERVICE -n 50"
        fi
    fi
}

edit_ports() {
    local role=$1
    echo ""
    
    if [ "$role" = "server" ]; then
        local current_port
        current_port=$(grep -A1 "^listen:" "$PAQET_CONFIG" | grep "addr:" | sed 's/.*:\([0-9]*\)".*/\1/')
        read_port "Enter new paqet listen port" NEW_PORT "$current_port"
        
        # Update config file
        sed_inplace "s/addr: \":[0-9]*\"/addr: \":${NEW_PORT}\"/" "$PAQET_CONFIG"
        
        # Update iptables
        setup_iptables "$NEW_PORT"
        
        print_success "Port updated to $NEW_PORT"
    else
        echo -e "${CYAN}Current forward configuration:${NC}"
        get_current_forward_mappings | while read -r spec; do
            [ -n "$spec" ] && echo "  - $spec"
        done
        echo ""
        
        local current_mappings
        current_mappings=$(get_current_forward_mappings | paste -sd, -)
        [ -z "$current_mappings" ] && current_mappings="$DEFAULT_FORWARD_PORTS"
        local NEW_MAPPINGS=""
        read_forward_mappings "Enter new forward ports/mappings (comma-separated)" NEW_MAPPINGS "$current_mappings"
        
        # Rebuild forward section
        local forward_config=""
        if ! build_forward_config_from_mappings_csv "$NEW_MAPPINGS" forward_config; then
            print_error "Failed to build forward configuration"
            return 1
        fi
        
        # Use awk to replace the forward section
        awk -v new_forward="forward:${forward_config}" '
            /^forward:/ { in_forward=1; print new_forward; next }
            in_forward && /^[a-z]/ { in_forward=0 }
            !in_forward { print }
        ' "$PAQET_CONFIG" > "${PAQET_CONFIG}.tmp"
        mv "${PAQET_CONFIG}.tmp" "$PAQET_CONFIG"
        
        print_success "Forward mappings updated"
    fi
    
    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
}

#===============================================================================
# V2Ray/Forward Port Settings Menu
#===============================================================================

port_settings_menu() {
    local role
    role=$(grep "^role:" "$PAQET_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"')
    
    while true; do
        print_banner
        echo -e "${YELLOW}Port Settings${NC}"
        echo ""
        
        # Show current configuration
        echo -e "${YELLOW}Current Configuration:${NC}"
        echo -e "  Role: ${CYAN}$role${NC}"
        
        if [ "$role" = "server" ]; then
            local paqet_port
            paqet_port=$(grep -A1 "^listen:" "$PAQET_CONFIG" | grep "addr:" | sed 's/.*:\([0-9]*\)".*/\1/')
            echo -e "  paqet tunnel port: ${CYAN}$paqet_port${NC}"
            echo ""
            echo -e "${YELLOW}Note:${NC} Server B doesn't configure V2Ray ports directly."
            echo -e "       V2Ray runs separately on its own ports."
        else
            local server_addr
            server_addr=$(grep -A1 "^server:" "$PAQET_CONFIG" | grep "addr:" | awk '{print $2}' | tr -d '"')
            local server_port
            server_port=$(echo "$server_addr" | cut -d':' -f2)
            echo -e "  Server B paqet port: ${CYAN}$server_port${NC}"
            echo ""
            echo -e "  ${YELLOW}Forward Mappings (Iran -> Server B local, TCP/UDP):${NC}"
            get_current_forward_mappings | while read -r spec; do
                [ -z "$spec" ] && continue
                echo -e "    - ${CYAN}$spec${NC}"
            done
        fi
        
        echo ""
        echo -e "${YELLOW}Options:${NC}"
        echo ""
        
        if [ "$role" = "server" ]; then
            echo -e "  ${CYAN}1)${NC} Change paqet tunnel port"
        else
            echo -e "  ${CYAN}1)${NC} Change paqet tunnel port (Server B connection)"
            echo -e "  ${CYAN}2)${NC} Add forward mapping(s) (TCP/UDP)"
            echo -e "  ${CYAN}3)${NC} Remove forward mapping (TCP/UDP)"
            echo -e "  ${CYAN}4)${NC} Replace all forward mappings (TCP/UDP)"
        fi
        echo -e "  ${CYAN}0)${NC} Back to main menu"
        echo ""
        
        read -r -p "Choice: " port_choice < /dev/tty
        
        case $port_choice in
            1) 
                if [ "$role" = "server" ]; then
                    change_paqet_port_server
                else
                    change_paqet_port_client
                fi
                ;;
            2) 
                if [ "$role" = "client" ]; then
                    add_forward_ports
                else
                    print_error "Invalid choice"
                fi
                ;;
            3) 
                if [ "$role" = "client" ]; then
                    remove_forward_port
                else
                    print_error "Invalid choice"
                fi
                ;;
            4) 
                if [ "$role" = "client" ]; then
                    replace_all_forward_ports
                else
                    print_error "Invalid choice"
                fi
                ;;
            0) return 0 ;;
            *) print_error "Invalid choice" ;;
        esac
        
        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read -r < /dev/tty
    done
}

# Get current forward ports from config
get_current_forward_ports() {
    # Extract port from listen: "0.0.0.0:PORT" format
    grep 'listen:' "$PAQET_CONFIG" 2>/dev/null | grep -oE ':[0-9]+"' | tr -d ':"' | sort -nu
}

# Get current forward mappings from config
# Outputs one item per line:
#   443
#   8443:443
#   51820/udp
#   1090:443/udp
get_current_forward_mappings() {
    awk '
        /^forward:/ { in_forward=1; next }
        in_forward && /^[a-z]/ { in_forward=0 }
        in_forward && /listen:/ {
            line=$0
            sub(/^.*:/, "", line)
            sub(/".*$/, "", line)
            listen=line
        }
        in_forward && /target:/ {
            line=$0
            sub(/^.*:/, "", line)
            sub(/".*$/, "", line)
            target=line
        }
        in_forward && /protocol:/ {
            line=$0
            sub(/^.*protocol:[[:space:]]*/, "", line)
            gsub(/"/, "", line)
            sub(/[[:space:]]*#.*$/, "", line)
            gsub(/[[:space:]]/, "", line)
            proto=line
            if (proto == "") proto="tcp"
            if (listen != "") {
                if (target == "" || target == listen) spec=listen
                else spec=listen ":" target
                if (proto == "udp") spec=spec "/udp"
                print spec
                listen=""
                target=""
                proto=""
            }
        }
    ' "$PAQET_CONFIG" 2>/dev/null
}

has_udp_forward_entries() {
    get_current_forward_mappings 2>/dev/null | grep -q '/udp$'
}

# Change paqet port on Server B
change_paqet_port_server() {
    echo ""
    local current_port
    current_port=$(grep -A1 "^listen:" "$PAQET_CONFIG" | grep "addr:" | sed 's/.*:\([0-9]*\)".*/\1/')
    local current_ip_port
    current_ip_port=$(grep -A2 "^network:" "$PAQET_CONFIG" | grep -A1 "ipv4:" | grep "addr:" | awk '{print $2}' | tr -d '"')
    local current_ip
    current_ip=$(echo "$current_ip_port" | cut -d':' -f1)
    
    echo -e "Current paqet port: ${CYAN}$current_port${NC}"
    echo ""
    
    read_port "Enter new paqet listen port" NEW_PORT "$current_port"
    
    if [ "$NEW_PORT" = "$current_port" ]; then
        print_info "Port unchanged"
        return 0
    fi
    
    # Check port conflict
    check_port_conflict "$NEW_PORT" || return 0
    
    # Update listen section
    sed_inplace "s/addr: \":[0-9]*\"/addr: \":${NEW_PORT}\"/" "$PAQET_CONFIG"
    
    # Update network.ipv4.addr section
    sed_inplace "s|addr: \"${current_ip}:[0-9]*\"|addr: \"${current_ip}:${NEW_PORT}\"|" "$PAQET_CONFIG"
    
    # Update iptables
    setup_iptables "$NEW_PORT"
    
    print_success "paqet port updated to $NEW_PORT"
    
    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
    
    echo ""
    print_warning "Remember to update Server A with the new port!"
}

# Change paqet port on Server A (connection to Server B)
change_paqet_port_client() {
    echo ""
    local server_addr
    server_addr=$(grep -A1 "^server:" "$PAQET_CONFIG" | grep "addr:" | awk '{print $2}' | tr -d '"')
    local server_ip
    server_ip=$(echo "$server_addr" | cut -d':' -f1)
    local server_port
    server_port=$(echo "$server_addr" | cut -d':' -f2)
    
    echo -e "Current Server B address: ${CYAN}$server_addr${NC}"
    echo ""
    
    read_port "Enter Server B paqet port" NEW_PORT "$server_port"
    
    if [ "$NEW_PORT" = "$server_port" ]; then
        print_info "Port unchanged"
        return 0
    fi
    
    # Update server address
    sed_inplace "s|addr: \"${server_ip}:${server_port}\"|addr: \"${server_ip}:${NEW_PORT}\"|" "$PAQET_CONFIG"
    
    # Update iptables rules for new port
    remove_iptables_client "$server_ip" "$server_port"
    setup_iptables_client "$server_ip" "$NEW_PORT"
    
    print_success "Server B port updated to $NEW_PORT"
    
    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
}

# Add new forward port(s)
add_forward_ports() {
    echo ""
    echo -e "${CYAN}Current forward mappings:${NC}"
    local current_mappings_csv
    current_mappings_csv=$(get_current_forward_mappings | paste -sd, -)
    [ -z "$current_mappings_csv" ] && current_mappings_csv=$(get_current_forward_ports | tr '\n' ',' | sed 's/,$//')
    echo -e "  ${YELLOW}$current_mappings_csv${NC}"
    echo ""
    
    read_forward_mappings "Enter port(s)/mapping(s) to ADD (comma-separated)" NEW_MAPPINGS "" "tcp"
    
    # Get existing listen/protocol keys and existing mappings
    local existing_keys=""
    local existing_mappings="$current_mappings_csv"
    local existing_spec=""
    while read -r existing_spec; do
        [ -z "$existing_spec" ] && continue
        existing_keys="${existing_keys} $(mapping_protocol "$existing_spec"):$(mapping_listen_port "$existing_spec")"
    done <<< "$(get_current_forward_mappings)"
    
    # Parse new mappings and check for duplicates/conflicts (by protocol+listen)
    local mappings_to_add=""
    local duplicates=""
    IFS=',' read -ra NEW_PORT_ARRAY <<< "$NEW_MAPPINGS"
    for spec in "${NEW_PORT_ARRAY[@]}"; do
        spec=$(echo "$spec" | tr -d ' ')
        [ -z "$spec" ] && continue
        local listen_port proto key
        listen_port=$(mapping_listen_port "$spec")
        proto=$(mapping_protocol "$spec")
        key="${proto}:${listen_port}"
        if echo " $existing_keys " | grep -qw "$key"; then
            duplicates="${duplicates}${listen_port}/${proto} "
        else
            # Check port conflict for the same protocol only
            if ! check_port_conflict_proto "$listen_port" "$proto"; then
                echo -e "${YELLOW}Add anyway? (y/n)${NC}"
                read -r -p "> " add_anyway < /dev/tty
                if [[ ! "$add_anyway" =~ ^[Yy]$ ]]; then
                    continue
                fi
            fi
            mappings_to_add="${mappings_to_add}${mappings_to_add:+,}${spec}"
            existing_keys="${existing_keys} ${key}"
        fi
    done
    
    if [ -n "$duplicates" ]; then
        print_warning "Skipping duplicate mappings: $duplicates"
    fi
    
    if [ -z "$mappings_to_add" ]; then
        print_info "No new ports/mappings to add"
        return 0
    fi
    
    # Combine existing and new mappings
    local all_mappings="$existing_mappings"
    [ -z "$all_mappings" ] && all_mappings="$mappings_to_add" || all_mappings="${all_mappings},${mappings_to_add}"
    
    # Rebuild forward section
    rebuild_forward_config "$all_mappings" || return 1
    
    print_success "Added mappings: $mappings_to_add"
    
    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
}

# Remove a forward port
remove_forward_port() {
    echo ""
    echo -e "${CYAN}Current forward mappings:${NC}"
    local current_mappings_list
    current_mappings_list=$(get_current_forward_mappings)
    local port_count=0
    local mappings_array=()
    
    while read -r spec; do
        if [ -n "$spec" ]; then
            port_count=$((port_count + 1))
            mappings_array+=("$spec")
            echo -e "  ${CYAN}$port_count)${NC} $spec"
        fi
    done <<< "$current_mappings_list"
    
    if [ $port_count -eq 0 ]; then
        print_error "No forward ports configured"
        return 1
    fi
    
    if [ $port_count -eq 1 ]; then
        print_error "Cannot remove the last port. At least one forward port is required."
        return 1
    fi
    
    echo ""
    echo -e "${YELLOW}Enter the mapping number to remove, or exact mapping (e.g. 1090:443/udp, 443):${NC}"
    read -r -p "> " remove_input < /dev/tty
    
    local mapping_to_remove=""
    
    # Check if input is a menu number or exact mapping
    if [[ "$remove_input" =~ ^[0-9]+$ ]] && [ "$remove_input" -le "$port_count" ] && [ "$remove_input" -gt 0 ]; then
        mapping_to_remove="${mappings_array[$((remove_input - 1))]}"
    else
        local normalized_remove=""
        if ! normalize_forward_mappings_input "$remove_input" normalized_remove "tcp"; then
            print_error "Invalid mapping input"
            return 1
        fi
        if echo "$normalized_remove" | grep -q ','; then
            print_error "Please enter exactly one mapping to remove"
            return 1
        fi
        mapping_to_remove="$normalized_remove"
    fi
    
    # Verify exact mapping exists, or resolve shorthand if uniquely identifiable.
    if ! echo "$current_mappings_list" | grep -Fxq "$mapping_to_remove"; then
        local shorthand_mode=""
        local shorthand_listen=""
        local shorthand_proto=""

        if [[ "$remove_input" =~ ^[0-9]+$ ]]; then
            shorthand_mode="listen_only"
            shorthand_listen="$remove_input"
        elif [[ "$remove_input" =~ ^([0-9]+)/(tcp|udp)$ ]]; then
            shorthand_mode="listen_proto"
            shorthand_listen="${BASH_REMATCH[1]}"
            shorthand_proto="${BASH_REMATCH[2]}"
        fi

        if [ -n "$shorthand_mode" ]; then
            local matches=()
            local spec=""
            while read -r spec; do
                [ -z "$spec" ] && continue
                if [ "$shorthand_mode" = "listen_only" ]; then
                    [ "$(mapping_listen_port "$spec")" = "$shorthand_listen" ] && matches+=("$spec")
                else
                    [ "$(mapping_listen_port "$spec")" = "$shorthand_listen" ] && [ "$(mapping_protocol "$spec")" = "$shorthand_proto" ] && matches+=("$spec")
                fi
            done <<< "$current_mappings_list"

            if [ "${#matches[@]}" -eq 1 ]; then
                mapping_to_remove="${matches[0]}"
            elif [ "${#matches[@]}" -gt 1 ]; then
                print_error "Multiple mappings match '$remove_input'. Use exact mapping (e.g. ${matches[0]})."
                return 1
            else
                print_error "Mapping '$remove_input' is not in the current configuration"
                return 1
            fi
        else
            print_error "Mapping '$mapping_to_remove' is not in the current configuration"
            return 1
        fi
    fi
    
    # Build new mapping list without the removed exact mapping
    local new_mappings=""
    for spec in "${mappings_array[@]}"; do
        if [ "$spec" != "$mapping_to_remove" ]; then
            new_mappings="${new_mappings}${new_mappings:+,}${spec}"
        fi
    done
    
    # Rebuild forward section
    rebuild_forward_config "$new_mappings" || return 1
    
    print_success "Removed mapping: $mapping_to_remove"
    
    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
}

# Replace all forward ports
replace_all_forward_ports() {
    echo ""
    echo -e "${CYAN}Current forward mappings:${NC}"
    local current_mappings
    current_mappings=$(get_current_forward_mappings | paste -sd, -)
    [ -z "$current_mappings" ] && current_mappings=$(get_current_forward_ports | tr '\n' ',' | sed 's/,$//')
    echo -e "  ${YELLOW}$current_mappings${NC}"
    echo ""
    
    print_warning "This will replace ALL current forward ports!"
    echo ""
    
    read_forward_mappings "Enter new forward ports/mappings (comma-separated)" NEW_MAPPINGS "$current_mappings" "tcp"
    
    # Check port conflicts (protocol-aware); ignore currently configured same protocol+listen pairs
    local current_keys=""
    local cur_spec=""
    while read -r cur_spec; do
        [ -z "$cur_spec" ] && continue
        current_keys="${current_keys} $(mapping_protocol "$cur_spec"):$(mapping_listen_port "$cur_spec")"
    done <<< "$(get_current_forward_mappings)"
    IFS=',' read -ra PORTS <<< "$NEW_MAPPINGS"
    local mappings_str=""
    for spec in "${PORTS[@]}"; do
        spec=$(echo "$spec" | tr -d ' ')
        [ -z "$spec" ] && continue
        local listen_port proto key
        listen_port=$(mapping_listen_port "$spec")
        proto=$(mapping_protocol "$spec")
        key="${proto}:${listen_port}"
        if ! echo " $current_keys " | grep -qw "$key"; then
            if ! check_port_conflict_proto "$listen_port" "$proto"; then
                echo -e "${YELLOW}Include anyway? (y/n)${NC}"
                read -r -p "> " include_anyway < /dev/tty
                if [[ ! "$include_anyway" =~ ^[Yy]$ ]]; then
                    continue
                fi
            fi
        fi
        mappings_str="${mappings_str}${mappings_str:+,}${spec}"
    done
    
    if [ -z "$mappings_str" ]; then
        print_error "No valid ports/mappings provided"
        return 1
    fi
    
    # Rebuild forward section
    rebuild_forward_config "$mappings_str" || return 1
    
    print_success "Forward mappings updated to: $mappings_str"
    
    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
}

# Helper: Rebuild the forward config section
rebuild_forward_config() {
    local mappings_input="$1"
    local mappings_csv=""
    if ! normalize_forward_mappings_input "$mappings_input" mappings_csv; then
        return 1
    fi
    
    local forward_config=""
    if ! build_forward_config_from_mappings_csv "$mappings_csv" forward_config; then
        print_error "Failed to build forward configuration"
        return 1
    fi
    
    # Use awk to replace the forward section
    awk -v new_forward="forward:${forward_config}" '
        /^forward:/ { in_forward=1; print new_forward; next }
        in_forward && /^[a-z]/ { in_forward=0 }
        !in_forward { print }
    ' "$PAQET_CONFIG" > "${PAQET_CONFIG}.tmp"
    mv "${PAQET_CONFIG}.tmp" "$PAQET_CONFIG"
    return 0
}

edit_secret_key() {
    echo ""
    local new_key
    new_key=$(generate_secret_key)
    echo -e "${CYAN}Generated new key: $new_key${NC}"
    read_required "Enter new secret key (or use generated)" SECRET_KEY "$new_key"
    
    sed_inplace "s/key: \"[^\"]*\"/key: \"${SECRET_KEY}\"/" "$PAQET_CONFIG"
    print_success "Secret key updated"
    
    print_warning "Remember to update the key on the other server as well!"
    
    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
}

edit_kcp_settings() {
    echo ""
    load_active_profile_preset_defaults
    echo -e "${YELLOW}KCP Mode options:${NC}"
    echo -e "  ${CYAN}normal${NC}  - Balanced (default)"
    echo -e "  ${CYAN}fast${NC}    - Low latency"
    echo -e "  ${CYAN}fast2${NC}   - Lower latency"
    echo -e "  ${CYAN}fast3${NC}   - Aggressive, best for high latency"
    echo ""
    
    local current_mode
    current_mode=$(grep "mode:" "$PAQET_CONFIG" | awk '{print $2}' | tr -d '"')
    read_required "Enter KCP mode" KCP_MODE "$current_mode"
    
    local current_conn
    current_conn=$(grep "conn:" "$PAQET_CONFIG" | awk '{print $2}')
    read_required "Enter number of parallel connections (1-8)" KCP_CONN "$current_conn"
    
    echo ""
    echo -e "${YELLOW}MTU (Maximum Transmission Unit):${NC}"
    echo -e "  ${CYAN}1400-1500${NC} - Normal networks"
    echo -e "  ${CYAN}${PROFILE_PRESET_KCP_MTU}${NC}      - Active profile ceiling (${PROFILE_PRESET_NAME})"
    echo -e "  ${CYAN}1150-1200${NC} - Restrictive/LAN MTU paths, mobile/Passwall instability"
    echo -e "  ${YELLOW}Tip:${NC} Keep KCP MTU at least ${KCP_MTU_HEADROOM} bytes below interface/path MTU on BOTH ends."
    echo ""
    
    local current_mtu
    current_mtu=$(grep "mtu:" "$PAQET_CONFIG" | grep -oE '[0-9]+' | head -1)
    [ -z "$current_mtu" ] && current_mtu="$PROFILE_PRESET_KCP_MTU"
    
    while true; do
        read_required "Enter MTU value, between ${KCP_MTU_MIN} and 1500" KCP_MTU "$current_mtu"
        if ! [[ "$KCP_MTU" =~ ^[0-9]+$ ]]; then
            print_error "MTU must be a number (e.g., 1350)"
            echo ""
            continue
        fi
        if [ "$KCP_MTU" -lt "$KCP_MTU_MIN" ] || [ "$KCP_MTU" -gt 1500 ]; then
            print_error "MTU must be between ${KCP_MTU_MIN} and 1500"
            echo ""
            continue
        fi
        break
    done
    
    sed_inplace "s/mode: \"[^\"]*\"/mode: \"${KCP_MODE}\"/" "$PAQET_CONFIG"
    sed_inplace "s/conn: [0-9]*.*/conn: ${KCP_CONN}/" "$PAQET_CONFIG"
    
    # Update or add MTU setting (match entire value after "mtu: " to handle corrupted values)
    if grep -q "mtu:" "$PAQET_CONFIG"; then
        sed_inplace "s/mtu: .*/mtu: ${KCP_MTU}/" "$PAQET_CONFIG"
    else
        # Add mtu after key line
        sed_inplace "/key:/a\\    mtu: ${KCP_MTU}" "$PAQET_CONFIG"
    fi
    
    print_success "KCP settings updated (mode: $KCP_MODE, conn: $KCP_CONN, mtu: $KCP_MTU)"
    
    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
}

edit_interface() {
    echo ""
    local current_iface
    current_iface=$(grep "interface:" "$PAQET_CONFIG" | awk '{print $2}' | tr -d '"')
    echo -e "Current interface: ${CYAN}$current_iface${NC}"
    echo ""
    echo -e "${YELLOW}Available interfaces:${NC}"
    ip -o link show | awk -F': ' '{print "  " $2}'
    echo ""
    
    read_required "Enter network interface" NEW_IFACE "$current_iface"
    
    local new_ip
    new_ip=$(get_local_ip "$NEW_IFACE")
    if [ -z "$new_ip" ]; then
        read_ip "Could not detect IP. Enter local IP for $NEW_IFACE" new_ip
    fi
    
    local new_mac
    new_mac=$(get_gateway_mac)
    if [ -z "$new_mac" ]; then
        read_mac "Enter gateway MAC address" new_mac
    fi
    
    sed_inplace "s/interface: \"[^\"]*\"/interface: \"${NEW_IFACE}\"/" "$PAQET_CONFIG"
    sed_inplace "s/router_mac: \"[^\"]*\"/router_mac: \"${new_mac}\"/" "$PAQET_CONFIG"
    # Update IP in addr field (keeping the port)
    sed_inplace "s|addr: \"[0-9.]*:|addr: \"${new_ip}:|" "$PAQET_CONFIG"
    
    print_success "Network interface updated"
    
    echo ""
    local restart_now=false
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
}

edit_server_address() {
    echo ""
    local current_addr
    current_addr=$(grep -A1 "^server:" "$PAQET_CONFIG" | grep "addr:" | awk '{print $2}' | tr -d '"')
    local current_ip
    current_ip=$(echo "$current_addr" | cut -d':' -f1)
    local current_port
    current_port=$(echo "$current_addr" | cut -d':' -f2)
    
    echo -e "Current Server B: ${CYAN}$current_addr${NC}"
    echo ""
    
    read_ip "Enter Server B IP address" NEW_SERVER_IP "$current_ip"
    read_port "Enter Server B paqet port" NEW_SERVER_PORT "$current_port"
    
    sed_inplace "s|addr: \"${current_addr}\"|addr: \"${NEW_SERVER_IP}:${NEW_SERVER_PORT}\"|" "$PAQET_CONFIG"
    
    # Update iptables rules: remove old target, add new target
    if [ -n "$current_ip" ] && [ -n "$current_port" ]; then
        remove_iptables_client "$current_ip" "$current_port"
    fi
    setup_iptables_client "$NEW_SERVER_IP" "$NEW_SERVER_PORT"
    
    print_success "Server B address updated to ${NEW_SERVER_IP}:${NEW_SERVER_PORT}"
    
    echo ""
    read_confirm "Restart paqet service to apply changes?" restart_now "y"
    if [ "$restart_now" = true ]; then
        systemctl_or_dry_run restart "$PAQET_SERVICE"
        print_success "Service restarted"
    fi
}

#===============================================================================
# Connection Test Tool
#===============================================================================

test_connection() {
    print_banner
    echo -e "${YELLOW}Connection Test Tool${NC}"
    echo ""
    
    # Select tunnel if multiple exist
    select_tunnel "Select tunnel to test" || return 1
    
    local role
    role=$(grep "^role:" "$PAQET_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"')
    local name
    name=$(get_tunnel_name "$PAQET_CONFIG")
    
    echo ""
    echo -e "Tunnel: ${CYAN}$name${NC}  Role: ${CYAN}$role${NC}"
    echo ""
    
    # Check if service is running
    print_step "Checking paqet service..."
    if systemctl is-active --quiet "$PAQET_SERVICE" 2>/dev/null; then
        print_success "paqet service is running"
    else
        print_error "paqet service is NOT running"
        echo ""
        local start_svc=false
        read_confirm "Would you like to start it?" start_svc "y"
        if [ "$start_svc" = true ]; then
            systemctl_or_dry_run start "$PAQET_SERVICE"
            sleep 2
            if systemctl is-active --quiet "$PAQET_SERVICE"; then
                print_success "Service started"
            else
                print_error "Failed to start service"
                echo -e "${YELLOW}Check logs:${NC} journalctl -u $PAQET_SERVICE -n 20"
                return 1
            fi
        else
            return 1
        fi
    fi
    
    echo ""
    
    if [ "$role" = "server" ]; then
        # Server B tests
        test_server_b
    else
        # Server A tests
        test_server_a
    fi
}

test_server_b() {
    echo -e "${GREEN}Running Server B (Abroad) tests...${NC}"
    echo ""
    
    local listen_port
    listen_port=$(grep -A1 "^listen:" "$PAQET_CONFIG" | grep "addr:" | sed 's/.*:\([0-9]*\)".*/\1/')
    
    # Test 1: Check if paqet is listening
    print_step "Test 1: Checking if paqet is listening on port $listen_port..."
    if ss -tuln | grep -q ":${listen_port} "; then
        print_success "paqet is listening on port $listen_port"
    else
        print_warning "paqet might be using raw sockets (not visible in ss)"
        print_info "This is normal for paqet"
    fi
    
    echo ""
    
    # Test 2: Check iptables rules
    print_step "Test 2: Checking iptables rules..."
    local raw_rules
    raw_rules=$(iptables -t raw -L -n 2>/dev/null | grep -c "$listen_port" || true)
    local mangle_rules
    mangle_rules=$(iptables -t mangle -L -n 2>/dev/null | grep -c "$listen_port" || true)
    
    if [ "$raw_rules" -gt 0 ] && [ "$mangle_rules" -gt 0 ]; then
        print_success "iptables rules are configured"
    else
        print_warning "Some iptables rules may be missing"
        print_info "Run setup again to reconfigure"
    fi
    
    echo ""
    
    # Test 3: Check for recent connections in logs
    print_step "Test 3: Checking recent activity..."
    local recent_logs
    recent_logs=$(journalctl -u "$PAQET_SERVICE" --since "5 minutes ago" 2>/dev/null | tail -5)
    if [ -n "$recent_logs" ]; then
        echo "$recent_logs"
    else
        print_info "No recent activity in logs"
    fi
    
    echo ""
    
    # Test 4: External connectivity check
    print_step "Test 4: Checking external connectivity..."
    if curl -s --max-time 5 ifconfig.me >/dev/null 2>&1; then
        local public_ip
        public_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
        print_success "External connectivity OK (Public IP: $public_ip)"
    else
        print_warning "Cannot reach external services"
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Server B Checklist:${NC}"
    echo -e "  • Ensure port ${CYAN}$listen_port${NC} is open in cloud firewall"
    echo -e "  • Ensure V2Ray/X-UI listens on ${CYAN}0.0.0.0${NC}"
    echo -e "  • Share the secret key with Server A"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

test_server_a() {
    echo -e "${GREEN}Running Server A (Iran/Entry Point) tests...${NC}"
    echo ""
    
    local server_addr
    server_addr=$(grep -A1 "^server:" "$PAQET_CONFIG" | grep "addr:" | awk '{print $2}' | tr -d '"')
    local server_ip
    server_ip=$(echo "$server_addr" | cut -d':' -f1)
    local server_port
    server_port=$(echo "$server_addr" | cut -d':' -f2)
    
    echo -e "Target Server B: ${CYAN}$server_addr${NC}"
    echo ""
    
    # Test 1: Basic network connectivity
    print_step "Test 1: Basic network connectivity to Server B..."
    if ping -c 1 -W 3 "$server_ip" >/dev/null 2>&1; then
        print_success "Server B is reachable via ICMP"
    else
        print_warning "ICMP blocked (this may be normal)"
    fi
    
    echo ""
    
    # Test 2: TCP connectivity to paqet port
    # NOTE: paqet uses raw sockets, so standard TCP probes won't get a response
    # This is EXPECTED - paqet is designed to be invisible to normal TCP
    print_step "Test 2: TCP probe to Server B port $server_port..."
    print_info "Note: paqet uses raw sockets - standard TCP may not respond"
    
    local tcp_reachable=false
    if timeout 5 bash -c "echo >/dev/tcp/$server_ip/$server_port" 2>/dev/null; then
        tcp_reachable=true
    elif command -v nc >/dev/null 2>&1; then
        if nc -z -w 5 "$server_ip" "$server_port" 2>/dev/null; then
            tcp_reachable=true
        fi
    fi
    
    if [ "$tcp_reachable" = true ]; then
        print_success "Port $server_port responds to TCP (unusual for paqet)"
    else
        print_warning "No TCP response on port $server_port"
        print_info "This is NORMAL - paqet operates at raw socket level"
        print_info "The tunnel may still work. Run end-to-end test to verify."
    fi
    
    echo ""
    
    # Test 3: Check connection protection iptables rules
    print_step "Test 3: Checking connection protection iptables rules..."
    local raw_rules
    raw_rules=$(iptables -t raw -L -n 2>/dev/null | grep -c "$server_ip" || true)
    local mangle_rules
    mangle_rules=$(iptables -t mangle -L -n 2>/dev/null | grep -c "$server_ip" || true)
    
    if [ "$raw_rules" -gt 0 ] && [ "$mangle_rules" -gt 0 ]; then
        print_success "Connection protection iptables rules are active"
    else
        print_warning "Connection protection iptables rules are missing"
        print_info "Run 'Connection Protection & MTU Tuning' (option d) from the main menu to fix"
    fi
    
    echo ""
    
    # Test 4: Check forwarded ports
    print_step "Test 4: Checking forwarded ports..."
    local forward_ports
    forward_ports=$(grep -A10 "^forward:" "$PAQET_CONFIG" | grep "listen:" | sed 's/.*:\([0-9]*\)".*/\1/' | tr '\n' ' ')
    
    for port in $forward_ports; do
        if ss -tuln | grep -q ":${port} "; then
            print_success "Port $port is listening"
        else
            print_warning "Port $port may be using raw sockets"
        fi
    done
    
    echo ""
    
    # Test 5: Check recent tunnel activity
    print_step "Test 5: Checking tunnel activity..."
    local recent_logs
    recent_logs=$(journalctl -u "$PAQET_SERVICE" --since "5 minutes ago" 2>/dev/null | grep -iE "connect|tunnel|forward" | tail -3)
    if [ -n "$recent_logs" ]; then
        echo "$recent_logs"
    else
        print_info "No recent tunnel activity"
    fi
    
    echo ""
    
    # Test 6: End-to-end test (if user wants)
    echo -e "${YELLOW}Would you like to run an end-to-end test?${NC}"
    echo -e "${CYAN}This will attempt to connect through the tunnel.${NC}"
    local run_e2e=false
    read_confirm "Run end-to-end test?" run_e2e "n"
    
    if [ "$run_e2e" = true ]; then
        echo ""
        local test_port
        test_port=$(echo "$forward_ports" | awk '{print $1}')
        print_step "Attempting connection through tunnel on port $test_port..."
        
        if timeout 10 bash -c "echo >/dev/tcp/127.0.0.1/$test_port" 2>/dev/null; then
            print_success "Tunnel connection successful!"
        else
            print_error "Tunnel connection failed"
            print_info "Check logs: journalctl -u $PAQET_SERVICE -f"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Server A Checklist:${NC}"
    echo -e "  • Verify secret key matches Server B"
    echo -e "  • Ensure Server B's cloud firewall allows port $server_port"
    echo -e "  • TCP probe failing is NORMAL (paqet uses raw sockets)"
    echo -e "  • Update V2Ray clients to use this server's IP"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

#===============================================================================
# Manage Tunnels Menu
#===============================================================================

manage_tunnels_menu() {
    while true; do
        print_banner
        echo -e "${YELLOW}Manage Tunnels${NC}"
        echo ""
        
        # Show all tunnels
        local configs
        configs=$(get_all_configs)
        if [ -n "$configs" ]; then
            echo -e "${YELLOW}Current Tunnels:${NC}"
            echo ""
            list_tunnels
        else
            print_info "No tunnels configured yet"
        fi
        
        echo ""
        echo -e "${YELLOW}Options:${NC}"
        echo ""
        echo -e "  ${CYAN}1)${NC} Add new tunnel (setup Server A)"
        echo -e "  ${CYAN}2)${NC} Remove a tunnel"
        echo -e "  ${CYAN}3)${NC} Restart a tunnel"
        echo -e "  ${CYAN}4)${NC} Stop a tunnel"
        echo -e "  ${CYAN}5)${NC} Start a tunnel"
        echo -e "  ${CYAN}0)${NC} Back to main menu"
        echo ""
        
        read -r -p "Choice: " manage_choice < /dev/tty
        
        case $manage_choice in
            1) run_iran_optimizations; install_dependencies; setup_server_a ;;
            2) remove_tunnel ;;
            3) tunnel_service_action "restart" ;;
            4) tunnel_service_action "stop" ;;
            5) tunnel_service_action "start" ;;
            0) return 0 ;;
            *) print_error "Invalid choice" ;;
        esac
        
        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read -r < /dev/tty
    done
}

# Remove a specific tunnel
remove_tunnel() {
    echo ""
    
    local configs
    configs=$(get_all_configs)
    if [ -z "$configs" ]; then
        print_error "No tunnels to remove"
        return 1
    fi
    
    select_tunnel "Select tunnel to remove" || return 1
    
    local name
    name=$(get_tunnel_name "$PAQET_CONFIG")
    local service="$PAQET_SERVICE"
    
    echo ""
    print_warning "This will remove tunnel '$name':"
    echo -e "  Config:  ${CYAN}$PAQET_CONFIG${NC}"
    echo -e "  Service: ${CYAN}$service${NC}"
    echo ""
    
    local confirm_remove=false
    read_confirm "Are you sure?" confirm_remove "n"

    if [ "$confirm_remove" = true ]; then
        if is_dry_run; then
            dry_run_notice "would remove tunnel config: $PAQET_CONFIG"
            dry_run_notice "would stop/disable/remove service: $service"
            dry_run_notice "would remove related client iptables rules if this is a client tunnel"
            dry_run_notice "would optionally remove $PAQET_DIR when no tunnels remain"
            print_success "DRY-RUN: tunnel '$name' not removed"
            return 0
        fi

        # Remove iptables rules for this tunnel
        local role
        role=$(grep "^role:" "$PAQET_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"')
        if [ "$role" = "client" ]; then
            local server_addr
            server_addr=$(grep -A1 "^server:" "$PAQET_CONFIG" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"')
            local s_ip
            s_ip=$(echo "$server_addr" | cut -d':' -f1)
            local s_port
            s_port=$(echo "$server_addr" | cut -d':' -f2)
            if [ -n "$s_ip" ] && [ -n "$s_port" ]; then
                remove_iptables_client "$s_ip" "$s_port"
                save_iptables
            fi
        fi
        
        # Stop and disable service
        print_step "Stopping service $service..."
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
        rm -f "/etc/systemd/system/${service}.service"
        systemctl daemon-reload
        print_success "Service removed"
        
        # Remove config
        rm -f "$PAQET_CONFIG"
        print_success "Configuration removed"
        
        # Check if any tunnels remain
        local remaining
        remaining=$(get_all_configs)
        if [ -z "$remaining" ]; then
            echo ""
            local remove_bin=false
            read_confirm "No tunnels remaining. Remove paqet binary too?" remove_bin "n"
            if [ "$remove_bin" = true ]; then
                rm -rf "$PAQET_DIR"
                print_success "All paqet files removed"
            fi
        fi
        
        echo ""
        print_success "Tunnel '$name' removed"
    else
        print_info "Cancelled"
    fi
    
    # Reset globals to defaults
    PAQET_CONFIG="$PAQET_DIR/config.yaml"
    PAQET_SERVICE="paqet"
}

# Restart/stop/start a tunnel service
tunnel_service_action() {
    local action="$1"
    echo ""
    
    select_tunnel "Select tunnel to $action" || return 1
    
    local name
    name=$(get_tunnel_name "$PAQET_CONFIG")
    
    print_step "${action^}ing tunnel '$name' ($PAQET_SERVICE)..."
    
    if systemctl_or_dry_run "$action" "$PAQET_SERVICE" 2>/dev/null; then
        sleep 1
        if [ "$action" = "stop" ]; then
            print_success "Tunnel '$name' stopped"
        elif systemctl is-active --quiet "$PAQET_SERVICE" 2>/dev/null; then
            print_success "Tunnel '$name' is running"
        else
            print_error "Tunnel '$name' failed to start"
            echo -e "${YELLOW}Check logs:${NC} journalctl -u $PAQET_SERVICE -n 20"
        fi
    else
        print_error "Failed to $action tunnel '$name'"
    fi
    
    # Reset globals
    PAQET_CONFIG="$PAQET_DIR/config.yaml"
    PAQET_SERVICE="paqet"
}

#===============================================================================
# Automatic Reset (periodic service restart for reliability)
#===============================================================================

# Read auto-reset config. Returns: ENABLED, INTERVAL, UNIT
read_auto_reset_config() {
    if [ -f "$AUTO_RESET_CONF" ]; then
        ENABLED=$(grep '^ENABLED=' "$AUTO_RESET_CONF" 2>/dev/null | head -1 | cut -d'"' -f2)
        INTERVAL=$(grep '^INTERVAL=' "$AUTO_RESET_CONF" 2>/dev/null | head -1 | cut -d'"' -f2)
        UNIT=$(grep '^UNIT=' "$AUTO_RESET_CONF" 2>/dev/null | head -1 | cut -d'"' -f2)
    fi
    case "${ENABLED:-false}" in true|false) ;; *) ENABLED="false" ;; esac
    [[ "${INTERVAL:-6}" =~ ^[0-9]+$ ]] || INTERVAL="6"
    case "${UNIT:-hour}" in min|minute|minutes|hour|hours|day|days|week|weeks) ;; *) UNIT="hour" ;; esac
    ENABLED="${ENABLED:-false}"
    INTERVAL="${INTERVAL:-6}"
    UNIT="${UNIT:-hour}"
}

# Write auto-reset config
write_auto_reset_config() {
    local enabled="$1"
    local interval="$2"
    local unit="$3"
    if is_dry_run; then
        dry_run_notice "would write auto-reset config: $AUTO_RESET_CONF"
        return 0
    fi
    mkdir -p "$PAQET_DIR"
    cat > "$AUTO_RESET_CONF" << EOF
# Auto-reset config - restarts paqet services periodically for reliability
ENABLED="$enabled"
INTERVAL="$interval"
UNIT="$unit"
EOF
    secure_file_permissions "$AUTO_RESET_CONF" 600
}

# Create the reset script that restarts all paqet services
create_auto_reset_script() {
    if is_dry_run; then
        dry_run_notice "would write auto-reset script: $AUTO_RESET_SCRIPT"
        return 0
    fi
    cat > "$AUTO_RESET_SCRIPT" << 'RESET_SCRIPT'
#!/bin/bash
# Auto-reset: restart all paqet services periodically for reliability

CONF="/opt/paqet/auto-reset.conf"
if [ -f "$CONF" ]; then
    ENABLED=$(grep '^ENABLED=' "$CONF" 2>/dev/null | head -1 | cut -d'"' -f2)
fi

[ "$ENABLED" != "true" ] && exit 0

for svc in /etc/systemd/system/paqet*.service; do
    [ -f "$svc" ] || continue
    name=$(basename "$svc" .service)
    [ "$name" = "recoba-tunnel-auto-reset" ] && continue
    systemctl restart "$name" 2>/dev/null || true
done
RESET_SCRIPT
    chmod 700 "$AUTO_RESET_SCRIPT"
}

# Create systemd service and timer for auto-reset
create_auto_reset_timer() {
    local interval="$1"
    local unit="$2"
    
    # Convert to systemd time format
    local period="${interval}${unit}"
    
    create_auto_reset_script

    if is_dry_run; then
        dry_run_notice "would write systemd unit: /etc/systemd/system/${AUTO_RESET_SERVICE}.service"
        dry_run_notice "would write systemd timer: /etc/systemd/system/${AUTO_RESET_TIMER}.timer"
        dry_run_notice "would run: systemctl daemon-reload"
        dry_run_notice "would run: systemctl enable --now ${AUTO_RESET_TIMER}.timer"
        print_success "DRY-RUN: auto-reset timer not created"
        return 0
    fi
    
    cat > /etc/systemd/system/${AUTO_RESET_SERVICE}.service << EOF
[Unit]
Description=paqet Auto-Reset (periodic service restart for reliability)
After=network.target

[Service]
Type=oneshot
ExecStart=$AUTO_RESET_SCRIPT
EOF

    cat > /etc/systemd/system/${AUTO_RESET_TIMER}.timer << EOF
[Unit]
Description=paqet Auto-Reset Timer
Requires=${AUTO_RESET_SERVICE}.service

[Timer]
OnBootSec=10min
OnUnitActiveSec=${period}
Persistent=yes

[Install]
WantedBy=timers.target
EOF

    systemctl_or_dry_run daemon-reload
    systemctl_or_dry_run enable --now "${AUTO_RESET_TIMER}.timer" 2>/dev/null || true
    print_success "Auto-reset timer enabled (every $interval $unit(s))"
}

# Remove systemd timer and service
remove_auto_reset_timer() {
    systemctl_or_dry_run stop "${AUTO_RESET_TIMER}.timer" 2>/dev/null || true
    systemctl_or_dry_run disable "${AUTO_RESET_TIMER}.timer" 2>/dev/null || true
    if is_dry_run; then
        dry_run_notice "would remove: /etc/systemd/system/${AUTO_RESET_TIMER}.timer"
        dry_run_notice "would remove: /etc/systemd/system/${AUTO_RESET_SERVICE}.service"
        dry_run_notice "would run: systemctl daemon-reload"
        print_success "DRY-RUN: auto-reset timer not removed"
        return 0
    fi
    rm -f "/etc/systemd/system/${AUTO_RESET_TIMER}.timer"
    rm -f "/etc/systemd/system/${AUTO_RESET_SERVICE}.service"
    systemctl_or_dry_run daemon-reload
    print_success "Auto-reset timer disabled"
}

# Manual reset: restart all paqet services
manual_reset_all() {
    echo ""
    print_step "Restarting all paqet services..."
    
    local count=0
    local configs
    configs=$(get_all_configs)
    
    if [ -z "$configs" ]; then
        print_error "No tunnels configured"
        return 1
    fi
    
    while IFS= read -r config_file; do
        local service
        service=$(get_tunnel_service "$config_file")
        local name
        name=$(get_tunnel_name "$config_file")
        if systemctl restart "$service" 2>/dev/null; then
            print_success "Restarted: $name"
            count=$((count + 1))
        else
            print_warning "Could not restart: $name"
        fi
    done <<< "$configs"
    
    if [ $count -gt 0 ]; then
        print_success "Manual reset complete ($count service(s) restarted)"
    fi
    echo ""
}

#===============================================================================
# Connection Protection & MTU Tuning
#===============================================================================

apply_connection_protection() {
    print_banner
    echo -e "${YELLOW}Connection Protection & MTU Tuning${NC}"
    echo -e "${CYAN}Applies iptables rules to improve tunnel stability and resist fake disconnects${NC}"
    echo ""
    echo -e "${YELLOW}What this does:${NC}"
    echo -e "  - Blocks fake RST packets injected by ISP middleboxes"
    echo -e "  - Bypasses kernel connection tracking for tunnel traffic"
    echo -e "  - Prevents kernel from sending RST packets that break raw socket tunnels"
    echo -e "  - Adds TCP MSS clamping to prevent oversized inner TCP segments"
    echo -e "  - Optionally lowers KCP MTU to keep safe packet-size headroom"
    echo ""
    
    local configs
    configs=$(get_all_configs)
    if [ -z "$configs" ]; then
        print_error "No tunnels configured. Set up a server first."
        return 1
    fi
    
    local applied=0
    
    while IFS= read -r config_file; do
        local name
        name=$(get_tunnel_name "$config_file")
        local role
        role=$(grep "^role:" "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')
        
        if [ "$role" = "server" ]; then
            # Server B: apply server-side rules
            local listen_port
            listen_port=$(grep -A1 "^listen:" "$config_file" 2>/dev/null | grep "addr:" | grep -oE '[0-9]+' | tail -1)
            if [ -n "$listen_port" ]; then
                echo -e "${CYAN}Tunnel '${name}' (Server B) — port $listen_port${NC}"
                setup_iptables "$listen_port"
                applied=$((applied + 1))
            else
                print_warning "Could not detect port for tunnel '$name', skipping"
            fi
        elif [ "$role" = "client" ]; then
            # Server A: apply client-side rules targeting Server B
            local server_addr
            server_addr=$(grep -A1 "^server:" "$config_file" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"')
            local s_ip
            s_ip=$(echo "$server_addr" | cut -d':' -f1)
            local s_port
            s_port=$(echo "$server_addr" | cut -d':' -f2)
            if [ -n "$s_ip" ] && [ -n "$s_port" ]; then
                echo -e "${CYAN}Tunnel '${name}' (Server A) — target $s_ip:$s_port${NC}"
                setup_iptables_client "$s_ip" "$s_port"
                applied=$((applied + 1))
            else
                print_warning "Could not detect Server B address for tunnel '$name', skipping"
            fi
        fi
    done <<< "$configs"
    
    echo ""
    if [ "$applied" -gt 0 ]; then
        print_success "Protection rules applied to $applied tunnel(s)"
    else
        print_warning "No tunnels were updated"
    fi
    
    # Offer MTU reduction
    echo ""
    echo -e "${YELLOW}MTU Optimization:${NC}"
    echo -e "  KCP MTU must leave headroom below the interface/path MTU."
    echo -e "  If logs show 'send: Message too large', lower KCP MTU on BOTH ends."
    echo -e "  Current restrictive-path recommendation: ${CYAN}1200${NC}"
    echo ""
    
    local lower_mtu=false
    read_confirm "Lower KCP MTU to 1200 on all tunnels above that value?" lower_mtu "y"
    
    if [ "$lower_mtu" = true ]; then
        local mtu_updated=0
        while IFS= read -r config_file; do
            local current_mtu
            current_mtu=$(grep "mtu:" "$config_file" 2>/dev/null | grep -oE '[0-9]+' | head -1)
            if [ -n "$current_mtu" ] && [ "$current_mtu" -gt 1200 ]; then
                sed_inplace "s/mtu: .*/mtu: 1200/" "$config_file"
                local name
                name=$(get_tunnel_name "$config_file")
                print_info "  $name: MTU $current_mtu -> 1200"
                mtu_updated=$((mtu_updated + 1))
            fi
        done <<< "$configs"
        
        if [ "$mtu_updated" -gt 0 ]; then
            print_success "MTU updated on $mtu_updated tunnel(s)"
            echo ""
            local restart_now=false
            read_confirm "Restart all paqet services to apply changes?" restart_now "y"
            if [ "$restart_now" = true ]; then
                while IFS= read -r config_file; do
                    local service
                    service=$(get_tunnel_service "$config_file")
                    systemctl restart "$service" 2>/dev/null || true
                done <<< "$configs"
                print_success "All services restarted"
            fi
        else
            print_info "All tunnels already at MTU 1200 or below"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}      Connection Protection & MTU Tuning Complete           ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Active protections:${NC}"
    echo -e "  - Fake RST injection blocked (iptables mangle)"
    echo -e "  - Kernel connection tracking bypassed (iptables raw NOTRACK)"
    echo -e "  - Kernel RST responses suppressed"
    echo -e "  - TCP MSS clamp enabled for safer mobile/Passwall paths"
    echo ""
    echo -e "${YELLOW}If issues persist:${NC}"
    echo -e "  - Try changing the paqet port to a less common port"
    echo -e "  - Try KCP mode 'fast3' for aggressive retransmission"
    echo -e "  - Apply this optimization on BOTH Server A and Server B"
    echo ""
}

#===============================================================================
# IPTables Port Forwarding Menu
#===============================================================================

iptables_port_forwarding_menu() {
    while true; do
        print_banner
        echo -e "${YELLOW}IPTables NAT Port Forwarding${NC}"
        echo -e "${CYAN}Forward traffic to another server using iptables NAT rules${NC}"
        echo -e "${CYAN}Each rule set is independent — useful for testing backup tunnels${NC}"
        echo ""
        
        # Quick status: show if IP forwarding is enabled
        local fwd_status
        fwd_status=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
        if [ "$fwd_status" = "1" ]; then
            echo -e "  ${GREEN}[✓] IP forwarding is enabled${NC}"
        else
            echo -e "  ${YELLOW}[—] IP forwarding is disabled${NC}"
        fi
        
        local nat_count
        nat_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "DNAT" || true)
        echo -e "  ${CYAN}Active DNAT rules: ${nat_count}${NC}"
        echo ""
        
        echo -e "  ${CYAN}1)${NC} Multi-Port Forward (specific ports -> destination)"
        echo -e "  ${CYAN}2)${NC} All-Ports Forward (all except excluded -> destination)"
        echo -e "  ${CYAN}3)${NC} View NAT Rules"
        echo -e "  ${CYAN}4)${NC} Remove Forwarding by Destination IP"
        echo -e "  ${CYAN}5)${NC} Flush All NAT Rules"
        echo -e "  ${CYAN}0)${NC} Back"
        echo ""
        read -r -p "Choice: " fwd_choice < /dev/tty
        
        case $fwd_choice in
            1) add_nat_forward_multi_port ;;
            2) add_nat_forward_all_ports ;;
            3) view_nat_rules ;;
            4) remove_nat_forward_by_dest ;;
            5) flush_nat_rules ;;
            0) return ;;
            *) print_error "Invalid choice" ;;
        esac
        
        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read -r < /dev/tty
    done
}

# Auto-reset menu
auto_reset_menu() {
    while true; do
        print_banner
        echo -e "${YELLOW}Automatic Reset${NC}"
        echo -e "${CYAN}Periodically restart paqet services for reliability${NC}"
        echo ""
        
        read_auto_reset_config
        
        # Show current status
        echo -e "${YELLOW}Current settings:${NC}"
        if [ "$ENABLED" = "true" ]; then
            echo -e "  Status:   ${GREEN}Enabled${NC}"
            echo -e "  Interval: ${CYAN}Every $INTERVAL $UNIT(s)${NC}"
            if systemctl is-active --quiet ${AUTO_RESET_TIMER}.timer 2>/dev/null; then
                echo -e "  Timer:    ${GREEN}Active${NC}"
            else
                echo -e "  Timer:    ${RED}Inactive${NC}"
            fi
        else
            echo -e "  Status:   ${RED}Disabled${NC}"
        fi
        echo ""
        
        echo -e "${YELLOW}Options:${NC}"
        echo ""
        echo -e "  ${CYAN}1)${NC} Enable automatic reset"
        echo -e "  ${CYAN}2)${NC} Disable automatic reset"
        echo -e "  ${CYAN}3)${NC} Set reset interval"
        echo -e "  ${CYAN}4)${NC} Manual reset now (restart all tunnels)"
        echo -e "  ${CYAN}0)${NC} Back to main menu"
        echo ""
        
        read -r -p "Choice: " reset_choice < /dev/tty
        
        case $reset_choice in
            1)
                echo ""
                if [ "$ENABLED" = "true" ]; then
                    print_info "Automatic reset is already enabled"
                else
                    # Use existing interval or default
                    read_auto_reset_config
                    write_auto_reset_config "true" "${INTERVAL:-6}" "${UNIT:-hour}"
                    create_auto_reset_timer "${INTERVAL:-6}" "${UNIT:-hour}"
                fi
                ;;
            2)
                echo ""
                if [ "$ENABLED" != "true" ]; then
                    print_info "Automatic reset is already disabled"
                else
                    write_auto_reset_config "false" "$INTERVAL" "$UNIT"
                    remove_auto_reset_timer
                fi
                ;;
            3)
                echo ""
                echo -e "${CYAN}Set reset interval${NC}"
                echo ""
                echo -e "  ${YELLOW}1)${NC} Every 1 hour"
                echo -e "  ${YELLOW}2)${NC} Every 3 hours"
                echo -e "  ${YELLOW}3)${NC} Every 6 hours"
                echo -e "  ${YELLOW}4)${NC} Every 12 hours"
                echo -e "  ${YELLOW}5)${NC} Every 24 hours (1 day)"
                echo -e "  ${YELLOW}6)${NC} Every 7 days"
                echo ""
                read -r -p "Choice: " interval_choice < /dev/tty
                
                case $interval_choice in
                    1) new_interval=1; new_unit=hour ;;
                    2) new_interval=3; new_unit=hour ;;
                    3) new_interval=6; new_unit=hour ;;
                    4) new_interval=12; new_unit=hour ;;
                    5) new_interval=1; new_unit=day ;;
                    6) new_interval=7; new_unit=day ;;
                    *) print_error "Invalid choice"; new_interval=""; new_unit="" ;;
                esac
                
                if [ -n "$new_interval" ]; then
                    write_auto_reset_config "$ENABLED" "$new_interval" "$new_unit"
                    if [ "$ENABLED" = "true" ]; then
                        create_auto_reset_timer "$new_interval" "$new_unit"
                    fi
                    print_success "Interval set to every $new_interval $new_unit(s)"
                fi
                ;;
            4)
                manual_reset_all
                ;;
            0)
                return 0
                ;;
            *)
                print_error "Invalid choice"
                ;;
        esac
        
        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read -r < /dev/tty
    done
}

#===============================================================================
# Maintenance Helpers (auto-tune retrofit)
#===============================================================================

upsert_transport_conn_value() {
    local config_file="$1"
    local conn_value="$2"

    if grep -Eq '^[[:space:]]*conn:[[:space:]]*[0-9]+' "$config_file"; then
        sed_inplace "s/^[[:space:]]*conn:[[:space:]]*[0-9][0-9]*.*/  conn: ${conn_value}/" "$config_file"
    else
        # Accept quoted or unquoted `protocol: kcp` (users may manually edit YAML style).
        sed_inplace "/^[[:space:]]*protocol:[[:space:]]*\"\\?kcp\"\\?\\([[:space:]]*#.*\\)\\?$/a\\
  conn: ${conn_value}" "$config_file"
    fi
}

upsert_kcp_scalar_value() {
    local config_file="$1"
    local key="$2"
    local value="$3"
    local quote_style="$4" # "quoted" or "bare"
    local rendered="$value"

    if [ "$quote_style" = "quoted" ]; then
        rendered="\"${value}\""
    fi

    if grep -Eq "^[[:space:]]*${key}:" "$config_file"; then
        sed_inplace "s|^[[:space:]]*${key}:.*|    ${key}: ${rendered}|" "$config_file"
    else
        sed_inplace "/^[[:space:]]*kcp:/a\\
    ${key}: ${rendered}" "$config_file"
    fi
}

remove_legacy_kcp_alias_keys() {
    local config_file="$1"

    # Remove legacy/alternate KCP key names that paqet does not use anymore.
    # Keeping only canonical keys avoids confusing "duplicate" values in configs.
    sed_inplace \
        -e '/^[[:space:]]*snd_wnd:[[:space:]]*/d' \
        -e '/^[[:space:]]*rcv_wnd:[[:space:]]*/d' \
        -e '/^[[:space:]]*data_shard:[[:space:]]*/d' \
        -e '/^[[:space:]]*parity_shard:[[:space:]]*/d' \
        "$config_file"
}

apply_auto_tune_to_config_file() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*protocol:[[:space:]]*"?kcp"?([[:space:]]*#.*)?$' "$config_file" 2>/dev/null; then
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*kcp:' "$config_file"; then
        return 1
    fi

    load_active_profile_preset_defaults

    # If Behzad preset is active, keep this path aligned with the active preset model
    # (fixed profile, no PaqX CPU/RAM auto KCP tuning fields).
    if false; then
        apply_profile_preset_to_config_file "$config_file" "behzad"
        return $?
    fi

    upsert_transport_conn_value "$config_file" "$AUTO_TUNE_CONN"

    upsert_kcp_scalar_value "$config_file" "mode" "$DEFAULT_KCP_MODE" "quoted"
    upsert_kcp_scalar_value "$config_file" "nodelay" "1" "bare"
    upsert_kcp_scalar_value "$config_file" "interval" "10" "bare"
    upsert_kcp_scalar_value "$config_file" "resend" "2" "bare"
    upsert_kcp_scalar_value "$config_file" "nocongestion" "0" "bare"
    upsert_kcp_scalar_value "$config_file" "wdelay" "false" "bare"
    upsert_kcp_scalar_value "$config_file" "acknodelay" "true" "bare"
    upsert_kcp_scalar_value "$config_file" "mtu" "$PROFILE_PRESET_KCP_MTU" "bare"
    upsert_kcp_scalar_value "$config_file" "rcvwnd" "$AUTO_TUNE_RCVWND" "bare"
    upsert_kcp_scalar_value "$config_file" "sndwnd" "$AUTO_TUNE_SNDWND" "bare"
    upsert_kcp_scalar_value "$config_file" "block" "$PROFILE_PRESET_KCP_BLOCK" "quoted"
    upsert_kcp_scalar_value "$config_file" "smuxbuf" "$AUTO_TUNE_SMUXBUF" "bare"
    upsert_kcp_scalar_value "$config_file" "streambuf" "$AUTO_TUNE_STREAMBUF" "bare"
    upsert_kcp_scalar_value "$config_file" "dshard" "$DEFAULT_KCP_DSHARD" "bare"
    upsert_kcp_scalar_value "$config_file" "pshard" "$DEFAULT_KCP_PSHARD" "bare"
    remove_legacy_kcp_alias_keys "$config_file"

    return 0
}

apply_auto_tune_existing_configs() {
    print_banner
    echo -e "${YELLOW}Apply PaqX-style Auto Tuning (Existing Configs)${NC}"
    echo ""

    local configs
    configs=$(get_all_configs)
    if [ -z "$configs" ]; then
        print_error "No paqet configurations found"
        print_info "Run setup first"
        return 1
    fi

    calculate_auto_kcp_profile
    show_auto_kcp_profile

    if [ "$(get_current_profile_preset)" = "behzad" ]; then
        print_warning "Profile preset applied."
        echo ""
    fi

    echo -e "${YELLOW}This will update existing KCP settings on this server:${NC}"
    echo -e "  - conn / mode / mtu"
    echo -e "  - window sizes (rcvwnd/sndwnd)"
    echo -e "  - PaqX-style KCP defaults (nodelay/acknodelay/FEC/buffers)"
    echo -e "  - MTU/block use the active profile preset baseline ($(get_current_profile_preset))"
    echo -e "  - Kernel sysctl optimization file (${OPTIMIZE_SYSCTL_FILE})"
    echo ""
    echo -e "${YELLOW}Note:${NC} Existing configs will be backed up as *.autotune.bak.<timestamp>"
    echo ""

    local do_apply=false
    read_confirm "Apply auto tuning to all existing configs on this server?" do_apply "y"
    [ "$do_apply" != true ] && return 0

    local ts
    ts=$(date +%s)
    local updated=0
    local skipped=0
    local failed=0
    local updated_configs=""

    while IFS= read -r config_file; do
        [ -z "$config_file" ] && continue

        local name
        name=$(get_tunnel_name "$config_file")
        local backup_file="${config_file}.autotune.bak.${ts}"

        if ! cp "$config_file" "$backup_file" 2>/dev/null; then
            print_warning "Backup failed for ${name}; skipping (${config_file})"
            failed=$((failed + 1))
            continue
        fi
        secure_file_permissions "$backup_file" 600

        if apply_auto_tune_to_config_file "$config_file"; then
            secure_file_permissions "$config_file" 600
            print_success "Updated KCP profile for '${name}'"
            updated=$((updated + 1))
            updated_configs="${updated_configs}${config_file}
"
        else
            print_warning "Skipped '${name}' (unsupported or invalid KCP config)"
            skipped=$((skipped + 1))
        fi
    done <<< "$configs"

    apply_paqx_kernel_optimizations

    echo ""
    print_info "Summary: updated=${updated}, skipped=${skipped}, failed=${failed}"

    if [ "$updated" -gt 0 ]; then
        echo ""
        local do_restart=false
        read_confirm "Restart paqet services now to apply new KCP settings?" do_restart "y"
        if [ "$do_restart" = true ]; then
            while IFS= read -r config_file; do
                [ -z "$config_file" ] && continue
                local service
                service=$(get_tunnel_service "$config_file")
                if systemctl cat "$service" >/dev/null 2>&1; then
                    if systemctl restart "$service" >/dev/null 2>&1; then
                        print_success "Restarted $service"
                    else
                        print_warning "Failed to restart $service (check logs)"
                    fi
                fi
            done <<< "$updated_configs"
        else
            print_warning "Services not restarted. Restart them manually to apply changes."
        fi
    fi
}

#===============================================================================
# Profile Preset Helpers (separate from PaqX auto-tune)
#===============================================================================

upsert_transport_scalar_value() {
    local config_file="$1"
    local key="$2"
    local value="$3"

    if grep -Eq "^[[:space:]]*${key}:" "$config_file"; then
        sed_inplace "s|^[[:space:]]*${key}:.*|  ${key}: ${value}|" "$config_file"
    else
        sed_inplace "/^[[:space:]]*transport:[[:space:]]*$/a\\  ${key}: ${value}" "$config_file"
    fi
}

remove_transport_scalar_value() {
    local config_file="$1"
    local key="$2"
    sed_inplace "/^[[:space:]]*${key}:[[:space:]]*/d" "$config_file"
}

upsert_or_remove_network_pcap_sockbuf() {
    local config_file="$1"
    local sockbuf_value="$2"
    local tmp_file="${config_file}.pcap.$$"

    awk -v sockbuf="$sockbuf_value" '
        function print_pcap_block() {
            print "  pcap:"
            print "    sockbuf: " sockbuf
        }
        {
            line = $0

            if (!in_network && line ~ /^network:[[:space:]]*$/) {
                in_network = 1
                print line
                next
            }

            if (in_network) {
                if (in_pcap) {
                    if (line ~ /^    /) {
                        next
                    }
                    in_pcap = 0
                }

                if (line ~ /^  pcap:[[:space:]]*$/) {
                    replaced_or_inserted = 1
                    if (sockbuf != "") {
                        print_pcap_block()
                    }
                    in_pcap = 1
                    next
                }

                if (line ~ /^[^[:space:]]/) {
                    if (!replaced_or_inserted && sockbuf != "") {
                        print_pcap_block()
                        replaced_or_inserted = 1
                    }
                    in_network = 0
                    print line
                    next
                }

                print line
                next
            }

            print line
        }
        END {
            if (in_network && !replaced_or_inserted && sockbuf != "") {
                print_pcap_block()
            }
        }
    ' "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
}

apply_profile_preset_to_config_file() {
    local config_file="$1"
    local preset="${2:-$(get_current_profile_preset)}"

    if [ ! -f "$config_file" ]; then
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*protocol:[[:space:]]*"?kcp"?([[:space:]]*#.*)?$' "$config_file" 2>/dev/null; then
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*kcp:' "$config_file"; then
        return 1
    fi

    load_active_profile_preset_defaults "$preset"

    # Profile switch is intentionally limited to tuning-related sections only.
    # It does NOT touch forward ports, tunnel/server ports, server IPs, or bind IPs.
    local effective_kcp_mode="$DEFAULT_KCP_MODE"
    local effective_kcp_mtu="$PROFILE_PRESET_KCP_MTU"
    local config_iface=""
    local config_iface_mtu=""
    config_iface=$(grep '^[[:space:]]*interface:' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -1 || true)
    if [ -n "$config_iface" ]; then
        config_iface_mtu=$(detect_interface_mtu "$config_iface" 2>/dev/null || true)
    fi

    if false; then
        true # behzad removed
        effective_kcp_mtu=$(calculate_safe_kcp_mtu "$PROFILE_PRESET_KCP_MTU" "$config_iface_mtu")
        upsert_transport_conn_value "$config_file" "$AUTO_TUNE_CONN"
        remove_paqx_kcp_tuning_keys "$config_file"
    elif [ "$PROFILE_PRESET_NAME" = "iran-optimized" ]; then
        # Iran-optimised production profile — fixed values from validated testing.
        # Does NOT use auto-tune; uses the proven stable config from Iran→Dubai path.
        effective_kcp_mode="fast"
        effective_kcp_mtu="$DEFAULT_KCP_MTU"
        effective_kcp_mtu=$(calculate_safe_kcp_mtu "$effective_kcp_mtu" "$config_iface_mtu")
        upsert_transport_conn_value "$config_file" "$DEFAULT_KCP_CONN"
        upsert_kcp_scalar_value "$config_file" "nodelay" "1" "bare"
        upsert_kcp_scalar_value "$config_file" "interval" "10" "bare"
        upsert_kcp_scalar_value "$config_file" "resend" "2" "bare"
        upsert_kcp_scalar_value "$config_file" "nocongestion" "0" "bare"
        upsert_kcp_scalar_value "$config_file" "wdelay" "false" "bare"
        upsert_kcp_scalar_value "$config_file" "acknodelay" "true" "bare"
        upsert_kcp_scalar_value "$config_file" "rcvwnd" "$LOW_MTU_PROFILE_RCVWND" "bare"
        upsert_kcp_scalar_value "$config_file" "sndwnd" "$LOW_MTU_PROFILE_SNDWND" "bare"
        upsert_kcp_scalar_value "$config_file" "smuxbuf" "$LOW_MTU_PROFILE_SMUXBUF" "bare"
        upsert_kcp_scalar_value "$config_file" "streambuf" "$LOW_MTU_PROFILE_STREAMBUF" "bare"
        upsert_kcp_scalar_value "$config_file" "dshard" "$OPTIMIZED_KCP_DSHARD" "bare"
        upsert_kcp_scalar_value "$config_file" "pshard" "$OPTIMIZED_KCP_PSHARD" "bare"
    else
        # Apply the PaqX auto-tune profile deterministically for the default preset,
        # even if the current active preset was changed just before this call.
        calculate_paqx_auto_kcp_profile
        apply_low_mtu_upload_stability_profile "$config_iface_mtu"
        [ -n "$AUTO_TUNE_KCP_MODE" ] && effective_kcp_mode="$AUTO_TUNE_KCP_MODE"
        [ -n "$AUTO_TUNE_KCP_MTU" ] && effective_kcp_mtu="$AUTO_TUNE_KCP_MTU"
        effective_kcp_mtu=$(calculate_safe_kcp_mtu "$effective_kcp_mtu" "$config_iface_mtu")
        upsert_transport_conn_value "$config_file" "$AUTO_TUNE_CONN"
        upsert_kcp_scalar_value "$config_file" "nodelay" "1" "bare"
        upsert_kcp_scalar_value "$config_file" "interval" "10" "bare"
        upsert_kcp_scalar_value "$config_file" "resend" "2" "bare"
        upsert_kcp_scalar_value "$config_file" "nocongestion" "0" "bare"
        upsert_kcp_scalar_value "$config_file" "wdelay" "false" "bare"
        upsert_kcp_scalar_value "$config_file" "acknodelay" "true" "bare"
        upsert_kcp_scalar_value "$config_file" "rcvwnd" "$AUTO_TUNE_RCVWND" "bare"
        upsert_kcp_scalar_value "$config_file" "sndwnd" "$AUTO_TUNE_SNDWND" "bare"
        upsert_kcp_scalar_value "$config_file" "smuxbuf" "$AUTO_TUNE_SMUXBUF" "bare"
        upsert_kcp_scalar_value "$config_file" "streambuf" "$AUTO_TUNE_STREAMBUF" "bare"
        upsert_kcp_scalar_value "$config_file" "dshard" "$DEFAULT_KCP_DSHARD" "bare"
        upsert_kcp_scalar_value "$config_file" "pshard" "$DEFAULT_KCP_PSHARD" "bare"
    fi

    upsert_kcp_scalar_value "$config_file" "mode" "$effective_kcp_mode" "quoted"

    upsert_kcp_scalar_value "$config_file" "block" "$PROFILE_PRESET_KCP_BLOCK" "quoted"
    upsert_kcp_scalar_value "$config_file" "mtu" "$effective_kcp_mtu" "bare"

    if [ -n "$PROFILE_PRESET_TRANSPORT_TCPBUF" ]; then
        upsert_transport_scalar_value "$config_file" "tcpbuf" "$PROFILE_PRESET_TRANSPORT_TCPBUF"
    else
        remove_transport_scalar_value "$config_file" "tcpbuf"
    fi

    if [ -n "$PROFILE_PRESET_TRANSPORT_UDPBUF" ]; then
        upsert_transport_scalar_value "$config_file" "udpbuf" "$PROFILE_PRESET_TRANSPORT_UDPBUF"
    else
        remove_transport_scalar_value "$config_file" "udpbuf"
    fi

    local role=""
    role=$(grep '^role:' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"')
    local pcap_sockbuf=""
    if [ "$role" = "server" ]; then
        pcap_sockbuf="$PROFILE_PRESET_PCAP_SOCKBUF_SERVER"
    else
        pcap_sockbuf="$PROFILE_PRESET_PCAP_SOCKBUF_CLIENT"
    fi
    upsert_or_remove_network_pcap_sockbuf "$config_file" "$pcap_sockbuf"
    remove_legacy_kcp_alias_keys "$config_file"

    return 0
}

apply_active_profile_preset_existing_configs() {
    print_banner
    local active_preset
    active_preset=$(get_current_profile_preset)
    load_active_profile_preset_defaults "$active_preset"

    echo -e "${YELLOW}Apply Active Profile Preset (Existing Configs)${NC}"
    echo ""
    echo -e "  ${YELLOW}Preset:${NC} ${CYAN}${PROFILE_PRESET_NAME}${NC} (${PROFILE_PRESET_LABEL})"
    echo -e "  ${YELLOW}Changes:${NC}"
    echo -e "    - KCP block: ${CYAN}${PROFILE_PRESET_KCP_BLOCK}${NC}"
    echo -e "    - KCP MTU:   ${CYAN}${PROFILE_PRESET_KCP_MTU}${NC}"
    if [ -n "$PROFILE_PRESET_TRANSPORT_TCPBUF" ] || [ -n "$PROFILE_PRESET_TRANSPORT_UDPBUF" ]; then
        echo -e "    - transport.tcpbuf / udpbuf: ${CYAN}${PROFILE_PRESET_TRANSPORT_TCPBUF:-default}/${PROFILE_PRESET_TRANSPORT_UDPBUF:-default}${NC}"
    else
        echo -e "    - transport.tcpbuf / udpbuf: ${CYAN}removed (use paqet defaults)${NC}"
    fi
    if [ -n "$PROFILE_PRESET_PCAP_SOCKBUF_SERVER" ] || [ -n "$PROFILE_PRESET_PCAP_SOCKBUF_CLIENT" ]; then
        echo -e "    - network.pcap.sockbuf: ${CYAN}role-based preset values${NC}"
    else
        echo -e "    - network.pcap.sockbuf: ${CYAN}removed (use paqet defaults)${NC}"
    fi
    if false; then
        echo -e "    - KCP conn: ${CYAN}fixed Behzad preset (4)${NC}"
        echo -e "    - PaqX KCP auto-tune fields: ${CYAN}removed (no mixing)${NC}"
    else
        echo -e "    - KCP conn/windows/FEC/smux: ${CYAN}PaqX CPU/RAM auto-tune${NC}"
    fi
    echo ""
    echo -e "${CYAN}Ports and IP addresses are NOT changed. Only profile/tuning settings are updated.${NC}"
    print_warning "Apply the same transport/KCP profile on BOTH tunnel ends to keep them compatible."
    echo ""

    local configs
    configs=$(get_all_configs)
    if [ -z "$configs" ]; then
        print_error "No paqet configurations found"
        print_info "Run setup first"
        return 1
    fi

    if is_dry_run; then
        while IFS= read -r config_file; do
            [ -z "$config_file" ] && continue
            dry_run_notice "would backup and apply profile preset '$active_preset' to: $config_file"
        done <<< "$configs"
        dry_run_notice "would optionally restart paqet services after profile apply"
        print_success "DRY-RUN: profile preset not applied"
        return 0
    fi

    local do_apply=false
    read_confirm "Apply active profile preset to all existing configs on this server?" do_apply "y"
    [ "$do_apply" != true ] && return 0

    local ts
    ts=$(date +%s)
    local updated=0
    local skipped=0
    local failed=0
    local updated_configs=""

    while IFS= read -r config_file; do
        [ -z "$config_file" ] && continue

        local name
        name=$(get_tunnel_name "$config_file")
        local backup_file="${config_file}.profilepreset.bak.${ts}"

        if ! cp "$config_file" "$backup_file" 2>/dev/null; then
            print_warning "Backup failed for ${name}; skipping (${config_file})"
            failed=$((failed + 1))
            continue
        fi
        secure_file_permissions "$backup_file" 600

        if apply_profile_preset_to_config_file "$config_file" "$active_preset"; then
            secure_file_permissions "$config_file" 600
            print_success "Applied profile preset to '${name}'"
            updated=$((updated + 1))
            updated_configs="${updated_configs}${config_file}
"
        else
            print_warning "Skipped '${name}' (unsupported or invalid KCP config)"
            skipped=$((skipped + 1))
        fi
    done <<< "$configs"

    echo ""
    print_info "Summary: updated=${updated}, skipped=${skipped}, failed=${failed}"

    if [ "$updated" -gt 0 ]; then
        echo ""
        local do_restart=false
        read_confirm "Restart paqet services now to apply profile preset changes?" do_restart "y"
        if [ "$do_restart" = true ]; then
            while IFS= read -r config_file; do
                [ -z "$config_file" ] && continue
                local service
                service=$(get_tunnel_service "$config_file")
                if systemctl cat "$service" >/dev/null 2>&1; then
                    if systemctl restart "$service" >/dev/null 2>&1; then
                        print_success "Restarted $service"
                    else
                        print_warning "Failed to restart $service (check logs)"
                    fi
                fi
            done <<< "$updated_configs"
        else
            print_warning "Services not restarted. Restart them manually to apply changes."
        fi
    fi
}

#===============================================================================
# Core Updater + Auto-Updater
#===============================================================================

create_paqet_core_backup() {
    local reason="${1:-manual}"

    if [ ! -f "$PAQET_BIN" ]; then
        return 1
    fi

    local ts
    ts=$(date +%s)
    local backup_bin="${PAQET_BIN}.corebak.${ts}.${reason}"
    cp "$PAQET_BIN" "$backup_bin" || return 1
    chmod 755 "$backup_bin" 2>/dev/null || chmod +x "$backup_bin" 2>/dev/null || true

    local current_provider
    current_provider=$(get_current_core_provider)
    cat > "${backup_bin}.meta" << EOF
# paqet core binary backup metadata
CORE_PROVIDER="${current_provider}"
BACKUP_REASON="${reason}"
CREATED_AT="$(date -Iseconds 2>/dev/null || date)"
EOF
    secure_file_permissions "${backup_bin}.meta" 600

    echo "$backup_bin"
    return 0
}

list_paqet_core_backups() {
    find "$PAQET_DIR" -maxdepth 1 -type f \( -name 'paqet.corebak.*' -o -name 'paqet.bak.*' \) ! -name '*.meta' 2>/dev/null \
        | while IFS= read -r f; do
            [ -f "$f" ] || continue
            printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || echo 0)" "$f"
        done \
        | sort -rn | cut -f2-
    return 0
}

restore_paqet_core_backup_file() {
    local backup_file="$1"
    [ -f "$backup_file" ] || { print_error "Backup file not found: $backup_file"; return 1; }

    if is_dry_run; then
        dry_run_notice "would restore core backup: $backup_file -> $PAQET_BIN"
        dry_run_notice "would optionally restore core provider metadata"
        print_success "DRY-RUN: core backup not restored"
        return 0
    fi

    # Avoid "Text file busy" by replacing through a temp file + rename.
    local tmp_restore="${PAQET_BIN}.restore.$$"
    cp "$backup_file" "$tmp_restore" || return 1
    chmod 755 "$tmp_restore" 2>/dev/null || chmod +x "$tmp_restore" 2>/dev/null || true
    mv -f "$tmp_restore" "$PAQET_BIN" || {
        rm -f "$tmp_restore" 2>/dev/null || true
        return 1
    }

    local meta_file="${backup_file}.meta"
    if [ -f "$meta_file" ]; then
        local backup_provider=""
        backup_provider=$(grep '^CORE_PROVIDER=' "$meta_file" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [ -n "$backup_provider" ]; then
            local restore_meta=false
            read_confirm "Restore core provider metadata to '${backup_provider}' too?" restore_meta "y"
            if [ "$restore_meta" = true ]; then
                set_current_core_provider "$backup_provider"
                print_info "Core provider metadata restored to: $(get_core_provider_label "$backup_provider")"
            fi
        fi
    fi

    return 0
}

show_core_management_status() {
    local provider
    provider=$(get_current_core_provider)
    local profile_preset
    profile_preset=$(get_current_profile_preset)
    local core_ver
    local raw_ver
    raw_ver=$(get_installed_paqet_version_text)
    core_ver=$(extract_recoba_version_from_text "$raw_ver")

    echo -e "  ${YELLOW}Core Provider:${NC}  ${CYAN}$(get_core_provider_label "$provider")${NC}"
    echo -e "  ${YELLOW}Core Version:${NC}   ${CYAN}${core_ver}${NC}"
    echo -e "  ${YELLOW}Profile Preset:${NC} ${CYAN}${profile_preset}${NC} ($(get_profile_preset_label "$profile_preset"))"
    if [ -f "$CORE_META" ]; then
        local meta_version=""
        local meta_source=""
        local meta_archive=""
        local meta_binary_sha=""
        local meta_archive_sha=""
        meta_version=$(get_installed_core_meta_field "CORE_VERSION")
        meta_source=$(get_installed_core_meta_field "CORE_ARCHIVE_SOURCE")
        meta_archive=$(get_installed_core_meta_field "CORE_ARCHIVE_PATH")
        meta_binary_sha=$(get_installed_core_meta_field "CORE_BINARY_SHA256")
        meta_archive_sha=$(get_installed_core_meta_field "CORE_ARCHIVE_SHA256")
        [ -n "$meta_version" ] && echo -e "  ${YELLOW}Installed Tag:${NC}  ${CYAN}${meta_version}${NC}"
        [ -n "$meta_source" ] && echo -e "  ${YELLOW}Archive Source:${NC} ${CYAN}${meta_source}${NC}"
        [ -n "$meta_archive" ] && echo -e "  ${YELLOW}Archive Path:${NC}   ${CYAN}${meta_archive}${NC}"
        [ -n "$meta_archive_sha" ] && echo -e "  ${YELLOW}Archive SHA256:${NC} ${CYAN}${meta_archive_sha}${NC}"
        [ -n "$meta_binary_sha" ] && echo -e "  ${YELLOW}Binary SHA256:${NC}  ${CYAN}${meta_binary_sha}${NC}"
    fi
}

show_core_install_metadata() {
    print_banner
    echo -e "${YELLOW}Installed Core Metadata${NC}"
    echo ""

    if [ ! -f "$CORE_META" ]; then
        print_warning "No installed core metadata found."
        print_info "Older installs may not have this file. Update or switch the core once to create it."
        return 0
    fi

    local provider=""
    local version=""
    local asset_url=""
    local archive_path=""
    local archive_source=""
    local archive_sha=""
    local binary_path=""
    local binary_sha=""
    local updated_at=""

    provider=$(get_installed_core_meta_field "CORE_PROVIDER")
    version=$(get_installed_core_meta_field "CORE_VERSION")
    asset_url=$(get_installed_core_meta_field "CORE_ASSET_URL")
    archive_path=$(get_installed_core_meta_field "CORE_ARCHIVE_PATH")
    archive_source=$(get_installed_core_meta_field "CORE_ARCHIVE_SOURCE")
    archive_sha=$(get_installed_core_meta_field "CORE_ARCHIVE_SHA256")
    binary_path=$(get_installed_core_meta_field "CORE_BINARY_PATH")
    binary_sha=$(get_installed_core_meta_field "CORE_BINARY_SHA256")
    updated_at=$(get_installed_core_meta_field "UPDATED_AT")

    echo -e "  ${YELLOW}Provider:${NC}       ${CYAN}${provider:-unknown}${NC}"
    echo -e "  ${YELLOW}Version/Tag:${NC}    ${CYAN}${version:-unknown}${NC}"
    echo -e "  ${YELLOW}Asset URL:${NC}      ${CYAN}${asset_url:-not recorded}${NC}"
    echo -e "  ${YELLOW}Archive Source:${NC} ${CYAN}${archive_source:-not recorded}${NC}"
    echo -e "  ${YELLOW}Archive Path:${NC}   ${CYAN}${archive_path:-not recorded}${NC}"
    echo -e "  ${YELLOW}Archive SHA256:${NC} ${CYAN}${archive_sha:-not recorded}${NC}"
    echo -e "  ${YELLOW}Binary Path:${NC}    ${CYAN}${binary_path:-$PAQET_BIN}${NC}"
    echo -e "  ${YELLOW}Binary SHA256:${NC}  ${CYAN}${binary_sha:-not recorded}${NC}"
    echo -e "  ${YELLOW}Installed At:${NC}   ${CYAN}${updated_at:-not recorded}${NC}"
    echo ""
}

switch_paqet_core_provider() {
    local target_provider="$1"
    local target_label
    target_label=$(get_core_provider_label "$target_provider")
    local current_provider
    current_provider=$(get_current_core_provider)

    print_banner
    echo -e "${YELLOW}Switch paqet Core Provider${NC}"
    echo ""
    echo -e "  ${YELLOW}Current:${NC} ${CYAN}$(get_core_provider_label "$current_provider")${NC}"
    echo -e "  ${YELLOW}Target:${NC}  ${CYAN}${target_label}${NC}"
    echo ""
    echo -e "${CYAN}This replaces only the paqet binary (core). Your configs/services remain the same.${NC}"
    echo -e "${CYAN}A backup of the current binary will be created before switching.${NC}"
    print_warning "Core protocol compatibility may differ between providers/versions."
    print_warning "Switch both tunnel ends to compatible cores (or rollback) if connections drop."
    echo ""

    local do_switch=false
    read_confirm "Switch core provider now and restart services?" do_switch "y"
    [ "$do_switch" != true ] && return 0

    if is_dry_run; then
        dry_run_notice "would backup current core binary if present: $PAQET_BIN"
        dry_run_notice "would switch core provider metadata to: $target_provider"
        dry_run_notice "would download/install selected core and restart services"
        print_success "DRY-RUN: core provider not switched"
        return 0
    fi

    local backup_bin=""
    if [ -f "$PAQET_BIN" ]; then
        backup_bin=$(create_paqet_core_backup "switch-${target_provider}") || {
            print_error "Failed to create core backup"
            return 1
        }
        print_info "Backup created: $backup_bin"
    else
        print_info "No existing paqet binary found; provider will be set after install"
    fi

    local old_provider="$current_provider"
    # single core — override not needed

    if download_paqet; then
        set_current_core_provider "$target_provider"
        restart_paqet_services_after_core_update
        print_success "Core provider switched to: $(get_core_provider_label "$target_provider")"
        return 0
    fi

    print_error "Core provider switch failed"
    if [ -n "$backup_bin" ] && [ -f "$backup_bin" ]; then
        if restore_paqet_core_backup_file "$backup_bin"; then
            print_warning "Restored previous paqet binary from backup"
        fi
    fi
    set_current_core_provider "$old_provider"
    return 1
}

set_profile_preset_interactive() {
    local target_preset="$1"
    load_active_profile_preset_defaults "$target_preset"

    print_banner
    echo -e "${YELLOW}Switch Profile Preset${NC}"
    echo ""
    echo -e "  ${YELLOW}Target preset:${NC} ${CYAN}${PROFILE_PRESET_NAME}${NC} (${PROFILE_PRESET_LABEL})"
    echo -e "  ${YELLOW}KCP block:${NC}     ${CYAN}${PROFILE_PRESET_KCP_BLOCK}${NC}"
    echo -e "  ${YELLOW}KCP MTU:${NC}       ${CYAN}${PROFILE_PRESET_KCP_MTU}${NC}"
    echo -e "  ${YELLOW}tcpbuf/udpbuf:${NC} ${CYAN}${PROFILE_PRESET_TRANSPORT_TCPBUF:-default}/${PROFILE_PRESET_TRANSPORT_UDPBUF:-default}${NC}"
    if [ -n "$PROFILE_PRESET_PCAP_SOCKBUF_SERVER" ] || [ -n "$PROFILE_PRESET_PCAP_SOCKBUF_CLIENT" ]; then
        echo -e "  ${YELLOW}pcap.sockbuf:${NC}  ${CYAN}server=${PROFILE_PRESET_PCAP_SOCKBUF_SERVER}, client=${PROFILE_PRESET_PCAP_SOCKBUF_CLIENT}${NC}"
    else
        echo -e "  ${YELLOW}pcap.sockbuf:${NC}  ${CYAN}use paqet defaults${NC}"
    fi
    echo ""
    echo -e "${CYAN}This only changes the active profile preset metadata for future setups.${NC}"
    echo -e "${CYAN}Use the apply option to retrofit the preset to existing configs.${NC}"
    echo -e "${CYAN}Profile apply keeps ports and IP addresses unchanged (tuning fields only).${NC}"
    print_warning "KCP profile values (especially block/MTU) should match on BOTH tunnel ends."
    print_warning "Applying a preset on only one side can cause connection loss until the peer is updated."
    echo ""

    local do_set=false
    read_confirm "Set active profile preset to '${target_preset}'?" do_set "y"
    [ "$do_set" != true ] && return 0

    set_current_profile_preset "$target_preset"
    print_success "Active profile preset is now: $target_preset"

    echo ""
    local do_apply_now=false
    read_confirm "Apply this profile preset to existing configs now?" do_apply_now "n"
    if [ "$do_apply_now" = true ]; then
        apply_active_profile_preset_existing_configs
    fi
}

rollback_paqet_core_menu() {
    print_banner
    echo -e "${YELLOW}Rollback paqet Core Binary${NC}"
    echo ""

    local backups
    backups=$(list_paqet_core_backups)
    if [ -z "$backups" ]; then
        print_error "No paqet core backups found"
        return 1
    fi

    local idx=0
    local backup_array=()
    while IFS= read -r b; do
        [ -z "$b" ] && continue
        idx=$((idx + 1))
        backup_array+=("$b")
        echo -e "  ${CYAN}${idx})${NC} ${YELLOW}$b${NC}"
    done <<< "$backups"

    echo ""
    read -r -p "Select backup to restore (0 to cancel): " rollback_choice < /dev/tty
    if [ "$rollback_choice" = "0" ]; then
        return 0
    fi
    if ! [[ "$rollback_choice" =~ ^[0-9]+$ ]] || [ "$rollback_choice" -lt 1 ] || [ "$rollback_choice" -gt "${#backup_array[@]}" ]; then
        print_error "Invalid choice"
        return 1
    fi

    local selected_backup="${backup_array[$((rollback_choice - 1))]}"
    echo ""
    local do_restore=false
    read_confirm "Restore selected backup and restart services?" do_restore "y"
    [ "$do_restore" != true ] && return 0

    if restore_paqet_core_backup_file "$selected_backup"; then
        restart_paqet_services_after_core_update
        print_success "Core rollback completed"
        return 0
    fi

    print_error "Core rollback failed"
    return 1
}

core_management_menu() {
    while true; do
        print_banner
        echo -e "${YELLOW}Core & Profile Management${NC}"
        echo ""
        show_core_management_status
        echo ""
        echo -e "${CYAN}Profile apply updates tuning fields only and keeps ports/IP addresses unchanged.${NC}"
        echo ""
        echo -e "  ${CYAN}1)${NC} Update/Reinstall Core"
        echo -e "  ${CYAN}2)${NC} Rollback Core Binary from Backup"
        echo -e "  ${CYAN}3)${NC} Set Profile Preset -> Default (auto-tuned)"
        echo -e "  ${CYAN}4)${NC} Set Profile Preset -> Iran Optimized (recommended)"
        echo -e "  ${CYAN}5)${NC} Apply Active Profile Preset to Existing Configs"
        echo -e "  ${CYAN}6)${NC} View Active KCP Profile Preview (read-only)"
        echo -e "  ${CYAN}7)${NC} Show Effective Port/Profile Defaults"
        echo -e "  ${CYAN}8)${NC} Show Installed Core Metadata"
        echo -e "  ${CYAN}b)${NC} Core Benchmarking"
        echo -e "  ${CYAN}0)${NC} Back"
        echo ""
        read -r -p "Choice: " core_choice < /dev/tty

        case "$core_choice" in
            1) update_paqet_core ;;
            2) rollback_paqet_core_menu ;;
            3) set_profile_preset_interactive "default" ;;
            4) set_profile_preset_interactive "iran-optimized" ;;
            5) apply_active_profile_preset_existing_configs ;;
            6) view_current_auto_profile ;;
            7) show_port_config ;;
            8) show_core_install_metadata ;;
            [Bb]) benchmark_menu ;;
            0) return 0 ;;
            *) print_error "Invalid choice" ;;
        esac

        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read -r < /dev/tty
    done
}

get_latest_paqet_release_tag() {
    get_latest_paqet_release_tag_for_provider "#removed"
}

get_installed_paqet_version_text() {
    if [ ! -x "$PAQET_BIN" ]; then
        echo "not installed"
        return 0
    fi

    local out=""
    out=$("$PAQET_BIN" version 2>/dev/null | head -1) || true
    [ -z "$out" ] && out=$("$PAQET_BIN" --version 2>/dev/null | head -1) || true
    [ -z "$out" ] && out=$("$PAQET_BIN" -v 2>/dev/null | head -1) || true

    if [ -n "$out" ]; then
        echo "$out"
    else
        echo "installed (version output unavailable)"
    fi
}

extract_recoba_version_from_text() {
    local text="$1"
    local ver=""
    local version_line=""

    # Prefer lines containing "version" or "Version" (case-insensitive)
    version_line=$(echo "$text" | grep -Ei "version" | head -1)
    if [ -z "$version_line" ]; then
        version_line=$(echo "$text" | head -1)
    fi

    # Extract the token matching v[0-9]+\.[0-9]+\.[0-9]+
    ver=$(echo "$version_line" | grep -oEi 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$ver" ]; then
        # Try fallback matching [0-9]+\.[0-9]+\.[0-9]+ and prefixing with 'v'
        local clean_num=""
        clean_num=$(echo "$version_line" | grep -oEi '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ -n "$clean_num" ]; then
            ver="v$clean_num"
        fi
    fi

    # Fallback to scanning the entire text if the version line didn't yield anything
    if [ -z "$ver" ]; then
        ver=$(echo "$text" | grep -oEi 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    if [ -z "$ver" ]; then
        local clean_num=""
        clean_num=$(echo "$text" | grep -oEi '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ -n "$clean_num" ]; then
            ver="v$clean_num"
        fi
    fi

    if [ -n "$ver" ]; then
        # Clean any whitespace or unsafe characters
        ver=$(echo "$ver" | tr -d '[:space:]/\\?*%:|"<>')
        echo "$ver"
    else
        echo "unknown"
    fi
}

restart_paqet_services_after_core_update() {
    print_step "Restarting paqet services..."

    local configs
    configs=$(get_all_configs)
    local restarted=0
    local failed=0

    if [ -n "$configs" ]; then
        while IFS= read -r config_file; do
            [ -z "$config_file" ] && continue
            local service
            service=$(get_tunnel_service "$config_file")
            if systemctl cat "$service" >/dev/null 2>&1; then
                if systemctl restart "$service" >/dev/null 2>&1; then
                    print_success "Restarted $service"
                    restarted=$((restarted + 1))
                else
                    print_warning "Failed to restart $service (check: journalctl -u $service -n 50)"
                    failed=$((failed + 1))
                fi
            fi
        done <<< "$configs"
    elif systemctl cat paqet >/dev/null 2>&1; then
        if systemctl restart paqet >/dev/null 2>&1; then
            print_success "Restarted paqet"
            restarted=1
        else
            print_warning "Failed to restart paqet (check: journalctl -u paqet -n 50)"
            failed=1
        fi
    fi

    if [ "$restarted" -eq 0 ] && [ "$failed" -eq 0 ]; then
        print_info "No installed paqet services detected to restart"
    fi
}

update_paqet_core() {
    print_banner
    echo -e "${YELLOW}Update paqet Core Binary${NC}"
    echo ""

    local provider
    provider=$(get_current_core_provider)
    print_info "Core provider: ${CYAN}$(get_core_provider_label "$provider")${NC}"

    local installed_ver
    local raw_ver
    raw_ver=$(get_installed_paqet_version_text)
    installed_ver=$(extract_recoba_version_from_text "$raw_ver")
    print_info "Installed core: ${CYAN}${installed_ver}${NC}"

    local latest_tag
    latest_tag=$(get_latest_paqet_release_tag_for_provider "$provider")
    if [ -n "$latest_tag" ]; then
        print_info "Latest provider release/tag: ${CYAN}${latest_tag}${NC}"
    else
        print_warning "Could not fetch latest release tag (network may be restricted)"
    fi
    local installed_meta_provider=""
    local installed_meta_version=""
    installed_meta_provider=$(get_installed_core_meta_field "CORE_PROVIDER")
    installed_meta_version=$(get_installed_core_meta_field "CORE_VERSION")
    if [ -n "$latest_tag" ] && [ "$installed_meta_provider" = "$provider" ] && [ "$installed_meta_version" = "$latest_tag" ]; then
        print_success "Installed core already matches the latest provider release/tag (${latest_tag})."
        print_info "No download needed. Cached core archives remain available for future switches/rollbacks."
        return 0
    fi
    print_warning "Core updates may require updating the peer server too if protocol compatibility changes."
    echo ""

    local do_core_update=false
    read_confirm "Download latest core for current provider and restart services?" do_core_update "y"
    [ "$do_core_update" != true ] && return 0

    mkdir -p "$PAQET_DIR"

    local backup_bin=""
    if [ -f "$PAQET_BIN" ]; then
        backup_bin=$(create_paqet_core_backup "update-${provider}") || {
            print_error "Failed to create core backup"
            return 1
        }
        print_info "Backup created: $backup_bin"
    fi

    local old_version_setting="$PAQET_VERSION"
    PAQET_VERSION="latest"

    if download_paqet; then
        PAQET_VERSION="$old_version_setting"
        restart_paqet_services_after_core_update
        print_success "paqet core update completed"
    else
        PAQET_VERSION="$old_version_setting"
        print_error "paqet core update failed"
        if [ -n "$backup_bin" ] && [ -f "$backup_bin" ]; then
            local tmp_restore="${PAQET_BIN}.restorefail.$$"
            if cp "$backup_bin" "$tmp_restore" 2>/dev/null && chmod +x "$tmp_restore" 2>/dev/null && mv -f "$tmp_restore" "$PAQET_BIN" 2>/dev/null; then
                print_warning "Restored previous paqet binary from backup"
            else
                rm -f "$tmp_restore" 2>/dev/null || true
                print_warning "Failed to restore previous paqet binary automatically (manual restore may be required)"
            fi
        fi
        return 1
    fi
}

check_for_updates() {
    print_banner
    echo -e "${YELLOW}Checking for Updates${NC}"
    echo ""
    
    print_step "Current version: ${CYAN}$INSTALLER_VERSION${NC}"
    echo ""
    
    print_step "Fetching latest version from GitHub..."
    
    # Get latest version from GitHub
    local latest_version=""
    local release_info=""
    local raw_script=""
    
    # Method 1: Try GitHub releases API
    release_info=$(curl -s --max-time 10 "https://api.github.com/repos/${INSTALLER_REPO}/releases/latest" 2>/dev/null)
    if [ -n "$release_info" ]; then
        latest_version=$(echo "$release_info" | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
    fi
    
    # Method 2: If no release found, fetch from raw main branch
    if [ -z "$latest_version" ]; then
        print_info "No releases found, checking main branch..."
        raw_script=$(curl -s --max-time 15 "https://raw.githubusercontent.com/${INSTALLER_REPO}/main/install.sh" 2>/dev/null)
        if [ -n "$raw_script" ]; then
            latest_version=$(echo "$raw_script" | grep 'INSTALLER_VERSION=' | head -1 | cut -d'"' -f2)
        fi
    fi
    
    if [ -z "$latest_version" ]; then
        print_error "Could not fetch version information"
        print_info "This may be due to network restrictions"
        echo ""
        echo -e "${YELLOW}Manual update:${NC}"
        echo -e "  ${CYAN}bash <(curl -fsSL https://raw.githubusercontent.com/${INSTALLER_REPO}/main/install.sh)${NC}"
        return 1
    fi
    
    print_info "Latest version: ${CYAN}$latest_version${NC}"
    echo ""
    
    # Compare versions (simple string comparison)
    if [ "$INSTALLER_VERSION" = "$latest_version" ]; then
        echo ""
        echo -e "${YELLOW}Check out my latest tunnel project (SMTP-based):${NC}"
        echo -e "  ${CYAN}https://github.com/g3ntrix/smtp-tunnel${NC}"
        echo ""
        print_success "You are running the latest version!"
        return 0
    fi
    
    # Version is different (could be newer or older)
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}A new version is available!${NC}"
    echo -e "  Current: ${RED}$INSTALLER_VERSION${NC}"
    echo -e "  Latest:  ${GREEN}$latest_version${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local do_update=false
    read_confirm "Would you like to update now?" do_update "y"
    
    if [ "$do_update" = true ]; then
        update_installer
    fi
}

update_installer() {
    print_step "Downloading latest installer..."

    local temp_script
    temp_script=$(mktemp /tmp/paqet_install_new.XXXXXX)
    local download_url="https://raw.githubusercontent.com/${INSTALLER_REPO}/main/install.sh"

    if is_dry_run; then
        dry_run_notice "would download installer: $download_url -> $temp_script"
        dry_run_notice "would validate downloaded installer"
        dry_run_notice "would backup current configs under $PAQET_DIR"
        dry_run_notice "would update installed command if present: $INSTALLER_CMD"
        dry_run_notice "would execute updated installer"
        print_success "DRY-RUN: installer not updated"
        return 0
    fi
    
    if curl -fsSL "$download_url" -o "$temp_script" 2>/dev/null; then
        chmod +x "$temp_script"
        
        # Verify the downloaded script
        if grep -q "INSTALLER_VERSION" "$temp_script"; then
            local new_version
            new_version=$(grep '^INSTALLER_VERSION=' "$temp_script" | cut -d'"' -f2)
            print_success "Downloaded version: $new_version"
            
            # Backup current configs if they exist
            local backup_configs
            backup_configs=$(get_all_configs 2>/dev/null)
            if [ -n "$backup_configs" ]; then
                while IFS= read -r cfg; do
                    cp "$cfg" "${cfg}.backup"
                    secure_file_permissions "${cfg}.backup" 600
                done <<< "$backup_configs"
                print_info "Configurations backed up"
            fi
            
            # Update the installed command if it exists
            if is_command_installed; then
                cp "$temp_script" "$INSTALLER_CMD"
                chmod +x "$INSTALLER_CMD"
                print_success "Updated recoba-tunnel command at $INSTALLER_CMD"
            fi
            
            echo ""
            echo -e "${YELLOW}Check out my latest tunnel project (SMTP-based):${NC}"
            echo -e "  ${CYAN}https://github.com/g3ntrix/smtp-tunnel${NC}"
            echo ""
            print_step "Launching updated installer..."
            echo ""
            
            # Execute the new script
            exec bash "$temp_script"
        else
            print_error "Downloaded file doesn't appear to be valid"
            rm -f "$temp_script"
            return 1
        fi
    else
        print_error "Failed to download update"
        print_info "Network may be restricted. Try manual update:"
        echo -e "  ${CYAN}bash <(curl -fsSL $download_url)${NC}"
        return 1
    fi
}

#===============================================================================
# Update Menu + Read-only Auto Profile + Quick Port Configuration Display
#===============================================================================

updates_menu() {
    while true; do
        print_banner
        echo -e "${YELLOW}Updates${NC}"
        echo ""

        local core_ver
        local raw_ver
        raw_ver=$(get_installed_paqet_version_text)
        core_ver=$(extract_recoba_version_from_text "$raw_ver")
        local core_provider
        core_provider=$(get_current_core_provider)
        local profile_preset
        profile_preset=$(get_current_profile_preset)
        echo -e "  ${YELLOW}Installer:${NC}   ${CYAN}${INSTALLER_VERSION}${NC}"
        echo -e "  ${YELLOW}paqet Core:${NC}  ${CYAN}${core_ver}${NC}"
        echo -e "  ${YELLOW}Provider:${NC}    ${CYAN}$(get_core_provider_label "$core_provider")${NC}"
        echo -e "  ${YELLOW}Profile:${NC}     ${CYAN}${profile_preset}${NC} ($(get_profile_preset_label "$profile_preset"))"
        echo ""

        echo -e "  ${CYAN}1)${NC} Check/Update Installer Script"
        echo -e "  ${CYAN}2)${NC} Update Recoba Core (Safe, Checksum Verified)"
        echo -e "  ${CYAN}3)${NC} Core & Profile Management"
        echo -e "  ${CYAN}0)${NC} Back"
        echo ""
        read -r -p "Choice: " upd_choice < /dev/tty

        case $upd_choice in
            1) check_for_updates ;;
            2) safe_update_core ;;
            3) core_management_menu ;;
            0) return 0 ;;
            *) print_error "Invalid choice" ;;
        esac

        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read -r < /dev/tty
    done
}

view_current_auto_profile() {
    print_banner
    echo -e "${YELLOW}Active KCP Profile Preview (Read-only)${NC}"
    echo ""
    calculate_auto_kcp_profile
    show_auto_kcp_profile
    echo -e "${CYAN}No changes were applied. This only shows the effective KCP profile for this server.${NC}"
    echo -e "${CYAN}To apply it to existing configs, use: Updates -> Core & Profile Management -> Apply Active Profile Preset to Existing Configs.${NC}"
    echo ""
}

show_port_config() {
    load_active_profile_preset_defaults
    calculate_auto_kcp_profile
    echo ""
    echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}              Current Port Configuration                    ${NC}"
    echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${YELLOW}Default paqet port:${NC}     ${CYAN}$DEFAULT_PAQET_PORT${NC}"
    echo -e "  ${YELLOW}Default forward ports:${NC}  ${CYAN}$DEFAULT_FORWARD_PORTS${NC}"
    echo -e "  ${YELLOW}Profile preset:${NC}         ${CYAN}${PROFILE_PRESET_NAME}${NC} (${PROFILE_PRESET_LABEL})"
    echo -e "  ${YELLOW}KCP mode:${NC}               ${CYAN}$(get_effective_profile_kcp_mode)${NC}"
    if false; then
        echo -e "  ${YELLOW}KCP connections:${NC}        ${CYAN}$AUTO_TUNE_CONN${NC} (Behzad minimal + hardware-adaptive)"
    else
        echo -e "  ${YELLOW}KCP connections:${NC}        ${CYAN}$AUTO_TUNE_CONN${NC} (PaqX CPU/RAM auto-tuned for this server)"
    fi
    echo -e "  ${YELLOW}KCP MTU:${NC}                ${CYAN}$(get_effective_profile_kcp_mtu)${NC} (effective baseline)"
    echo -e "  ${YELLOW}KCP block:${NC}              ${CYAN}${PROFILE_PRESET_KCP_BLOCK}${NC}"
    if [ -n "$PROFILE_PRESET_TRANSPORT_TCPBUF" ] || [ -n "$PROFILE_PRESET_TRANSPORT_UDPBUF" ]; then
        echo -e "  ${YELLOW}tcpbuf/udpbuf:${NC}          ${CYAN}${PROFILE_PRESET_TRANSPORT_TCPBUF:-default}/${PROFILE_PRESET_TRANSPORT_UDPBUF:-default}${NC}"
    else
        echo -e "  ${YELLOW}tcpbuf/udpbuf:${NC}          ${CYAN}use paqet defaults${NC}"
    fi
    echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
    echo ""
    if false; then
        echo -e "${CYAN}Setup applies the active Behzad preset as a standalone profile (no PaqX KCP auto-tune mixing) + kernel sysctl optimization.${NC}"
    else
        echo -e "${CYAN}Setup applies the active profile preset + PaqX-style CPU/RAM auto tuning (conn + wnd) + kernel sysctl optimization.${NC}"
    fi
    echo -e "${CYAN}Use Maintenance -> 'd' if you need to lower MTU to 1280 on restrictive networks.${NC}"
    echo ""
}

#===============================================================================
# Install/Uninstall Script as Command
#===============================================================================

install_command() {
    print_step "Installing recoba-tunnel command..."

    # Download latest script from GitHub
    local temp_script
    temp_script=$(mktemp /tmp/paqet-tunnel-install.XXXXXX)
    local download_url="https://raw.githubusercontent.com/${INSTALLER_REPO}/main/install.sh"

    if is_dry_run; then
        dry_run_notice "would download installer command from: $download_url"
        dry_run_notice "would install command to: $INSTALLER_CMD"
        print_success "DRY-RUN: recoba-tunnel command not installed"
        return 0
    fi
    
    # Check if we're running from the installed location
    if [ -f "$INSTALLER_CMD" ]; then
        # Already installed, just update
        print_info "Updating existing installation..."
    fi
    
    # Try to download latest version
    if curl -fsSL "$download_url" -o "$temp_script" 2>/dev/null; then
        chmod +x "$temp_script"
        mv "$temp_script" "$INSTALLER_CMD"
        print_success "recoba-tunnel command installed successfully!"
    else
        # If download fails, copy current script
        print_warning "Could not download latest version, installing current script..."
        
        # Get the path of the currently running script
        local current_script="${BASH_SOURCE[0]}"
        if [ -f "$current_script" ]; then
            cp "$current_script" "$INSTALLER_CMD"
            chmod +x "$INSTALLER_CMD"
            print_success "recoba-tunnel command installed from local script!"
        else
            # If running from curl pipe, save from stdin
            print_info "Saving script from current execution..."
            # Re-download or use $0
            if [ -f "$0" ]; then
                cp "$0" "$INSTALLER_CMD"
                chmod +x "$INSTALLER_CMD"
                print_success "recoba-tunnel command installed!"
            else
                print_error "Could not determine script source"
                print_info "Please run: curl -fsSL $download_url -o $INSTALLER_CMD && chmod +x $INSTALLER_CMD"
                return 1
            fi
        fi
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         recoba-tunnel command installed!                    ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  You can now run: ${CYAN}paqet-tunnel${NC}"
    echo ""
    echo -e "  Location: ${CYAN}$INSTALLER_CMD${NC}"
    echo ""
}

uninstall_command() {
    if [ -f "$INSTALLER_CMD" ]; then
        rm -f "$INSTALLER_CMD"
        print_success "recoba-tunnel command removed from $INSTALLER_CMD"
    else
        print_info "recoba-tunnel command is not installed"
    fi
}

is_command_installed() {
    [ -f "$INSTALLER_CMD" ]
}

#===============================================================================
# Core Benchmarking & Stability Suite
#===============================================================================

start_local_benchmark_listener() {
    if ss -tuln | grep -q ":19999 "; then
        print_success "Benchmark listener is already running on port 19999"
        return 0
    fi
    
    print_step "Starting local benchmark listener on port 19999..."
    python3 -c '
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path.startswith("/download"):
            s=10485760
            try: s=int(self.path.split("size=")[1])
            except: pass
            self.send_response(200)
            self.send_header("Content-Type","application/octet-stream")
            self.send_header("Content-Length",str(s))
            self.end_headers()
            chunk = b"\0" * 65536
            sent = 0
            while sent < s:
                to_send = min(65536, s - sent)
                self.wfile.write(chunk[:to_send])
                sent += to_send
        elif self.path=="/ping":
            self.send_response(200); self.end_headers(); self.wfile.write(b"pong")
    def do_POST(self):
        if self.path=="/upload":
            l=int(self.headers.get("Content-Length",0))
            chunk_size = 65536
            remaining = l
            while remaining > 0:
                to_read = min(chunk_size, remaining)
                _ = self.rfile.read(to_read)
                remaining -= to_read
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
socketserver.TCPServer.allow_reuse_address=True
httpd=socketserver.TCPServer(("",19999),H)
httpd.serve_forever()
' >/dev/null 2>&1 &
    
    local pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        print_success "Benchmark listener started successfully (PID: $pid)"
        PAQET_BENCH_PID="$pid"
        return 0
    else
        print_error "Failed to start benchmark listener"
        return 1
    fi
}

stop_local_benchmark_listener() {
    print_step "Stopping local benchmark listener..."
    if [ -n "${PAQET_BENCH_PID:-}" ]; then
        kill "$PAQET_BENCH_PID" 2>/dev/null || true
        PAQET_BENCH_PID=""
    fi
    pkill -f "socketserver.TCPServer.*H" || true
    print_success "Benchmark listener stopped"
}

deploy_benchmark_helper_remote() {
    local ip="$1"
    local user="${2:-ubuntu}"
    local key_path="${3:-}"
    
    print_step "Attempting to deploy benchmark listener to Server B ($user@$ip)..."
    
    local ssh_cmd="ssh -o StrictHostKeyChecking=no"
    if [ -n "$key_path" ]; then
        ssh_cmd="$ssh_cmd -i $key_path"
    fi
    
    if ! $ssh_cmd -o ConnectTimeout=5 "$user@$ip" "echo connection_ok" >/dev/null 2>&1; then
        print_error "Failed to connect to Server B via SSH. Please check host, user, and keys."
        return 1
    fi
    
    $ssh_cmd "$user@$ip" "pkill -f 'socketserver.TCPServer.*H' || true"
    
    $ssh_cmd "$user@$ip" "nohup python3 -c '
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        if self.path.startswith(\"/download\"):
            s=10485760
            try: s=int(self.path.split(\"size=\")[1])
            except: pass
            self.send_response(200)
            self.send_header(\"Content-Type\",\"application/octet-stream\")
            self.send_header(\"Content-Length\",str(s))
            self.end_headers()
            chunk = b\"\0\" * 65536
            sent = 0
            while sent < s:
                to_send = min(65536, s - sent)
                self.wfile.write(chunk[:to_send])
                sent += to_send
        elif self.path==\"/ping\":
            self.send_response(200); self.end_headers(); self.wfile.write(b\"pong\")
    def do_POST(self):
        if self.path==\"/upload\":
            l=int(self.headers.get(\"Content-Length\",0))
            chunk_size = 65536
            remaining = l
            while remaining > 0:
                to_read = min(chunk_size, remaining)
                _ = self.rfile.read(to_read)
                remaining -= to_read
            self.send_response(200); self.end_headers(); self.wfile.write(b\"ok\")
socketserver.TCPServer.allow_reuse_address=True
httpd=socketserver.TCPServer((\"\",19999),H)
httpd.serve_forever()
' >/dev/null 2>&1 &"
    
    print_success "Benchmark listener successfully started on Server B!"
    return 0
}

cleanup_benchmark_helper_remote() {
    local ip="$1"
    local user="${2:-ubuntu}"
    local key_path="${3:-}"
    
    local ssh_cmd="ssh -o StrictHostKeyChecking=no"
    if [ -n "$key_path" ]; then
        ssh_cmd="$ssh_cmd -i $key_path"
    fi
    
    $ssh_cmd "$user@$ip" "pkill -f 'socketserver.TCPServer.*H' || true" >/dev/null 2>&1 || true
}

setup_temporary_benchmark_forwarding() {
    if [ ! -f "$PAQET_CONFIG" ]; then
        print_error "Configuration file not found: $PAQET_CONFIG"
        return 1
    fi
    
    if grep -q "19999" "$PAQET_CONFIG" 2>/dev/null; then
        print_info "Port 19999 is already present in forwarding config."
        BENCH_TEMP_CONFIG_USED=false
        return 0
    fi
    
    print_step "Configuring temporary forwarding for benchmark port 19999..."
    BENCH_CONFIG_BACKUP="${PAQET_CONFIG}.benchbak"
    cp "$PAQET_CONFIG" "$BENCH_CONFIG_BACKUP"
    
    if grep -q "^forward:" "$PAQET_CONFIG"; then
        sed -i '/^forward:/a \  - listen: "0.0.0.0:19999"\n    target: "127.0.0.1:19999"\n    protocol: "tcp"' "$PAQET_CONFIG"
    else
        cat >> "$PAQET_CONFIG" <<EOF

forward:
  - listen: "0.0.0.0:19999"
    target: "127.0.0.1:19999"
    protocol: "tcp"
EOF
    fi
    
    BENCH_TEMP_CONFIG_USED=true
    print_success "Temporary benchmark forwarding configured. Restarting services..."
    systemctl_or_dry_run restart "$PAQET_SERVICE"
    sleep 3
}

restore_benchmark_forwarding() {
    if [ "${BENCH_TEMP_CONFIG_USED:-false}" = true ]; then
        print_step "Restoring original configuration and restarting services..."
        if [ -f "$BENCH_CONFIG_BACKUP" ]; then
            mv -f "$BENCH_CONFIG_BACKUP" "$PAQET_CONFIG"
            systemctl_or_dry_run restart "$PAQET_SERVICE"
            sleep 2
            print_success "Original configuration restored successfully."
        fi
    fi
}

run_core_benchmark() {
    local provider="$1"
    local test_port="19999"
    local ping_url="http://127.0.0.1:${test_port}/ping"
    local dl_url="http://127.0.0.1:${test_port}/download?size=10485760"
    local ul_url="http://127.0.0.1:${test_port}/upload"
    
    print_step "Starting core benchmark for $(get_core_provider_label "$provider")..."
    
    if is_dry_run; then
        dry_run_notice "would run benchmark for provider: $provider"
        BENCH_RESULT_RTT="10"
        BENCH_RESULT_DL="50.00"
        BENCH_RESULT_UL="25.00"
        BENCH_RESULT_ERRS="0"
        return 0
    fi

    print_info "Testing RTT/latency..."
    local rtt_sum=0
    local rtt_count=0
    local _
    for _ in {1..5}; do
        local ts
        ts=$(date +%s%N 2>/dev/null || date +%s000000000)
        if curl -s -o /dev/null --max-time 3 "$ping_url"; then
            local te
            te=$(date +%s%N 2>/dev/null || date +%s000000000)
            local diff=$((te - ts))
            local rtt=$((diff / 1000000))
            [ "$rtt" -lt 0 ] && rtt=0
            rtt_sum=$((rtt_sum + rtt))
            rtt_count=$((rtt_count + 1))
        fi
        sleep 0.2
    done
    
    local avg_rtt="N/A"
    if [ "$rtt_count" -gt 0 ]; then
        avg_rtt=$((rtt_sum / rtt_count))
        print_success "RTT: ${avg_rtt} ms (averaged over ${rtt_count} probes)"
    else
        print_error "Server B is unreachable via the benchmark port. Test failed."
        return 1
    fi
    
    local start_time
    start_time=$(date +"%Y-%m-%d %H:%M:%S")
    
    print_info "Testing download throughput (10MB)..."
    local dl_speed
    dl_speed=$(curl -s -o /dev/null -w "%{speed_download}" --max-time 20 "$dl_url" || echo "0")
    local dl_mbps="0.00"
    if [ -n "$dl_speed" ] && [ "$dl_speed" != "0" ]; then
        dl_mbps=$(awk -v s="$dl_speed" 'BEGIN {printf "%.2f", s * 8 / 1000000}')
        print_success "Download: ${dl_mbps} Mbps"
    else
        print_error "Download test failed."
    fi
    
    print_info "Testing upload throughput (10MB)..."
    local ul_speed
    ul_speed=$(dd if=/dev/zero bs=1M count=10 2>/dev/null | curl -s -o /dev/null -w "%{speed_upload}" -X POST --data-binary @- --max-time 20 "$ul_url" || echo "0")
    local ul_mbps="0.00"
    if [ -n "$ul_speed" ] && [ "$ul_speed" != "0" ]; then
        ul_mbps=$(awk -v s="$ul_speed" 'BEGIN {printf "%.2f", s * 8 / 1000000}')
        print_success "Upload: ${ul_mbps} Mbps"
    else
        print_error "Upload test failed."
    fi
    
    print_info "Scanning system logs for transmit queue drops/ENOBUFS..."
    local err_count=0
    if command -v journalctl >/dev/null 2>&1; then
        err_count=$(journalctl -u "$PAQET_SERVICE" --since "$start_time" 2>/dev/null | grep -Ei "no buffer space|ENOBUFS|send error|write error" -c || true)
    fi
    
    if [ "$err_count" -gt 0 ]; then
        print_warning "Detected ${err_count} buffer drops/transmit queue errors during upload test!"
    else
        print_success "0 buffer space errors detected. Stability OK."
    fi
    
    BENCH_RESULT_RTT="$avg_rtt"
    BENCH_RESULT_DL="$dl_mbps"
    BENCH_RESULT_UL="$ul_mbps"
    BENCH_RESULT_ERRS="$err_count"
    return 0
}

benchmark_all_cores() {
    if [ -f "$PAQET_CONFIG" ] && [ "$(grep '^role:' "$PAQET_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"')" = "server" ]; then
        print_info "Running benchmark on Server B (Dubai)..."
    else
        select_tunnel "Select tunnel to benchmark" || return 1
    fi

    local current_provider
    current_provider=$(get_current_core_provider)
    
    local providers=()
    local rtts=()
    local dls=()
    local uls=()
    local errs=()
    
    print_banner
    echo -e "${YELLOW}Automatic Core Evaluation & Benchmarking${NC}"
    echo ""
    echo -e "${CYAN}This will benchmark all known cores: ${KNOWN_CORE_PROVIDERS}${NC}"
    echo -e "${CYAN}The script will temporarily install each core, run metrics, and restore your system.${NC}"
    echo ""
    
    if is_dry_run; then
        dry_run_notice "would configure temporary forwarding, run all core benchmarks, and generate report"
        return 0
    fi

    setup_temporary_benchmark_forwarding || return 1
    
    echo -e "${YELLOW}Before proceeding, the benchmark listener must be running on Server B (Dubai).${NC}"
    echo -e "You can automate this via SSH or start it manually."
    echo ""
    echo -e "  ${CYAN}1)${NC} Automate deployment via SSH to Server B"
    echo -e "  ${CYAN}2)${NC} I started it manually (running on port 19999)"
    echo -e "  ${CYAN}0)${NC} Cancel benchmark"
    echo ""
    read -r -p "Choice: " listener_choice < /dev/tty
    
    local remote_ip=""
    local remote_user=""
    local remote_key=""
    
    if [ "$listener_choice" = "1" ]; then
        local server_addr
        server_addr=$(grep -A1 "^server:" "$PAQET_CONFIG" 2>/dev/null | grep "addr:" | awk '{print $2}' | tr -d '"')
        local default_ip
        default_ip=$(echo "$server_addr" | cut -d':' -f1)
        
        read -r -p "Server B IP (default: $default_ip): " remote_ip < /dev/tty
        [ -z "$remote_ip" ] && remote_ip="$default_ip"
        
        read -r -p "SSH user (default: ubuntu): " remote_user < /dev/tty
        [ -z "$remote_user" ] && remote_user="ubuntu"
        
        read -r -p "SSH key path (default: ~/.ssh/id_rsa, leave empty for agent/config default): " remote_key < /dev/tty
        
        if ! deploy_benchmark_helper_remote "$remote_ip" "$remote_user" "$remote_key"; then
            restore_benchmark_forwarding
            return 1
        fi
    elif [ "$listener_choice" = "2" ]; then
        print_info "Using manual listener. Testing connectivity..."
        if ! curl -s -o /dev/null --max-time 3 "http://127.0.0.1:19999/ping"; then
            print_error "Cannot reach benchmark helper on http://127.0.0.1:19999/ping. Please make sure the service is running and tunnel is active."
            restore_benchmark_forwarding
            return 1
        fi
    else
        print_info "Cancelled."
        restore_benchmark_forwarding
        return 0
    fi
    
    local prov
    for prov in $KNOWN_CORE_PROVIDERS; do
        echo ""
        echo -e "${YELLOW}======================================================${NC}"
        echo -e "${YELLOW} Testing Core Provider: $(get_core_provider_label "$prov") ${NC}"
        echo -e "${YELLOW}======================================================${NC}"
        echo ""
        
        local backup_bin=""
        if [ -f "$PAQET_BIN" ]; then
            backup_bin=$(create_paqet_core_backup "benchmark-${prov}") || {
                print_error "Failed to create core backup"
                continue
            }
        fi
        
        # single core — override not needed
        if download_paqet; then
            set_current_core_provider "$prov"
            restart_paqet_services_after_core_update
            print_info "Stabilizing tunnel for 5 seconds..."
            sleep 5
            
            if run_core_benchmark "$prov"; then
                providers+=("$prov")
                rtts+=("$BENCH_RESULT_RTT")
                dls+=("$BENCH_RESULT_DL")
                uls+=("$BENCH_RESULT_UL")
                errs+=("$BENCH_RESULT_ERRS")
            fi
        else
            print_error "Failed to switch to provider: $prov"
        fi
        
        if [ -n "$backup_bin" ] && [ -f "$backup_bin" ]; then
            local tmp_restore="${PAQET_BIN}.restore.$$"
            cp "$backup_bin" "$tmp_restore" && mv -f "$tmp_restore" "$PAQET_BIN" || true
            rm -f "${backup_bin}" "${backup_bin}.meta" 2>/dev/null || true
        fi
    done
    
    if [ "$listener_choice" = "1" ] && [ -n "$remote_ip" ]; then
        cleanup_benchmark_helper_remote "$remote_ip" "$remote_user" "$remote_key"
    fi
    
    # single core — override not needed
    download_paqet && {
        set_current_core_provider "$current_provider"
        restart_paqet_services_after_core_update
    }
    
    restore_benchmark_forwarding
    
    print_banner
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                    Core Benchmark Results                        ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════════╣${NC}"
    printf "${YELLOW}║ %-20s │ %-10s │ %-10s │ %-8s │ %-8s ║${NC}\n" "Core Provider" "DL Speed" "UL Speed" "Latency" "Errors"
    echo -e "${YELLOW}╠──────────────────────────────────────────────────────────────────╣${NC}"
    
    local idx=0
    for ((idx=0; idx<${#providers[@]}; idx++)); do
        local p="${providers[$idx]}"
        local p_label
        p_label=$(get_core_provider_label "$p" | cut -d' ' -f1)
        printf "${YELLOW}║${NC} %-20s │ %-8s Mbps │ %-8s Mbps │ %-5s ms │ %-8s ${YELLOW}║${NC}\n" \
            "$p_label" "${dls[$idx]}" "${uls[$idx]}" "${rtts[$idx]}" "${errs[$idx]}"
    done
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local best_provider=""
    local min_errors=99999
    local max_ul=0
    
    for ((idx=0; idx<${#providers[@]}; idx++)); do
        local err="${errs[$idx]}"
        local ul="${uls[$idx]}"
        local ul_raw="${ul//./}"
        
        if [ "$err" -lt "$min_errors" ]; then
            min_errors="$err"
            max_ul="$ul_raw"
            best_provider="${providers[$idx]}"
        elif [ "$err" -eq "$min_errors" ]; then
            if [ "$ul_raw" -gt "$max_ul" ]; then
                max_ul="$ul_raw"
                best_provider="${providers[$idx]}"
            fi
        fi
    done
    
    if [ -n "$best_provider" ]; then
        echo -e "${GREEN}[✓] Recommended Core for Stability: $(get_core_provider_label "$best_provider")${NC}"
        echo -e "${GREEN}    This core achieved the lowest transit errors and best performance under load.${NC}"
        echo ""
    fi
}

benchmark_menu() {
    if [ -f "$PAQET_CONFIG" ] && [ "$(grep '^role:' "$PAQET_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"')" = "server" ]; then
        print_info "Running benchmark menu on Server B (Dubai)..."
    else
        select_tunnel "Select tunnel to benchmark" || return 1
    fi

    while true; do
        print_banner
        echo -e "${YELLOW}Core Benchmarking & Stability Suite${NC}"
        echo ""
        local provider
        provider=$(get_current_core_provider)
        echo -e "  ${YELLOW}Active Core Provider:${NC}  ${CYAN}$(get_core_provider_label "$provider")${NC}"
        echo ""
        echo -e "  ${CYAN}1)${NC} Benchmark Active Core"
        echo -e "  ${CYAN}2)${NC} Run Automatic Multi-Core Evaluation (Test All)"
        echo -e "  ${CYAN}3)${NC} Start Local Benchmark Listener (Server B mode)"
        echo -e "  ${CYAN}4)${NC} Stop Local Benchmark Listener"
        echo -e "  ${CYAN}0)${NC} Back"
        echo ""
        read -r -p "Choice: " choice < /dev/tty
        
        case "$choice" in
            1)
                setup_temporary_benchmark_forwarding || continue
                run_core_benchmark "$provider"
                restore_benchmark_forwarding
                ;;
            2)
                benchmark_all_cores
                ;;
            3)
                start_local_benchmark_listener
                ;;
            4)
                stop_local_benchmark_listener
                ;;
            0)
                return 0
                ;;
            *)
                print_error "Invalid choice"
                ;;
        esac
        
        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read -r < /dev/tty
    done
}

#===============================================================================
# Migration from old Paqet Manager (/opt/paqet → /opt/recoba-tunnel)
#===============================================================================

migrate_old_paqet_install() {
    local old_dir="/opt/paqet"
    local old_configs=""

    print_banner
    echo -e "${YELLOW}Migrate from Old Paqet Manager Install${NC}"
    echo ""
    echo -e "  ${YELLOW}Old path:${NC} ${CYAN}${old_dir}${NC}"
    echo -e "  ${YELLOW}New path:${NC} ${CYAN}${PAQET_DIR}${NC}"
    echo ""

    if [ ! -d "$old_dir" ]; then
        print_info "No old /opt/paqet directory found. Nothing to migrate."
        return 0
    fi

    old_configs=$(find "$old_dir" -maxdepth 1 -name 'config*.yaml' -type f 2>/dev/null | sort || true)
    if [ -z "$old_configs" ]; then
        print_info "No old paqet config files found in ${old_dir}. Nothing to migrate."
        return 0
    fi

    echo -e "${CYAN}Found old configurations:${NC}"
    while IFS= read -r cfg; do
        [ -z "$cfg" ] && continue
        local name=""
        name=$(basename "$cfg" .yaml | sed 's/^config-//; s/^config$/default/')
        echo -e "  ${CYAN}→${NC} $cfg ${YELLOW}(tunnel: ${name})${NC}"
    done <<< "$old_configs"
    echo ""

    if is_dry_run; then
        echo -e "${YELLOW}=== DRY-RUN: Migration Plan ===${NC}"
        while IFS= read -r cfg; do
            [ -z "$cfg" ] && continue
            local name=""
            name=$(basename "$cfg" .yaml | sed 's/^config-//; s/^config$/default/')
            local new_config="$PAQET_DIR/config-${name}.yaml"
            local old_service="paqet-${name}"
            local new_service="recoba-tunnel-${name}"
            [ "$name" = "default" ] && old_service="paqet" && new_service="recoba-tunnel"

            echo ""
            echo -e "  ${CYAN}Tunnel: ${name}${NC}"
            dry_run_notice "would backup: cp $cfg ${cfg}.migrated.bak.$(date +%s)"
            dry_run_notice "would copy:   cp $cfg $new_config"
            dry_run_notice "would create systemd unit: $new_service (from $old_service)"
            dry_run_notice "would NOT delete old config or stop old service"
        done <<< "$old_configs"
        echo ""
        dry_run_notice "would install core binary if missing"
        print_success "DRY-RUN: migration not applied"
        return 0
    fi

    print_warning "This will copy old configs and create new service units."
    print_warning "Old /opt/paqet files will NOT be deleted or modified."
    print_warning "Old paqet-*.service units will NOT be stopped."
    echo ""

    local do_migrate=false
    read_confirm "Proceed with migration?" do_migrate "n"
    [ "$do_migrate" != true ] && { print_info "Migration cancelled."; return 0; }

    local ts=""
    ts=$(date +%s)
    local migrated=0
    local failed=0

    mkdir -p "$PAQET_DIR"

    while IFS= read -r cfg; do
        [ -z "$cfg" ] && continue
        local name=""
        name=$(basename "$cfg" .yaml | sed 's/^config-//; s/^config$/default/')
        local new_config="$PAQET_DIR/config-${name}.yaml"
        local old_service="paqet-${name}"
        local new_service="recoba-tunnel-${name}"
        [ "$name" = "default" ] && old_service="paqet" && new_service="recoba-tunnel" && new_config="$PAQET_DIR/config.yaml"

        # Backup old config
        local backup_cfg="${cfg}.migrated.bak.${ts}"
        if cp "$cfg" "$backup_cfg" 2>/dev/null; then
            print_success "Backed up: $backup_cfg"
        fi

        # Copy config
        if cp "$cfg" "$new_config" 2>/dev/null; then
            print_success "Copied config: $cfg → $new_config"
        else
            print_error "Failed to copy config for tunnel '$name'"
            failed=$((failed + 1))
            continue
        fi

        # Generate service unit
        local service_file="/etc/systemd/system/${new_service}.service"
        if [ ! -f "$service_file" ]; then
            local desc="${PROJECT_NAME} - Tunnel: ${name}"
            local temp_svc
            temp_svc=$(mktemp "/tmp/${new_service}.XXXXXX")
            cat > "$temp_svc" << EOF
[Unit]
Description=${desc}
After=network.target

[Service]
Type=simple
ExecStart=${PAQET_BIN} run -c ${new_config}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
            if mv "$temp_svc" "$service_file" 2>/dev/null; then
                systemctl daemon-reload 2>/dev/null || true
                print_success "Created service: $new_service"
            else
                print_warning "Could not create service file: $service_file"
            fi
        else
            print_info "Service already exists: $new_service (skipped)"
        fi

        migrated=$((migrated + 1))
    done <<< "$old_configs"

    # Install core binary if missing
    if [ ! -x "$PAQET_BIN" ]; then
        print_step "Downloading Recoba Enhanced Core..."
        download_paqet || print_warning "Core download failed; install manually later"
    fi

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         Migration Complete: ${migrated} tunnels migrated          ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "  1. Review migrated configs in ${CYAN}${PAQET_DIR}${NC}"
    echo -e "  2. Stop old services: ${CYAN}sudo systemctl stop paqet paqet-*${NC}"
    echo -e "  3. Start new services: ${CYAN}sudo systemctl start recoba-tunnel recoba-tunnel-*${NC}"
    echo -e "  4. Verify: ${CYAN}recoba-tunnel → 3) Check Status${NC}"
    echo ""
    echo -e "${YELLOW}Rollback:${NC}"
    echo -e "  ${CYAN}sudo systemctl stop recoba-tunnel recoba-tunnel-*${NC}"
    echo -e "  ${CYAN}sudo systemctl start paqet paqet-*${NC}"
    echo -e "  (Old install is untouched at ${old_dir})"
    echo ""

    return 0
}

#===============================================================================
# Main Menu
#===============================================================================

main() {
    check_root
    
    # Auto-sync: if recoba-tunnel command exists but is outdated, update it silently
    if is_command_installed; then
        local installed_ver
        installed_ver=$(grep '^INSTALLER_VERSION=' "$INSTALLER_CMD" 2>/dev/null | cut -d'"' -f2)
        if [ -n "$installed_ver" ] && [ "$installed_ver" != "$INSTALLER_VERSION" ]; then
            local running_script="${BASH_SOURCE[0]}"
            if [ -f "$running_script" ]; then
                cp "$running_script" "$INSTALLER_CMD"
                chmod +x "$INSTALLER_CMD"
            fi
        fi
    fi
    
    while true; do
        print_banner
        
        # Show if command is installed
        if is_command_installed; then
            echo -e "${GREEN}[✓] recoba-tunnel command is installed. Run: ${CYAN}paqet-tunnel${NC}"
        else
            echo -e "${YELLOW}[i] Tip: Install as command with option 'i' to run: ${CYAN}paqet-tunnel${NC}"
        fi
        local core_ver
        local raw_ver
        raw_ver=$(get_installed_paqet_version_text)
        core_ver=$(extract_recoba_version_from_text "$raw_ver")
        local header_core_provider
        header_core_provider=$(get_current_core_provider)
        local header_profile_preset
        header_profile_preset=$(get_current_profile_preset)
        echo -e "${CYAN}[i] paqet core:${NC} ${core_ver}"
        echo -e "${CYAN}[i] core provider:${NC} $(get_core_provider_label "$header_core_provider") | ${CYAN}profile:${NC} ${header_profile_preset}"
        echo ""
        
        echo -e "${YELLOW}Select option:${NC}"
        echo ""
        echo -e "  ${GREEN}── Setup ──${NC}"
        echo -e "  ${CYAN}1)${NC} Setup Server B (Abroad - VPN server)"
        echo -e "  ${CYAN}2)${NC} Setup Server A (Iran - entry point)"
        echo ""
        echo -e "  ${GREEN}── Management ──${NC}"
        echo -e "  ${CYAN}3)${NC} Check Status"
        echo -e "  ${CYAN}4)${NC} View Configuration"
        echo -e "  ${CYAN}5)${NC} Edit Configuration"
        echo -e "  ${CYAN}6)${NC} Manage Tunnels (add/remove/restart)"
        echo -e "  ${CYAN}7)${NC} Test Connection"
        echo -e "  ${CYAN}h)${NC} Internal Health Check"
        echo ""
        echo -e "  ${GREEN}── Maintenance ──${NC}"
        echo -e "  ${CYAN}8)${NC} Updates / Core / Profiles"
        echo -e "  ${CYAN}a)${NC} Automatic Reset (scheduled restart)"
        echo -e "  ${CYAN}d)${NC} Connection Protection & MTU Tuning (fix fake RST/disconnects)"
        echo -e "  ${CYAN}f)${NC} IPTables Port Forwarding (relay/NAT)"
        echo -e "  ${CYAN}m)${NC} Migrate from old /opt/paqet (Paqet Manager → Recoba Tunnel)"
        echo -e "  ${CYAN}u)${NC} Uninstall"
        echo ""
        echo -e "  ${GREEN}── Script ──${NC}"
        if ! is_command_installed; then
            echo -e "  ${CYAN}i)${NC} Install as 'recoba-tunnel' command"
        fi
        echo -e "  ${CYAN}r)${NC} Remove recoba-tunnel command"
        echo -e "  ${CYAN}0)${NC} Exit"
        echo ""
        read -r -p "Choice: " choice < /dev/tty
        
        case $choice in
            1) install_dependencies; setup_server_b ;;
            2) run_iran_optimizations; install_dependencies; setup_server_a ;;
            3) check_status ;;
            4) view_config ;;
            5) edit_config ;;
            6) manage_tunnels_menu ;;
            7) test_connection ;;
            8) updates_menu ;;
            [Hh]) health_check_menu ;;
            [Bb]) update_paqet_core ;;
            [Aa]) auto_reset_menu ;;
            [Dd]) apply_connection_protection ;;
            [Ff]) iptables_port_forwarding_menu ;;
            [Uu]) uninstall ;;
            [Ii]) install_command ;;
            [Mm]) migrate_old_paqet_install ;;
            [Rr]) uninstall_command ;;
            0) exit 0 ;;
            *) print_error "Invalid choice" ;;
        esac
        
        echo ""
        echo -e "${YELLOW}Press Enter to continue...${NC}"
        read -r < /dev/tty
    done
}

if [[ "${PAQET_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
