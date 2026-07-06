#!/bin/bash

set -e

DNS1="192.168.16.122"
DNS2="192.168.16.184"
DNS3="8.8.8.8"

echo "===================================="
echo "Configuring DNS..."
echo "===================================="

# Detect systemd-resolved
if systemctl is-active --quiet systemd-resolved; then
    echo "Detected systemd-resolved"

    mkdir -p /etc/systemd/resolved.conf.d

    cat >/etc/systemd/resolved.conf.d/finsurge-dns.conf <<EOF
[Resolve]
DNS=$DNS1 $DNS2 $DNS3
FallbackDNS=8.8.4.4
EOF

    systemctl restart systemd-resolved

    echo "DNS configured successfully."
    exit 0
fi

# Detect NetworkManager
if command -v nmcli >/dev/null 2>&1; then

    CONNECTION=$(nmcli -t -f NAME connection show --active | head -1)

    if [ -n "$CONNECTION" ]; then

        echo "Detected NetworkManager"

        nmcli connection modify "$CONNECTION" ipv4.ignore-auto-dns yes
        nmcli connection modify "$CONNECTION" ipv4.dns "$DNS1 $DNS2 $DNS3"
        nmcli connection up "$CONNECTION"

        echo "DNS configured successfully."
        exit 0
    fi
fi

echo "Legacy DNS configuration..."

rm -f /etc/resolv.conf

cat >/etc/resolv.conf <<EOF
nameserver $DNS1
nameserver $DNS2
nameserver $DNS3
EOF

echo "DNS configured."
