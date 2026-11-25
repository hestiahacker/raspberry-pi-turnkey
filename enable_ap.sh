#!/bin/bash
# Enable the turnkey AP so users can connect and enter their wifi settings
#
# The network stack is detected at runtime and every setting comes from config/
# next to this script.  Nothing here needs the internet. Calling this with
# --no-reboot re-applies AP mode without rebooting (used by turnkey.service) and
# is a no-op unless status.json says "hostapd".

set -u
cd "$(dirname "$0")"

# Optional settings from setup-turnkey.sh (WLAN is the only one used here).
[ -r /etc/default/turnkey ] && . /etc/default/turnkey
WLAN="${WLAN:-wlan0}"
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO=sudo

NO_REBOOT=0
[ "${1:-}" = "--no-reboot" ] && NO_REBOOT=1
if [ "$NO_REBOOT" -eq 1 ] && ! grep -q hostapd status.json 2>/dev/null; then
    # We already have working wifi, don't change anything
    exit 0
fi

# Prefer stopping/disabling the unit; only fall back to the disabled config
# file when systemd cannot do it.  All configs live in config/.
stop_service() {
    local unit="$1" disabled="$2" dest="$3"
    if $SUDO systemctl disable --now "$unit" >/dev/null 2>&1; then
        return 0
    fi
    [ -f "$disabled" ] && $SUDO cp "$disabled" "$dest"
}

# Enumerate only the supplicant instances that actually exist for the AP
# interface.  Templates such as wpa_supplicant@.service are skipped.  Other
# radios' supplicants (for example netplan-wpa-wlan0.service when the AP is on
# a USB adapter) must stay up so client-mode internet is not lost.
list_supplicant_units() {
    local pat="${WLAN//./\\.}"
    {
        systemctl list-units --all --no-legend --plain 2>/dev/null
        systemctl list-unit-files --no-legend --plain 2>/dev/null
    } | awk '{print $1}' |
        grep -E "^(wpa_supplicant@|wpa_supplicant-nl80211@|wpa_supplicant-wired@|netplan-wpa-)${pat}\\.service$" |
        sort -u
}

# A station-mode supplicant left running on the AP interface will fight hostapd
# for that radio ("Failed to set beacon parameters").  Stop/disable/mask only
# instances for WLAN, then clear that interface's stale control sockets and
# netplan runtime state.
stop_supplicants() {
    local unit
    if [ "$WLAN" = wlan0 ]; then
        # On the original single-radio setup the generic service owns wlan0.
        $SUDO systemctl disable --now wpa_supplicant.service >/dev/null 2>&1 || true
        $SUDO cp config/wpa_supplicant.conf.disabled /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null || true
    fi
    for unit in $(list_supplicant_units); do
        $SUDO systemctl disable --now "$unit" >/dev/null 2>&1 || true
        $SUDO systemctl mask "$unit" >/dev/null 2>&1 || true
    done
    $SUDO rm -f "/run/wpa_supplicant/${WLAN}" "/var/run/wpa_supplicant/${WLAN}" 2>/dev/null || true
    $SUDO rm -f "/run/netplan/wpa-${WLAN}.conf" 2>/dev/null || true
}

# Install a config file, adapting the interface name from the shipped wlan0.
install_config() {
    local src="$1" dest="$2"
    if [ "$WLAN" = wlan0 ]; then
        $SUDO cp "$src" "$dest"
    else
        sed "s/wlan0/$WLAN/g" "$src" | $SUDO tee "$dest" >/dev/null
    fi
}

# wpa_supplicant must not associate while hostapd owns the radio.
stop_supplicants

if [ -f /etc/dhcpcd.conf ] && command -v dhcpcd >/dev/null 2>&1; then
    # Raspbian: dhcpcd owns wlan0, so give it the AP's static address.
    install_config config/dhcpcd.conf /etc/dhcpcd.conf
else
    # netplan/systemd-networkd: keep netplan's supplicant and (if present)
    # dhcpcd away from the interface, then let networkd own it.
    stop_service dhcpcd.service config/dhcpcd.conf.disabled /etc/dhcpcd.conf
    for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [ -e "$f" ] || continue
        grep -Eq "(^|[[:space:]])${WLAN}:|wifis:" "$f" || continue
        [ -e "$f.turnkey-disabled" ] || $SUDO mv "$f" "$f.turnkey-disabled"
    done
    install_config config/systemd-networkd.conf \
        "/etc/systemd/network/00-turnkey-${WLAN}.network"
    $SUDO networkctl reload >/dev/null 2>&1 || true
fi

# Debian/Armbian ship these units masked; both must be unmasked to serve AP mode.
# dnsmasq supplies the portal's DHCP/DNS, so a masked unit would leave clients
# with no address and no working captive portal.
$SUDO systemctl unmask hostapd.service dnsmasq.service >/dev/null 2>&1 || true

# hostapd and dnsmasq serve the portal from the shipped config files.
$SUDO cp config/hostapd /etc/default/hostapd
install_config config/hostapd.conf /etc/hostapd/hostapd.conf
install_config config/dnsmasq.conf /etc/dnsmasq.conf
# Start sequentially: on USB radios hostapd must first finish switching the
# interface to AP mode.  Starting both in one systemctl call lets dnsmasq race
# that mode change and exit with "unknown interface <ifname>".
$SUDO systemctl start hostapd.service >/dev/null 2>&1 || true
$SUDO systemctl start dnsmasq.service >/dev/null 2>&1 || true

[ "$NO_REBOOT" -eq 0 ] && exec /sbin/reboot now
exit 0
