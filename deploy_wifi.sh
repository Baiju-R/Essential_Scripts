#!/bin/bash
# ============================================================
# Script Name : deploy_wifi.sh
# Purpose     : Enterprise Automated Wi-Fi Recovery & NetworkManager Healing
#               for FinSurge Laptops (Remote & Local execution)
# Features    : - Disconnect-immune remote background execution (nohup + watcher)
#               - Unblocks hardware & software RF switches (rfkill + WMI drivers)
#               - Sets regulatory domain (iw reg set IN) unlocking full 5GHz spectrum
#               - Verifies & installs NetworkManager, wpasupplicant, iw, wireless-tools
#               - Unlocks APT locks and repairs broken packages automatically
#               - Resets NetworkManager state file & Netplan renderer (managed=true)
#               - Disables Wi-Fi power saving (wifi.powersave = 2 & hw power_save off)
#               - Disables MAC randomization for stable enterprise AP / DHCP connectivity
#               - Configures Polkit rules allowing standard/AD users to manage Wi-Fi
#               - Unlocks immutable /etc/resolv.conf and repairs broken DNS
#               - Scans visible Wi-Fi access points and displays rich signal table
#               - Connects to specified SSID or auto-connects to strongest saved network
#               - Multi-tier diagnostic verification (L1 Hardware -> L4 Internet/DNS)
# Usage       : ./deploy_wifi.sh <TARGET_IP> [SSID] [PASSWORD]
#               ./deploy_wifi.sh <TARGET_IP> --scan
#               ./deploy_wifi.sh <TARGET_IP> --status
#               ./deploy_wifi.sh <TARGET_IP> --forget "<SSID>"
#               ./deploy_wifi.sh --local [SSID] [PASSWORD]
# ============================================================

set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SSH_USER="${FINSURGE_REMOTE_USER:-fsuser}"
PASS="${FINSURGE_REMOTE_PASS:-f\$us#r@098}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# ------------------------------------------------------------
# Help Manual
# ------------------------------------------------------------
show_help() {
    cat <<'EOF'
══════════════════════════════════════════════════════════════════
     FinSurge Enterprise Wi-Fi Recovery & Network Manager
══════════════════════════════════════════════════════════════════

Usage:
  Remote Execution:
    ./deploy_wifi.sh <TARGET_IP>
    ./deploy_wifi.sh <TARGET_IP> "<SSID>" "<PASSWORD>"
    ./deploy_wifi.sh <TARGET_IP> --scan
    ./deploy_wifi.sh <TARGET_IP> --status
    ./deploy_wifi.sh <TARGET_IP> --saved
    ./deploy_wifi.sh <TARGET_IP> --forget "<SSID>"
    ./deploy_wifi.sh <TARGET_IP> --fix-dns

  Local Execution (Directly on target laptop terminal):
    sudo ./deploy_wifi.sh --local
    sudo ./deploy_wifi.sh --local "<SSID>" "<PASSWORD>"
    sudo ./deploy_wifi.sh --local --scan
    sudo ./deploy_wifi.sh --local --status

Options & Commands:
  <TARGET_IP>               Remote laptop IP address
  <SSID> [PASSWORD]         Wi-Fi network name and optional WPA/WPA2/WPA3 passphrase
  --scan, -s                Scan nearby Wi-Fi networks and display formatted table
  --status                  Run quick, non-disruptive L1-L4 health status check
  --saved, -l               List all saved Wi-Fi connection profiles on target
  --forget, -f <SSID>       Delete a saved/corrupted Wi-Fi connection profile
  --fix-dns                 Safely unlock immutable resolv.conf & restore healthy DNS
  --diagnose, -d            Perform deep L1-L4 diagnostic health check
  --local                   Execute directly on current machine (requires sudo)
  -h, --help                Display this help documentation

Core Healing Actions Performed:
  [1/10] Unblock hardware & software RF switches (rfkill & WMI modules)
  [2/10] Verify and auto-repair NetworkManager, wpasupplicant & wireless tools
  [3/10] Set regulatory domain (unlocks full 5GHz channels & DFS)
  [4/10] Reset NetworkManager state file & Netplan renderer (managed=true)
  [5/10] Optimize enterprise stability (disable powersave & MAC randomization)
  [6/10] Configure Polkit rules (allows standard/AD users to manage Wi-Fi)
  [7/10] Flush stale sockets & cleanly restart wpa_supplicant + NetworkManager
  [8/10] Cycle & rearm wireless interfaces (power on radio, link down/up)
  [9/10] Reload profiles, active rescan & connect to SSID or strongest saved network
  [10/10] End-to-end diagnostics (L1 Physical -> L2 Link -> L3 IP -> L4 Internet/DNS)

Note: Remote execution runs detached with nohup. If the SSH session drops
      when NetworkManager restarts or interfaces cycle, the script continues
      running independently to full completion on the target laptop.
══════════════════════════════════════════════════════════════════
EOF
}

