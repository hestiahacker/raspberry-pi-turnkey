#!/bin/bash
# Leave AP mode and rejoin the WiFi described by wpa.conf.
# Same runtime detection and config/ pattern as enable_ap.sh

set -u
cd "$(dirname "$0")"

# Load default variable if we have them
[ -r /etc/default/turnkey ] && . /etc/default/turnkey
WLAN="${WLAN:-wlan0}"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO=sudo

stop_service() {
    local unit="$1" disabled="$2" dest="$3"
    if $SUDO systemctl disable --now "$unit" >/dev/null 2>&1; then
        return 0
    fi
    [ -f "$disabled" ] && $SUDO cp "$disabled" "$dest"
}

install_config() {
    local src="$1" dest="$2"
    if [ "$WLAN" = wlan0 ]; then
        $SUDO cp "$src" "$dest"
    else
        sed "s/wlan0/$WLAN/g" "$src" | $SUDO tee "$dest" >/dev/null
    fi
}

# Same enumeration as enable_ap.sh: only real instances for WLAN.  Do not
# touch other radios' supplicants; they may be carrying the client internet.
list_supplicant_units() {
    local pat="${WLAN//./\\.}"
    {
        systemctl list-units --all --no-legend --plain 2>/dev/null
        systemctl list-unit-files --no-legend --plain 2>/dev/null
    } | awk '{print $1}' |
        grep -E "^(wpa_supplicant@|wpa_supplicant-nl80211@|wpa_supplicant-wired@|netplan-wpa-)${pat}\\.service$" |
        sort -u
}

# The AP services are no longer needed.  Mask hostapd so it cannot be started
# accidentally while the board is in client mode; enable_ap.sh unmasks it again.
stop_service hostapd.service config/hostapd.disabled /etc/default/hostapd
$SUDO systemctl mask hostapd.service >/dev/null 2>&1 || true
stop_service dnsmasq.service config/dnsmasq.conf.disabled /etc/dnsmasq.conf

if [ -f /etc/dhcpcd.conf ] && command -v dhcpcd >/dev/null 2>&1; then
    # Raspbian: drop the static AP address so dhcpcd uses DHCP again.
    install_config config/dhcpcd.conf.disabled /etc/dhcpcd.conf
else
    # netplan/systemd-networkd: give wlan0 back to its normal client config.
    for f in /etc/netplan/*.yaml.turnkey-disabled /etc/netplan/*.yml.turnkey-disabled; do
        [ -e "$f" ] || continue
        $SUDO mv "$f" "${f%.turnkey-disabled}"
    done
    install_config config/systemd-networkd.conf.disabled \
        "/etc/systemd/network/00-turnkey-${WLAN}.network"
    $SUDO networkctl reload >/dev/null 2>&1 || true
fi

# Unmask only the supplicant instances that enable_ap.sh masked for this
# interface.  Other radios' units were never touched and must stay as they are.
if [ "$WLAN" = wlan0 ]; then
    $SUDO systemctl unmask wpa_supplicant.service >/dev/null 2>&1 || true
fi
for unit in $(list_supplicant_units); do
    $SUDO systemctl unmask "$unit" >/dev/null 2>&1 || true
done

# Credentials written by the sign-in page, restored locally on either stack.
if [ -f wpa.conf ]; then
    if [ "$WLAN" = wlan0 ]; then
        $SUDO cp wpa.conf /etc/wpa_supplicant/wpa_supplicant.conf
    fi
    $SUDO cp wpa.conf "/etc/wpa_supplicant/wpa_supplicant-${WLAN}.conf"

    # Use the stack-specific unit when one already owns this interface.  Netplan
    # creates netplan-wpa-<iface>.service for wlan0; starting a second
    # supplicant there would fight it for the control socket.  Netplan creates
    # no unit for a USB adapter, so fall back to the distro's interface-specific
    # wpa_supplicant@<iface>.service template to make the selected WLAN a client.
    client_unit=""
    for unit in $(list_supplicant_units); do
        case "$unit" in
            "netplan-wpa-${WLAN}.service"|*"@${WLAN}.service")
                client_unit="$unit"
                break
                ;;
        esac
    done
    if [ -z "$client_unit" ] && systemctl cat wpa_supplicant@.service >/dev/null 2>&1; then
        client_unit="wpa_supplicant@${WLAN}.service"
    fi

    if [ -n "$client_unit" ]; then
        $SUDO systemctl unmask "$client_unit" >/dev/null 2>&1 || true
        $SUDO systemctl enable "$client_unit" >/dev/null 2>&1 || true
        $SUDO systemctl start "$client_unit" >/dev/null 2>&1 || true
    fi
fi

# Record client-mode intent so turnkey.service's ExecStartPre does not re-enter
# AP mode on reboot because of a stale "hostapd" status. startup.py will
# downgrade this to disconnected/hostapd if the WiFi link actually fails.
printf '{"status": "connected"}\n' > status.json
$SUDO chown pi:pi status.json 2>/dev/null || true

exec /sbin/reboot now
