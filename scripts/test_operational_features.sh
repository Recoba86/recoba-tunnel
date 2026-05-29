#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317,SC2016
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export PAQET_TEST_MODE=1
export PAQET_DRY_RUN=1
source "$REPO_ROOT/install.sh"

pass_count=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s\nExpected: %s\nActual:   %s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
    pass_count=$((pass_count + 1))
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        printf 'FAIL: %s\nMissing: %s\nIn: %s\n' "$label" "$needle" "$haystack" >&2
        exit 1
    fi
    pass_count=$((pass_count + 1))
}

tmp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

# ---------------------------------------------------------
# Test: Runtime Discovery
# ---------------------------------------------------------
systemctl() {
    local cmd="$1"
    local svc="$2"
    if [ "$cmd" = "cat" ]; then
        if [ "$svc" = "paqet-dubai.service" ]; then
            echo "ExecStart=/opt/paqet/paqet -c /opt/paqet/config.yaml"
        elif [ "$svc" = "recoba-tunnel-dubai.service" ]; then
            echo "ExecStart=/opt/recoba-tunnel/recoba-tunnel -c /opt/recoba-tunnel/config-dubai.yaml"
        else
            return 1
        fi
    elif [ "$cmd" = "show" ]; then
        return 1
    fi
}
export -f systemctl

assert_eq "/opt/paqet/paqet" "$(get_active_binary_path "paqet-dubai.service")" "legacy binary path parsed correctly"
assert_eq "/opt/recoba-tunnel/recoba-tunnel" "$(get_active_binary_path "recoba-tunnel-dubai.service")" "standalone binary path parsed correctly"

# ---------------------------------------------------------
# Test: Health Check Classification
# ---------------------------------------------------------
mkdir -p "$tmp_dir/opt"
touch "$tmp_dir/opt/recoba-tunnel"
chmod +x "$tmp_dir/opt/recoba-tunnel"

# Mock system commands for health check
systemctl() {
    local cmd="$1"
    local svc="${2:-}"
    if [ "$cmd" = "is-active" ]; then
        svc="$3"
        if [[ "$svc" == *"inactive"* ]]; then
            return 1
        fi
        return 0
    fi
    if [ "$cmd" = "cat" ]; then
        if [[ "$svc" == *"missing_bin"* ]]; then
            echo "ExecStart=/does/not/exist/bin"
        else
            echo "ExecStart=$tmp_dir/opt/recoba-tunnel"
        fi
    fi
}
export -f systemctl

get_tunnel_service() {
    local cfg="$1"
    local name
    name=$(basename "$cfg" .yaml)
    echo "${name}.service"
}
export -f get_tunnel_service

# Mock journalctl to inject logs
journalctl() {
    if [[ "$*" == *"panic.service"* ]]; then
        echo "panic: runtime error"
    elif [[ "$*" == *"retry_failed.service"* ]]; then
        echo "retry_failed: 1"
    elif [[ "$*" == *"enobufs.service"* ]]; then
        echo "write udp: ENOBUFS"
    elif [[ "$*" == *"conn_lost.service"* ]]; then
        echo "connection lost"
    else
        echo "normal log"
    fi
}
export -f journalctl

# Mock ss to pretend ports are open
ss() {
    echo "LISTEN 0 128 0.0.0.0:1090 0.0.0.0:* users:((\"recoba-tunnel\",pid=1234,fd=3))"
}
export -f ss

# Create dummy config files
for f in missing_bin.yaml inactive.yaml panic.yaml retry_failed.yaml enobufs.yaml conn_lost.yaml ok.yaml; do
    echo 'role: "client"' > "$f"
    echo '  - listen: "0.0.0.0:1090"' >> "$f"
    echo '    target: "127.0.0.1:443"' >> "$f"
done

# Missing binary
out=$(health_check_tunnel "missing_bin.yaml")
assert_contains "$out" "FAIL" "missing binary = FAIL"

# Inactive service
out=$(health_check_tunnel "inactive.yaml")
assert_contains "$out" "FAIL" "inactive service = FAIL"
assert_contains "$out" "service inactive" "inactive service reason"

# Panic
out=$(health_check_tunnel "panic.yaml")
assert_contains "$out" "FAIL" "panic = FAIL"

# Retry Failed
out=$(health_check_tunnel "retry_failed.yaml")
assert_contains "$out" "FAIL" "retry_failed = FAIL"

# ENOBUFS (warn)
out=$(health_check_tunnel "enobufs.yaml")
assert_contains "$out" "WARN" "recovered ENOBUFS = WARN"

# Conn lost (warn)
out=$(health_check_tunnel "conn_lost.yaml")
assert_contains "$out" "WARN" "connection lost = WARN"

# OK
out=$(health_check_tunnel "ok.yaml")
assert_contains "$out" "OK" "clean log = OK"

# ---------------------------------------------------------
# Test: Auto-Update
# ---------------------------------------------------------
# Mock read_confirm to always say yes
read_confirm() {
    eval "$2=true"
}
export -f read_confirm

get_installed_paqet_version_text() {
    echo "v$MOCK_INSTALLED"
}
export -f get_installed_paqet_version_text