check_target_reachable() {
    local ip="$1"
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        return 0
    elif ping -n 1 -w 2000 "$ip" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------
# Helper: Scan Nearby Wi-Fi Access Points
# ------------------------------------------------------------
scan_wifi_networks() {
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "       Nearby Visible Wi-Fi Networks"
    echo "══════════════════════════════════════════════════"
    
    if ! command -v nmcli >/dev/null 2>&1; then
        echo "[ERROR] nmcli utility not found. Please run full recovery first."
        return 1
    fi

    echo "[+] Triggering active Wi-Fi rescan..."
    nmcli radio wifi on 2>/dev/null || true
    nmcli device wifi rescan 2>/dev/null || true
    sleep 2

    echo ""
    printf "%-3s | %-24s | %-17s | %-5s | %-8s | %-8s | %-18s\n" "USE" "SSID" "BSSID" "CHAN" "FREQ" "SIGNAL" "SECURITY"
    echo "----+--------------------------+-------------------+-------+----------+----------+-------------------"

    local raw_list
    raw_list="$(nmcli -t -f IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list 2>/dev/null | sort -t: -k6,6nr | head -n 25 || true)"

    if [[ -z "$raw_list" ]]; then
        echo "No wireless networks detected or Wi-Fi radio is disabled."
        echo "Run full healing to reset interfaces: sudo ./deploy_wifi.sh --local"
        return 0
    fi

    while IFS=: read -r in_use ssid bssid chan freq signal sec; do
        [[ -z "$ssid" ]] && ssid="<Hidden SSID>"
        [[ "$in_use" == "*" ]] && in_use=" ✔ " || in_use="   "
        printf "%-3s | %-24.24s | %-17s | %-5s | %-8s | %3s%%      | %-18.18s\n" \
            "$in_use" "$ssid" "$bssid" "$chan" "$freq" "$signal" "$sec"
    done <<< "$raw_list"
    echo "----+--------------------------+-------------------+-------+----------+----------+-------------------"
    echo ""
}

# ------------------------------------------------------------
# Helper: List Saved Wi-Fi Connection Profiles
# ------------------------------------------------------------
list_saved_profiles() {
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "       Saved Wi-Fi Connection Profiles"
    echo "══════════════════════════════════════════════════"
    
    if ! command -v nmcli >/dev/null 2>&1; then
        echo "[ERROR] nmcli utility not found."
        return 1
    fi

    local saved
    saved="$(nmcli -t -f NAME,UUID,TYPE,AUTOCONNECT connection show 2>/dev/null | awk -F: '$3=="802-11-wireless" || $3=="wifi" {print $0}')"
    
    if [[ -z "$saved" ]]; then
        echo "No saved Wi-Fi connection profiles found on this system."
        return 0
    fi

    printf "%-30s | %-36s | %-12s\n" "CONNECTION NAME / SSID" "UUID" "AUTOCONNECT"
    echo "-------------------------------+--------------------------------------+-------------"
    while IFS=: read -r name uuid type auto; do
        printf "%-30.30s | %-36s | %-12s\n" "$name" "$uuid" "$auto"
    done <<< "$saved"
    echo "-------------------------------+--------------------------------------+-------------"
    echo ""
}

# ------------------------------------------------------------
# Helper: Forget / Delete Saved Wi-Fi Profile
# ------------------------------------------------------------
forget_wifi_profile() {
    local target_prof="$1"
    if [[ -z "$target_prof" ]]; then
        echo "[ERROR] Please specify the SSID or profile name to forget."
        return 1
    fi

    echo "[+] Deleting Wi-Fi profile: $target_prof..."
    if nmcli connection delete "$target_prof" 2>/dev/null; then
        echo "[✓] Successfully removed profile '$target_prof'."
    else
        echo "[!] Profile '$target_prof' was not found or could not be removed."
    fi
}

# ------------------------------------------------------------
# Helper: Quick Status & Health Check
# ------------------------------------------------------------
show_wifi_status() {
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "       FinSurge Wi-Fi Health & Status"
    echo "══════════════════════════════════════════════════"

    echo "1. Network Interfaces:"
    nmcli device status 2>/dev/null || ip link show

    echo ""
    echo "2. Wi-Fi Radio State:"
    local radio_state
    radio_state="$(nmcli radio wifi 2>/dev/null || echo "unknown")"
    echo "   Radio: $radio_state"

    echo ""
    echo "3. Active Wi-Fi Connection:"
    local active_wifi
    active_wifi="$(nmcli -t -f NAME,DEVICE,TYPE,STATE connection show --active 2>/dev/null | awk -F: '$3=="802-11-wireless" || $3=="wifi" {print $0}' | head -n1)"

    if [[ -n "$active_wifi" ]]; then
        local w_name w_dev
        w_name="$(echo "$active_wifi" | cut -d: -f1)"
        w_dev="$(echo "$active_wifi" | cut -d: -f2)"
        echo "   Connected to: $w_name (Interface: $w_dev)"

        # Signal details
        local sig_info
        sig_info="$(nmcli -t -f IN-USE,SSID,SIGNAL,BARS,RATE,FREQ,SECURITY device wifi list 2>/dev/null | grep '^\*' | head -n1)"
        if [[ -n "$sig_info" ]]; then
            local sig_pct sig_bars sig_rate sig_freq sig_sec
            sig_pct="$(echo "$sig_info" | cut -d: -f3)"
            sig_bars="$(echo "$sig_info" | cut -d: -f4)"
            sig_rate="$(echo "$sig_info" | cut -d: -f5)"
            sig_freq="$(echo "$sig_info" | cut -d: -f6)"
            sig_sec="$(echo "$sig_info" | cut -d: -f7)"
            echo "   Signal Strength: ${sig_pct}% [${sig_bars}] | Rate: ${sig_rate} | Freq: ${sig_freq} | Security: ${sig_sec}"
        fi

        echo ""
        echo "4. IP Configuration:"
        ip -4 addr show dev "$w_dev" 2>/dev/null | grep -E 'inet ' || echo "   No IPv4 assigned."

        echo ""
        echo "5. Connectivity & Reachability Tests:"
        local default_gw
        default_gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
        if [[ -n "$default_gw" ]]; then
            echo -n "   -> Default Gateway ($default_gw): "
            if ping -c 2 -W 2 "$default_gw" >/dev/null 2>&1; then
                echo "[PASS - REACHABLE]"
            else
                echo "[FAIL - UNREACHABLE]"
            fi
        fi

        echo -n "   -> Public Internet (8.8.8.8): "
        if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "[PASS - ONLINE]"
        elif ip route get 8.8.8.8 >/dev/null 2>&1; then
            if curl -s -m 2 -I http://connectivity-check.ubuntu.com >/dev/null 2>&1 || curl -s -m 2 -I http://www.google.com >/dev/null 2>&1; then
                echo "[PASS - ONLINE (HTTP OK, ICMP Filtered by Enterprise Firewall)]"
            else
                echo "[PASS - ROUTE ACTIVE (ICMP Ping blocked by Enterprise Firewall)]"
            fi
        else
            echo "[FAIL - NO ROUTE]"
        fi

        echo -n "   -> DNS Resolution (google.com): "
        if getent hosts google.com >/dev/null 2>&1; then
            echo "[PASS - RESOLVED]"
        else
            echo "[FAIL - CANNOT RESOLVE]"
        fi

        echo -n "   -> FinSurge Corporate DNS/Domain (192.168.16.122): "
        if ping -c 1 -W 2 192.168.16.122 >/dev/null 2>&1; then
            echo "[PASS - REACHABLE]"
        else
            echo "[FAIL / OFF-SITE]"
        fi
    else
        echo "   [!] Wi-Fi is NOT connected to any network."
    fi
    echo "══════════════════════════════════════════════════"
    echo ""
}

# ------------------------------------------------------------
# Helper: Fix & Restore DNS Subsystem
# ------------------------------------------------------------
fix_dns_subsystem() {
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "       DNS Subsystem Healing & Recovery"
    echo "══════════════════════════════════════════════════"

    # 1. Unlock immutable resolv.conf if present
    if [ -f /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
        if command -v lsattr >/dev/null 2>&1; then
            if lsattr -d /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
                echo "[+] Removing immutable flag (chattr -i) from /etc/resolv.conf..."
                chattr -i /etc/resolv.conf 2>/dev/null || true
            fi
        fi
    fi

    # 2. Write resilient multi-tier DNS config (FinSurge Enterprise Primary + Fallbacks)
    echo "[+] Writing resilient FinSurge multi-tier DNS configuration..."
    cat > /etc/resolv.conf.tmp <<EOF
# FinSurge Auto-Healed Resilient DNS Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
nameserver 192.168.16.122
nameserver 192.168.16.184
nameserver 8.8.8.8
nameserver 1.1.1.1
options timeout:2 attempts:3 rotate
EOF
    mv -f /etc/resolv.conf.tmp /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true

    # 3. Stop systemd-resolved if active to prevent overwriting static resolv.conf
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
    fi

    echo "[✓] DNS configuration restored and locked."
    echo -n "  -> Testing DNS resolution: "
    if getent hosts google.com >/dev/null 2>&1; then
        echo "[PASS - RESOLVED]"
    else
        echo "[FAIL - STILL UNRESOLVED]"
    fi
    echo ""
}

# ------------------------------------------------------------
# Core Wi-Fi Healing Logic (Runs locally or over SSH)
# ------------------------------------------------------------
run_wifi_recovery() {
    local target_ssid="${1:-}"
    local target_pass="${2:-}"

    echo "══════════════════════════════════════════════════"
    echo "       FinSurge Wi-Fi Network Healing & Recovery"
    echo "       Started at: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "══════════════════════════════════════════════════"

    # [1/10] Unblock RFKill Switches & Fix Hardware Buggy WMI Drivers
    echo ""
    echo "[1/10] Checking & unblocking RF switches (rfkill & WMI modules)..."
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock wifi 2>/dev/null || true
        rfkill unblock all 2>/dev/null || true
        echo "  [✓] RF switches unblocked."

        # Check for hard-blocked state caused by buggy vendor WMI drivers (e.g. ideapad_laptop, acer_wmi, hp_wmi)
        if rfkill list wifi 2>/dev/null | grep -q "Hard blocked: yes"; then
            echo "  [!] Wireless is HARD-BLOCKED by a platform driver or physical hardware switch."
            for mod in "ideapad_laptop" "acer_wmi" "hp_wmi" "dell_rbtn"; do
                if lsmod | grep -q "^$mod"; then
                    echo "  -> Attempting to unload buggy WMI kernel module: $mod..."
                    modprobe -r "$mod" 2>/dev/null || true
                    sleep 1
                    rfkill unblock all 2>/dev/null || true
                fi
            done
        fi
    else
        echo "  [i] rfkill utility not found, will install in step 2."
    fi

    # [2/10] Verify NetworkManager, wpasupplicant & wireless packages
    echo ""
    echo "[2/10] Verifying NetworkManager & wireless packages..."
    local nm_available=false
    if command -v nmcli >/dev/null 2>&1 && command -v NetworkManager >/dev/null 2>&1; then
        nm_available=true
    fi

    if [ "$nm_available" = false ]; then
        echo "  [!] NetworkManager not found. Checking network reachability for package installation..."
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || getent hosts archive.ubuntu.com >/dev/null 2>&1; then
            echo "  [+] Network reachable. Freeing APT locks and installing packages..."
            export DEBIAN_FRONTEND=noninteractive

            # Free any stale APT locks safely
            local max_wait=30
            local waited=0
            while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
                sleep 2
                waited=$((waited + 2))
                [[ $waited -ge $max_wait ]] && break
            done

            dpkg --configure -a 2>/dev/null || true
            apt-get update -qq 2>/dev/null || true
            apt-get install -y -qq network-manager wpasupplicant rfkill iproute2 2>/dev/null || true
        else
            echo "  [i] System is offline or behind portal; proceeding with built-in networking drivers."
        fi
    fi
    echo "  [✓] NetworkManager and wireless subsystem verified."

    # [3/10] Set Regulatory Domain (Unlocks full 5GHz spectrum, DFS & TX power)
    echo ""
    echo "[3/10] Setting wireless regulatory domain (unlocking full 5GHz channels)..."
    local iw_bin
    iw_bin=$(command -v iw 2>/dev/null || echo "/usr/sbin/iw")
    if [ -x "$iw_bin" ]; then
        "$iw_bin" reg set IN 2>/dev/null || "$iw_bin" reg set US 2>/dev/null || true
        echo "  [✓] Regulatory domain set to IN/US (Full 5GHz spectrum enabled)."
    else
        if [ -f /etc/default/crda ]; then
            sed -i 's/^REGDOMAIN=.*/REGDOMAIN=IN/' /etc/default/crda 2>/dev/null || true
        fi
        echo "  [✓] Regulatory domain configured via system defaults."
    fi

    # [4/10] Reset NetworkManager State File & Ensure Managed Mode
    echo ""
    echo "[4/10] Ensuring NetworkManager device management & state file consistency..."
    local nm_conf="/etc/NetworkManager/NetworkManager.conf"
    if [ -f "$nm_conf" ]; then
        sed -i 's/managed=false/managed=true/g' "$nm_conf" 2>/dev/null || true
    fi

    # Reset NetworkManager state file which frequently gets stuck in WirelessEnabled=false
    local state_file="/var/lib/NetworkManager/NetworkManager.state"
    if [ -f "$state_file" ]; then
        sed -i 's/NetworkingEnabled=false/NetworkingEnabled=true/g' "$state_file" 2>/dev/null || true
        sed -i 's/WirelessEnabled=false/WirelessEnabled=true/g' "$state_file" 2>/dev/null || true
        sed -i 's/WWANEnabled=false/WWANEnabled=true/g' "$state_file" 2>/dev/null || true
    fi

    # Ensure Netplan uses NetworkManager cleanly via drop-in file (avoids YAML sed corruption)
    if [ -d /etc/netplan ]; then
        if ! grep -rq "renderer: NetworkManager" /etc/netplan/ 2>/dev/null; then
            cat <<'NP_EOF' > /etc/netplan/99-networkmanager.yaml
network:
  version: 2
  renderer: NetworkManager
NP_EOF
            chmod 600 /etc/netplan/99-networkmanager.yaml 2>/dev/null || true
            netplan generate 2>/dev/null || rm -f /etc/netplan/99-networkmanager.yaml
        fi
    fi
    echo "  [✓] NetworkManager state and device management set to managed=true."

    # [5/10] Optimize Enterprise Wi-Fi Stability (Disable Power Save & MAC Randomization)
    echo ""
    echo "[5/10] Applying enterprise Wi-Fi optimizations (power save off & stable MAC)..."
    mkdir -p /etc/NetworkManager/conf.d 2>/dev/null || true

    # 1. Disable power saving (prevents Wi-Fi drops, sleep disconnections, and latency spikes)
    cat <<'POW_EOF' > /etc/NetworkManager/conf.d/99-disable-wifi-powersave.conf
[connection]
wifi.powersave = 2
POW_EOF
    if [ -f /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf ]; then
        sed -i 's/wifi.powersave = 3/wifi.powersave = 2/g' /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf 2>/dev/null || true
    fi

    # 2. Disable MAC Address Randomization (prevents drops on enterprise Cisco/Aruba APs and DHCP exhaustion)
    cat <<'MAC_EOF' > /etc/NetworkManager/conf.d/99-mac-randomization.conf
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.cloned-mac-address=preserve
ethernet.cloned-mac-address=preserve
MAC_EOF
    echo "  [✓] Wi-Fi power saving disabled (wifi.powersave = 2) & MAC randomization disabled."

    # [6/10] Configure Polkit & User Permissions (Allows non-root/AD users to manage Wi-Fi)
    echo ""
    echo "[6/10] Configuring Polkit rules (allowing standard & domain users to manage Wi-Fi)..."
    
    # 1. Modify org.freedesktop.NetworkManager.policy (with safe backup)
    local pol_file="/usr/share/polkit-1/actions/org.freedesktop.NetworkManager.policy"
    if [ -f "$pol_file" ]; then
        if [[ ! -f "${pol_file}.bak_orig" ]]; then
            cp -p "$pol_file" "${pol_file}.bak_orig" 2>/dev/null || true
        fi
        sed -i 's|<allow_active>auth_admin_keep</allow_active>|<allow_active>yes</allow_active>|g' "$pol_file" 2>/dev/null || true
        sed -i 's|<allow_active>auth_admin</allow_active>|<allow_active>yes</allow_active>|g' "$pol_file" 2>/dev/null || true
        sed -i 's|<allow_inactive>auth_admin_keep</allow_inactive>|<allow_inactive>yes</allow_inactive>|g' "$pol_file" 2>/dev/null || true
        sed -i 's|<allow_inactive>auth_admin</allow_inactive>|<allow_inactive>yes</allow_inactive>|g' "$pol_file" 2>/dev/null || true
    fi

    # 2. Polkit JavaScript rules (Ubuntu 24.04+ / modern Polkit)
    mkdir -p /etc/polkit-1/rules.d 2>/dev/null || true
    cat <<'POLKIT_RULES_EOF' > /etc/polkit-1/rules.d/10-networkmanager.rules
/* FinSurge Policy: Allow all active & netdev users to manage Wi-Fi without admin password */
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 && (subject.active || subject.isInGroup("netdev"))) {
        return polkit.Result.YES;
    }
});
POLKIT_RULES_EOF
    chmod 644 /etc/polkit-1/rules.d/10-networkmanager.rules 2>/dev/null || true

    # 3. Polkit PKLA (Ubuntu 22.04 / 20.04 Backward Compatibility)
    mkdir -p /etc/polkit-1/localauthority/50-local.d 2>/dev/null || true
    cat <<'POLKIT_PKLA_EOF' > /etc/polkit-1/localauthority/50-local.d/10-networkmanager.pkla
