#!/bin/bash

################################################################################
# Node Auto-Update Script (Sui, Walrus, and more)
# Description: Automatically checks for and installs new node releases
# Usage: node-update.sh [OPTIONS]
################################################################################

set -euo pipefail

# ========== Configuration ==========
# Node type: sui, walrus, etc.
NODE_TYPE="${NODE_TYPE:-sui}"

# Network type: testnet, mainnet, or devnet (will be set from config if not provided)
NETWORK="${NETWORK:-}"

# Number of old version directories to keep
KEEP_OLD_VERSIONS="${KEEP_OLD_VERSIONS:-3}"

# Dry run mode - test without making changes
DRY_RUN="${DRY_RUN:-false}"

# Telegram notifications (optional)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Architecture and OS (auto-detect or use override)
# Store user-provided ARCH before detection
USER_ARCH="${ARCH:-}"

# Always auto-detect architecture for validation
DETECTED_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
DETECTED_ARCH=$(uname -m)

# Map common OS names
case "$DETECTED_OS" in
    linux) OS_NAME="ubuntu" ;;  # Most releases use 'ubuntu' for Linux
    darwin) OS_NAME="macos" ;;
    *) OS_NAME="$DETECTED_OS" ;;
esac

# Map architecture names to release naming conventions
case "$DETECTED_ARCH" in
    x86_64|amd64) ARCH_NAME="x86_64" ;;
    aarch64|arm64) ARCH_NAME="aarch64" ;;
    *) ARCH_NAME="$DETECTED_ARCH" ;;
esac

AUTO_DETECTED_ARCH="${OS_NAME}-${ARCH_NAME}"

# Use user-provided or auto-detected
if [[ -z "${USER_ARCH}" ]]; then
    ARCH="${AUTO_DETECTED_ARCH}"
else
    ARCH="${USER_ARCH}"
fi

# Valid networks
VALID_NETWORKS="testnet mainnet devnet"

# Lock file location
LOCK_FILE="/var/lock/node-updater-${NODE_TYPE}.lock"

# Paths (will be overridden by config files if specified)
DEFAULT_INSTALL_DIR="/usr/local/bin"
DEFAULT_DOWNLOAD_DIR="/mnt/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/configs"

# Load node-specific configuration
CONFIG_FILE="${CONFIG_DIR}/${NODE_TYPE}.conf"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}" >&2
    echo "Supported node types: $(ls -1 "${CONFIG_DIR}" 2>/dev/null | sed 's/\.conf$//' | tr '\n' ', ' | sed 's/, $//' || echo 'none')" >&2
    exit 1
fi

# Source the configuration
source "${CONFIG_FILE}"

# Validate required configuration variables
required_vars="REPO PRIMARY_BIN SECONDARY_BIN SERVICE_NAME VERSION_REGEX DEFAULT_NETWORK"
for var in $required_vars; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Missing required variable in config file: $var" >&2
        echo "Config file: ${CONFIG_FILE}" >&2
        exit 1
    fi
done

# Use config-specified paths or defaults
INSTALL_DIR="${INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${DEFAULT_DOWNLOAD_DIR}}"

# Network will be determined later (auto-detect or default)
# Keep NETWORK as-is if user specified it
NETWORK="${NETWORK:-}"

# Set binary paths
PRIMARY_BIN_PATH="${INSTALL_DIR}/${PRIMARY_BIN}"
SECONDARY_BIN_PATH="${INSTALL_DIR}/${SECONDARY_BIN}"

# GitHub API
GITHUB_API_BASE="https://api.github.com/repos/${REPO}"
GITHUB_API="${GITHUB_API_BASE}/releases"

# Optional: regex (grep -oP) extracting the build commit from "<bin> --version".
# Empty disables commit/digest verification (version-only comparison).
COMMIT_REGEX="${COMMIT_REGEX:-}"

# Logging
LOG_TAG="${NODE_TYPE}-updater"

# ========== Functions ==========

log() {
    local level="$1"
    shift
    local message="$*"
    echo "[${level}] ${message}" >&2
    logger -t "${LOG_TAG}" -p "user.${level}" "${message}" 2>/dev/null || true
}

# Send error to Telegram and exit
# Usage: error_exit "Error message" [exit_code]
error_exit() {
    local message="$1"
    local exit_code="${2:-1}"
    
    log "error" "${message}"
    
    # Try to get network emoji, fallback to generic
    local net_emoji="🌐"
    if [[ -n "${NETWORK:-}" ]]; then
        case "${NETWORK}" in
            mainnet) net_emoji="🚀" ;;
            testnet) net_emoji="🧪" ;;
            devnet)  net_emoji="🔧" ;;
        esac
    fi
    
    send_telegram "❌ <b>${NODE_TYPE^} Update Error</b>

Network: ${net_emoji} <b>${NETWORK:-unknown}</b>
Host: $(hostname)
Error: ${message}"
    
    exit "${exit_code}"
}

# Send GraphQL error notification (without exiting)
send_graphql_error() {
    local version="$1"
    local net_emoji=$(get_network_emoji "${NETWORK}")
    
    log "error" "GraphQL stack failed to update to version ${version}"
    
    send_telegram "❌ <b>${NODE_TYPE^} GraphQL Update Failed</b>

Network: ${net_emoji} <b>${NETWORK^^}</b>
Version: ${version}
Host: $(hostname)
Status: GraphQL stack failed to update
Action: Check docker compose logs"
}

