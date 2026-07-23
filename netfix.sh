#!/usr/bin/env bash
# ==============================================================================
# Enterprise Debian/Ubuntu Network Auto-Remediation & Diagnostic Suite
# ==============================================================================
set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Exit Codes Standard
#   0  = Network healthy (No action required)
#   10 = Issues detected and automatically repaired
#   20 = Unresolved issues / Manual intervention required
#   1  = Script failure (Fatal error / Permission error)
# ------------------------------------------------------------------------------
EXIT_HEALTHY=0
EXIT_REPAIRED=10
EXIT_MANUAL_REQUIRED=20

# ------------------------------------------------------------------------------
# Global Declarations & CLI Parsing
# ------------------------------------------------------------------------------
AUTO_MODE=0
DRY_RUN=0
SUMMARY_ONLY=0
LOG_DIR="/var/log/netfix"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO_MODE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --summary) SUMMARY_ONLY=1; shift ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[0;31mError: Please run this script with sudo.\033[0m"
  exit 1
fi

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/netfix_${TIMESTAMP}.log"
HTML_REPORT="${LOG_DIR}/netfix_report_${TIMESTAMP}.html"
JSON_REPORT="${LOG_DIR}/netfix_report_${TIMESTAMP}.json"
BUNDLE_ARCHIVE="${LOG_DIR}/netfix_bundle_${TIMESTAMP}.tar.gz"
STATE_BACKUP="${LOG_DIR}/backup_${TIMESTAMP}"

mkdir -p "$STATE_BACKUP"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Diagnostic State
DISTRO_NAME="Unknown"
STACK_TYPE="Unknown"
SCORE_IFACE="FAIL"
SCORE_RFKILL="OK"
SCORE_DRIVER="FAIL"
SCORE_DHCP="FAIL"
SCORE_GW="FAIL"
SCORE_DNS4="FAIL"
SCORE_INET4="FAIL"
SCORE_PORTAL="NONE"
SCORE_EAP="N/A"
SCORE_FIREWALL="OK"
OPTIMAL_MTU="1500"
BUG_DIAGNOSIS="Undetermined Network Anomaly"
REPAIRS_APPLIED=()
MANUAL_RECOMMENDATIONS=()
SYSTEM_MUTATED=0

# Hardware & Telemetry
MAIN_INT=""
INT_TYPE="Unknown"
ETH_SPEED="N/A"
ETH_DUPLEX="N/A"
ETH_LINK="N/A"
ORIG_MTU="1500"
MODULE=""
WIFI_RSSI="N/A"
WIFI_SSID="N/A"
WIFI_CONGESTION="LOW"
DNS_LATENCY_MS="N/A"
PACKET_LOSS_PCT="0%"
GATEWAY_COUNT=0
PORT_53_STATE="CLOSED"
PORT_80_STATE="CLOSED"
PORT_443_STATE="CLOSED"

log() {
  if [ "$SUMMARY_ONLY" -eq 0 ]; then
    echo -e "$1" | tee -a "$LOG_FILE"
  else
    echo -e "$1" >> "$LOG_FILE"
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

confirm() {
    if [ "$DRY_RUN" -eq 1 ]; then return 1; fi
    if [ "$AUTO_MODE" -eq 1 ]; then return 0; fi
    if [ "$SUMMARY_ONLY" -eq 1 ]; then return 1; fi
    read -p "$1 [y/N]: " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

rotate_logs() {
    local files_to_del
    files_to_del=$(find "$LOG_DIR" -maxdepth 1 -type f \( -name "netfix_*" -o -name "backup_*" \) | sort -r | tail -n +31 || true)
    if [ -n "$files_to_del" ]; then
        echo "$files_to_del" | xargs rm -rf 2>/dev/null || true
    fi
}
rotate_logs

log "${GREEN}====================================================${NC}"
log "${GREEN} Enterprise Network Auto-Remediation & Diagnostic   ${NC}"
log "Started at: $(date) | Log: $LOG_FILE"
if [ "$DRY_RUN" -eq 1 ]; then log "${YELLOW}[RUNNING IN DRY-RUN MODE - NO CHANGES WILL BE MADE]${NC}"; fi
log "${GREEN}====================================================${NC}"

# ------------------------------------------------------------------------------
# Targeted Dynamic Rollback System
# ------------------------------------------------------------------------------
rollback_changes() {
    if [ "$SYSTEM_MUTATED" -eq 0 ]; then return 0; fi

    log "\n${RED}[Rollback Engine Triggered] Restoring original network configuration...${NC}"

    if [ -n "$MAIN_INT" ] && [ -f "${STATE_BACKUP}/orig_mtu.txt" ]; then
        local target_mtu
        target_mtu=$(cat "${STATE_BACKUP}/orig_mtu.txt")
        ip link set dev "$MAIN_INT" mtu "$target_mtu" 2>/dev/null || true
        log "Restored MTU on $MAIN_INT to $target_mtu."
    fi

    if [ -f "${STATE_BACKUP}/resolv.conf.bak" ]; then
        cp "${STATE_BACKUP}/resolv.conf.bak" /etc/resolv.conf 2>/dev/null || true
    fi

    if has_cmd resolvectl && [ -n "$MAIN_INT" ]; then
        resolvectl revert "${MAIN_INT}" 2>/dev/null || true
    fi

    log "Rollback completed successfully."
}

on_error() {
    log "${RED}Unexpected error encountered during remediation!${NC}"
    rollback_changes
    exit 1
}

# ------------------------------------------------------------------------------
# Step 1: Environment Detection & State Backup
# ------------------------------------------------------------------------------
log "\n${YELLOW}[Step 1] Environment Detection & State Backup${NC}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_NAME="${NAME:-Linux} ${VERSION_ID:-}"
fi
log "Operating System: ${GREEN}${DISTRO_NAME}${NC}"

cp /etc/resolv.conf "${STATE_BACKUP}/resolv.conf.bak" 2>/dev/null || true

if has_cmd ip; then
    ip addr show > "${STATE_BACKUP}/ip_addrs.txt"
    ip route show > "${STATE_BACKUP}/ip_routes.txt"
fi

# Primary Interface Detection
if has_cmd iw; then
    MAIN_INT=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -n 1)
fi
if [ -z "$MAIN_INT" ] && has_cmd ip; then
    MAIN_INT=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(w|e|en|wl|eth)' | grep -v 'docker\|veth\|br-' | head -n 1 | sed 's/@.*//')
fi

if [ -n "$MAIN_INT" ]; then
    if [[ "$MAIN_INT" =~ ^(w|wl) ]]; then
        INT_TYPE="Wireless"
    else
        INT_TYPE="Ethernet"
    fi

    ORIG_MTU=$(ip link show dev "$MAIN_INT" | awk '{print $5}' || echo "1500")
    echo "$ORIG_MTU" > "${STATE_BACKUP}/orig_mtu.txt"
fi

log "Interface Detected: ${GREEN}${MAIN_INT:-None} (${INT_TYPE})${NC}"
log "State backup created at: ${STATE_BACKUP}"

# ------------------------------------------------------------------------------
# Step 2: Hardware, Driver, Wi-Fi & Ethernet Diagnostics
# ------------------------------------------------------------------------------
log "\n${YELLOW}[Step 2] Hardware, Driver & Link Diagnostics${NC}"

if [ -n "$MAIN_INT" ]; then
    SCORE_IFACE="OK"

    if [ -e "/sys/class/net/$MAIN_INT/device/driver" ]; then
        MODULE=$(basename "$(readlink "/sys/class/net/$MAIN_INT/device/driver")")
        log "Kernel Driver Module: ${GREEN}${MODULE}${NC}"
        SCORE_DRIVER="OK"

        case "$MODULE" in
            iwlwifi)
                if has_cmd journalctl && journalctl -u systemd-modules-load -u Kernel --since "2 hours ago" 2>/dev/null | grep -i "iwlwifi.*Microcode" >/dev/null; then
                    MANUAL_RECOMMENDATIONS+=("Intel Wi-Fi firmware crash detected. Consider updating linux-firmware package.")
                fi
                ;;
            rtl8169|rtl8111|r8169)
                MANUAL_RECOMMENDATIONS+=("Realtek NIC detected. If experiencing dropped links, test r8168-dkms driver alternative.")
                ;;
            wl|b43)
                MANUAL_RECOMMENDATIONS+=("Broadcom proprietary driver in use. Verify broadcom-sta-dkms package is properly compiled.")
                ;;
        esac
    fi

    # Ethernet Diagnostics
    if [ "$INT_TYPE" = "Ethernet" ]; then
        if [ -f "/sys/class/net/$MAIN_INT/carrier" ]; then
            C_STATE=$(cat "/sys/class/net/$MAIN_INT/carrier" 2>/dev/null || echo "0")
            [ "$C_STATE" = "1" ] && ETH_LINK="Connected" || ETH_LINK="No Carrier"
        fi

        if has_cmd ethtool; then
            ETH_SPEED=$(ethtool "$MAIN_INT" 2>/dev/null | grep "Speed:" | awk '{print $2}' || echo "Unknown")
            ETH_DUPLEX=$(ethtool "$MAIN_INT" 2>/dev/null | grep "Duplex:" | awk '{print $2}' || echo "Unknown")
        fi

        log "Ethernet Link State : ${GREEN}${ETH_LINK}${NC}"
        log "Speed / Duplex      : ${ETH_SPEED} / ${ETH_DUPLEX}"

        if [ "$ETH_LINK" = "No Carrier" ]; then
            MANUAL_RECOMMENDATIONS+=("Ethernet cable is unplugged or physical port link is down.")
        fi
    fi

    # Wi-Fi Diagnostics & Channel Congestion
    if [ "$INT_TYPE" = "Wireless" ]; then
        if has_cmd nmcli; then
            WIFI_SSID=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep "^yes" | cut -d: -f2 || echo "Disconnected")
            WIFI_RSSI=$(nmcli -t -f ACTIVE,SIGNAL dev wifi 2>/dev/null | grep "^yes" | cut -d: -f2 || echo "N/A")

            NEARBY_APS=$(nmcli dev wifi list 2>/dev/null | wc -l || echo "0")
            if [ "$NEARBY_APS" -gt 25 ]; then
                WIFI_CONGESTION="HIGH ($NEARBY_APS APs detected)"
                MANUAL_RECOMMENDATIONS+=("High Wi-Fi congestion nearby ($NEARBY_APS APs). Switch router to 5 GHz or 6 GHz band.")
            fi
        fi

        if has_cmd rfkill; then
            if rfkill list wlan 2>/dev/null | grep -i "Hard blocked: yes" >/dev/null; then
                SCORE_RFKILL="HARD_BLOCKED"
                log "${RED}CRITICAL: Wi-Fi is HARDWARE blocked by physical toggle switch!${NC}"
                MANUAL_RECOMMENDATIONS+=("Toggle physical Wi-Fi switch or Fn key combination on laptop chassis.")
            elif rfkill list wlan 2>/dev/null | grep -i "Soft blocked: yes" >/dev/null; then
                SCORE_RFKILL="SOFT_BLOCKED"
                log "${YELLOW}Wi-Fi is soft-blocked by RFKill.${NC}"
                if confirm "Unblock wireless interfaces via rfkill?"; then
                    trap on_error ERR
                    SYSTEM_MUTATED=1
                    rfkill unblock wlan 2>/dev/null || true
                    REPAIRS_APPLIED+=("RFKill Soft-Unblock")
                    SCORE_RFKILL="UNBLOCKED"
                fi
            fi
        fi
    fi
