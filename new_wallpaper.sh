#!/bin/bash

set -e

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
    echo "Run this script using sudo."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_IMAGE="$SCRIPT_DIR/pic.jpg"

DEST_DIR="/usr/share/backgrounds/company"
DEST_IMAGE="$DEST_DIR/pic.jpg"

echo "Installing wallpaper..."

mkdir -p "$DEST_DIR"
cp "$SOURCE_IMAGE" "$DEST_IMAGE"
chmod 644 "$DEST_IMAGE"

#########################################
# Default wallpaper for all future users
#########################################

mkdir -p /etc/dconf/db/local.d

cat >/etc/dconf/db/local.d/01-company-wallpaper <<EOF
[org/gnome/desktop/background]
picture-uri='file://$DEST_IMAGE'
picture-uri-dark='file://$DEST_IMAGE'
EOF

#########################################
# Lock wallpaper (optional)
#########################################

mkdir -p /etc/dconf/db/local.d/locks

echo "/org/gnome/desktop/background/picture-uri" \
> /etc/dconf/db/local.d/locks/background

echo "/org/gnome/desktop/background/picture-uri-dark" \
>> /etc/dconf/db/local.d/locks/background

dconf update

#########################################
# Apply to existing users
#########################################

echo ""
echo "Updating existing users..."

for HOME_DIR in /home/*; do

    USERNAME=$(basename "$HOME_DIR")

    if id "$USERNAME" &>/dev/null; then

        USER_UID=$(id -u "$USERNAME")

        sudo -u "$USERNAME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
        gsettings set org.gnome.desktop.background picture-uri "file://$DEST_IMAGE" 2>/dev/null || true

        sudo -u "$USERNAME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
        gsettings set org.gnome.desktop.background picture-uri-dark "file://$DEST_IMAGE" 2>/dev/null || true

        echo "Updated $USERNAME"

    fi

done

echo ""
echo "Wallpaper installation completed."
