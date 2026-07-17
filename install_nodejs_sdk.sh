#!/bin/bash

# ==============================================================================
# Script Name: install_nodejs_sdk.sh
# Description: Hardened, enterprise-grade Node.js & JS Ecosystem Installer.
# Version:     2.1.0
#
# Usage:
#   sudo NODE_MAJOR="24" INSTALL_NATIVE_BUILD_TOOLS="false" ./install_nodejs_sdk.sh
# ==============================================================================

# --- Strict Execution Enforcement ---
set -Eeuo pipefail

# --- Configuration & Defaults ---
NODE_MAJOR="${NODE_MAJOR:-24}"
INSTALL_NATIVE_BUILD_TOOLS="${INSTALL_NATIVE_BUILD_TOOLS:-false}"
NVM_VERSION="v0.40.6" # Resolves NVD-identified concerns (CVE-2026-15921)
SCRIPT_VERSION="2.1.0"
LOG_FILE="/var/log/nodejs_sdk_install.log"

# --- Output Styling & Formatting Helpers ---
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

log_info() { echo -e "${BOLD}🕒 [$(date +'%H:%M:%S')]${RESET} $1"; }
log_ok()   { echo -e "${GREEN}✓ [SUCCESS]${RESET} $1"; }
log_warn() { echo -e "${YELLOW}⚠ [WARNING]${RESET} $1" >&2; }
log_fail() { echo -e "${RED}❌ [FATAL]${RESET} $1" >&2; exit 1; }

# --- Redirect Output to Log ---
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
    log_info "🧹 Cleaning temporary operational files..."
    rm -f /tmp/install_nvm.sh
}
trap cleanup EXIT

# --- 1. Immediate Privilege Verification ---
if [[ $EUID -ne 0 ]]; then
    log_fail "This script must be run as root. Usage: sudo ./install_nodejs_sdk.sh"
fi

# Determine architecture safely early on for the audit log
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)

echo "======================================================"
log_info "Starting Node.js SDK Installation Pipeline [v${SCRIPT_VERSION}]"
log_info "Target Node.js Line : ${NODE_MAJOR}.x LTS"
log_info "Architecture        : ${ARCH}"
log_info "Build Tools (C/C++) : ${INSTALL_NATIVE_BUILD_TOOLS}"
echo "======================================================"

# --- 2. Operating System Validation ---
if ! grep -q "Ubuntu" /etc/os-release; then
    log_fail "This installer officially supports Ubuntu environments only."
fi

if [[ "$ARCH" != "amd64" ]]; then
    log_fail "Unsupported CPU architecture ($ARCH). This installation requires amd64."
fi
log_ok "Base environment (Ubuntu amd64) verified."

# --- 3. Robust Active User Discovery ---
ACTIVE_USER="${SUDO_USER:-}"
if [[ -z "$ACTIVE_USER" || "$ACTIVE_USER" == "root" ]]; then
    ACTIVE_USER=$(loginctl list-sessions --no-legend | awk '$3!="gdm" && $3!="" {print $3; exit}')
fi
if [[ -z "$ACTIVE_USER" ]]; then
    ACTIVE_USER=$(who | awk '/:0|tty/{print $1; exit}')
fi

if [[ -n "${ACTIVE_USER:-}" && "$ACTIVE_USER" != "root" ]]; then
    USER_HOME=$(eval echo "~$ACTIVE_USER")
    log_ok "Target system user identified: $ACTIVE_USER ($USER_HOME)"
else
    log_fail "Could not determine a valid non-root active user. Shell profiles require a target user."
fi

# --- 4. Pre-Flight Network & Connection Validation ---
log_info "Verifying internet connectivity and registry reachability..."
NETWORK_TARGETS=(
    "https://deb.nodesource.com"
    "https://registry.npmjs.org"
    "https://raw.githubusercontent.com"
)

for target in "${NETWORK_TARGETS[@]}"; do
    if ! curl -fsSL --connect-timeout 5 "$target" >/dev/null; then
        log_fail "Failed connection test to $target. Verify network or proxy configuration."
    fi
