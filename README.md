# Node Auto-Update Script

## Overview

This repository contains an automated update script for blockchain nodes (Sui, Walrus, and more). The script automatically checks for and installs new releases from GitHub, with comprehensive safety features, logging, and monitoring capabilities.

## Supported Node Types

- **Sui** - Sui blockchain node
- **Walrus** - Walrus decentralized storage node

Add new node types by creating configuration files in `configs/` directory.

## Installation

### Quick Start

```bash
# Clone repository
cd /opt
git clone git@github.com:chirpwireless/node-maintainer.git
cd node-maintainer

# Make script executable
chmod +x node-update.sh

# Copy to system path (optional)
cp node-update.sh /usr/local/bin/
```

### Installation Locations

Scripts manage binaries and downloads based on node type configuration:

**Sui Node:**

- Binaries: `/usr/local/bin/sui-node` and `/usr/local/bin/sui-tool`
- Download directory: `/mnt/bin/`

**Walrus Node:**

- Binaries: `/opt/walrus/bin/walrus-node` and `/opt/walrus/bin/walrus`
- Download directory: `/mnt/bin/`

## Configuration

### Environment Variables

| Variable             | Default       | Description                                                   |
| -------------------- | ------------- | ------------------------------------------------------------- |
| `NODE_TYPE`          | `sui`         | Node type: sui, walrus                                        |
| `NETWORK`            | auto-detected | Network: testnet, mainnet, devnet (auto-detects from service) |
| `KEEP_OLD_VERSIONS`  | `3`           | Number of old versions to keep                                |
| `DRY_RUN`            | `false`       | Test mode without making changes                              |
| `INSTALL_DIR`        | from config   | Override installation directory                               |
| `DOWNLOAD_DIR`       | from config   | Override download directory                                   |
| `ARCH`               | auto-detected | Architecture (auto-detects from system, e.g. ubuntu-x86_64)   |
| `TELEGRAM_BOT_TOKEN` | none          | Telegram bot token (optional)                                 |
| `TELEGRAM_CHAT_ID`   | none          | Telegram chat ID(s), comma-separated (optional)               |
| `SECRETS_FILE`       | `/etc/node-maintainer/secrets.env` | File with `TELEGRAM_*` values (optional, see below) |

### Network Auto-Detection

The script automatically detects which network your node is running on:

**Method 1: Config File Parsing**

- Extracts config path from systemd service (`--config-path /opt/sui-node/config/fullnode.yaml`)
- Scans config for network indicators:
  - Database paths: `/opt/sui/db/testnet`
  - Genesis files: `testnet-genesis.blob`
  - Network keywords in URLs/paths

**Method 2: Directory Structure**

- Checks common locations: `/opt/sui/config`, `/opt/walrus/config`, `/etc/`
- Looks for network-specific files or subdirectories

**Example:**

```bash
# Auto-detects from /opt/sui-node/config/fullnode.yaml
NODE_TYPE=sui ./node-update.sh

# Override auto-detection
NODE_TYPE=sui NETWORK=mainnet ./node-update.sh
```

**Supported patterns:**

- Config paths containing network: `/opt/sui/db/testnet/`
- Genesis files: `testnet-genesis.blob`, `mainnet.blob`
- Network in YAML/TOML keys

**Fallback:** If auto-detection fails, uses `DEFAULT_NETWORK` from config file.

**Validation:** If you manually specify a network, the script validates it against auto-detection and warns if they differ. This prevents dangerous mistakes like running mainnet updates on a testnet node.

### Architecture Auto-Detection

The script automatically detects your system architecture:

**Detection logic:**

```bash
# Detects OS: Linux → ubuntu, macOS → macos
# Detects Architecture: x86_64, aarch64, arm64
# Combines: ubuntu-x86_64, macos-aarch64, etc.
```

**Supported mappings:**

