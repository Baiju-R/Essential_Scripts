#!/bin/bash

# ==============================================================================
# Script Name: install_java_sdk.sh
# Description: Hardened, enterprise-ready offline OpenJDK 21 installer.
# Version:     1.0.1
#
# Prerequisites:
#   • Run as root (sudo)
#   • Target OpenJDK 21 Linux x64 Binaries archive (.tar.gz) must be downloaded.
#     Get it from: https://adoptium.net/ or https://jdk.java.net/21/
#
# Usage:
#   chmod +x install_java_sdk.sh
#   sudo ./install_java_sdk.sh /path/to/openjdk-21_linux-x64_bin.tar.gz
#
# If no archive path is supplied, the script expects:
#   /tmp/openjdk-21.tar.gz
# ==============================================================================

# --- Strict Execution Enforcement ---
set -Eeuo pipefail

# --- 1. Immediate Root Privilege Verification ---
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: This script must be run as root."
    echo "Usage: sudo $0 [/path/to/openjdk-21.tar.gz]"
    exit 1
fi

# --- 2. Logging & Version Infrastructure ---
SCRIPT_VERSION="1.0.1"
LOG_FILE="/var/log/java_sdk_install.log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

# --- Automated Workspace Cleanup & Error Diagnostic Trap ---
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo "======================================================"
        echo "❌ FAILURE DIAGNOSTIC TRIGGERED"
        echo "   Exit Code:       $exit_code"
        echo "   Faulting Line:   ${BASH_LINENO[0]:-Unknown}"
        echo "   Command Context: ${BASH_COMMAND:-Unknown}"
        echo "======================================================"
    fi
    
    echo "🧹 Cleaning temporary operational files..."
    rm -rf /tmp/jdk-unpacked-* 2>/dev/null || true
}
trap cleanup EXIT

# --- Configuration ---
INSTALL_BASE="/opt"
TARGET_DIR_NAME="jdk-21"
INSTALL_DIR="${INSTALL_BASE}/${TARGET_DIR_NAME}"
ENV_PROFILE_PATH="/etc/profile.d/java.sh"

# Binaries to link system-wide and defensively validate
JAVA_BINARIES=("java" "javac" "jar" "javadoc" "jshell")

echo "======================================================"
echo "🔄 Starting Java SDK Installation Pipeline [v${SCRIPT_VERSION}]"
echo "⏰ Timestamp: $(date)"
echo "======================================================"

# --- 3. Process Input Argument (Target Tarball Location) ---
ARCHIVE_PATH="${1:-/tmp/openjdk-21.tar.gz}"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "❌ Error: JDK archive not found at: $ARCHIVE_PATH"
    echo "Please download the OpenJDK 21 (.tar.gz) package manually first, or specify the path:"
    echo "Usage: sudo $0 /path/to/openjdk-21_linux-x64_bin.tar.gz"
    exit 1
fi
echo "📦 Using target archive: $ARCHIVE_PATH"

# --- 4. Verify Operating System Compatibility ---
if ! grep -q "Ubuntu" /etc/os-release; then
    echo "❌ Error: This installer supports Ubuntu only."
    exit 1
fi
echo "✓ OS Validation: Ubuntu environment confirmed."

# --- 5. Verify CPU Architecture ---
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" != "amd64" ]]; then
    echo "❌ Error: Unsupported architecture ($ARCH). This installation requires amd64."
    exit 1
fi
echo "✓ Architecture Validation: amd64 confirmed."

# --- 6. Robust Active User Discovery ---
ACTIVE_USER="${SUDO_USER:-}"
if [[ -z "$ACTIVE_USER" || "$ACTIVE_USER" == "root" ]]; then
    ACTIVE_USER=$(loginctl list-sessions --no-legend | awk '$3!="gdm" && $3!="" {print $3; exit}')
fi
if [[ -z "$ACTIVE_USER" ]]; then
    ACTIVE_USER=$(who | awk '/:0|tty/{print $1; exit}')
fi

if [[ -n "${ACTIVE_USER:-}" && "$ACTIVE_USER" != "root" ]]; then
    echo "✅ Active target system user detected: $ACTIVE_USER"
else
    echo "⚠️ Warning: Operating in daemon/system-only context."
fi

# --- 7. Verify Core Extraction Utilities ---
if ! command -v tar >/dev/null 2>&1; then
    echo "❌ Error: Required utility 'tar' is not available."
    exit 1
fi

if ! command -v update-alternatives >/dev/null 2>&1; then
    echo "❌ Error: update-alternatives is unavailable."
    exit 1
fi
echo "✓ Core dependencies check passed."

# --- 8. Legacy/Old Version Evacuation ---
echo "🗑️ Evacuating legacy target paths to guarantee a clean install..."
rm -rf "$INSTALL_DIR"
rm -f "$ENV_PROFILE_PATH"

# --- 9. Verify Archive Integrity (Offline Check) ---
echo "🔎 Checking package integrity..."
if ! tar -tzf "$ARCHIVE_PATH" >/dev/null 2>&1; then
    echo "❌ Error: Target archive is corrupted or not a valid gzipped tarball."
    exit 1
fi
echo "✓ Integrity Verification: Tarball valid."