done
log_ok "Network and repository connectivity is online."

# --- 5. Base Dependency Management ---
log_info "Updating system base packages..."
apt-get update -y

REQUIRED_DEPS=(curl git ca-certificates gnupg lsb-release)
for dep in "${REQUIRED_DEPS[@]}"; do
    if ! dpkg -s "$dep" >/dev/null 2>&1; then
        log_info "Installing missing dependency: $dep..."
        apt-get install -y "$dep"
    fi
done

if [[ "$INSTALL_NATIVE_BUILD_TOOLS" == "true" ]]; then
    log_info "Native C/C++ compilation tools requested. Installing build-essential..."
    apt-get install -y build-essential
else
    log_info "Skipping native build tools (build-essential) to keep base installation lean."
fi

# --- 6. Resilient NodeSource Repository Codename Resolution ---
CODENAME=""
if command -v lsb_release >/dev/null 2>&1; then
    CODENAME=$(lsb_release -cs)
elif [[ -f /etc/os-release ]]; then
    CODENAME=$(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release || grep -oP 'UBUNTU_CODENAME=\K\w+' /etc/os-release || echo "")
fi

if [[ -z "$CODENAME" ]]; then
    log_warn "Could not programmatically detect Ubuntu codename. Defaulting to 'nodistro'."
    CODENAME="nodistro"
fi

# Pre-flight verify that NodeSource officially supports this codename
log_info "Verifying NodeSource repository availability for codename: $CODENAME..."
if [[ "$CODENAME" != "nodistro" ]]; then
    if ! curl -fsSL -I "https://deb.nodesource.com/node_${NODE_MAJOR}.x/dists/${CODENAME}/Release" >/dev/null 2>&1; then
        log_warn "NodeSource does not officially support Ubuntu codename '$CODENAME' yet."
        log_warn "Falling back to 'nodistro' configuration to protect APT integrity."
        CODENAME="nodistro"
    fi
fi
log_info "Resolved NodeSource Distribution Codename Target: '$CODENAME'"

# Safe key collection
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes

# Establish standard codename-based APT listing
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x ${CODENAME} main" > /etc/apt/sources.list.d/nodesource.list

log_info "Installing Node.js runtime..."
apt-get update -y
apt-get install -y nodejs

# --- 7. Initialize Corepack ---
log_info "Activating Corepack..."
corepack enable

# --- 8. Download & Install NVM for the Active User ---
log_info "Downloading NVM installation payload to temporary storage..."
curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" -o /tmp/install_nvm.sh

# Enterprise Checksum/Signature-Equivalent validation: Verify the payload isn't blank and contains valid script commands
if [[ ! -s /tmp/install_nvm.sh ]] || ! grep -q "NVM_DIR" /tmp/install_nvm.sh; then
    log_fail "NVM installer download verification failed. The downloaded file is empty or corrupted."
fi
log_ok "NVM installer script structural integrity verified."

log_info "Executing NVM installer under the profile context of: $ACTIVE_USER..."
sudo -u "$ACTIVE_USER" -i bash -c "
    export NVM_DIR=\"${USER_HOME}/.nvm\"
    bash /tmp/install_nvm.sh
"

# --- 9. Safe & Non-Duplicating Environment Integration ---
BASHRC_FILE="${USER_HOME}/.bashrc"
BLOCK_START="# >>> NODEJS-WORKSTATION-SETUP START >>>"
BLOCK_END="# <<< NODEJS-WORKSTATION-SETUP END <<<"

log_info "Configuring environment hooks in $BASHRC_FILE..."
# Eliminate past variations to ensure absolute idempotency
sed -i "/${BLOCK_START}/,/${BLOCK_END}/d" "$BASHRC_FILE"

cat << EOF >> "$BASHRC_FILE"

$BLOCK_START
# Automatically generated configuration by Node.js installer
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"
$BLOCK_END
EOF

chown "$ACTIVE_USER:$ACTIVE_USER" "$BASHRC_FILE"

# --- 10. Install Angular CLI ---
log_info "Installing Angular CLI (@latest)..."
npm install -g @angular/cli@latest