- `x86_64`, `amd64` → `x86_64`
- `aarch64`, `arm64` → `aarch64`
- `linux` → `ubuntu` (for release compatibility)
- `darwin` → `macos`

**Override if needed:**

```bash
# Force specific architecture
ARCH=ubuntu-aarch64 NODE_TYPE=sui ./node-update.sh
```

**Validation:** The script validates user-specified architecture against system detection to prevent using incompatible binaries.

### Safety Validation

The script includes built-in safety checks to prevent configuration mistakes:

**Network Mismatch Warning:**

```
[warning] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[warning] ⚠️  NETWORK MISMATCH DETECTED ⚠️
[warning] User specified: mainnet
[warning] Auto-detected:  testnet
[warning] Using user-specified value, but this may be incorrect!
[warning] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[warning] 🚨 CRITICAL: Mainnet mismatch - double check your configuration!
```

**Architecture Mismatch Warning:**

```
[warning] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[warning] ⚠️  ARCHITECTURE MISMATCH DETECTED ⚠️
[warning] User specified: ubuntu-aarch64
[warning] Auto-detected:  ubuntu-x86_64
[warning] Using user-specified value, but binary may not work!
[warning] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**When validation succeeds:**

```
[info] Network validation: OK (matches auto-detection)
[info] Architecture validation: OK (ubuntu-x86_64)
```

### Configuration Files

Each node type has a configuration file in `configs/`:

- `configs/sui.conf` - Sui node configuration
- `configs/walrus.conf` - Walrus node configuration

## Usage

### Get Help

```bash
./node-update.sh --help
# or
./node-update.sh -h
```

### Basic Usage

```bash
# Update Sui testnet node
NODE_TYPE=sui ./node-update.sh

# Update Walrus mainnet node
NODE_TYPE=walrus NETWORK=mainnet ./node-update.sh

# Dry run (test without making changes)
DRY_RUN=true NODE_TYPE=sui ./node-update.sh

# Custom paths and retention
NODE_TYPE=walrus INSTALL_DIR=/custom/path KEEP_OLD_VERSIONS=5 ./node-update.sh
```

### Cron Configuration

Schedule automatic updates via cron:

```bash
# Edit crontab
crontab -e

# Sui testnet - every 6 hours
0 */6 * * * NODE_TYPE=sui /usr/local/bin/node-update.sh >> /dev/null 2>&1

# Walrus mainnet - every 4 hours
0 */4 * * * NODE_TYPE=walrus NETWORK=mainnet /usr/local/bin/node-update.sh >> /dev/null 2>&1

# Sui mainnet with custom retention - daily at 2 AM
0 2 * * * NODE_TYPE=sui NETWORK=mainnet KEEP_OLD_VERSIONS=5 /usr/local/bin/node-update.sh >> /dev/null 2>&1
```

### Telegram Notifications

Get notified when your nodes are updated or when updates fail.

#### Setup

1. **Create a Telegram Bot:**

   - Message [@BotFather](https://t.me/BotFather) on Telegram
   - Send `/newbot` and follow instructions
   - Copy the bot token (looks like: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

2. **Get Your Chat ID:**

   - Message your bot
   - Visit: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
   - Find your chat ID in the JSON response
   - For group chats: Add bot to group, then check getUpdates (group IDs are negative)

3. **Store the credentials:**

Keep them in a root-only file rather than in the crontab line, where they show up in every `crontab -l` output:

```bash
install -d -m 700 /etc/node-maintainer
install -m 600 -o root -g root /dev/null /etc/node-maintainer/secrets.env
nano /etc/node-maintainer/secrets.env   # an editor keeps the token out of shell history
```

```
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=123456789,-987654321
```

```
0 */6 * * * NODE_TYPE=sui /usr/local/bin/node-update.sh >> /dev/null 2>&1
```

The file is parsed as `KEY=value` lines (an `export ` prefix, spaces around `=` and quotes are accepted), never executed; only `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are read, and they are not passed on to child processes. Values set in the environment win over the file. The script warns when the file is readable by group or others or not owned by root.

