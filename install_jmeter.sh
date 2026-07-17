#!/bin/bash

# ==============================================================================
# Script Name: install_jmeter.sh
# Description: Hardened, enterprise-ready non-interactive Apache JMeter installer.
# Version:     1.0.2
#
# Prerequisites:
#   • Run as root (sudo)
#   • Package index must already be updated (apt-get update)
#   • Apache JMeter Binaries archive (.tgz) must already be downloaded.
#     Get it from: https://jmeter.apache.org/download_jmeter.cgi
#
# Usage:
#   chmod +x install_jmeter.sh
#   sudo ./install_jmeter.sh /path/to/apache-jmeter-*.tgz
#
# If no archive path is supplied, the script expects:
#   /tmp/apache-jmeter.tgz
# ==============================================================================

# --- Strict Execution Enforcement ---
set -Eeuo pipefail

# --- 1. Immediate Root Privilege Verification ---
# Checked BEFORE any file descriptors or logging layers are instantiated
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: This script must be run as root."
    echo "Usage: sudo $0 [/path/to/archive.tgz]"
    exit 1
fi

# --- 2. Logging & Version Infrastructure ---
SCRIPT_VERSION="1.0.2"
LOG_FILE="/var/log/jmeter_install.log"
exec > >(tee -a "$LOG_FILE")
exec 2>&1

# --- Automated Workspace Cleanup & Error Diagnostic Trap ---
cleanup() {
    local exit_code=$?
    # If the exit code is non-zero, capture the faulting command context
    if [[ $exit_code -ne 0 ]]; then
        echo "======================================================"
        echo "❌ FAILURE DIAGNOSTIC TRIGGERED"
        echo "   Exit Code:       $exit_code"
        echo "   Faulting Line:   ${BASH_LINENO[0]:-Unknown}"
        echo "   Command Context: ${BASH_COMMAND:-Unknown}"
        echo "======================================================"
    fi
    
    echo "🧹 Cleaning temporary operational files..."
    rm -rf /tmp/jmeter-unpacked-* 2>/dev/null || true
}
# Trap covers standard exits (including set -e trips) and sudden process terminations
trap cleanup EXIT

# --- Configuration ---
INSTALL_BASE="/opt"
TARGET_DIR_NAME="apache-jmeter"
INSTALL_DIR="${INSTALL_BASE}/${TARGET_DIR_NAME}"
LAUNCHER_PATH="/usr/share/applications/jmeter.desktop"
SYMLINK_PATH="/usr/local/bin/jmeter"

echo "======================================================"
echo "🔄 Starting JMeter Installation Pipeline [v${SCRIPT_VERSION}]"
echo "⏰ Timestamp: $(date)"
echo "======================================================"

# --- 3. Process Input Argument (Target Tarball Location) ---
ARCHIVE_PATH="${1:-/tmp/apache-jmeter.tgz}"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "❌ Error: JMeter archive not found at: $ARCHIVE_PATH"
    echo "Please download the Binaries (.tgz) package manually first, or specify the path:"
    echo "Usage: sudo $0 /path/to/apache-jmeter-X.X.X.tgz"
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

# --- 6. Robust Active User & XDG Desktop Discovery ---
ACTIVE_USER="${SUDO_USER:-}"

if [[ -z "$ACTIVE_USER" || "$ACTIVE_USER" == "root" ]]; then
    ACTIVE_USER=$(loginctl list-sessions --no-legend | awk '$3!="gdm" && $3!="" {print $3; exit}')
fi

if [[ -z "$ACTIVE_USER" ]]; then
    ACTIVE_USER=$(who | awk '/:0|tty/{print $1; exit}')
fi