# --- 10. Extraction & Structural Normalization ---
TEMP_EXTRACT_DIR=$(mktemp -d /tmp/jdk-unpacked-XXXXXX)

echo "📂 Unpacking payload..."
tar -xzf "$ARCHIVE_PATH" -C "$TEMP_EXTRACT_DIR"

# Locate the actual directory extracted inside the temp path
EXTRACTED_FOLDER=$(find "$TEMP_EXTRACT_DIR" -maxdepth 1 -mindepth 1 -type d | head -n 1)

if [[ -z "$EXTRACTED_FOLDER" ]]; then
    echo "❌ Error: Failed to locate extracted contents."
    exit 1
fi

# Defensive Pre-Relocation Verification: Validate ALL required binaries exist inside the unpacked payload
echo "🔎 Validating extracted JDK binaries layout..."
for bin in "${JAVA_BINARIES[@]}"; do
    if [[ ! -f "$EXTRACTED_FOLDER/bin/$bin" ]]; then
        echo "❌ Error: Extracted package is missing required compiler tool: bin/$bin"
        echo "💡 Ensure you downloaded the full 'JDK' (Java Development Kit) bundle, and not a stripped-down JRE build."
        exit 1
    fi
done

# Defensive absolute check: Ensure no concurrent process has newly created the target path
if [[ -e "$INSTALL_DIR" ]]; then
    echo "⚠️ Warning: Found an existing path at $INSTALL_DIR immediately prior to relocation. Forcing purge..."
    rm -rf "$INSTALL_DIR"
fi

mv "$EXTRACTED_FOLDER" "$INSTALL_DIR"
rm -rf "$TEMP_EXTRACT_DIR"

# --- 11. Granular Permissions Set ---
echo "🔒 Applying system access controls..."
chown -R root:root "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
chmod -R a+rX "$INSTALL_DIR"

# Ensure core binaries are fully executable
for bin in "${JAVA_BINARIES[@]}"; do
    chmod 755 "$INSTALL_DIR/bin/$bin"
done

# --- 12. System-Wide Integration (update-alternatives) ---
echo "⚙️ Registering OpenJDK tools with system-wide alternatives database..."
for bin in "${JAVA_BINARIES[@]}"; do
    bin_path="$INSTALL_DIR/bin/$bin"
    # Use high priority (2100) to override generic system configurations
    update-alternatives --install "/usr/bin/$bin" "$bin" "$bin_path" 2100
    update-alternatives --set "$bin" "$bin_path"
    echo "  ✓ Configured alternatives for: $bin"
done

# --- 13. System Environment Variable Auto-Configuration ---
echo "📝 Writing system environment configuration to $ENV_PROFILE_PATH..."
cat <<EOF > "$ENV_PROFILE_PATH"
# Automated configuration for Java SDK
export JAVA_HOME="$INSTALL_DIR"
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF
chmod 644 "$ENV_PROFILE_PATH"

# --- 14. Post-Installation Verification Check ---
echo "🩺 Performing structural health validation..."
echo "------------------------------------------------------"
HEALTH_CHECK_PASSED=true

for bin in "${JAVA_BINARIES[@]}"; do
    # Check physical paths
    if [[ ! -f "$INSTALL_DIR/bin/$bin" ]]; then
        echo "  ✗ Missing physical binary: $INSTALL_DIR/bin/$bin"
        HEALTH_CHECK_PASSED=false
    fi
    # Check if alternative path is registered and working
    if ! command -v "$bin" &>/dev/null; then
        echo "  ✗ Command not accessible in system path: $bin"
        HEALTH_CHECK_PASSED=false
    fi
done

if [ "$HEALTH_CHECK_PASSED" = true ]; then
    echo "  ✓ Installation Status: Core verification passed"
    # Show active registered paths
    echo "  ✓ Command 'java' points to: $(readlink -f "$(which java)")"
    echo "  ✓ Command 'javac' points to: $(readlink -f "$(which javac)")"
else
    echo "  ✗ Installation Status: Failure detected in post-install health checks"
    exit 1
fi
echo "------------------------------------------------------"

# --- 15. Standardized Success Summary ---
# Dynamically fetch version outputs from active system alternatives
ACTIVE_JAVA_VERSION=$(java --version | head -n 1)
ACTIVE_JAVAC_VERSION=$(javac --version | head -n 1)

cat <<EOF

======================================================
 🎉 OpenJDK 21 Installed Successfully (JDK & JRE)

 Installation Path:
  $INSTALL_DIR

 Active Environment Variable Profiles:
  • JAVA_HOME="$INSTALL_DIR"
  • Path Integration: Done system-wide

 Installed Command-Line Tools:
  ✅ java (Java VM Runtime)
  ✅ javac (Compiler)
  ✅ jar (Archive Packaging)
  ✅ javadoc (Documentation Engine)
  ✅ jshell (Interactive REPL)

 Active System Tool Versions:
  • $ACTIVE_JAVA_VERSION
  • $ACTIVE_JAVAC_VERSION

 Note:
  Run 'source /etc/profile.d/java.sh' (or log in/out) 
  to refresh your current terminal's environment variables.

 Installer Log:
  $LOG_FILE (Installer v$SCRIPT_VERSION)
======================================================
EOF
