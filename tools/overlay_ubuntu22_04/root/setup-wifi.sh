#!/bin/bash
# Configure WPA/WPA2-Personal Wi-Fi, or connect using an existing config.
set -Eeuo pipefail
umask 077

ACTION="${1:-configure}"
IFACE="${2:-wlan0}"
CONF=/etc/wpa_supplicant.conf
CTRL=/run/wpa_supplicant
RUN=/run/modulellm-wifi
WPA_LOG="/var/log/wpa_supplicant-$IFACE.log"
DHCP_LOG="/var/log/wifi-dhcp-$IFACE.log"
WPA_PID="$RUN/wpa-$IFACE.pid"
DHCP_PID="$RUN/dhcp-$IFACE.pid"
LEASE="/var/lib/dhcp/modulellm-$IFACE.leases"
WPA_DRIVER="${WPA_DRIVER:-nl80211,wext}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-45}"

usage() {
    cat <<'EOF'
Usage: /root/setup-wifi.sh [configure|connect|status|stop] [wlan0]
  configure  Prompt for SSID/passphrase, write /etc/wpa_supplicant.conf, connect.
  connect    Use the existing /etc/wpa_supplicant.conf without changing it.
  status     Show authentication state, IPv4 address and recent logs.
  stop       Stop only dedicated wpa_supplicant/dhclient processes for this interface.
Logs: /var/log/wpa_supplicant-wlan0.log and /var/log/wifi-dhcp-wlan0.log
To test the legacy driver API: WPA_DRIVER=wext /root/setup-wifi.sh connect
Enterprise/WPA3-only networks: edit /etc/wpa_supplicant.conf, then use connect.
EOF
}
case "$ACTION" in help|-h|--help) usage; exit 0;; configure|connect|status|stop) ;; *) usage; exit 1;; esac
[[ "$IFACE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || { echo "Invalid interface: $IFACE" >&2; exit 1; }
[ "$EUID" -eq 0 ] || { echo "Run this script as root." >&2; exit 1; }

show_logs() {
    for log in "$WPA_LOG" "$DHCP_LOG"; do
        if [ -f "$log" ]; then echo "--- $log"; tail -n 40 "$log"; fi
    done
}
fail() { echo "ERROR: $*" >&2; show_logs >&2; exit 1; }
trap 'rc=$?; echo "Wi-Fi setup failed. Check $WPA_LOG and $DHCP_LOG" >&2; show_logs >&2; exit "$rc"' ERR

# Match command arguments, never kill all supplicants/DHCP clients. A
# multi-interface daemon is left running, because it may also own Ethernet.
stop_dedicated() {
    local program="$1" path pid arg match shared count i
    local -a argv
    for path in /proc/[0-9]*/cmdline; do
        mapfile -d '' -t argv < "$path" 2>/dev/null || continue
        [ "${#argv[@]}" -gt 0 ] || continue
        [ "${argv[0]##*/}" = "$program" ] || continue
        match=0; shared=0; count=0
        for ((i=1; i<${#argv[@]}; i++)); do
            arg="${argv[i]}"
            if [ "$program" = wpa_supplicant ]; then
                case "$arg" in
                    -i) [ "${argv[i+1]:-}" != "$IFACE" ] || match=1;;
                    "-i$IFACE") match=1;;
                    -N|-u) shared=1;;
                esac
            else
                [ "$arg" != "$IFACE" ] || match=1
                if [ -e "/sys/class/net/$arg" ]; then count=$((count+1)); fi
            fi
        done
        [ "$match" -eq 1 ] || continue
        pid="${path#/proc/}"; pid="${pid%/cmdline}"
        [ "$shared" -eq 0 ] && [ "$count" -le 1 ] || fail "$program PID $pid owns multiple interfaces; stop its $IFACE connection separately."
        echo "Stopping $program PID $pid for $IFACE"
        kill -TERM "$pid" 2>/dev/null || continue
        for ((i=0; i<25; i++)); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        ! kill -0 "$pid" 2>/dev/null || fail "$program PID $pid did not stop."
    done
}

configure() {
    local ssid password country ssid_hex psk temporary
    read -r -p 'SSID: ' ssid
    [ -n "$ssid" ] && [ "$(printf '%s' "$ssid" | wc -c)" -le 32 ] || fail 'SSID must be 1-32 bytes.'
    read -r -s -p 'Wi-Fi passphrase (8-63 bytes; empty for an open network): ' password
    echo
    read -r -p 'Country code [JP]: ' country
    country="${country:-JP}"
    [[ "$country" =~ ^[A-Z]{2}$ ]] || fail 'Use a two-letter uppercase country code.'
    ssid_hex="$(printf '%s' "$ssid" | od -An -tx1 | tr -d ' \n')"
    if [ -n "$password" ]; then
        psk="$(printf '%s\n' "$password" | wpa_passphrase "$ssid" | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')"
        [ "${#psk}" -eq 64 ] || fail 'Could not generate PSK; check passphrase length.'
    fi
    unset password
    temporary="$(mktemp /etc/.wpa_supplicant.conf.XXXXXX)"
    {
        printf 'ctrl_interface=%s\nupdate_config=0\ncountry=%s\nap_scan=1\n\nnetwork={\n    ssid=%s\n    scan_ssid=1\n' "$CTRL" "$country" "$ssid_hex"
        if [ -n "${psk:-}" ]; then printf '    key_mgmt=WPA-PSK\n    psk=%s\n' "$psk"; else printf '    key_mgmt=NONE\n'; fi
        printf '}\n'
    } > "$temporary"
    chmod 0600 "$temporary"
    if [ -f "$CONF" ]; then cp -p "$CONF" "$CONF.bak"; chmod 0600 "$CONF.bak"; fi
    mv "$temporary" "$CONF"
    echo "Saved $CONF (mode 600)."
}

connect() {
    [ -f "$CONF" ] && grep -Eq '^[[:space:]]*network[[:space:]]*=' "$CONF" || fail "Configure Wi-Fi first: /root/setup-wifi.sh configure $IFACE"
    [[ "$CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail 'CONNECT_TIMEOUT must be a positive number.'
    if [ ! -d "/sys/class/net/$IFACE" ]; then modprobe 8821cu || true; fi
    [ -d "/sys/class/net/$IFACE" ] || fail "Interface $IFACE is missing. Check lsusb and dmesg."
    # Keep NetworkManager from creating a second supplicant for this device.
    mkdir -p /etc/NetworkManager/conf.d
    printf '[device-modulellm-%s]\nmatch-device=interface-name:%s\nmanaged=0\n' "$IFACE" "$IFACE" > "/etc/NetworkManager/conf.d/90-modulellm-$IFACE.conf"
    if command -v nmcli >/dev/null && [ "$(nmcli -t -f RUNNING general 2>/dev/null || true)" = running ]; then
        nmcli general reload conf || true
        nmcli --wait 10 device set "$IFACE" managed no
    fi
    stop_dedicated wpa_supplicant
    stop_dedicated dhclient
    if [ -S "$CTRL/$IFACE" ]; then
        if wpa_cli -p "$CTRL" -i "$IFACE" ping 2>/dev/null | grep -qx PONG; then
            fail "Another supplicant still owns $IFACE; inspect ps -ef."
        fi
        rm -f "$CTRL/$IFACE"
    fi
    mkdir -p "$CTRL" /var/lib/dhcp /var/log
    chmod 0600 "$CONF"
    touch "$WPA_LOG" "$DHCP_LOG"; chmod 0600 "$WPA_LOG" "$DHCP_LOG"
    ip link set dev "$IFACE" up
    # Daemons must not inherit the setup lock when they fork into the background.
    wpa_supplicant -B -i "$IFACE" -c "$CONF" -D "$WPA_DRIVER" -O "$CTRL" -P "$WPA_PID" -f "$WPA_LOG" -d -t 9>&-
    echo "Waiting for Wi-Fi authentication on $IFACE..."
    local state= elapsed
    for ((elapsed=0; elapsed<CONNECT_TIMEOUT; elapsed++)); do
        state="$(wpa_cli -p "$CTRL" -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p' || true)"
        [ "$state" != COMPLETED ] || break
        sleep 1
    done
    [ "$state" = COMPLETED ] || fail "Authentication timed out (state: ${state:-unknown})."
    echo "Authenticated. Requesting an IPv4 address..."
    dhclient -4 -1 -v -pf "$DHCP_PID" -lf "$LEASE" "$IFACE" 9>&- >> "$DHCP_LOG" 2>&1 || fail 'DHCP failed after authentication.'
    ip -4 -brief address show dev "$IFACE"
    echo "Wi-Fi connected. Logs: $WPA_LOG and $DHCP_LOG"
}

if [ "$ACTION" = status ]; then
    wpa_cli -p "$CTRL" -i "$IFACE" status || true
    ip -4 -brief address show dev "$IFACE" || true
    show_logs
    exit 0
fi
mkdir -p "$RUN"
exec 9> "$RUN/$IFACE.lock"
flock -n 9 || fail "Another setup process is running for $IFACE."
case "$ACTION" in
    configure) configure; connect;;
    connect) connect;;
    stop) stop_dedicated dhclient; stop_dedicated wpa_supplicant; rm -f "$WPA_PID" "$DHCP_PID";;
esac