DESKTOP_DIR=""
if [[ -n "${ACTIVE_USER:-}" && "$ACTIVE_USER" != "root" ]]; then
    echo "✅ Target Desktop User Detected: $ACTIVE_USER"
    USER_HOME=$(getent passwd "$ACTIVE_USER" | cut -d: -f6)
    
    if command -v runuser >/dev/null 2>&1 && command -v xdg-user-dir &>/dev/null; then
        DESKTOP_DIR=$(runuser -u "$ACTIVE_USER" -- xdg-user-dir DESKTOP 2>/dev/null || echo "")
    fi
    
    if [[ -z "${DESKTOP_DIR:-}" ]]; then
        DESKTOP_DIR="$USER_HOME/Desktop"
    fi
else
    echo "⚠️ Warning: Could not explicitly map active desktop user. Skipping desktop shortcut."
fi

# --- 7. Intelligent Java Environment Handling ---
echo "☕ Checking Java runtime environment status..."
JAVA_MAJOR=0
if command -v java &>/dev/null; then
    JAVA_VERSION_STR=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    if [[ "$JAVA_VERSION_STR" =~ ^1\. ]]; then
        JAVA_MAJOR=$(echo "$JAVA_VERSION_STR" | cut -d. -f2)
    else
        JAVA_MAJOR=$(echo "$JAVA_VERSION_STR" | cut -d. -f1)
    fi
fi

if [[ "$JAVA_MAJOR" -lt 21 ]]; then
    echo "📦 Target version missing or lower than Java 21. Installing openjdk-21-jdk..."
    apt-get install -y openjdk-21-jdk
else
    echo "✓ OpenJDK environment compliant (Detected Major Version: $JAVA_MAJOR)."
fi

# Guarantee core extraction tools availability
if ! command -v tar &>/dev/null; then
    apt-get install -y tar
fi

# --- 8. Comprehensive Legacy/Old Version Evacuation ---
echo "🗑️ Evacuating legacy JMeter structures to guarantee a clean install..."
rm -rf "$INSTALL_DIR"         # Deletes the core program folder
rm -f "$SYMLINK_PATH"        # Wipes old binary shortcut
rm -f "$LAUNCHER_PATH"       # Removes system launcher manifest

if [[ -n "${ACTIVE_USER:-}" && -d "${DESKTOP_DIR:-}" ]]; then
    # Removes previous desktop-level user shortcut if it exists
    rm -f "$DESKTOP_DIR/jmeter.desktop"
fi

# --- 9. Verify Archive Integrity ---
echo "🔎 Checking package integrity..."
if ! tar -tzf "$ARCHIVE_PATH" >/dev/null 2>&1; then
    echo "❌ Error: Target archive is corrupted or not a valid gzipped tarball."
    exit 1
fi
echo "✓ Integrity Verification: Tarball valid."

# --- 10. Extraction & Structural Normalization ---
TEMP_EXTRACT_DIR=$(mktemp -d /tmp/jmeter-unpacked-XXXXXX)

echo "📂 Unpacking payload..."
tar -xzf "$ARCHIVE_PATH" -C "$TEMP_EXTRACT_DIR"

# Locate the actual directory extracted inside the temp path
EXTRACTED_FOLDER=$(find "$TEMP_EXTRACT_DIR" -maxdepth 1 -mindepth 1 -type d | head -n 1)

if [[ -z "$EXTRACTED_FOLDER" ]]; then
    echo "❌ Error: Failed to locate extracted contents."
    exit 1
fi

# Defensive absolute check: Ensure no concurrent process or symlink occupies the path
if [[ -e "$INSTALL_DIR" ]]; then
    echo "⚠️ Warning: Found an existing path at $INSTALL_DIR immediately prior to relocation. Forcing purge..."
    rm -rf "$INSTALL_DIR"
fi

mv "$EXTRACTED_FOLDER" "$INSTALL_DIR"
rm -rf "$TEMP_EXTRACT_DIR"

if [[ ! -f "$INSTALL_DIR/bin/jmeter" ]]; then
    echo "❌ Error: Target JMeter binary '$INSTALL_DIR/bin/jmeter' was not found."
    echo "💡 Invalid package type detected."
    echo "   Ensure you downloaded the 'Binaries' archive (e.g., apache-jmeter-X.X.X.tgz),"
    echo "   and NOT the 'Source' archive."
    exit 1