else
    log "${RED}No active network interface found.${NC}"
    BUG_DIAGNOSIS="Missing Interface Hardware or Driver"
fi

# ------------------------------------------------------------------------------
# Step 3: Enterprise 802.1X / EAP Security Audit
# ------------------------------------------------------------------------------
log "\n${YELLOW}[Step 3] Enterprise 802.1X / EAP Security Audit${NC}"

if has_cmd journalctl; then
    EAP_LOGS=$(journalctl -u wpa_supplicant -u NetworkManager --since "1 hour ago" 2>/dev/null | grep -iE 'eap|802-1x|supplicant|TLS: Certificate|failed to authenticate' | tail -n 5 || true)
    if [ -n "$EAP_LOGS" ]; then
        log "${YELLOW}Recent Enterprise Authentication Events Detected:${NC}"
        echo "$EAP_LOGS" | while read -r line; do log "   $line"; done

        if echo "$EAP_LOGS" | grep -iE 'failed|rejected|expired' >/dev/null; then
            SCORE_EAP="FAIL"
            MANUAL_RECOMMENDATIONS+=("802.1X / WPA-Enterprise authentication failed. Verify domain credentials or updated RADIUS CA certificates.")
        else
            SCORE_EAP="EVENTS_FOUND"
        fi
    else
        SCORE_EAP="NONE"
        log "802.1X/EAP Status: ${GREEN}No authentication errors in active session logs${NC}"
    fi