Environment variables still work:

```bash
# Single chat ID
0 */6 * * * TELEGRAM_BOT_TOKEN="123456:ABC..." TELEGRAM_CHAT_ID="123456789" NODE_TYPE=sui /usr/local/bin/node-update.sh >> /dev/null 2>&1

# Multiple chat IDs (personal + team group)
0 */6 * * * TELEGRAM_BOT_TOKEN="123456:ABC..." TELEGRAM_CHAT_ID="123456789,-987654321" NODE_TYPE=sui /usr/local/bin/node-update.sh >> /dev/null 2>&1

# Or export in shell profile
export TELEGRAM_BOT_TOKEN="123456:ABC..."
export TELEGRAM_CHAT_ID="123456789,-987654321,111222333"  # Supports multiple IDs
```

**Test your setup with dry-run:**

```bash
DRY_RUN=true TELEGRAM_BOT_TOKEN="..." TELEGRAM_CHAT_ID="..." NODE_TYPE=sui ./node-update.sh
# Will ALWAYS send a real test notification at startup to verify setup
# Works even if no update is available
```

**Notification format:**

```
✅ Sui Node Updated

Network: 🧪 TESTNET
Version: 1.58.0 → 1.58.1
Host: sui-node-01
Status: Success
```

**Network indicators:**

- 🚀 **MAINNET** - Production environment (with warning banner)
- 🧪 **TESTNET** - Development/testing environment
- 🔧 **DEVNET** - Developer network

**Test notification (sent immediately in dry-run):**

```
🧪 [TEST] Sui Node Update - Dry Run

This is a test notification from dry-run mode

Network: 🧪 TESTNET
Host: sui-node-01
Dry Run: true

✅ Telegram notifications are working correctly!
```

## How It Works

### Script Workflow

1. **Initialization**

   - Parse command-line arguments (--help flag)
   - Acquire exclusive lock to prevent concurrent runs
   - Check and auto-install missing dependencies

2. **Configuration Loading**

   - Load node-specific configuration from `configs/{NODE_TYPE}.conf`
   - Validate network parameter (testnet/mainnet/devnet)
   - Ensure installation directory exists

3. **Version Check**

   - Query installed node version using binary's `--version` command
   - Extract version using node-specific regex pattern

4. **GitHub API Query**

   - Check GitHub API rate limits
   - Fetch latest release for specified network
   - Extract version from release tag

5. **Version Comparison**

   - Compare installed vs. latest version using semantic versioning
   - Skip if already running latest version
   - Skip if installed version is newer (development builds)

6. **Binary Availability Check**

   - Verify binary download URL returns HTTP 200
   - Prevents update attempts when binaries aren't published yet

7. **Download & Install** (skipped in dry-run mode)

   - Download and extract to `{DOWNLOAD_DIR}/{NODE_TYPE}-{network}-v{version}-{arch}/`
   - Verify expected binaries exist in extracted archive
   - Stop systemd service
   - Copy binaries to installation directory
   - Start systemd service
   - Verify service is running (3-second check)

8. **GraphQL Stack** (when `GRAPHQL_ENABLED=true`, after a node update and on every run where the node is already up to date)

   - Only versioned services count: those whose image in `{GRAPHQL_DIR}/docker-compose.yml` follows the version variable (fixed images such as `postgres` never trigger an update on their own)
   - The stack is in sync when each of those services has a container on the image of the node version that is running or stopped by hand (`exited`, `paused`); such a stopped service stays stopped, while `created`, `restarting` or `dead` containers count as out of sync
   - No versioned service at all (wrong `GRAPHQL_VERSION_VAR`) is reported as a failure
   - Otherwise pull the images of that version first; if the pull fails (images of a fresh release can appear hours after its binaries), leave `.env` and the containers untouched and report the failure
   - Update the version in `.env`, run `docker compose up -d` for the whole stack, and check that every versioned service now runs the new image
   - A failed or partial update is retried on the next run and reported to Telegram on each failed run

