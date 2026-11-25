#!/bin/bash
# Let turnkey.service finish its AP/client decision before the kiosk loader
# renders.  Only used by the optional kiosk.service override.
set -u

status=/home/pi/scripts/raspberry-pi-turnkey/status.json
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
exit 0