fi

# ------------------------------------------------------------------------------
# Step 4: Routing, Latency & Port Diagnostics
# ------------------------------------------------------------------------------
log "\n${YELLOW}[Step 4] Routing, Latency & Outbound Port Audit${NC}"

GATEWAY_COUNT=$(ip -4 route show default 2>/dev/null | wc -l || echo 0)
GW4=$(ip -4 route show default | awk '{print $3}' | head -n 1 || echo "")

if [ "$GATEWAY_COUNT" -gt 1 ]; then
    MANUAL_RECOMMENDATIONS+=("Multiple default IPv4 routes detected ($GATEWAY_COUNT gateways). Resolve metric conflicts in network stack.")
elif [ -n "$GW4" ]; then
    SCORE_GW="OK"
    SCORE_DHCP="OK"
    log "IPv4 Gateway: ${GREEN}${GW4}${NC}"
fi

if has_cmd ping; then
    PING_OUT=$(ping -c 5 -W 2 1.1.1.1 2>/dev/null || true)
    if echo "$PING_OUT" | grep -q "bytes from"; then
        SCORE_INET4="OK"
        PACKET_LOSS_PCT="$(echo "$PING_OUT" | grep -oP '\d+(?=% packet loss)' || echo "0")%"
    fi
fi

if has_cmd dig; then
    DNS_LATENCY_MS=$(dig @1.1.1.1 google.com 2>/dev/null | grep "Query time:" | awk '{print $4}' || echo "N/A")
    if [ "$DNS_LATENCY_MS" != "N/A" ]; then SCORE_DNS4="OK"; fi
