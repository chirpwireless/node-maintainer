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
# Default format: ubuntu-x86_64, can be overridden via environment
ARCH="${ARCH:-ubuntu-x86_64}"

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
GITHUB_API="https://api.github.com/repos/${REPO}/releases"

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
                log "error" "Failed to create directory: ${install_dir}"
                exit 1
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
    
    # Find the first release matching the network
    local latest_release
    latest_release=$(echo "${releases}" | jq -r ".[] | select(.tag_name | startswith(\"${network}-v\")) | .tag_name" | head -1)
    
    if [[ -z "${latest_release}" ]]; then
        log "error" "No ${network} releases found"
        echo ""
        return 1
    fi
    
    # Extract version number (e.g., "testnet-v1.58.1" -> "1.58.1")
    local version
    version=$(echo "${latest_release}" | grep -oP "${network}-v\K[0-9]+\.[0-9]+\.[0-9]+")
    
    echo "${version}"
}

check_binary_available() {
    local network="$1"
    local version="$2"
    local arch="$3"
    
    local tag="${network}-v${version}"
    
    # Expand the binary name pattern
    local VERSION="${version}"
    local NETWORK="${network}"
    local ARCH="${arch}"
    eval "local binary_name=\"${BINARY_NAME_PATTERN}\""
    
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

download_and_install() {
    local network="$1"
    local version="$2"
    local arch="$3"
    local download_url="$4"
    
    local tag="${network}-v${version}"
    local extract_dir="${DOWNLOAD_DIR}/${NODE_TYPE}-${tag}-${arch}"
    
    log "info" "Starting download and installation of ${NODE_TYPE} ${tag}"
    
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "info" "[DRY RUN] Would create download directory: ${DOWNLOAD_DIR}"
        log "info" "[DRY RUN] Would create extraction directory: ${extract_dir}"
        log "info" "[DRY RUN] Would download from: ${download_url}"
        log "info" "[DRY RUN] Would stop ${SERVICE_NAME} service"
        log "info" "[DRY RUN] Would install binaries to ${INSTALL_DIR}"
        log "info" "[DRY RUN] Would start ${SERVICE_NAME} service"
        log "info" "[DRY RUN] Would verify service is running"
        return 0
    fi
    
    # Save current directory
    local original_dir=$(pwd)
    
    # Create download directory if it doesn't exist
    mkdir -p "${DOWNLOAD_DIR}"
    cd "${DOWNLOAD_DIR}" || { log "error" "Failed to change to download directory"; return 1; }
    
    # Create extraction directory
    log "info" "Creating directory: ${extract_dir}"
    mkdir -p "${extract_dir}"
    
    # Download and extract
    log "info" "Downloading from: ${download_url}"
    if ! wget --timeout=300 -qO- "${download_url}" | tar xz -C "${extract_dir}"; then
        log "error" "Failed to download or extract binary"
        rm -rf "${extract_dir}"
        cd "${original_dir}" || true
        return 1
    fi
    
    # Restore original directory immediately after download/extract
    cd "${original_dir}" || true
    
    # Verify binaries exist (using absolute paths now)
    if [[ ! -f "${extract_dir}/${PRIMARY_BIN}" ]] || [[ ! -f "${extract_dir}/${SECONDARY_BIN}" ]]; then
        log "error" "Expected binaries (${PRIMARY_BIN}, ${SECONDARY_BIN}) not found in extracted archive"
        log "info" "Contents of extracted directory:"
        ls -la "${extract_dir}" >&2
        rm -rf "${extract_dir}"
        return 1
    fi
    
    log "info" "Successfully downloaded and extracted to ${extract_dir}"
    
    # Stop the service
    log "info" "Stopping ${SERVICE_NAME} service..."
    if ! systemctl stop "${SERVICE_NAME}"; then
        log "error" "Failed to stop ${SERVICE_NAME} service"
        return 1
    fi
    
    # Copy binaries
    log "info" "Installing binaries to ${INSTALL_DIR}..."
    cp "${extract_dir}/${PRIMARY_BIN}" "${PRIMARY_BIN_PATH}"
    cp "${extract_dir}/${SECONDARY_BIN}" "${SECONDARY_BIN_PATH}"
    chmod +x "${PRIMARY_BIN_PATH}" "${SECONDARY_BIN_PATH}"
    
    # Start the service
    log "info" "Starting ${SERVICE_NAME} service..."
    if ! systemctl start "${SERVICE_NAME}"; then
        log "error" "Failed to start ${SERVICE_NAME} service"
        return 1
    fi
    
    # Wait and verify service is actually running
    log "info" "Verifying ${SERVICE_NAME} service status..."
    sleep 3
    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
        log "error" "Service ${SERVICE_NAME} failed to start properly"
        log "error" "Check logs: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
        return 1
    fi
    
    log "info" "Service ${SERVICE_NAME} is running successfully"
    log "info" "Successfully updated ${NODE_TYPE} to version ${version}"
    
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
            rm -rf "${dir}"
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
    
    # Determine network: auto-detect if not specified, fallback to default
    if [[ -z "${NETWORK}" ]]; then
        log "info" "Network not specified, attempting auto-detection..."
        NETWORK=$(detect_network)
        if [[ -z "${NETWORK}" ]]; then
            log "info" "Auto-detection failed, using default network: ${DEFAULT_NETWORK}"
            NETWORK="${DEFAULT_NETWORK}"
        fi
    else
        log "info" "Using specified network: ${NETWORK}"
    fi
    
    # Validate network parameter
    validate_network "${NETWORK}"
    
    # Ensure installation directory exists
    ensure_install_directory
    
    log "info" "========== ${NODE_TYPE^} Node Update Check Started =========="
    log "info" "Node Type: ${NODE_TYPE}"
    log "info" "Network: ${NETWORK}"
    log "info" "Architecture: ${ARCH}"
    log "info" "Keep old versions: ${KEEP_OLD_VERSIONS}"
    log "info" "Dry Run: ${DRY_RUN}"
    log "info" "Repository: ${REPO}"
    log "info" "Primary Binary: ${PRIMARY_BIN}"
    log "info" "Secondary Binary: ${SECONDARY_BIN}"
    log "info" "Service: ${SERVICE_NAME}"
    log "info" "Install Directory: ${INSTALL_DIR}"
    log "info" "Download Directory: ${DOWNLOAD_DIR}"
    
    # Send test notification in dry-run mode
    if [[ "${DRY_RUN}" == "true" ]]; then
        send_telegram "🧪 <b>[TEST] ${NODE_TYPE^} Node Update - Dry Run</b>

<i>This is a test notification from dry-run mode</i>

Network: ${NETWORK}
Host: $(hostname)
Dry Run: ${DRY_RUN}

✅ Telegram notifications are working correctly!"
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
    
    # Compare versions (temporarily disable errexit to capture return code)
    set +e
    version_compare "${installed_version}" "${latest_version}"
    local cmp_result=$?
    set -e
    
    if [[ ${cmp_result} -eq 0 ]]; then
        log "info" "Already running the latest version (${installed_version})"
        log "info" "========== ${NODE_TYPE^} Node Update Check Completed =========="
        exit 0
    elif [[ ${cmp_result} -eq 1 ]]; then
        log "warning" "Installed version (${installed_version}) is newer than latest release (${latest_version})"
        log "info" "========== ${NODE_TYPE^} Node Update Check Completed =========="
        exit 0
    fi
    
    # New version available
    log "info" "New version available: ${installed_version} -> ${latest_version}"
    
    # Check if binary is available
    local download_url
    download_url=$(check_binary_available "${NETWORK}" "${latest_version}" "${ARCH}")
    
    if [[ -z "${download_url}" ]]; then
        log "warning" "Binary for version ${latest_version} is not yet available, skipping update"
        log "info" "========== ${NODE_TYPE^} Node Update Check Completed =========="
        exit 0
    fi
    
    # Download and install
    if download_and_install "${NETWORK}" "${latest_version}" "${ARCH}" "${download_url}"; then
        log "info" "Update completed successfully"
        
        # Send success notification
        send_telegram "✅ <b>${NODE_TYPE^} Node Updated</b>

Network: ${NETWORK}
Version: ${installed_version} → ${latest_version}
Host: $(hostname)
Status: Success"
        
        # Cleanup old versions
        cleanup_old_versions "${NETWORK}" "${KEEP_OLD_VERSIONS}"
        
        log "info" "========== ${NODE_TYPE^} Node Update Check Completed =========="
        exit 0
    else
        log "error" "Update failed"
        
        # Send failure notification
        send_telegram "❌ <b>${NODE_TYPE^} Node Update Failed</b>

Network: ${NETWORK}
Version: ${installed_version} → ${latest_version}
Host: $(hostname)
Status: Failed"
        
        exit 1
    fi
}

# Run main function
main "$@"