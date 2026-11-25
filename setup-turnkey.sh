#!/usr/bin/env bash
# Install this checkout as the kiosk's WiFi provisioning service.
#
# Run as root while the board still has internet:
#
#   git clone https://github.com/hestiahacker/raspberry-pi-turnkey.git \
#       /home/pi/scripts/raspberry-pi-turnkey
#   cd /home/pi/scripts/raspberry-pi-turnkey
#   sudo ./setup-turnkey.sh [wifi-interface] [--dry-run] [--no-ap-scan]
#
# Everything written outside the repo except /etc/default/turnkey is a verbatim
# copy of a file in config/.  This script never switches WiFi into AP mode, so
# you'll stay online.

set -Eeuo pipefail

EXPECTED_DIR="/home/pi/scripts/raspberry-pi-turnkey"
SERVICE="/etc/systemd/system/turnkey.service"
TURNKEY_DEFAULT="/etc/default/turnkey"
KIOSK_OVERRIDE_DIR="/etc/systemd/system/kiosk.service.d"
KIOSK_OVERRIDE="$KIOSK_OVERRIDE_DIR/turnkey.conf"
PI_USER="pi"
WLAN="wlan0"
DRY_RUN=0
NO_AP_SCAN=0

log()  { printf '\n[*] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    (dry-run)'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

# Best-effort unit tweaks: informational only in dry-run mode.
run_quiet() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    (dry-run)'; printf ' %q' "$@"; printf '\n'
    else
        "$@" >/dev/null 2>&1 || true
    fi
}

usage() {
    cat <<'USAGE'
Usage: sudo ./setup-turnkey.sh [WIFI_INTERFACE] [--dry-run] [--no-ap-scan]

  WIFI_INTERFACE  Optional AP interface; defaults to wlan0.

  --dry-run       Show what would be changed; write nothing.

  --no-ap-scan    For chipsets that assert when scanned in AP mode: scan before
                  AP startup only, and show the saved list in the portal.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --no-ap-scan) NO_AP_SCAN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)        die "unknown argument: $1 (try --help)" ;;
        *)         [ "$WLAN" = wlan0 ] || die "only one WiFi interface may be given (try --help)"
                   WLAN="$1"; shift ;;
    esac
done

[[ "$WLAN" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid WiFi interface name: $WLAN"

check_repo() {
    [ "$(id -u)" -eq 0 ] || die "run this script as root (sudo ./setup-turnkey.sh)"
    local here
    here="$(cd "$(dirname "$0")" && pwd)"
    if [ "$here" != "$EXPECTED_DIR" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            warn "render-loader expects $EXPECTED_DIR, not $here"
        else
            die "check out this repo at $EXPECTED_DIR (render-loader looks for status.json there)"
        fi
    fi
    local f
    for f in startup.py enable_ap.sh disable_ap.sh wait-for-turnkey-status.sh \
             config/hostapd config/hostapd.conf config/dnsmasq.conf \
             config/turnkey.service config/kiosk-turnkey.conf; do
        [ -f "$here/$f" ] || die "missing $f in $here"
    done
}

ensure_pi_user() {
    if id "$PI_USER" >/dev/null 2>&1; then
        log "user $PI_USER already exists"
        return
    fi
    warn "creating $PI_USER (render-loader expects /home/pi/scripts)"
    local groups="" g
    for g in netdev dialout plugdev video render input audio sudo; do
        getent group "$g" >/dev/null 2>&1 && groups="${groups:+${groups},}${g}"
    done
    run useradd -m -s /bin/bash ${groups:+-G "$groups"} "$PI_USER"
}

install_packages() {
    log "Installing packages (this step needs internet)..."
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update
    # hostapd/dnsmasq: the AP; flask/requests: startup.py; wpasupplicant:
    # wpa_passphrase and client mode; iw: link detection and scans.
    run apt-get install -y --no-install-recommends \
        hostapd dnsmasq python3-flask python3-requests wpasupplicant iw iproute2
}

install_configs() {
    log "Installing configuration from the checkout..."
    run install -D -m 0644 "$EXPECTED_DIR/config/hostapd.conf" /etc/hostapd/hostapd.conf
    run install -D -m 0644 "$EXPECTED_DIR/config/hostapd"      /etc/default/hostapd
    run install -D -m 0644 "$EXPECTED_DIR/config/dnsmasq.conf" /etc/dnsmasq.conf
    run install -D -m 0644 "$EXPECTED_DIR/config/turnkey.service" "$SERVICE"
}

install_kiosk_override() {
    if ! systemctl cat kiosk.service >/dev/null 2>&1; then
        log "kiosk.service not installed; skipping kiosk override"
        return
    fi
    log "Making kiosk.service wait for turnkey.service..."
    run install -D -m 0644 "$EXPECTED_DIR/config/kiosk-turnkey.conf" "$KIOSK_OVERRIDE"
}

install_wlan_default() {
    # enable_ap.sh, disable_ap.sh and startup.py all read this file.
    log "Recording WiFi interface: $WLAN (AP scan disabled: $NO_AP_SCAN)"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    (dry-run) write %s: WLAN=%s NO_AP_SCAN=%s\n' \
            "$TURNKEY_DEFAULT" "$WLAN" "$NO_AP_SCAN"
        return
    fi
    install -d -m 0755 /etc/default
    printf 'WLAN=%s\nNO_AP_SCAN=%s\n' "$WLAN" "$NO_AP_SCAN" > "$TURNKEY_DEFAULT"
    chmod 0644 "$TURNKEY_DEFAULT"
}

enable_service() {
    log "Enabling turnkey.service..."
    run systemctl daemon-reload
    run systemctl enable turnkey.service
    # netplan creates netplan-wpa-wlan0.service itself.  Do not also enable
    # wpa_supplicant@wlan0.service or the two fight over the control socket.
    # For a non-wlan0 AP interface, disable_ap.sh enables the interface-specific
    # wpa_supplicant@<iface>.service after credentials are saved.
    # hostapd is masked in client mode; enable_ap.sh unmasks it when AP mode is
    # active. dnsmasq is only started on demand by enable_ap.sh as well.
    run_quiet systemctl disable hostapd.service dnsmasq.service
    run_quiet systemctl mask hostapd.service
    run systemctl start turnkey.service || warn "turnkey.service failed to start; check journalctl -u turnkey"
}

main() {
    check_repo
    ensure_pi_user
    install_packages
    install_configs
    install_kiosk_override
    install_wlan_default
    # startup.py writes pi.id, status.json and wpa.conf into the checkout.
    run chown -R "${PI_USER}:${PI_USER}" "$EXPECTED_DIR"
    enable_service

    log "Done."
    local enabled active
    enabled="$(systemctl is-enabled turnkey.service 2>/dev/null || true)"
    active="$(systemctl is-active turnkey.service 2>/dev/null || true)"
    echo "  service   : ${enabled:-unknown}/${active:-unknown}"
    echo "  status    : $(cat "$EXPECTED_DIR/status.json" 2>/dev/null || echo 'created on first start')"
    echo "  WiFi link : $(iw dev "$WLAN" link 2>/dev/null | grep -m1 'SSID:' | sed 's/^[[:space:]]*//' || echo 'not associated')"
    echo
    echo "If the board cannot reach its configured WiFi, turnkey starts the HESTIAPI"
    echo "access point automatically; join it and open http://192.168.4.1/ to set credentials."
}

main "$@"