elif has_cmd ping && ping -c 1 -W 2 google.com >/dev/null 2>&1; then
    SCORE_DNS4="OK"
fi

log "IPv4 Connectivity: ${SCORE_INET4} (Loss: ${PACKET_LOSS_PCT}) | DNS IPv4: ${SCORE_DNS4} (${DNS_LATENCY_MS} ms)"

# Outbound Port Check Helper
test_port() {
    local host="$1" port="$2"
    if has_cmd nc; then
        nc -z -w 2 "$host" "$port" >/dev/null 2>&1 && echo "OPEN" || echo "BLOCKED"
    else
        timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null && echo "OPEN" || echo "BLOCKED"
    fi
}

PORT_53_STATE=$(test_port "1.1.1.1" 53)
PORT_80_STATE=$(test_port "neverssl.com" 80)
PORT_443_STATE=$(test_port "1.1.1.1" 443)

log "Outbound Ports : DNS(53): $PORT_53_STATE | HTTP(80): $PORT_80_STATE | HTTPS(443): $PORT_443_STATE"

if [ "$PORT_443_STATE" = "BLOCKED" ] && [ "$SCORE_INET4" = "OK" ]; then
    SCORE_FIREWALL="RESTRICTED"
    MANUAL_RECOMMENDATIONS+=("Outbound TCP 443 blocked. Upstream firewall or corporate web proxy interfering.")
fi

if has_cmd curl; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://neverssl.com 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
        SCORE_PORTAL="DETECTED"
        MANUAL_RECOMMENDATIONS+=("Captive portal intercepted request. Complete authentication at http://neverssl.com")
    elif [ "$HTTP_CODE" = "200" ]; then
        SCORE_PORTAL="CLEAR"
    fi
fi

# ------------------------------------------------------------------------------
# Step 5: Stack Service Reset & DNS Auto-Repair
# ------------------------------------------------------------------------------
log "\n${YELLOW}[Step 5] Stack Reset & DNS Auto-Repair${NC}"

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    STACK_TYPE="NetworkManager"
elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    STACK_TYPE="systemd-networkd"
else
    STACK_TYPE="Static/Other"
fi