9. **Cleanup**

   - Remove old version directories
   - Keep configured number of recent versions for rollback

10. **Finalization**
   - Release exclusive lock
   - Log completion status

## Logging

All activities are logged to syslog with node-specific tags. View logs with:

```bash
# Sui node logs
journalctl -t sui-updater --since "1 hour ago" --no-pager
journalctl -t sui-updater -f  # Follow in real-time

# Walrus node logs
journalctl -t walrus-updater --since "1 hour ago" --no-pager
journalctl -t walrus-updater -f  # Follow in real-time

# View all logs from today
journalctl -t sui-updater --since "today" --no-pager

# Filter by log level
journalctl -t sui-updater -p err  # Errors only
journalctl -t sui-updater -p warning  # Warnings and above
```

## Safety Features

1. **Dependency Auto-Check & Install**: Automatically detects and installs missing dependencies
2. **Dry-Run Mode**: Test updates without making any changes (`DRY_RUN=true`)
3. **Exclusive Locking**: Prevents concurrent script executions using `flock`
4. **Network Validation**: Only accepts valid network parameters (testnet/mainnet/devnet)
5. **Service Verification**: Confirms service actually started after update (3-second check)
6. **GitHub API Rate Limiting**: Monitors and warns about API quota usage
7. **Binary Availability Check**: Verifies binary download URL before attempting update
8. **Version Comparison**: Only updates if newer version is available
9. **Service Management**: Properly stops/starts systemd service
10. **Old Version Retention**: Keeps previous versions for rollback capability
11. **Installation Directory Creation**: Automatically creates required directories
12. **Comprehensive Logging**: Full audit trail to syslog
13. **Error Handling**: Extensive error checking with helpful messages
14. **Atomic Operations**: Downloads to temporary directory before installation

## Manual Rollback

If you need to rollback to a previous version:

### Sui Node Rollback

```bash
# List available versions
ls -la /mnt/bin/sui-*

# Stop the service
systemctl stop sui

# Copy old binaries (example version)
cp /mnt/bin/sui-testnet-v1.57.2-ubuntu-x86_64/sui-node /usr/local/bin/
cp /mnt/bin/sui-testnet-v1.57.2-ubuntu-x86_64/sui-tool /usr/local/bin/
chmod +x /usr/local/bin/sui-node /usr/local/bin/sui-tool

# Start the service
systemctl start sui

# Verify version
sui-node --version
```

### Walrus Node Rollback

```bash
# List available versions
ls -la /mnt/bin/walrus-*

# Stop the service
systemctl stop walrus-node

# Copy old binaries (example version)
cp /mnt/bin/walrus-testnet-v1.34.0-ubuntu-x86_64/walrus-node /opt/walrus/bin/
cp /mnt/bin/walrus-testnet-v1.34.0-ubuntu-x86_64/walrus /opt/walrus/bin/
chmod +x /opt/walrus/bin/walrus-node /opt/walrus/bin/walrus

# Start the service
systemctl start walrus-node

# Verify version
/opt/walrus/bin/walrus-node --version
```

## Tests

```bash
tests/graphql_update_test.sh   # GraphQL stack sync against a fake docker compose
tests/secrets_file_test.sh     # SECRETS_FILE parsing
```

## Troubleshooting

### Getting Help

```bash
# View built-in help
./node-update.sh --help
```

### Testing with Dry-Run

```bash
# Test Sui update without making changes
DRY_RUN=true NODE_TYPE=sui ./node-update.sh

# Test Walrus mainnet update
DRY_RUN=true NODE_TYPE=walrus NETWORK=mainnet ./node-update.sh
```

### View Update Status