send_telegram() {
    local message="$1"
    
    # Skip if Telegram is not configured
    if [[ -z "${TELEGRAM_BOT_TOKEN}" ]] || [[ -z "${TELEGRAM_CHAT_ID}" ]]; then
        return 0
    fi
    
    # Escape special characters for JSON
    # Replace backslash, quotes, and control characters
    message=$(echo -n "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g')
    
    # Send notification to multiple chat IDs (comma-separated)
    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    local IFS=','
    local chat_ids=(${TELEGRAM_CHAT_ID})
    local success_count=0
    local fail_count=0
    
    for chat_id in "${chat_ids[@]}"; do
        # Trim whitespace
        chat_id=$(echo "${chat_id}" | xargs)
        
        local payload=$(cat <<EOF
{
  "chat_id": "${chat_id}",
  "text": "${message}",
  "parse_mode": "HTML"
}
EOF
)
        
        if curl -s --max-time 10 -X POST "${url}" \
            -H "Content-Type: application/json" \
            -d "${payload}" > /dev/null 2>&1; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
            log "warning" "Failed to send Telegram notification to chat ID: ${chat_id}"
        fi
    done
    
    if [[ ${success_count} -gt 0 ]]; then
        log "info" "Telegram notification sent to ${success_count} chat(s)"
    fi
    
    if [[ ${fail_count} -gt 0 ]]; then
        log "warning" "Failed to send to ${fail_count} chat(s)"
    fi
}

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Universal node auto-update script for Sui, Walrus, and more.

Environment Variables:
  NODE_TYPE            Node type to update (default: sui)
                       Available: $(ls -1 "${CONFIG_DIR}" 2>/dev/null | sed 's/\.conf$//' | tr '\n' ',' | sed 's/,$//' || echo "sui, walrus")
  NETWORK              Network type: testnet, mainnet, devnet (default: from config)
  KEEP_OLD_VERSIONS    Number of old versions to keep (default: 3)
  INSTALL_DIR          Installation directory override
  DOWNLOAD_DIR         Download directory override
  DRY_RUN              Dry run mode: true/false (default: false)
  TELEGRAM_BOT_TOKEN   Telegram bot token for notifications (optional)
  TELEGRAM_CHAT_ID     Telegram chat ID for notifications (optional)

Examples:
  # Update Sui testnet node
  NODE_TYPE=sui $0
  
  # Update Walrus mainnet node
  NODE_TYPE=walrus NETWORK=mainnet $0
  
  # Dry run to see what would happen
  NODE_TYPE=sui DRY_RUN=true $0
  
  # Custom installation path
  NODE_TYPE=walrus INSTALL_DIR=/custom/path $0

Logs: journalctl -t <node-type>-updater -f

EOF
    exit 0
}

check_dependencies() {
    local missing_deps=()
    local install_cmd=""
    
    # Check for required commands
    for cmd in curl wget jq tar systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "warning" "Missing required dependencies: ${missing_deps[*]}"
        
        # Try to install missing dependencies
        if command -v apt-get &>/dev/null; then
            install_cmd="apt-get install -y ${missing_deps[*]}"
        elif command -v yum &>/dev/null; then
            install_cmd="yum install -y ${missing_deps[*]}"
        elif command -v dnf &>/dev/null; then
            install_cmd="dnf install -y ${missing_deps[*]}"
        else
            log "error" "Cannot auto-install dependencies. Please install manually: ${missing_deps[*]}"
            exit 1
        fi
        
        log "info" "Attempting to install dependencies: ${install_cmd}"
        log "info" "Note: Dependencies are required even for dry-run mode, installing..."
        
        if eval "${install_cmd}"; then
            log "info" "Successfully installed dependencies"
        else
            log "error" "Failed to install dependencies. Please install manually: ${missing_deps[*]}"
            exit 1
        fi
    else
        log "info" "All required dependencies are installed"
    fi
}

acquire_lock() {
    local lock_dir=$(dirname "${LOCK_FILE}")
    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p "$lock_dir" 2>/dev/null || LOCK_FILE="/tmp/node-updater-${NODE_TYPE}.lock"
    fi
    
    # Use flock for exclusive locking
    exec 200>"${LOCK_FILE}"
    if ! flock -n 200; then
        log "error" "Another instance is already running (lock file: ${LOCK_FILE})"
        exit 1
    fi
    log "info" "Acquired lock: ${LOCK_FILE}"
}

release_lock() {
    # Lock is automatically released when the script exits
    # flock releases the lock when file descriptor 200 is closed
    if [[ -f "${LOCK_FILE}" ]]; then
        rm -f "${LOCK_FILE}" 2>/dev/null || true
    fi
}

validate_network() {
    local net="$1"
    local valid_networks="testnet mainnet devnet"
    
    for valid in $valid_networks; do
        if [[ "$net" == "$valid" ]]; then
            return 0
        fi
    done
    
    log "error" "Invalid network: ${net}. Valid options: ${valid_networks}"
    exit 1
}

get_network_emoji() {
    local network="$1"
    case "${network}" in
        mainnet) echo "🚀" ;;
        testnet) echo "🧪" ;;
        devnet)  echo "🔧" ;;
        *)       echo "🌐" ;;
    esac
}