fi

# --- 11. Offline Icon Configuration ---
# Look for pre-packaged icons within the extracted folder, otherwise use a safe generic fallback.
echo "🎨 Mapping application icon..."
if [[ -f "$INSTALL_DIR/bin/jmeter.png" ]]; then
    ICON_PATH="$INSTALL_DIR/bin/jmeter.png"
elif [[ -f "$INSTALL_DIR/docs/images/jmeter_square.png" ]]; then
    ICON_PATH="$INSTALL_DIR/docs/images/jmeter_square.png"
else
    ICON_PATH="applications-development"
fi
echo "✓ Icon set to: $ICON_PATH"

# --- 12. Granular Permissions Set ---
echo "🔒 Applying system access controls..."
chown -R root:root "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
chmod -R a+rX "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR/bin/jmeter" "$INSTALL_DIR/bin/jmeter.sh"

# --- 13. Construct System Launcher ---
echo "🖥️ Writing system-wide desktop application launcher..."
cat <<EOF > "$LAUNCHER_PATH"
[Desktop Entry]
Version=1.0
Type=Application
Name=Apache JMeter
GenericName=Performance Testing Tool
Comment=Load test functional behavior and measure performance
Icon=$ICON_PATH
Exec=$INSTALL_DIR/bin/jmeter
Terminal=false
StartupNotify=true
Categories=Development;Testing;
Keywords=Performance;Testing;Load;JMeter;
EOF

chmod 644 "$LAUNCHER_PATH"

# --- 14. Direct Path Symlink Integration ---
echo "⚙️ Linking binary executable to $SYMLINK_PATH..."
ln -sf "$INSTALL_DIR/bin/jmeter" "$SYMLINK_PATH"

# --- 15. Copy User Desktop Shortcut ---
if [[ -n "${ACTIVE_USER:-}" && -d "${DESKTOP_DIR:-}" ]]; then
    echo "✨ Dropping desktop shortcut into $DESKTOP_DIR..."
    USER_LAUNCHER="$DESKTOP_DIR/jmeter.desktop"
    
    # Copy, assign owner, and set execution flags atomically
    install -o "$ACTIVE_USER" -m 755 "$LAUNCHER_PATH" "$USER_LAUNCHER"
    
    # Authorize launcher metadata cleanly within GNOME environments via runuser
    if command -v runuser >/dev/null 2>&1 && command -v gio &>/dev/null; then
        runuser -u "$ACTIVE_USER" -- gio set "$USER_LAUNCHER" metadata::trusted true 2>/dev/null || true
    fi
fi

# --- 16. Refresh Application Database ---
if ! command -v update-desktop-database >/dev/null 2>&1; then
    echo "📦 System missing 'desktop-file-utils'. Installing dependencies..."
    apt-get install -y desktop-file-utils
fi

echo "🔄 Updating desktop application database..."
update-desktop-database /usr/share/applications/

# --- 17. Post-Installation Verification Check ---
echo "🩺 Performing structural health validation..."
echo "----------------------------------------"
if [[ -f "$INSTALL_DIR/bin/jmeter" && -f "$LAUNCHER_PATH" && -L "$SYMLINK_PATH" ]]; then
    echo "  ✓ Installation Status: Core verification passed"
else
    echo "  ✗ Installation Status: Failure detected in post-install structure checks"
    exit 1
fi
echo "----------------------------------------"

# --- 18. Standardized Success Summary ---
cat <<EOF

======================================================
 🎉 Apache JMeter installed successfully

 Installation Path:
  $INSTALL_DIR

 Launch Methods:
  • Applications → Apache JMeter
  • Desktop Shortcut (if created)
  • Terminal command: jmeter

 Java:
  OpenJDK 21

 Installer Log:
  $LOG_FILE (Installer v$SCRIPT_VERSION)
======================================================
EOF