```bash
# View last update logs
journalctl -t sui-updater --since "today" --no-pager | tail -50

# Check for errors
journalctl -t sui-updater -p err --since "today"

# Follow live updates
journalctl -t walrus-updater -f
```

### Check Lock File

```bash
# Check if another instance is running
ls -l /var/lock/node-updater-*.lock

# Manually remove stuck lock (be careful!)
rm -f /var/lock/node-updater-sui.lock
```

### Verify Dependencies

```bash
# The script auto-checks, but you can verify manually
which curl wget jq tar systemctl flock

# Install missing dependencies manually (Ubuntu/Debian)
apt-get install -y curl wget jq tar systemd util-linux
```

### Service Status

```bash
# Check if service failed to start after update
systemctl status sui
systemctl status walrus-node

# View service logs
journalctl -u sui -n 50 --no-pager
journalctl -u walrus-node -n 50 --no-pager
```

### Check Cron Status

```bash
# Verify cron jobs are configured
crontab -l

# Check cron execution logs
journalctl -u cron --since "today" --no-pager | grep node-update

# Check for cron errors
grep CRON /var/log/syslog | grep node-update
```

### Common Issues

| Issue                        | Solution                                                                      |
| ---------------------------- | ----------------------------------------------------------------------------- |
| **Dependencies missing**     | Script auto-installs, or run: `apt-get install -y curl wget jq tar systemctl` |
| **Another instance running** | Wait for completion or remove lock: `rm /var/lock/node-updater-*.lock`        |
| **Network connectivity**     | Check: `curl -I https://api.github.com`                                       |
| **Permissions**              | Ensure execute: `chmod +x node-update-universal.sh`                           |
| **Wrong service name**       | Verify: `systemctl status sui` or `systemctl status walrus-node`              |
| **Invalid network**          | Use: testnet, mainnet, or devnet only                                         |
| **API rate limit**           | Wait for reset (shown in logs) or use authenticated requests                  |
| **Binary not available**     | Script will skip and retry later automatically                                |

## Adding New Node Types

To add support for a new node type, create a configuration file:

```bash
# Create new config file
cat > configs/mynode.conf << 'EOF'
# MyNode Configuration
REPO="Organization/repository"
PRIMARY_BIN="mynode"
SECONDARY_BIN="mynode-cli"
SERVICE_NAME="mynode"
INSTALL_DIR="/usr/local/bin"
DOWNLOAD_DIR="/mnt/bin"
BINARY_NAME_PATTERN="mynode-\${NETWORK}-v\${VERSION}-\${ARCH}.tgz"
VERSION_REGEX="mynode \\K[0-9]+\\.[0-9]+\\.[0-9]+"
DEFAULT_NETWORK="testnet"
EOF

# Use the new node type
NODE_TYPE=mynode ./node-update.sh
```

## Production Best Practices

1. **Always test in dry-run mode first**

   ```bash
   DRY_RUN=true NODE_TYPE=sui ./node-update.sh
   ```

2. **Monitor logs regularly**

   ```bash
   journalctl -t sui-updater --since "1 week ago" --no-pager
   ```

3. **Keep adequate disk space**

   - Each version requires ~500MB-1GB
   - With 3 old versions retained: ~2-4GB total

4. **Set appropriate cron schedules**

   - Testnet: Every 4-6 hours (more frequent updates)
   - Mainnet: Every 6-12 hours (more stable)

5. **Use mainnet with caution**

   - Test on testnet first
   - Monitor first update manually

6. **Enable notifications** (optional)
   ```bash
   # Example: Send email on update
   0 */6 * * * NODE_TYPE=sui /usr/local/bin/node-update.sh && echo "Sui updated" | mail -s "Node Update" admin@example.com
   ```

## Support and Contributing

- Report issues with detailed logs from `journalctl`
- Test with dry-run mode before reporting bugs
- Include node type, network, and script version in reports