detect_network() {
    # Try to auto-detect network from systemd service or config files
    log "info" "Attempting to auto-detect network from ${SERVICE_NAME} service..."
    
    # Method 1: Extract config path from systemd service and parse it
    local service_config
    service_config=$(systemctl cat "${SERVICE_NAME}" 2>/dev/null || echo "")
    
    if [[ -n "$service_config" ]]; then
        # Extract config file path from ExecStart (handles --config-path, --config, -c)
        local config_path
        config_path=$(echo "$service_config" | grep -oP '(?:--config-path|--config|-c)[=\s]+\K[^\s]+' | head -1)
        
        # If not found, try to find any yaml/toml/json file mentioned
        if [[ -z "$config_path" ]]; then
            config_path=$(echo "$service_config" | grep -oP '[^\s]+\.(yaml|yml|toml|json)' | head -1)
        fi
        
        if [[ -n "$config_path" ]] && [[ -f "$config_path" ]]; then
            log "info" "Found config file: ${config_path}"
            
            # Parse config file for network indicators
            local config_content
            config_content=$(cat "$config_path" 2>/dev/null || echo "")
            
            if [[ -n "$config_content" ]]; then
                # Look for network in various formats:
                # - db-path: /opt/sui/db/testnet
                # - genesis: testnet-genesis.blob
                # - network: testnet
                # - testnet in URLs/paths
                if echo "$config_content" | grep -iqE "(testnet|/testnet/|testnet-genesis|testnet\.blob)"; then
                    log "info" "Detected network: testnet (from config file: ${config_path})"
                    echo "testnet"
                    return 0
                elif echo "$config_content" | grep -iqE "(mainnet|/mainnet/|mainnet-genesis|mainnet\.blob)"; then
                    log "info" "Detected network: mainnet (from config file: ${config_path})"
                    echo "mainnet"
                    return 0
                elif echo "$config_content" | grep -iqE "(devnet|/devnet/|devnet-genesis|devnet\.blob)"; then
                    log "info" "Detected network: devnet (from config file: ${config_path})"
                    echo "devnet"
                    return 0
                fi
            fi
        fi
        
        # Fallback: Check service file itself for network keywords
        if echo "$service_config" | grep -iqE "testnet"; then
            log "info" "Detected network: testnet (from service file)"
            echo "testnet"
            return 0
        elif echo "$service_config" | grep -iqE "mainnet"; then
            log "info" "Detected network: mainnet (from service file)"
            echo "mainnet"
            return 0
        elif echo "$service_config" | grep -iqE "devnet"; then
            log "info" "Detected network: devnet (from service file)"
            echo "devnet"
            return 0
        fi
    fi
    
    # Method 2: Check common config directories for network-specific files
    local config_dirs="/opt/${NODE_TYPE}/config /opt/${NODE_TYPE}-node/config /etc/${NODE_TYPE} ${INSTALL_DIR}/../config"
    for dir in $config_dirs; do
        if [[ -d "$dir" ]]; then
            # Check for network-specific files or directories
            if ls "$dir"/*testnet* 2>/dev/null | grep -q . || ls "$dir"/testnet* 2>/dev/null | grep -q .; then
                log "info" "Detected network: testnet (from config directory: ${dir})"
                echo "testnet"
                return 0
            elif ls "$dir"/*mainnet* 2>/dev/null | grep -q . || ls "$dir"/mainnet* 2>/dev/null | grep -q .; then
                log "info" "Detected network: mainnet (from config directory: ${dir})"
                echo "mainnet"
                return 0
            elif ls "$dir"/*devnet* 2>/dev/null | grep -q . || ls "$dir"/devnet* 2>/dev/null | grep -q .; then
                log "info" "Detected network: devnet (from config directory: ${dir})"
                echo "devnet"
                return 0
            fi
        fi
    done
    
    log "warning" "Could not auto-detect network"
    echo ""
    return 1
}

ensure_install_directory() {
    local install_dir=$(dirname "${PRIMARY_BIN_PATH}")
    
    if [[ ! -d "$install_dir" ]]; then
        log "info" "Installation directory does not exist: ${install_dir}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "info" "[DRY-RUN] Would create directory: ${install_dir}"
        else
            log "info" "Creating installation directory: ${install_dir}"
            if mkdir -p "$install_dir" 2>/dev/null; then
                log "info" "Successfully created directory: ${install_dir}"
            else
                error_exit "Failed to create directory: ${install_dir}"
            fi
        fi
    else
        log "info" "Installation directory exists: ${install_dir}"
    fi
}

get_installed_version() {
    # Binary existence already checked in main(), so just get version
    local version_output
    version_output=$("${PRIMARY_BIN_PATH}" --version 2>&1 || echo "")
    
    if [[ -z "${version_output}" ]]; then
        log "error" "Failed to get ${PRIMARY_BIN} version"
        echo ""
        return 1
    fi
    
    # Extract version number using config regex
    local version
    version=$(echo "${version_output}" | grep -oP "${VERSION_REGEX}" || echo "")
    
    if [[ -z "${version}" ]]; then
        log "error" "Failed to parse version from: ${version_output}"
        echo ""
        return 1
    fi
    
    echo "${version}"
}

expand_binary_name() {
    local network="$1"
    local version="$2"
    local arch="$3"

    local VERSION="${version}"
    local NETWORK="${network}"
    local ARCH="${arch}"
    eval "echo \"${BINARY_NAME_PATTERN}\""
}

# Extract the build commit from "<bin> --version" output using COMMIT_REGEX.
# Prints nothing when COMMIT_REGEX is empty or does not match.
parse_commit_from_version_output() {
    local version_output="$1"

    if [[ -z "${COMMIT_REGEX}" ]]; then
        return 0
    fi

    local commit
    commit=$(echo "${version_output}" | grep -oP "${COMMIT_REGEX}" | head -1 | tr 'A-F' 'a-f' || true)

    # Too short or non-hex values are treated as unknown
    if [[ "${commit}" =~ ^[0-9a-f]{7,40}$ ]]; then
        echo "${commit}"
    fi
}

# True if the (already validated) build commit is a prefix of the full tag commit.
commit_matches() {
    local tag_commit="$1"
    local build_commit="$2"

    [[ "${build_commit}" =~ ^[0-9a-f]{7,40}$ ]] && [[ "${tag_commit}" == "${build_commit}"* ]]
}

get_binary_commit() {
    local bin_path="$1"
    local version_output
    version_output=$("${bin_path}" --version 2>&1 || echo "")
    parse_commit_from_version_output "${version_output}"
}

# GET a GitHub API path under the repository. Prints the body; fails on any non-200 status.
github_api_get() {
    local path="$1"
    local response http_code body

    response=$(curl -s --max-time 30 -w $'\n%{http_code}' "${GITHUB_API_BASE}/${path}") || {
        log "error" "GitHub API request failed: ${path}"
        return 1
    }
    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "${http_code}" != "200" ]]; then
        log "error" "GitHub API ${path} returned HTTP ${http_code}"
        return 1
    fi

    printf '%s' "${body}"
}

# Resolve a tag to the commit sha it points at (dereferences annotated tags).
resolve_tag_commit() {
    local tag="$1"
    local ref obj_type obj_sha

    ref=$(github_api_get "git/ref/tags/${tag}") || return 1
    obj_type=$(echo "${ref}" | jq -r '.object.type // empty') || return 1
    obj_sha=$(echo "${ref}" | jq -r '.object.sha // empty') || return 1

    if [[ "${obj_type}" == "tag" ]]; then
        if [[ ! "${obj_sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
            log "error" "Tag ${tag} returned an invalid tag object sha"
            return 1
        fi
        local tag_obj
        tag_obj=$(github_api_get "git/tags/${obj_sha}") || return 1
        obj_type=$(echo "${tag_obj}" | jq -r '.object.type // empty') || return 1
        obj_sha=$(echo "${tag_obj}" | jq -r '.object.sha // empty') || return 1
    fi

    if [[ "${obj_type}" != "commit" ]] || [[ ! "${obj_sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
        log "error" "Tag ${tag} does not resolve to a commit (type: ${obj_type:-unknown})"
        return 1
    fi

    echo "${obj_sha}" | tr 'A-F' 'a-f'
}

# Print the sha256 hex digest of a release asset; empty if the release has no digest for it.
get_release_asset_digest() {
    local tag="$1"
    local asset_name="$2"
    local release digest

    release=$(github_api_get "releases/tags/${tag}") || return 1
    digest=$(echo "${release}" | jq -r --arg n "${asset_name}" \
        '[.assets[]? | select(.name == $n) | .digest // empty] | first // empty') || return 1

    if [[ -z "${digest}" ]]; then
        echo ""
        return 0
    fi

    if [[ ! "${digest}" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
        log "error" "Unexpected digest format for ${asset_name}"
        return 1
    fi

    echo "${digest#sha256:}" | tr 'A-F' 'a-f'
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual

    actual=$(sha256sum "${file}" | awk '{print $1}')
    [[ -n "${actual}" ]] && [[ "${actual}" == "${expected}" ]]
}

# Decide what to do given installed/latest versions and (optionally) commits.
# Prints one of: install-newer | install-rebuild | skip-current | skip-installed-newer | skip-unknown-commit
decide_update() {
    local installed_version="$1"
    local latest_version="$2"
    local installed_commit="$3"
    local tag_commit="$4"
    local cmp_result

    set +e
    version_compare "${installed_version}" "${latest_version}"
    cmp_result=$?
    set -e

    if [[ ${cmp_result} -eq 2 ]]; then
        echo "install-newer"
    elif [[ ${cmp_result} -eq 1 ]]; then
        echo "skip-installed-newer"
    elif [[ -z "${COMMIT_REGEX}" ]] || [[ -z "${installed_commit}" ]] || [[ -z "${tag_commit}" ]]; then
        echo "skip-unknown-commit"
    elif commit_matches "${tag_commit}" "${installed_commit}"; then
        echo "skip-current"
    else
        echo "install-rebuild"
    fi
}

get_latest_release() {
    local network="$1"
    
    log "info" "Querying GitHub API for latest ${network} release..."
    
    # Check GitHub API rate limit
    local rate_limit_info
    rate_limit_info=$(curl -s --max-time 10 https://api.github.com/rate_limit)
    if [[ -n "$rate_limit_info" ]]; then
        local remaining=$(echo "$rate_limit_info" | jq -r '.rate.remaining // "unknown"')
        local limit=$(echo "$rate_limit_info" | jq -r '.rate.limit // "unknown"')
        log "info" "GitHub API rate limit: ${remaining}/${limit} requests remaining"
        
        if [[ "$remaining" != "unknown" ]] && [[ "$remaining" -lt 5 ]]; then
            log "warning" "GitHub API rate limit is low (${remaining} remaining)"
            local reset_time=$(echo "$rate_limit_info" | jq -r '.rate.reset')
            if [[ -n "$reset_time" ]]; then
                log "warning" "Rate limit resets at: $(date -d @${reset_time} 2>/dev/null || date -r ${reset_time} 2>/dev/null || echo 'unknown')"
            fi
        fi
    fi
    
    # Fetch releases and filter by network prefix
    local releases
    releases=$(curl -s --max-time 30 "${GITHUB_API}?per_page=50" || echo "")
    
    if [[ -z "${releases}" ]]; then
        log "error" "Failed to fetch releases from GitHub API"
        echo ""
        return 1
    fi
    
    # Find all releases matching the network and sort by semver to get highest version
    # This prevents downgrade if a backport release (older version) is published after a newer one
    local all_versions
    all_versions=$(echo "${releases}" | jq -r ".[] | select(.tag_name | startswith(\"${network}-v\")) | .tag_name" | \
        grep -oP "${network}-v\K[0-9]+\.[0-9]+\.[0-9]+" | \
        sort -t. -k1,1n -k2,2n -k3,3n | \
        tail -1)
    
    if [[ -z "${all_versions}" ]]; then
        log "error" "No ${network} releases found"
        echo ""
        return 1
    fi
    
    local version="${all_versions}"
    log "info" "Highest ${network} version found: ${version}"
    
    echo "${version}"
}

check_binary_available() {
    local network="$1"
    local version="$2"
    local arch="$3"
    
    local tag="${network}-v${version}"
    
    local binary_name
    binary_name=$(expand_binary_name "${network}" "${version}" "${arch}")
    
    local download_url="https://github.com/${REPO}/releases/download/${tag}/${binary_name}"
    
    log "info" "Checking if binary is available: ${download_url}"
    
    # Check if URL returns 200
    local http_code
    http_code=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -L "${download_url}")
    
    if [[ "${http_code}" == "200" ]]; then
        log "info" "Binary is available (HTTP ${http_code})"
        echo "${download_url}"
        return 0
    else
        log "warning" "Binary not available (HTTP ${http_code})"
        echo ""
        return 1
    fi
}

version_compare() {
    # Compare two version strings
    # Returns: 0 if equal, 1 if v1 > v2, 2 if v1 < v2
    local v1="$1"
    local v2="$2"
    
    if [[ "${v1}" == "${v2}" ]]; then
        return 0
    fi
    
    local IFS=.
    local i ver1=($v1) ver2=($v2)
    
    # Fill empty positions with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]:-} ]]; then
            ver2[i]=0
        fi
        
        local num1=${ver1[i]}
        local num2=${ver2[i]}
        
        if ((num1 > num2)); then
            return 1
        fi
        if ((num1 < num2)); then
            return 2
        fi
    done
    
    return 0
}

# Put the backed-up binaries back and start the service; always exits via error_exit.
rollback_install() {
    local backup_dir="$1"
    local reason="$2"
    local restore_ok=true

    log "error" "${reason}; restoring previous binaries"
    systemctl stop "${SERVICE_NAME}" || true

    cp -p "${backup_dir}/${PRIMARY_BIN}" "${PRIMARY_BIN_PATH}" || restore_ok=false
    if [[ -f "${backup_dir}/${SECONDARY_BIN}" ]]; then
        cp -p "${backup_dir}/${SECONDARY_BIN}" "${SECONDARY_BIN_PATH}" || restore_ok=false
    fi

    if [[ "${restore_ok}" != "true" ]]; then
        error_exit "${reason}. Restoring the previous binaries FAILED: the node has no verified binary and ${SERVICE_NAME} was not started. Manual intervention required (backup: ${backup_dir})"
    fi

    if ! systemctl start "${SERVICE_NAME}"; then
        error_exit "${reason}. Previous binaries restored, but ${SERVICE_NAME} failed to start. Manual intervention required"
    fi

    error_exit "${reason}. Previous binaries restored and ${SERVICE_NAME} started"
}

download_and_install() {
    local network="$1"
    local version="$2"
    local arch="$3"
    local download_url="$4"
    local tag_commit="${5:-}"
    local expected_digest="${6:-}"

    local tag="${network}-v${version}"
    # The commit is part of the name so a rebuild of the same version never reuses stale files
    local dir_suffix=""
    if [[ -n "${tag_commit}" ]]; then
        dir_suffix="-${tag_commit:0:12}"
    fi
    local extract_dir="${DOWNLOAD_DIR}/${NODE_TYPE}-${tag}${dir_suffix}-${arch}"
    local archive_file="${extract_dir}.download.tgz"
    local backup_dir="${extract_dir}.previous"

    log "info" "Starting download and installation of ${NODE_TYPE} ${tag}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "info" "[DRY RUN] Would create download directory: ${DOWNLOAD_DIR}"
        log "info" "[DRY RUN] Would create fresh extraction directory: ${extract_dir}"
        log "info" "[DRY RUN] Would download from: ${download_url}"
        if [[ -n "${expected_digest}" ]]; then
            log "info" "[DRY RUN] Would verify archive sha256 ${expected_digest}"
        fi
        log "info" "[DRY RUN] Would stop ${SERVICE_NAME} service"
        log "info" "[DRY RUN] Would install binaries to ${INSTALL_DIR}"
        if [[ -n "${tag_commit}" ]]; then
            log "info" "[DRY RUN] Would verify installed ${PRIMARY_BIN} build commit matches ${tag_commit:0:12}"
        fi
        log "info" "[DRY RUN] Would start ${SERVICE_NAME} service"
        log "info" "[DRY RUN] Would verify service is running"
        return 0
    fi

    mkdir -p "${DOWNLOAD_DIR}"

    # Always start from an empty location
    rm -rf "${extract_dir}" "${archive_file}" "${backup_dir}"
    mkdir -p "${extract_dir}"

    log "info" "Downloading from: ${download_url}"
    if ! wget --timeout=300 -qO "${archive_file}" "${download_url}"; then
        log "error" "Failed to download binary"
        rm -rf "${extract_dir}" "${archive_file}"
        return 1
    fi

    if [[ -n "${expected_digest}" ]]; then
        if ! verify_sha256 "${archive_file}" "${expected_digest}"; then
            rm -rf "${extract_dir}" "${archive_file}"
            error_exit "Downloaded archive sha256 does not match the release digest (expected ${expected_digest}); nothing was installed"
        fi
        log "info" "Archive sha256 matches the release digest"
    elif [[ -n "${COMMIT_REGEX}" ]]; then
        log "warning" "Release has no digest for this asset; archive integrity not verified"
    fi

    if ! tar xzf "${archive_file}" -C "${extract_dir}"; then
        log "error" "Failed to extract binary"
        rm -rf "${extract_dir}" "${archive_file}"
        return 1
    fi
    rm -f "${archive_file}"

    if [[ ! -f "${extract_dir}/${PRIMARY_BIN}" ]] || [[ ! -f "${extract_dir}/${SECONDARY_BIN}" ]]; then
        log "error" "Expected binaries (${PRIMARY_BIN}, ${SECONDARY_BIN}) not found in extracted archive"
        log "info" "Contents of extracted directory:"
        ls -la "${extract_dir}" >&2
        rm -rf "${extract_dir}"
        return 1
    fi

    log "info" "Successfully downloaded and extracted to ${extract_dir}"

    # Check the build before touching the running service
    if [[ -n "${tag_commit}" ]]; then
        chmod +x "${extract_dir}/${PRIMARY_BIN}"
        local extracted_commit
        extracted_commit=$(get_binary_commit "${extract_dir}/${PRIMARY_BIN}")
        if ! commit_matches "${tag_commit}" "${extracted_commit}"; then
            rm -rf "${extract_dir}"
            error_exit "Downloaded ${PRIMARY_BIN} build commit '${extracted_commit:-unknown}' does not match tag commit ${tag_commit:0:12}; nothing was installed"
        fi
    fi

    # Keep the current binaries so a bad install can be undone; abort before touching the service
    if ! mkdir -p "${backup_dir}" || ! cp -p "${PRIMARY_BIN_PATH}" "${backup_dir}/${PRIMARY_BIN}"; then
        log "error" "Failed to back up current ${PRIMARY_BIN}; nothing was installed"
        rm -rf "${backup_dir}"
        return 1
    fi
    if [[ -f "${SECONDARY_BIN_PATH}" ]] && ! cp -p "${SECONDARY_BIN_PATH}" "${backup_dir}/${SECONDARY_BIN}"; then
        log "error" "Failed to back up current ${SECONDARY_BIN}; nothing was installed"
        rm -rf "${backup_dir}"
        return 1
    fi

    log "info" "Stopping ${SERVICE_NAME} service..."
    if ! systemctl stop "${SERVICE_NAME}"; then
        log "error" "Failed to stop ${SERVICE_NAME} service"
        return 1
    fi

    log "info" "Installing binaries to ${INSTALL_DIR}..."
    if ! cp "${extract_dir}/${PRIMARY_BIN}" "${PRIMARY_BIN_PATH}" ||
       ! cp "${extract_dir}/${SECONDARY_BIN}" "${SECONDARY_BIN_PATH}" ||
       ! chmod +x "${PRIMARY_BIN_PATH}" "${SECONDARY_BIN_PATH}"; then
        if [[ -n "${tag_commit}" ]]; then
            rollback_install "${backup_dir}" "Failed to copy new binaries into ${INSTALL_DIR}"
        fi
        log "error" "Failed to copy new binaries into ${INSTALL_DIR}"
        return 1
    fi

    if [[ -n "${tag_commit}" ]]; then
        local installed_commit
        installed_commit=$(get_binary_commit "${PRIMARY_BIN_PATH}")
        if ! commit_matches "${tag_commit}" "${installed_commit}"; then
            rollback_install "${backup_dir}" "Post-install build check failed (installed '${installed_commit:-unknown}', expected ${tag_commit:0:12})"
        fi
    fi

    log "info" "Starting ${SERVICE_NAME} service..."
    if ! systemctl start "${SERVICE_NAME}"; then
        if [[ -n "${tag_commit}" ]]; then
            rollback_install "${backup_dir}" "Failed to start ${SERVICE_NAME} with the new binary"
        fi
        log "error" "Failed to start ${SERVICE_NAME} service"
        return 1
    fi

    log "info" "Verifying ${SERVICE_NAME} service status..."
    sleep 3
    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
        log "error" "Check logs: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
        if [[ -n "${tag_commit}" ]]; then
            rollback_install "${backup_dir}" "Service ${SERVICE_NAME} is not active after starting with the new binary"
        fi
        log "error" "Service ${SERVICE_NAME} failed to start properly"
        return 1
    fi

    log "info" "Service ${SERVICE_NAME} is running successfully"
    log "info" "Successfully updated ${NODE_TYPE} to version ${version}"

    return 0
}

update_graphql_stack() {
    local network="$1"
    local version="$2"
    
    # Check if GraphQL is enabled in config
    if [[ "${GRAPHQL_ENABLED:-false}" != "true" ]]; then
        log "info" "GraphQL stack update is disabled"
        return 0
    fi
    
    # Check if GraphQL directory exists
    if [[ ! -d "${GRAPHQL_DIR:-}" ]]; then
        log "info" "GraphQL directory not found: ${GRAPHQL_DIR:-not set}, skipping"
        return 0
    fi
    
    # Check if .env file exists
    if [[ ! -f "${GRAPHQL_ENV_FILE:-}" ]]; then
        log "warning" "GraphQL .env file not found: ${GRAPHQL_ENV_FILE:-not set}, skipping"
        return 0
    fi
    
    local tag="${network}-v${version}"
    local env_var="${GRAPHQL_VERSION_VAR:-SUI_VERSION}"
    
    log "info" "Updating GraphQL stack to ${tag}..."
    
    # Get current version from .env
    local current_graphql_version
    current_graphql_version=$(grep "^${env_var}=" "${GRAPHQL_ENV_FILE}" | cut -d'=' -f2 | tr -d '"' || echo "")
    
    if [[ "${current_graphql_version}" == "${tag}" ]]; then
        log "info" "GraphQL stack already at version ${tag}"
        return 2  # Already in sync, no update needed
    fi
    
    log "info" "GraphQL version change: ${current_graphql_version:-unknown} -> ${tag}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "info" "[DRY RUN] Would update ${GRAPHQL_ENV_FILE}: ${env_var}=${tag}"
        log "info" "[DRY RUN] Would run: docker compose -f ${GRAPHQL_DIR}/docker-compose.yml pull"
        log "info" "[DRY RUN] Would run: docker compose -f ${GRAPHQL_DIR}/docker-compose.yml up -d"
        return 0
    fi
    
    # Update .env file
    if grep -q "^${env_var}=" "${GRAPHQL_ENV_FILE}"; then
        # Replace existing line
        sed -i "s|^${env_var}=.*|${env_var}=${tag}|" "${GRAPHQL_ENV_FILE}"
    else
        # Add new line
        echo "${env_var}=${tag}" >> "${GRAPHQL_ENV_FILE}"
    fi
    
    log "info" "Updated ${GRAPHQL_ENV_FILE}: ${env_var}=${tag}"
    
    # Pull new images
    log "info" "Pulling new Docker images..."
    if ! docker compose -f "${GRAPHQL_DIR}/docker-compose.yml" pull 2>&1 | while read line; do log "info" "docker: ${line}"; done; then
        log "warning" "Failed to pull some Docker images, continuing anyway..."
    fi
    
    # Restart containers
    log "info" "Restarting GraphQL stack..."
    if ! docker compose -f "${GRAPHQL_DIR}/docker-compose.yml" up -d 2>&1 | while read line; do log "info" "docker: ${line}"; done; then
        log "error" "Failed to restart GraphQL stack"
        return 1
    fi
    
    # Wait and verify containers are running
    sleep 5
    local running_containers
    running_containers=$(docker compose -f "${GRAPHQL_DIR}/docker-compose.yml" ps --status running -q 2>/dev/null | wc -l)
    
    if [[ ${running_containers} -gt 0 ]]; then
        log "info" "GraphQL stack updated successfully (${running_containers} containers running)"
    else
        log "warning" "GraphQL stack may not have started correctly, check: docker compose -f ${GRAPHQL_DIR}/docker-compose.yml ps"
    fi
    
    return 0
}

cleanup_old_versions() {
    local network="$1"
    local keep_count="$2"
    
    log "info" "Cleaning up old versions (keeping ${keep_count} most recent)..."
    
    # Check if download directory exists
    if [[ ! -d "${DOWNLOAD_DIR}" ]]; then
        log "info" "Download directory does not exist, no cleanup needed"
        return 0
    fi
    
    # Find all version directories for this node type and network, sorted by modification time
    # Using ls -dt for portability (works on Linux, macOS, BSD)
    local version_dirs
    mapfile -t version_dirs < <(cd "${DOWNLOAD_DIR}" 2>/dev/null && ls -dt ${NODE_TYPE}-${network}-v*-${ARCH} 2>/dev/null | sed "s|^|${DOWNLOAD_DIR}/|" || true)
    
    local total_dirs=${#version_dirs[@]}
    
    if [[ ${total_dirs} -le ${keep_count} ]]; then
        log "info" "Found ${total_dirs} version directories, no cleanup needed"
        return 0
    fi
    
    # Remove old directories
    local removed=0
    for ((i=${keep_count}; i<${total_dirs}; i++)); do
        local dir="${version_dirs[$i]}"
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "info" "[DRY RUN] Would remove old version directory: ${dir}"
        else
            log "info" "Removing old version directory: ${dir}"
            rm -rf "${dir}" "${dir}.previous"
        fi
        removed=$((removed + 1))
    done
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "info" "[DRY RUN] Would remove ${removed} old version directories"
    else
        log "info" "Removed ${removed} old version directories"
    fi
}

# ========== Main ==========

main() {
    # Handle help flag
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        show_usage
    fi
    
    # Early check: Verify binary exists before doing anything
    # This prevents installing dependencies and creating files on wrong machines
    if [[ ! -x "${PRIMARY_BIN_PATH}" ]]; then
        echo "ERROR: ${PRIMARY_BIN} not found at ${PRIMARY_BIN_PATH}" >&2
        echo "This script is for updating existing installations only." >&2
        echo "Please install ${PRIMARY_BIN} manually first, or verify you're running on the correct machine." >&2
        exit 1
    fi
    
    # Set up trap to release lock on exit
    trap release_lock EXIT INT TERM
    
    # Acquire lock to prevent concurrent runs
    acquire_lock
    
    # Check and install dependencies if needed
    check_dependencies
    
    # Always attempt to auto-detect network for validation
    log "info" "Auto-detecting network configuration..."
    local DETECTED_NETWORK=$(detect_network)
    
    # Determine final network value
    if [[ -z "${NETWORK}" ]]; then
        # User didn't specify - use detected or default
        if [[ -n "${DETECTED_NETWORK}" ]]; then
            NETWORK="${DETECTED_NETWORK}"
            log "info" "Using auto-detected network: ${NETWORK}"
        else
            log "info" "Auto-detection failed, using default network: ${DEFAULT_NETWORK}"
            NETWORK="${DEFAULT_NETWORK}"
        fi
    else
        # User specified network - validate against detection
        log "info" "User specified network: ${NETWORK}"
        
        if [[ -n "${DETECTED_NETWORK}" ]] && [[ "${NETWORK}" != "${DETECTED_NETWORK}" ]]; then
            log "warning" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log "warning" "⚠️  NETWORK MISMATCH DETECTED ⚠️"
            log "warning" "User specified: ${NETWORK}"
            log "warning" "Auto-detected:  ${DETECTED_NETWORK}"
            log "warning" "Using user-specified value, but this may be incorrect!"
            log "warning" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            
            # Extra warning if involving mainnet
            if [[ "${NETWORK}" == "mainnet" ]] || [[ "${DETECTED_NETWORK}" == "mainnet" ]]; then
                log "warning" "🚨 CRITICAL: Mainnet mismatch - double check your configuration!"
            fi
        else
            log "info" "Network validation: OK (matches auto-detection)"
        fi
    fi
    
    # Validate network parameter
    validate_network "${NETWORK}"
    
    # Set network visual indicator
    local NETWORK_EMOJI=$(get_network_emoji "${NETWORK}")
    
    # Show warning banner for mainnet
    if [[ "${NETWORK}" == "mainnet" ]]; then
        log "info" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "info" "⚠️  MAINNET OPERATION - PRODUCTION ENVIRONMENT ⚠️"
        log "info" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
    
    # Validate architecture if user specified it
    if [[ -n "${USER_ARCH}" ]] && [[ "${ARCH}" != "${AUTO_DETECTED_ARCH}" ]]; then
        log "warning" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "warning" "⚠️  ARCHITECTURE MISMATCH DETECTED ⚠️"
        log "warning" "User specified: ${ARCH}"
        log "warning" "Auto-detected:  ${AUTO_DETECTED_ARCH}"
        log "warning" "Using user-specified value, but binary may not work!"
        log "warning" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log "info" "Architecture validation: OK (${ARCH})"
    fi
    
    # Ensure installation directory exists
    ensure_install_directory
    
    log "info" "========== ${NODE_TYPE^} Node Update Check Started =========="
    log "info" "Node Type: ${NODE_TYPE}"
    log "info" "Network: ${NETWORK_EMOJI} ${NETWORK^^} ${NETWORK_EMOJI}"
    log "info" "Architecture: ${ARCH}"
    log "info" "Keep old versions: ${KEEP_OLD_VERSIONS}"
    log "info" "Dry Run: ${DRY_RUN}"
    log "info" "Repository: ${REPO}"
    log "info" "Primary Binary: ${PRIMARY_BIN}"
    log "info" "Secondary Binary: ${SECONDARY_BIN}"
    log "info" "Service: ${SERVICE_NAME}"
    log "info" "Install Directory: ${INSTALL_DIR}"
    log "info" "Download Directory: ${DOWNLOAD_DIR}"
    
    # Dry-run prefix for notifications
    local DRY_RUN_PREFIX=""
    if [[ "${DRY_RUN}" == "true" ]]; then
        DRY_RUN_PREFIX="[DRY RUN] "
    fi
    
    # Get installed version
    log "info" "Checking installed ${PRIMARY_BIN} version..."
    local installed_version
    installed_version=$(get_installed_version)
    
    if [[ -z "${installed_version}" ]]; then
        log "error" "Failed to get installed version"
        exit 1
    fi
    
    log "info" "Installed version: ${installed_version}"
    
    # Get latest release version
    local latest_version
    latest_version=$(get_latest_release "${NETWORK}")
    
    if [[ -z "${latest_version}" ]]; then
        log "error" "Failed to get latest release version"
        exit 1
    fi
    
    log "info" "Latest ${NETWORK} version: ${latest_version}"
    
    # Resolve build identity of the release (fails closed: no install on API errors)
    local installed_commit="" tag_commit="" release_digest=""
    if [[ -n "${COMMIT_REGEX}" ]]; then
        installed_commit=$(get_binary_commit "${PRIMARY_BIN_PATH}")
        log "info" "Installed build commit: ${installed_commit:-unknown}"

        tag_commit=$(resolve_tag_commit "${NETWORK}-v${latest_version}") || \
            error_exit "Failed to resolve commit of tag ${NETWORK}-v${latest_version} via GitHub API; not updating"
        log "info" "Release ${NETWORK}-v${latest_version} commit: ${tag_commit}"

        release_digest=$(get_release_asset_digest "${NETWORK}-v${latest_version}" \
            "$(expand_binary_name "${NETWORK}" "${latest_version}" "${ARCH}")") || \
            error_exit "Failed to fetch release assets of ${NETWORK}-v${latest_version} via GitHub API; not updating"

        if [[ -z "${installed_commit}" ]]; then
            log "warning" "Could not parse installed build commit; comparing versions only"
        fi
    else
        log "warning" "COMMIT_REGEX is not set for ${NODE_TYPE}; build commit is not verified (version-only comparison)"
    fi

    local decision
    decision=$(decide_update "${installed_version}" "${latest_version}" "${installed_commit}" "${tag_commit}")
    log "info" "Update decision: ${decision}"

    if [[ "${decision}" != install-* ]]; then
        if [[ "${decision}" == "skip-installed-newer" ]]; then
            log "warning" "Installed version (${installed_version}) is newer than latest release (${latest_version})"
        else
            log "info" "Already running the latest version (${installed_version})"
        fi
        
        # Sync GraphQL stack with current node version (in case it's out of sync)
        if [[ "${GRAPHQL_ENABLED:-false}" == "true" ]]; then
            local net_emoji=$(get_network_emoji "${NETWORK}")
            
            set +e
            update_graphql_stack "${NETWORK}" "${installed_version}"
            local graphql_result=$?
            set -e
            
            # 0 = updated, 1 = failed, 2 = already in sync
            if [[ ${graphql_result} -eq 0 ]]; then
                # GraphQL was actually updated - send notification
                send_telegram "✅ <b>${DRY_RUN_PREFIX}${NODE_TYPE^} GraphQL Synced</b>

Network: ${net_emoji} <b>${NETWORK^^}</b>
Version: ${installed_version}
Host: $(hostname)
Node: ✅ Already up to date
GraphQL: ✅ Updated
Status: Success"
            elif [[ ${graphql_result} -eq 1 ]]; then
                # GraphQL update failed
                send_telegram "❌ <b>${DRY_RUN_PREFIX}${NODE_TYPE^} GraphQL Sync Failed</b>

Network: ${net_emoji} <b>${NETWORK^^}</b>
Version: ${installed_version}
Host: $(hostname)
Node: ✅ Already up to date
GraphQL: ❌ Failed
Status: Failed"
            fi
            # graphql_result == 2 means already in sync, no notification needed
        fi
        
        log "info" "========== ${NODE_TYPE^} Node Update Check Completed =========="
        exit 0
    fi
    
    local build_line=""
    if [[ "${decision}" == "install-rebuild" ]]; then
        log "warning" "Same version, different build: installed ${installed_commit}, release ${tag_commit:0:12}"
        build_line="
Build: ${installed_commit} → ${tag_commit:0:12} (same version, different build)"
    else
        log "info" "New version available: ${installed_version} -> ${latest_version}"
    fi
    
    # Check if binary is available
    local download_url
    download_url=$(check_binary_available "${NETWORK}" "${latest_version}" "${ARCH}")
    
    if [[ -z "${download_url}" ]]; then
        log "warning" "Binary for version ${latest_version} is not yet available, skipping update"
        log "info" "========== ${NODE_TYPE^} Node Update Check Completed =========="
        exit 0
    fi
    
    # Build status message as we go
    local net_emoji=$(get_network_emoji "${NETWORK}")
    local node_status=""
    local graphql_status=""
    local overall_ok=true
    local msg_emoji=""
    
    # Download and install node
    if download_and_install "${NETWORK}" "${latest_version}" "${ARCH}" "${download_url}" "${tag_commit}" "${release_digest}"; then
        log "info" "Node update completed successfully"
        node_status="✅ Updated"
        msg_emoji="✅"
        
        # Update GraphQL stack if enabled
        if [[ "${GRAPHQL_ENABLED:-false}" == "true" ]]; then
            if update_graphql_stack "${NETWORK}" "${latest_version}"; then
                graphql_status="✅ Updated"
            else
                graphql_status="❌ Failed"
                overall_ok=false
                msg_emoji="⚠️"
            fi
        fi
        
        # Cleanup old versions
        cleanup_old_versions "${NETWORK}" "${KEEP_OLD_VERSIONS}"
    else
        log "error" "Node update failed"
        node_status="❌ Failed"
        overall_ok=false
        msg_emoji="❌"
        
        # Still try to keep GraphQL in sync if node update failed
        if [[ "${GRAPHQL_ENABLED:-false}" == "true" ]]; then
            graphql_status="⏭️ Skipped"
        fi
    fi
    
    # Build and send single notification
    local graphql_line=""
    if [[ "${GRAPHQL_ENABLED:-false}" == "true" ]]; then
        graphql_line="
GraphQL: ${graphql_status}"
    fi
    
    send_telegram "${msg_emoji} <b>${DRY_RUN_PREFIX}${NODE_TYPE^} Update Report</b>

Network: ${net_emoji} <b>${NETWORK^^}</b>
Version: ${installed_version} → ${latest_version}${build_line}
Host: $(hostname)
Node: ${node_status}${graphql_line}
Status: $(if [[ "${overall_ok}" == "true" ]]; then echo "Success"; else echo "Failed"; fi)"
    
    # Exit with appropriate code
    if [[ "${node_status}" == "✅ Updated" ]]; then
        log "info" "========== ${NODE_TYPE^} Node Update Check Completed =========="
        exit 0
    else
        exit 1
    fi
}

# Run main function (not when sourced, e.g. by tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
