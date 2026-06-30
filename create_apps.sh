#!/bin/bash

# ============================================================
# Script Name : create_apps.sh
# Purpose     : Create /home/apps and assign it to the logged-in
#               employee user on an AD-joined laptop.
#
# Run as:
#   sudo -i
#   ./create_apps.sh
# ============================================================

set -e

APP_DIR="/home/apps"

echo "========================================"
echo " Creating Apps Directory"
echo "========================================"

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Please run this script as root."
    exit 1
fi

# Detect employee user
EMP_USER=$(ls /home | grep -Ev '^(fsuser|root|lost\+found)$' | head -n1)

if [[ -z "$EMP_USER" ]]; then
    echo "ERROR: No employee user found under /home."
    exit 1
fi

# Verify user exists
if ! id "$EMP_USER" &>/dev/null; then
    echo "ERROR: User '$EMP_USER' does not exist."
    exit 1
fi

# Get primary group
EMP_GROUP=$(id -gn "$EMP_USER")

echo "Employee User : $EMP_USER"
echo "Primary Group : $EMP_GROUP"

# Create directory if needed
if [[ ! -d "$APP_DIR" ]]; then
    mkdir -p "$APP_DIR"
    echo "Created directory: $APP_DIR"
else
    echo "Directory already exists."
fi

# Change ownership
chown "$EMP_USER:$EMP_GROUP" "$APP_DIR"

# Set permissions
chmod 755 "$APP_DIR"

echo
echo "========================================"
echo "Completed Successfully"
echo "========================================"
echo "Directory : $APP_DIR"
echo "Owner     : $EMP_USER"
echo "Group     : $EMP_GROUP"
echo "Permission: 755"

ls -ld "$APP_DIR"
