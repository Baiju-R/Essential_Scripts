#!/bin/bash

# ==============================================================================
# Script Name: install_eclipse.sh
# Description: Hardened, enterprise-ready non-interactive Eclipse installer.
# Version:     1.0.0

# https://www.eclipse.org/downloads/packages/
# Download one of these Linux x86_64 .tar.gz packages:
# Eclipse IDE for Java Developers (recommended)
# eclipse-java-2026-06-R-linux-gtk-x86_64.tar.gz
#
# Prerequisites:
#   • Run as root (sudo)
#   • Package index must already be updated (apt-get update)
#   • Eclipse IDE archive must already be downloaded
#
# Usage:
#   chmod +x install_eclipse.sh
#   sudo ./install_eclipse.sh /path/to/eclipse-java-*.tar.gz
#
# If no archive path is supplied, the script expects:
#   /tmp/eclipse.tar.gz
# ==============================================================================

# --- Strict Execution Enforcement ---
set -Eeuo pipefail

# --- 1. Immediate Root Privilege Verification ---
# Checked BEFORE any file descriptors or logging layers are instantiated
if [[ $EUID -ne 0 ]]; then
    echo "❌ Error: This script must be run as root."
    echo "Usage: sudo $0 [/path/to/archive.tar.gz]"
    exit 1
fi

# --- 2. Logging & Version Infrastructure ---
SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/eclipse_install.log"
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
    rm -rf /tmp/eclipse-unpacked-* 2>/dev/null || true
}
# Trap covers standard exits (including set -e trips) and sudden process terminations
trap cleanup EXIT

# --- Configuration ---
INSTALL_DIR="/opt/eclipse"
LAUNCHER_PATH="/usr/share/applications/eclipse.desktop"
SYMLINK_PATH="/usr/local/bin/eclipse"

echo "======================================================"
echo "🔄 Starting Eclipse Installation Pipeline [v${SCRIPT_VERSION}]"
echo "⏰ Timestamp: $(date)"
echo "======================================================"

# --- 3. Process Input Argument (Target Tarball Location) ---
ARCHIVE_PATH="${1:-/tmp/eclipse.tar.gz}"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "❌ Error: Eclipse archive not found at: $ARCHIVE_PATH"
    echo "Please download the archive manually first, or specify the path:"
    echo "Usage: sudo $0 /path/to/your/eclipse-package.tar.gz"
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

# Guarantee core extraction tool availability
if ! command -v tar &>/dev/null; then
    apt-get install -y tar
fi

# --- 8. Evacuate Stale Extraction Tracks Safely ---
echo "🗑️ Clearing legacy installation paths..."
rm -rf "$INSTALL_DIR"

# --- 9. Verify Archive Integrity ---
echo "🔎 Checking package integrity..."
if ! tar -tzf "$ARCHIVE_PATH" >/dev/null 2>&1; then
    echo "❌ Error: Target archive is corrupted or not a valid gzipped tarball."
    exit 1
fi
echo "✓ Integrity Verification: Tarball valid."

# --- 10. Extraction & Structural Validation ---
echo "📂 Unpacking payload to /opt..."
if ! tar -xzf "$ARCHIVE_PATH" -C /opt; then
    echo "❌ Error: Extraction pipeline failure."
    exit 1
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "❌ Error: Target Eclipse root directory '$INSTALL_DIR' was not created during extraction."
    echo "💡 Invalid Eclipse package detected."
    echo "   Expected the standalone Eclipse IDE archive (e.g., eclipse-java-*.tar.gz),"
    echo "   not the interactive Eclipse Installer stub (eclipse-inst-linux64.tar.gz)."
    exit 1
fi

if [[ ! -x "$INSTALL_DIR/eclipse" ]]; then
    echo "❌ Error: Eclipse executable binary not found or not executable at '$INSTALL_DIR/eclipse'."
    echo "   The package structure may have changed unexpectedly."
    exit 1
fi

# --- 11. Optional Asset Sanity Check ---
if [[ ! -f "$INSTALL_DIR/icon.xpm" ]]; then
    echo "⚠️ Warning: Eclipse desktop icon asset '$INSTALL_DIR/icon.xpm' is missing."
    echo "   The launcher will still work, but the application icon may display as a fallback placeholder."
fi

# --- 12. Granular Permissions Set (Preserving Internal Execution Flags) ---
echo "🔒 Applying system access controls..."
chown -R root:root "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
# a+rX ensures read access everywhere, but only sets execute bits on directories and existing executables
chmod -R a+rX "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR/eclipse"

# --- 13. Construct System Launcher ---
echo "🖥️ Writing system-wide desktop application launcher..."
cat <<EOF > "$LAUNCHER_PATH"
[Desktop Entry]
Version=1.0
Type=Application
Name=Eclipse IDE
GenericName=Java IDE
Comment=Eclipse Integrated Development Environment
Icon=$INSTALL_DIR/icon.xpm
Exec=$INSTALL_DIR/eclipse
Terminal=false
StartupNotify=true
Categories=Development;IDE;Java;
Keywords=Java;IDE;Development;
StartupWMClass=eclipse
EOF

chmod 644 "$LAUNCHER_PATH"

# --- 14. Direct Path Symlink Integration ---
echo "⚙️ Linking binary executable to $SYMLINK_PATH..."
ln -sf "$INSTALL_DIR/eclipse" "$SYMLINK_PATH"

# --- 15. Copy User Desktop Shortcut ---
if [[ -n "${ACTIVE_USER:-}" && -d "${DESKTOP_DIR:-}" ]]; then
    echo "✨ Dropping desktop shortcut into $DESKTOP_DIR..."
    USER_LAUNCHER="$DESKTOP_DIR/eclipse.desktop"
    
    # Use 'install' to copy, assign owner, and set execution flags atomically.
    install -o "$ACTIVE_USER" -m 755 "$LAUNCHER_PATH" "$USER_LAUNCHER"
    
    # Authorize launcher metadata cleanly within GNOME environments via runuser if tool is available
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
if [[ -x "$INSTALL_DIR/eclipse" && -f "$LAUNCHER_PATH" && -L "$SYMLINK_PATH" ]]; then
    echo "  ✓ Installation Status: Core verification passed"
else
    echo "  ✗ Installation Status: Failure detected in post-install structure checks"
    exit 1
fi
echo "----------------------------------------"

# --- 18. Standardized Success Summary ---
cat <<EOF

======================================================
 🎉 Eclipse IDE installed successfully

 Installation Path:
  $INSTALL_DIR

 Launch Methods:
  • Applications → Eclipse IDE
  • Desktop Shortcut (if created)
  • Terminal command: eclipse

 Java:
  OpenJDK 21

 Installer Log:
  $LOG_FILE (Installer v$SCRIPT_VERSION)
======================================================
EOF
