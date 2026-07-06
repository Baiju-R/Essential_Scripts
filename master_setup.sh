#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo " FinSurge Ubuntu Configuration"
echo "=============================================="

run_script() {
    local script="$1"

    echo
    echo "----------------------------------------------"
    echo "Running: $script"
    echo "----------------------------------------------"

    if [ ! -f "$SCRIPT_DIR/$script" ]; then
        echo "ERROR: $script not found."
        exit 1
    fi

    chmod +x "$SCRIPT_DIR/$script"
    bash "$SCRIPT_DIR/$script"

    echo "✓ Completed: $script"
}

#################################################
# Execute scripts in required order
#################################################

run_script dns.sh

run_script ad.sh

run_script wifi_for_all_users.sh

run_script firefox.sh

run_script new_wallpaper.sh

#################################################
# Seqrite Installation
#################################################

echo
echo "=============================================="
echo "Seqrite installation requires Administrator privileges."
echo "You may be prompted for your password."
echo "=============================================="

chmod +x "$SCRIPT_DIR/install_seqrite.sh"

sudo bash "$SCRIPT_DIR/install_seqrite.sh"

echo
echo "=============================================="
echo "All scripts executed successfully."
echo "=============================================="