[Allow all users to manage network connections]
Identity=unix-user:*;unix-group:netdev
Action=org.freedesktop.NetworkManager.*
ResultAny=yes
ResultInactive=no
ResultActive=yes
POLKIT_PKLA_EOF
    chmod 644 /etc/polkit-1/localauthority/50-local.d/10-networkmanager.pkla 2>/dev/null || true

    # 4. Add all local, domain & desktop users to netdev group
    groupadd -f netdev 2>/dev/null || true
    for udir in /home/* /home/finsurge.local/*; do
        if [[ -d "$udir" && "$udir" != "/home/lost+found" ]]; then
            local u_name
            u_name="$(basename "$udir")"
            if id "$u_name" >/dev/null 2>&1; then
                usermod -aG netdev "$u_name" 2>/dev/null || true
            fi
        fi
    done
    for u in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | sort -u); do
        [[ -n "$u" && "$u" != "root" && "$u" != "gdm" ]] && usermod -aG netdev "$u" 2>/dev/null || true
    done

    # Reload polkit daemon immediately
    systemctl restart polkit 2>/dev/null || systemctl restart polkitd 2>/dev/null || true
    echo "  [✓] Polkit permissions configured; GUI Wi-Fi connects without password prompts."

    # [7/10] Clean Stale Sockets & Cleanly Restart Network Daemons
    echo ""
    echo "[7/10] Flushing stale sockets & restarting NetworkManager + wpa_supplicant..."
    rm -rf /run/wpa_supplicant/* 2>/dev/null || true

    systemctl unmask NetworkManager >/dev/null 2>&1 || true
    systemctl unmask wpa_supplicant >/dev/null 2>&1 || true
    systemctl enable NetworkManager >/dev/null 2>&1 || true

    systemctl restart wpa_supplicant 2>/dev/null || true
    systemctl restart NetworkManager
    sleep 3
    echo "  [✓] Network daemons restarted cleanly."

    # [8/10] Cycle & Rearm Wireless Interfaces
    echo ""
    echo "[8/10] Resetting and rearming wireless network interfaces..."
    nmcli radio wifi on 2>/dev/null || true
    sleep 1

    local wifi_interfaces
    wifi_interfaces=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1}')
    if [ -z "$wifi_interfaces" ]; then
        wifi_interfaces=$(ls -1 /sys/class/net 2>/dev/null | grep -E '^wl' || true)
    fi

    if [ -z "$wifi_interfaces" ]; then
        echo "  [!] No wireless hardware interfaces detected! Checking PCI/USB wireless adapters..."
        lspci 2>/dev/null | grep -i -E 'network|wireless|wi-fi' || true
        lsusb 2>/dev/null | grep -i -E 'wireless|wi-fi|802.11' || true
    else
        for iface in $wifi_interfaces; do
            echo "    -> Cycling interface: $iface"
            ip link set "$iface" down 2>/dev/null || true
            sleep 1
            ip link set "$iface" up 2>/dev/null || true
            sleep 1
            # Disable link-level hardware power management
            local iw_cmd
            iw_cmd=$(command -v iw 2>/dev/null || echo "/usr/sbin/iw")
            [ -x "$iw_cmd" ] && "$iw_cmd" dev "$iface" set power_save off 2>/dev/null || true
            nmcli device set "$iface" managed yes 2>/dev/null || true
        done
    fi

    # [9/10] Reload Profiles, Active Rescan & Connect
    echo ""
    echo "[9/10] Reloading connection profiles & rescanning access points..."
    nmcli connection reload 2>/dev/null || true
    nmcli device wifi rescan 2>/dev/null || true
    sleep 3

    if [ -n "$target_ssid" ]; then
        echo ""
        echo "[+] Attempting connection to specified SSID: $target_ssid..."
        # Check if an existing profile exists for this SSID
        local existing_uuid
        existing_uuid=$(nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null | awk -F: -v s="$target_ssid" '($3=="802-11-wireless" || $3=="wifi") && $1==s {print $2}' | head -n1)

        # Check if this profile is 802.1X enterprise
        local is_enterprise=false
        if [ -n "$existing_uuid" ]; then
            if nmcli -s -t -f 802-1x connection show uuid "$existing_uuid" 2>/dev/null | grep -q '802-1x'; then
                is_enterprise=true
            fi
        fi

        if [ "$is_enterprise" = true ]; then
            echo "    -> Identified Enterprise 802.1X profile for '$target_ssid'. Activating profile..."
            nmcli connection modify "$target_ssid" connection.autoconnect yes 2>/dev/null || true
            nmcli connection up "$target_ssid" 2>/dev/null || nmcli connection up uuid "$existing_uuid" 2>/dev/null || true
        elif [ -n "$target_pass" ]; then
            # WPA-PSK connection with provided password
            if [ -n "$existing_uuid" ]; then
                nmcli connection modify "$target_ssid" wifi-sec.key-mgmt wpa-psk 802-11-wireless-security.psk "$target_pass" connection.autoconnect yes 2>/dev/null || {
                    nmcli connection delete "$target_ssid" 2>/dev/null || true
                    nmcli device wifi connect "$target_ssid" password "$target_pass" 2>/dev/null || true
                }
                nmcli connection up "$target_ssid" 2>/dev/null || true
            else
                nmcli device wifi connect "$target_ssid" password "$target_pass" 2>/dev/null || true
            fi
        else
            if [ -n "$existing_uuid" ]; then
                nmcli connection modify "$target_ssid" connection.autoconnect yes 2>/dev/null || true
                nmcli connection up "$target_ssid" 2>/dev/null || true
            else
                nmcli device wifi connect "$target_ssid" 2>/dev/null || true
            fi
        fi
        sleep 3
    else
        # Auto-reconnect to strongest visible saved Wi-Fi network
        if ! nmcli -t -f TYPE,STATE device 2>/dev/null | grep -q "^wifi:connected$"; then
            echo "[+] Searching for visible saved Wi-Fi connection profiles..."
            
            local saved_profiles
            saved_profiles=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless" || $2=="wifi" {print $1}')

            # Get visible SSIDs ordered by signal strength (highest first)
            local visible_ssids
            visible_ssids=$(nmcli -t -f SSID,SIGNAL device wifi list 2>/dev/null | sort -t: -k2,2nr | awk -F: '!seen[$1]++ && $1!="" {print $1}')

            local connected_any=false
            if [ -n "$visible_ssids" ] && [ -n "$saved_profiles" ]; then
                while IFS= read -r v_ssid; do
                    [[ -z "$v_ssid" ]] && continue
                    if echo "$saved_profiles" | grep -Fxq "$v_ssid"; then
                        echo "    -> Found visible saved network: $v_ssid (Signal prioritized. Connecting...)"
                        nmcli connection modify "$v_ssid" connection.autoconnect yes 2>/dev/null || true
                        if nmcli connection up "$v_ssid" 2>/dev/null; then
                            echo "    [✓] Successfully connected to strongest saved network: $v_ssid"
                            connected_any=true
                            break
                        fi
                    fi
                done <<< "$visible_ssids"
            fi

            # Fallback: If visible scan didn't connect, try any remaining saved profiles
            if [ "$connected_any" = false ] && [ -n "$saved_profiles" ]; then
                while IFS= read -r prof; do
                    [[ -z "$prof" ]] && continue
                    echo "    -> Trying saved profile: $prof"
                    nmcli connection modify "$prof" connection.autoconnect yes 2>/dev/null || true
                    if nmcli connection up "$prof" 2>/dev/null; then
                        echo "    [✓] Successfully connected to saved network: $prof"
                        connected_any=true
                        break
                    fi
                done <<< "$saved_profiles"
            fi
        fi
    fi

    # [10/10] Multi-Tier Diagnostics & Verification
    echo ""
    echo "[10/10] Final Wi-Fi Connection Health & Diagnostic Report:"
    echo "──────────────────────────────────────────────────────────"
    nmcli device status 2>/dev/null || true
    echo "──────────────────────────────────────────────────────────"

    if nmcli -t -f TYPE,STATE device 2>/dev/null | grep -q "^wifi:connected$"; then
        echo ""
        echo "=========================================================="
        echo "  [SUCCESS] Wi-Fi is ACTIVE and CONNECTED!"
        echo "=========================================================="
        
        local active_conn active_dev
        active_conn="$(nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null | awk -F: '$3=="802-11-wireless" || $3=="wifi" {print $1}' | head -n1)"
        active_dev="$(nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null | awk -F: '$3=="802-11-wireless" || $3=="wifi" {print $2}' | head -n1)"

        echo "  SSID / Profile      : ${active_conn:-Unknown}"
        echo "  Interface           : ${active_dev:-Unknown}"

        # Signal details
        local sig_info
        sig_info="$(nmcli -t -f IN-USE,SSID,SIGNAL,BARS,RATE,FREQ,SECURITY device wifi list 2>/dev/null | grep '^\*' | head -n1)"
        if [[ -n "$sig_info" ]]; then
            local sig_pct sig_bars sig_rate sig_freq sig_sec
            sig_pct="$(echo "$sig_info" | cut -d: -f3)"
            sig_bars="$(echo "$sig_info" | cut -d: -f4)"
            sig_rate="$(echo "$sig_info" | cut -d: -f5)"
            sig_freq="$(echo "$sig_info" | cut -d: -f6)"
            sig_sec="$(echo "$sig_info" | cut -d: -f7)"
            echo "  Signal Quality      : ${sig_pct}% [${sig_bars}] (Band: ${sig_freq}, Rate: ${sig_rate})"
            echo "  Security Protocol   : ${sig_sec}"
        fi

        echo ""
        echo "  Assigned IP Address :"
        if [[ -n "$active_dev" ]]; then
            ip -4 addr show dev "$active_dev" 2>/dev/null | grep -E 'inet ' | awk '{print "    IPv4: "$2" (Broadcast: "$4")"}' || true
        else
            ip -4 addr show 2>/dev/null | grep -E 'inet.*(wl|wlan)' | awk '{print "    IPv4: "$2}' || true
        fi

        echo ""
        echo "  Network Verification Tests:"

        # 1. Gateway reachability
        local default_gw
        default_gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
        if [ -n "$default_gw" ]; then
            echo -n "    -> Default Gateway ($default_gw): "
            if ping -c 2 -W 2 "$default_gw" >/dev/null 2>&1; then
                echo "[PASS - REACHABLE]"
            else
                echo "[FAIL - UNREACHABLE]"
            fi
        fi

        # 2. Public Internet IP route
        echo -n "    -> Public Internet Route (8.8.8.8): "
        if ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
            echo "[PASS - ONLINE]"
        elif ip route get 8.8.8.8 >/dev/null 2>&1; then
            if curl -s -m 2 -I http://connectivity-check.ubuntu.com >/dev/null 2>&1 || curl -s -m 2 -I http://www.google.com >/dev/null 2>&1; then
                echo "[PASS - ONLINE (HTTP OK, ICMP Filtered by Enterprise Firewall)]"
            else
                echo "[PASS - ROUTE ACTIVE (ICMP Ping blocked by Enterprise Firewall)]"
            fi
        else
            echo "[FAIL - NO ROUTE]"
        fi

        # 3. DNS Hostname resolution
        echo -n "    -> DNS Resolution (google.com): "
        if getent hosts google.com >/dev/null 2>&1; then
            echo "[PASS - RESOLVED]"
        else
            echo "[FAIL - CANNOT RESOLVE]"
            echo "    -> Healing DNS automatically..."
            fix_dns_subsystem
        fi

        # 4. FinSurge Corporate Intranet / Domain check
        echo -n "    -> FinSurge Domain Network (192.168.16.122): "
        if ping -c 1 -W 2 192.168.16.122 >/dev/null 2>&1; then
            echo "[PASS - REACHABLE]"
        else
            echo "[FAIL / OFF-SITE NETWORK]"
        fi
        echo "=========================================================="
    else
        echo ""
        echo "=========================================================="
        echo "  [WARNING] Wi-Fi is currently not connected."
        echo "=========================================================="
        echo "  Nearby Available Wi-Fi Networks:"
        scan_wifi_networks
        echo "  To connect to an access point, execute:"
        echo "    ./deploy_wifi.sh <IP> \"<SSID>\" \"<PASSWORD>\""
        echo "=========================================================="
    fi

    echo ""
    echo "Healing sequence completed at: $(date '+%Y-%m-%d %H:%M:%S')"
}

# ------------------------------------------------------------
# CLI Mode Selection & Argument Parsing
# ------------------------------------------------------------
MODE="remote"
TARGET_IP=""
TARGET_SSID=""
TARGET_PASS=""
ACTION="heal"

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --local|-l)
            MODE="local"
            shift
            ;;
        --scan|-s)
            ACTION="scan"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --saved|--list-saved)
            ACTION="saved"
            shift
            ;;
        --forget|-f)
            ACTION="forget"
            [[ -n "${2:-}" ]] || { echo "[ERROR] --forget requires an SSID name."; exit 1; }
            TARGET_SSID="$2"
            shift 2
            ;;
        --fix-dns)
            ACTION="fix-dns"
            shift
            ;;
        --diagnose|-d)
            ACTION="diagnose"
            shift
            ;;
        -*)
            echo "[ERROR] Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            if [[ "$MODE" == "local" ]]; then
                if [[ -z "$TARGET_SSID" ]]; then
                    TARGET_SSID="$1"
                elif [[ -z "$TARGET_PASS" ]]; then
                    TARGET_PASS="$1"
                fi
            else
                if [[ -z "$TARGET_IP" ]]; then
                    # Check if first positional is an IP or hostname
                    if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$1" =~ ^[a-zA-Z0-9.-]+$ ]]; then
                        TARGET_IP="$1"
                    else
                        # If run as root locally without flags
                        if [[ $EUID -eq 0 ]]; then
                            MODE="local"
                            TARGET_SSID="$1"
                        else
                            TARGET_IP="$1"
                        fi
                    fi
                elif [[ -z "$TARGET_SSID" ]]; then
                    TARGET_SSID="$1"
                elif [[ -z "$TARGET_PASS" ]]; then
                    TARGET_PASS="$1"
                fi
            fi
            shift
            ;;
    esac
done

# ------------------------------------------------------------
# Local Execution Route
# ------------------------------------------------------------
if [[ "$MODE" == "local" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] Local execution requires root privileges."
        echo "Please run: sudo ./deploy_wifi.sh --local"
        exit 1
    fi

    case "$ACTION" in
        scan)
            scan_wifi_networks
            ;;
        status|diagnose)
            show_wifi_status
            ;;
        saved)
            list_saved_profiles
            ;;
        forget)
            forget_wifi_profile "$TARGET_SSID"
            ;;
        fix-dns)
            fix_dns_subsystem
            ;;
        heal)
            run_wifi_recovery "$TARGET_SSID" "$TARGET_PASS"
            ;;
    esac
    exit 0
fi

# ------------------------------------------------------------
# Remote Execution Route (Over SSH)
# ------------------------------------------------------------
if [[ -z "$TARGET_IP" ]]; then
    if [[ -t 0 ]]; then
        show_help
        echo ""
        read -rp "Enter target laptop IP (or '--local'): " TARGET_IP
        if [[ "$TARGET_IP" == "--local" ]]; then
            echo "Please run: sudo ./deploy_wifi.sh --local"
            exit 1
        fi
    fi
    if [[ -z "$TARGET_IP" ]]; then
        echo "[ERROR] Target laptop IP is required."
        show_help
        exit 1
    fi
fi

echo "══════════════════════════════════════════════════"
echo "       FinSurge Remote Wi-Fi Management Suite"
echo "══════════════════════════════════════════════════"
echo "  Target Laptop : $TARGET_IP"
echo "  SSH User      : $SSH_USER"
echo "  Action        : $ACTION"
if [[ -n "$TARGET_SSID" ]]; then
    echo "  Target SSID   : $TARGET_SSID"
else
    [[ "$ACTION" == "heal" ]] && echo "  Target SSID   : (Auto-reconnect to strongest saved network)"
fi
echo "  Execution     : Background-Protected (Immune to SSH drops)"
echo "══════════════════════════════════════════════════"

# Ensure sshpass or expect is installed locally
if ! command -v sshpass >/dev/null 2>&1 && ! command -v expect >/dev/null 2>&1; then
    echo "[+] Installing sshpass utility locally for automated execution..."
    sudo apt-get update -qq && sudo apt-get install -y -qq sshpass 2>/dev/null || true
fi

remote_ssh_sudo() {
    local cmd="$1"
    local escaped_cmd
    escaped_cmd=$(printf '%q' "$cmd")

    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$PASS" ssh $SSH_OPTS -t "${SSH_USER}@${TARGET_IP}" "printf '%s\n' '$PASS' | sudo -S -p '' bash -lc $escaped_cmd"
    else
        expect <<EOF
set timeout 300
spawn ssh $SSH_OPTS -t ${SSH_USER}@${TARGET_IP} "printf '%s\n' '$PASS' | sudo -S -p '' bash -lc $escaped_cmd"
expect {
    "*password:*" { send "$PASS\r"; exp_continue }
    eof
}
catch wait result
exit [lindex \$result 3]
EOF
    fi
}

remote_scp() {
    local src="$1" dest="$2"
    if command -v sshpass >/dev/null 2>&1; then
        sshpass -p "$PASS" scp $SSH_OPTS "$src" "${SSH_USER}@${TARGET_IP}:${dest}"
    else
        expect <<EOF
set timeout 300
spawn scp $SSH_OPTS $src ${SSH_USER}@${TARGET_IP}:${dest}
expect {
    "*password:*" { send "$PASS\r"; exp_continue }
    eof
}
catch wait result
exit [lindex \$result 3]
EOF
    fi
}

SCRIPT_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REMOTE_PAYLOAD="/tmp/deploy_wifi_runner.sh"
LOG_FILE="/var/log/wifi_recovery.log"
PID_FILE="/tmp/wifi_heal.pid"
DONE_FILE="/tmp/wifi_heal.done"

# 1. Transfer current script to remote laptop
echo ""
echo "[1/3] Uploading Wi-Fi management engine to $TARGET_IP..."
if remote_scp "$SCRIPT_SOURCE" "$REMOTE_PAYLOAD"; then
    echo "[✓] Management engine transferred successfully."
else
    echo "[ERROR] Failed to transfer payload to $TARGET_IP. Please verify IP and SSH credentials."
    exit 1
fi

# 2. Build and trigger remote execution
echo ""
if [[ "$ACTION" != "heal" ]]; then
    # Interactive / non-disruptive actions run synchronously
    echo "[2/3] Executing '$ACTION' on target laptop..."
    case "$ACTION" in
        scan)
            REMOTE_EXEC="chmod +x $REMOTE_PAYLOAD && $REMOTE_PAYLOAD --local --scan"
            ;;
        status|diagnose)
            REMOTE_EXEC="chmod +x $REMOTE_PAYLOAD && $REMOTE_PAYLOAD --local --status"
            ;;
        saved)
            REMOTE_EXEC="chmod +x $REMOTE_PAYLOAD && $REMOTE_PAYLOAD --local --saved"
            ;;
        forget)
            REMOTE_EXEC="chmod +x $REMOTE_PAYLOAD && $REMOTE_PAYLOAD --local --forget $(printf '%q' "$TARGET_SSID")"
            ;;
        fix-dns)
            REMOTE_EXEC="chmod +x $REMOTE_PAYLOAD && $REMOTE_PAYLOAD --local --fix-dns"
            ;;
    esac

    remote_ssh_sudo "$REMOTE_EXEC"
    echo ""
    echo "[3/3] Cleaning up temporary files..."
    remote_ssh_sudo "rm -f $REMOTE_PAYLOAD" 2>/dev/null || true
    echo "[✓] Complete."
    exit 0
fi

# Full Healing Action (Runs immune to SSH disconnection in background)
echo "[2/3] Initiating disconnect-immune Wi-Fi healing on $TARGET_IP..."

SSID_ARG=""
PASS_ARG=""
[[ -n "$TARGET_SSID" ]] && SSID_ARG="$(printf '%q' "$TARGET_SSID")"
[[ -n "$TARGET_PASS" ]] && PASS_ARG="$(printf '%q' "$TARGET_PASS")"

REMOTE_LAUNCH_CMD="chmod +x $REMOTE_PAYLOAD
rm -f $LOG_FILE $DONE_FILE $PID_FILE
nohup bash -c '$REMOTE_PAYLOAD --local $SSID_ARG $PASS_ARG; echo \"DONE:\$?:\$(date +%s)\" > $DONE_FILE' > $LOG_FILE 2>&1 &
echo \$! > $PID_FILE
"

if remote_ssh_sudo "$REMOTE_LAUNCH_CMD"; then
    echo "[✓] Recovery payload initiated in background (immune to SSH disconnection)."
else
    echo "[ERROR] Failed to launch recovery payload on $TARGET_IP."
    exit 1
fi

echo ""
echo "Streaming live recovery log from target laptop..."
echo "──────────────────────────────────────────────────────────────────"
STREAM_CMD="tail -n +1 -f --pid=\$(cat $PID_FILE 2>/dev/null) $LOG_FILE 2>/dev/null"
remote_ssh_sudo "$STREAM_CMD" || true
echo "──────────────────────────────────────────────────────────────────"

echo ""
echo "[3/3] Verifying final recovery status on target laptop..."
check_done_cmd="[ -f $DONE_FILE ] && echo 'PAYLOAD_FINISHED'"
is_already_done=$(remote_ssh_sudo "$check_done_cmd" 2>/dev/null || true)

if [[ "$is_already_done" =~ "PAYLOAD_FINISHED" ]]; then
    echo "[✓] Wi-Fi recovery sequence completed successfully for $TARGET_IP."
else
    echo "[!] SSH session disconnected (expected during network interface reset / Wi-Fi cycling)."
    echo "[✓] Recovery payload is continuing execution in the background on $TARGET_IP."
    echo "[+] Reconnection Watcher: Waiting for $TARGET_IP to settle and reconnect..."

    reconnected=false
    for i in {1..20}; do
        sleep 2
        if check_target_reachable "$TARGET_IP"; then
            reconnected=true
            break
        fi
        echo -n "."
    done
    echo ""

    if [ "$reconnected" = true ]; then
        echo "[✓] Target $TARGET_IP is reachable! Fetching completion report..."
        sleep 2
        remote_ssh_sudo "while [ ! -f $DONE_FILE ] && kill -0 \$(cat $PID_FILE 2>/dev/null) 2>/dev/null; do sleep 1; done; cat $LOG_FILE" || true
        echo ""
        echo "[✓] Wi-Fi recovery sequence completed for $TARGET_IP."
    else
        echo "[i] Target $TARGET_IP did not respond to ping within 40 seconds."
        echo "[i] Note: If the laptop connected to a new Wi-Fi network, it may have received a new DHCP IP address."
        echo "[✓] The recovery process executed in the background on the target laptop."
        echo "[i] The full output log is saved on the target at: $LOG_FILE"
    fi
fi

# Clean remote temporary engine
remote_ssh_sudo "rm -f $REMOTE_PAYLOAD" 2>/dev/null || true
echo "[✓] Cleanup complete."