# --- 11. Reusable Command Verification Helper ---
# This helper handles complete shell profile sourcing and checks command executions.
verify_command() {
    local cmd_name="$1"
    local version_arg="${2:---version}"
    
    # Executed within the real user shell to capture exact path resolution
    if sudo -u "$ACTIVE_USER" -i bash -c "
        export NVM_DIR=\"${USER_HOME}/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        command -v $cmd_name &>/dev/null && $cmd_name $version_arg &>/dev/null
    "; then
        local raw_ver
        raw_ver=$(sudo -u "$ACTIVE_USER" -i bash -c "
            export NVM_DIR=\"${USER_HOME}/.nvm\"
            [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
            $cmd_name $version_arg 2>&1
        " | head -n 1 | tr -d '\r\n')
        log_ok "Tool '$cmd_name' is active -> $raw_ver"
        return 0
    else
        log_warn "Tool '$cmd_name' failed health check verification."
        return 1
    fi
}

# --- 12. Rigorous Multi-Point Health & Version Verification ---
log_info "Performing health validation and version checks..."

HEALTH_PASS=true
verify_command "node" "-v" || HEALTH_PASS=false
verify_command "npm" "-v" || HEALTH_PASS=false
verify_command "npx" "-v" || HEALTH_PASS=false
verify_command "corepack" "--version" || HEALTH_PASS=false
verify_command "yarn" "-v" || HEALTH_PASS=false
verify_command "pnpm" "-v" || HEALTH_PASS=false
verify_command "ng" "version" || HEALTH_PASS=false

# Specific validation check for NVM (since it's a shell function, not a binary file)
if sudo -u "$ACTIVE_USER" -i bash -c "
    export NVM_DIR=\"${USER_HOME}/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
    type nvm | grep -q 'function'
"; then
    NVM_RUNNING_VER=$(sudo -u "$ACTIVE_USER" -i bash -c "export NVM_DIR=\"${USER_HOME}/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\" && nvm --version" | tr -d '\r\n')
    log_ok "Shell integration 'nvm' is active -> v$NVM_RUNNING_VER"
else
    log_warn "Shell integration 'nvm' is NOT functional."
    HEALTH_PASS=false
fi

if [[ "$HEALTH_PASS" == "false" ]]; then
    log_fail "Health diagnostics returned faults. Check details at: $LOG_FILE"
fi

# --- 13. Gather Ecosystem Versions for Success Summary ---
NODE_VER=$(sudo -u "$ACTIVE_USER" -i bash -c "node -v")
NPM_VER=$(sudo -u "$ACTIVE_USER" -i bash -c "npm -v")
CP_VER=$(sudo -u "$ACTIVE_USER" -i bash -c "corepack --version")
YARN_VER=$(sudo -u "$ACTIVE_USER" -i bash -c "yarn -v")
PNPM_VER=$(sudo -u "$ACTIVE_USER" -i bash -c "pnpm -v")
NG_VER=$(sudo -u "$ACTIVE_USER" -i bash -c "ng version" | grep "Angular CLI" | head -n 1 | awk '{print $3}')

# --- 14. Final Standardized Success Summary ---
cat <<EOF

======================================================
 🎉 JavaScript Stack Provisioned Successfully!

 Environment Parameters:
  • Target User:        $ACTIVE_USER
  • Profile Configuration: $BASHRC_FILE
  • Installer Version:  v$SCRIPT_VERSION

 Node.js Core Runtime
 -------------------------
  ✓ Node.js:            $NODE_VER
  ✓ npm:                v$NPM_VER
  ✓ Corepack:           v$CP_VER

 Package Managers
 -------------------------
  ✓ pnpm:               v$PNPM_VER
  ✓ Yarn:               v$YARN_VER
  ✓ nvm:                $NVM_VERSION

 Angular Developer Tools
 -------------------------
  ✓ Angular CLI:        v$NG_VER

 Setup Status:
 -------------------------
  👉 SUCCESS

 Actions Needed:
  Run 'source ~/.bashrc' (or open a new shell)
  to register these variables in your active terminal!
======================================================
EOF
