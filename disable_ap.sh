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

# The AP services are no longer needed.
stop_service hostapd.service config/hostapd.disabled /etc/default/hostapd
stop_service dnsmasq.service config/dnsmasq.conf.disabled /etc/dnsmasq.conf

if [ -f /etc/dhcpcd.conf ] && command -v dhcpcd >/dev/null 2>&1; then
    # Raspbian: drop the static AP address so dhcpcd uses DHCP again.
    install_config config/dhcpcd.conf.disabled /etc/dhcpcd.conf
else
    # netplan/systemd-networkd: give wlan0 back to its normal client config.
    $SUDO systemctl unmask "netplan-wpa-${WLAN}.service" >/dev/null 2>&1 || true
    for f in /etc/netplan/*.yaml.turnkey-disabled /etc/netplan/*.yml.turnkey-disabled; do
        [ -e "$f" ] || continue
        $SUDO mv "$f" "${f%.turnkey-disabled}"
    done
    install_config config/systemd-networkd.conf.disabled \
        "/etc/systemd/network/00-turnkey-${WLAN}.network"
    $SUDO networkctl reload >/dev/null 2>&1 || true
fi

# Credentials written by the sign-in page, restored locally on either stack.
if [ -f wpa.conf ]; then
    $SUDO cp wpa.conf /etc/wpa_supplicant/wpa_supplicant.conf
    $SUDO cp wpa.conf "/etc/wpa_supplicant/wpa_supplicant-${WLAN}.conf"
    $SUDO systemctl unmask "wpa_supplicant@${WLAN}.service" >/dev/null 2>&1 || true
    $SUDO systemctl enable "wpa_supplicant@${WLAN}.service" >/dev/null 2>&1 || true
fi

exec /sbin/reboot now