if [ "$SCORE_INET4" = "OK" ] && [ "$SCORE_DNS4" = "FAIL" ]; then
    BUG_DIAGNOSIS="DNS Resolution Failure"
    log "${RED}Network path clear, but DNS resolution failed.${NC}"

    if confirm "Apply safe public DNS fallback (1.1.1.1 / 8.8.8.8)?"; then
        trap on_error ERR
        SYSTEM_MUTATED=1
        DNS_REPAIRED=0

        if [ "$STACK_TYPE" = "NetworkManager" ] && has_cmd nmcli; then
            CONN_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep ":${MAIN_INT}" | cut -d: -f1 | head -n 1 || echo "")
            if [ -n "$CONN_NAME" ]; then
                nmcli connection modify "$CONN_NAME" ipv4.dns "1.1.1.1 8.8.8.8" ipv4.ignore-auto-dns yes 2>/dev/null || true
                nmcli connection up "$CONN_NAME" 2>/dev/null || true
                DNS_REPAIRED=1
            fi
        fi

        if [ "$DNS_REPAIRED" -eq 0 ]; then
            echo "nameserver 1.1.1.1" > /etc/resolv.conf
            echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        fi

        sleep 2
        if ping -c 2 -W 3 google.com >/dev/null 2>&1; then
            SCORE_DNS4="OK (Repaired)"
            REPAIRS_APPLIED+=("Native Stack DNS Fallback Configured")
            log "${GREEN}DNS auto-repair succeeded!${NC}"
        else
            log "${RED}DNS update failed to resolve queries. Rolling back...${NC}"
            rollback_changes
        fi
    fi
fi

# PMTU Optimization
if has_cmd ping && [ -n "$MAIN_INT" ] && [ "$SCORE_INET4" = "OK" ]; then
    for mtu in 1500 1492 1400 1360; do
        PAYLOAD=$((mtu - 28))
        if ping -c 1 -M do -s $PAYLOAD 1.1.1.1 >/dev/null 2>&1; then
            OPTIMAL_MTU="$mtu"
            break
        fi
    done

    if [ "$OPTIMAL_MTU" != "1500" ] && [ "$OPTIMAL_MTU" != "$ORIG_MTU" ]; then
        if confirm "Adjust interface $MAIN_INT MTU to $OPTIMAL_MTU?"; then
            trap on_error ERR
            SYSTEM_MUTATED=1
            ip link set dev "$MAIN_INT" mtu "$OPTIMAL_MTU" 2>/dev/null || true

            if ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
                rollback_changes
            else
                REPAIRS_APPLIED+=("MTU Adjusted to ${OPTIMAL_MTU}")
            fi
        fi
    fi
fi

# ------------------------------------------------------------------------------
# Final Classification
# ------------------------------------------------------------------------------
if [ "$SCORE_RFKILL" = "HARD_BLOCKED" ]; then
    BUG_DIAGNOSIS="Wi-Fi Hard-Blocked via Physical Hardware Switch"
elif [ "$SCORE_IFACE" = "FAIL" ]; then
    BUG_DIAGNOSIS="Network Interface Hardware Missing"
elif [ "$ETH_LINK" = "No Carrier" ]; then
    BUG_DIAGNOSIS="Ethernet Cable Disconnected"
elif [ "$SCORE_EAP" = "FAIL" ]; then
    BUG_DIAGNOSIS="Enterprise 802.1X/EAP Credentials or Certificate Rejection"
elif [ "$SCORE_DHCP" = "FAIL" ]; then
    BUG_DIAGNOSIS="DHCP Lease or Gateway Route Missing"
elif [ "$SCORE_INET4" = "FAIL" ]; then
    BUG_DIAGNOSIS="Local Network Connected, No External ISP Access"
elif [ "$SCORE_DNS4" = "FAIL" ]; then
    BUG_DIAGNOSIS="DNS Resolution Failed"
elif [ "$SCORE_PORTAL" = "DETECTED" ]; then
    BUG_DIAGNOSIS="Captive Portal Intercept"
else
    BUG_DIAGNOSIS="Network Fully Operational"
fi

# ------------------------------------------------------------------------------
# Export JSON, HTML & IT Support Bundle
# ------------------------------------------------------------------------------
cat << EOF > "$JSON_REPORT"
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "distro": "$DISTRO_NAME",
  "stack_type": "$STACK_TYPE",
  "diagnosis": "$BUG_DIAGNOSIS",
  "interface": {
    "name": "${MAIN_INT:-N/A}",
    "type": "$INT_TYPE",
    "driver": "${MODULE:-N/A}",
    "wifi_rssi": "$WIFI_RSSI",
    "wifi_congestion": "$WIFI_CONGESTION"
  },
  "metrics": {
    "dns_latency_ms": "${DNS_LATENCY_MS}",
    "packet_loss": "${PACKET_LOSS_PCT}",
    "port_443_https": "${PORT_443_STATE}",
    "gateway_count": ${GATEWAY_COUNT}
  }
}
EOF

