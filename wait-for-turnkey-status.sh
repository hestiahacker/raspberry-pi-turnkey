#!/bin/bash
# Let turnkey.service finish its AP/client decision and let the WiFi interface
# acquire its address before the kiosk loader renders.  Only used by the
# optional kiosk.service override.
set -u

repo=/home/pi/scripts/raspberry-pi-turnkey
status="$repo/status.json"
[ -r /etc/default/turnkey ] && . /etc/default/turnkey
WLAN=${WLAN:-wlan0}

has_ip() {
    ip -4 -o addr show dev "$WLAN" 2>/dev/null | grep -qv 'inet 169\.254\.'
}

wait_for_ip() {
    for _ in $(seq 1 "$1"); do
        has_ip && return 0
        sleep 1
    done
    return 1
}

initial_mtime=$(stat -c %y "$status" 2>/dev/null || echo 0)
# Wait no more than 25 seconds for the file to be updated
for _ in $(seq 1 25); do
    current_mtime=$(stat -c %y "$status" 2>/dev/null || echo 0)
    # the "modified time" changed, proceed
    [ "$current_mtime" != "$initial_mtime" ] && break
    sleep 1
done
# startup.py can write a transient status immediately before the final one.
sleep 1

# Normal case: the interface already has the address the loader will print.
if wait_for_ip 15; then
    exit 0
fi

# Only AP mode may change the radio; never force AP for a client connection.
if grep -q '"status": "hostapd"' "$status" 2>/dev/null; then
    "$repo/enable_ap.sh" --no-reboot >/dev/null 2>&1 || true
    wait_for_ip 15 || true
fi
exit 0