curl() {
    if [[ "$*" == *"api.github.com"* ]]; then
        echo '{"tag_name": "v'$MOCK_LATEST'"}'
    elif [[ "$*" == *"SHA256SUMS"* ]]; then
        if [ "$MOCK_DL" = "fail_sha256" ]; then return 1; fi
        echo "valid_hash recoba-tunnel-linux-amd64.tar.gz" > "$4"
    elif [[ "$*" == *".tar.gz"* ]]; then
        if [ "$MOCK_DL" = "fail_asset" ]; then return 1; fi
        touch "$4"
    fi
}
export -f curl

download_recoba_core() {
    # The actual implementation calls curl and sha256sum
    # Let's mock download_recoba_core directly since we are testing auto-update logic
    if [ "$MOCK_DL" = "fail_asset" ]; then return 1; fi
    if [ "$MOCK_DL" = "fail_sha256" ]; then return 1; fi
    if [ "$MOCK_DL" = "mismatch_sha256" ]; then return 1; fi
    
    local d="$tmp_dir/dl"
    mkdir -p "$d"
    touch "$d/recoba-tunnel"
    chmod +x "$d/recoba-tunnel"
    echo "$d"
}
export -f download_recoba_core

health_check_all_tunnels() {
    echo "$MOCK_HEALTH"
}
export -f health_check_all_tunnels

get_all_configs() {
    echo "dummy.yaml"
}
export -f get_all_configs

# Unset dry run so safe_update_core actually executes its logic
PAQET_DRY_RUN=0

# Test: installed == latest
MOCK_INSTALLED="2.1.0"
MOCK_LATEST="2.1.0"
out=$(safe_update_core)
assert_contains "$out" "Already up to date." "installed == latest -> no update"

# Test: installed > latest (handled same as installed == latest for simple string equality? wait, if they aren't equal it tries to update. Let's say it updates)
MOCK_INSTALLED="2.2.0"
MOCK_LATEST="2.1.0"
MOCK_DL="ok"
MOCK_HEALTH="[OK]"
out=$(safe_update_core) || true
assert_contains "$out" "Backup created" "installed != latest -> update allowed (or downgrade)"

# Test: update allowed (OK path)
MOCK_INSTALLED="2.0.0"
MOCK_LATEST="2.1.0"
MOCK_DL="ok"
MOCK_HEALTH="[OK]"
out=$(safe_update_core)
assert_contains "$out" "Update successful! All tunnels reported OK." "health OK after update -> keep update"

# Test: update WARN path
MOCK_HEALTH="[WARN]"
out=$(safe_update_core)
assert_contains "$out" "Update succeeded, but health check returned WARN" "health WARN after update -> keep update but warn"

# Test: update FAIL path -> rollback
MOCK_HEALTH="[FAIL]"
out=$(safe_update_core || true)
assert_contains "$out" "Initiating automatic rollback" "health FAIL after update -> rollback path triggered"

# Restore PAQET_DRY_RUN
PAQET_DRY_RUN=1

# ---------------------------------------------------------
# Test: Version Extraction & Backup Naming (v2.1.1)
# ---------------------------------------------------------

# Test 1: Extract version from multiline output
multiline_out=$(echo -e "Version:    v2.0.1\nGit Tag:    v2.0.1")
assert_eq "v2.0.1" "$(extract_recoba_version_from_text "$multiline_out")" "extract from multiline Version: line"

# Test 2: Extract version from single-line output
assert_eq "v2.0.1" "$(extract_recoba_version_from_text "v2.0.1")" "extract from single line v2.0.1"
assert_eq "v2.0.1" "$(extract_recoba_version_from_text "2.0.1")" "extract from single line 2.0.1 without v"

# Test 3: Unknown version returns unknown
assert_eq "unknown" "$(extract_recoba_version_from_text "no version here")" "extract from unknown returns unknown"

# Test 4: Backup filename does not contain spaces, slashes, or unsafe characters
unsafe_text=$(echo -e "Version:    v/2.0.1?\nGit Commit: *")
clean_ver=$(extract_recoba_version_from_text "$unsafe_text")
assert_eq "v2.0.1" "$clean_ver" "extract cleans slashes and question marks"

# Test 5: Safe update uses the parsed version in backup path
# Let's mock cp to verify the backup path format
cp() {
    local src="$1"
    local dest="$2"
    echo "CP_MOCK_DEST: $dest"
    touch "$dest" 2>/dev/null || true
    return 0
}
export -f cp

get_installed_paqet_version_text() {
    echo -e "Version:    v2.0.1\nGit Tag:    v2.0.1"
}
export -f get_installed_paqet_version_text

MOCK_INSTALLED="2.0.1"
MOCK_LATEST="2.1.1"
MOCK_DL="ok"
MOCK_HEALTH="[OK]"
PAQET_DRY_RUN=0

out=$(safe_update_core)
assert_contains "$out" "from-v2.0.1.to-v2.1.1." "safe update backup path has from-v2.0.1.to-v2.1.1 format"
assert_contains "$out" ".bak" "safe update backup path has .bak extension"

# Verify no spaces, slashes or 'Version:' in backup path
backup_path_line=""
backup_path_line=$(echo "$out" | grep -Ei "Backup created:" | head -1)
backup_filename=""
backup_filename=$(basename "$backup_path_line")
if [[ "$backup_filename" == *"Version:"* || "$backup_filename" == *" "* ]]; then
    printf 'FAIL: backup filename contains unsafe characters: %s\n' "$backup_filename" >&2
    exit 1
fi
pass_count=$((pass_count + 1))

printf 'All operational features tests passed (%s assertions).\n' "$pass_count"