cat << EOF > "$HTML_REPORT"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Network Diagnostics Report</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 30px; background: #f8f9fa; color: #212529; }
  .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); margin-bottom: 20px; }
  h1 { color: #0f172a; font-size: 22px; border-bottom: 2px solid #e2e8f0; padding-bottom: 8px; margin-top:0; }
  .status-ok { color: #16a34a; font-weight: bold; }
  .status-fail { color: #dc2626; font-weight: bold; }
</style>
</head>
<body>
<div class="card">
  <h1>Enterprise Network Diagnostics Report</h1>
  <p><strong>System:</strong> $DISTRO_NAME | <strong>Timestamp:</strong> $(date)</p>
  <p><strong>Diagnosis:</strong> <span class="$([ "$BUG_DIAGNOSIS" = "Network Fully Operational" ] && echo "status-ok" || echo "status-fail")">$BUG_DIAGNOSIS</span></p>
  <p><strong>Network Stack:</strong> $STACK_TYPE</p>
</div>
</body>
</html>
EOF

if has_cmd tar; then
    tar -czf "$BUNDLE_ARCHIVE" -C "$LOG_DIR" \
        "$(basename "$LOG_FILE")" \
        "$(basename "$HTML_REPORT")" \
        "$(basename "$JSON_REPORT")" \
        "$(basename "$STATE_BACKUP")" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# Terminal Output & Exit Code
# ------------------------------------------------------------------------------
if [ "$SUMMARY_ONLY" -eq 1 ]; then
    echo "===================================================="
    echo "             HELPDESK EXECUTIVE SUMMARY            "
    echo "===================================================="
    echo " OS / Stack   : $DISTRO_NAME ($STACK_TYPE)"
    echo " Diagnosis    : $BUG_DIAGNOSIS"
    echo " Interface    : ${MAIN_INT:-N/A} ($INT_TYPE - Driver: ${MODULE:-N/A})"
    echo " Link Quality : Loss: $PACKET_LOSS_PCT | DNS Latency: ${DNS_LATENCY_MS}ms"
    echo " Wi-Fi        : SSID: ${WIFI_SSID} | Signal: ${WIFI_RSSI}% | Congestion: ${WIFI_CONGESTION}"
    echo " Firewall     : DNS(53): $PORT_53_STATE | HTTP(80): $PORT_80_STATE | HTTPS(443): $PORT_443_STATE"
    echo " Support File : $BUNDLE_ARCHIVE"
    echo "===================================================="
else
    log "\n${GREEN}====================================================${NC}"
    log " System OS     : $DISTRO_NAME"
    log " Network Stack : $STACK_TYPE"
    log " Diagnosis     : ${YELLOW}${BUG_DIAGNOSIS}${NC}"
    log " Interface     : $SCORE_IFACE (${MAIN_INT:-N/A} - $INT_TYPE)"
    log " IPv4 Access   : $SCORE_INET4 (Loss: $PACKET_LOSS_PCT)"
    log " DNS Latency   : ${DNS_LATENCY_MS} ms"
    log " Support Bundle: ${GREEN}${BUNDLE_ARCHIVE}${NC}"

    if [ "${#REPAIRS_APPLIED[@]}" -gt 0 ]; then
        log "\n${GREEN}[Applied Repairs]${NC}"
        for r in "${REPAIRS_APPLIED[@]+"${REPAIRS_APPLIED[@]}"}"; do log " ${GREEN}✓${NC} $r"; done
    fi

    if [ "${#MANUAL_RECOMMENDATIONS[@]}" -gt 0 ]; then
        log "\n${YELLOW}[Manual Actions Required]${NC}"
        for m in "${MANUAL_RECOMMENDATIONS[@]+"${MANUAL_RECOMMENDATIONS[@]}"}"; do log " ${YELLOW}!${NC} $m"; done
    fi
    log "${GREEN}====================================================${NC}\n"
fi

if [ "$BUG_DIAGNOSIS" = "Network Fully Operational" ] && [ "${#REPAIRS_APPLIED[@]}" -eq 0 ]; then
    exit $EXIT_HEALTHY
elif [ "${#REPAIRS_APPLIED[@]}" -gt 0 ] && [ "$SCORE_INET4" = "OK" ]; then
    exit $EXIT_REPAIRED
else
    exit $EXIT_MANUAL_REQUIRED
fi