import subprocess
import signal
import string
import random
import re
import json
import time
import os
from shutil import which
import requests

from flask import Flask, request, send_from_directory, jsonify, render_template, redirect
app = Flask(__name__, static_url_path='')

currentdir = os.path.dirname(os.path.abspath(__file__))
os.chdir(currentdir)

# Written by setup-turnkey.sh; keeps every interface reference in sync.
WLAN = 'wlan0'
try:
    with open('/etc/default/turnkey') as f:
        for line in f:
            if line.startswith('WLAN='):
                WLAN = line.split('=', 1)[1].strip().strip('"\'')
                break
except OSError:
    pass

ssid_list = []
def getssid():
    global ssid_list
    if len(ssid_list) > 0:
        return ssid_list
    ssid_list = []
    try:
        get_ssid_list = subprocess.check_output(('iw', 'dev', WLAN, 'scan', 'ap-force'),
                                                stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, OSError):
        try:
            get_ssid_list = subprocess.check_output(('iw', 'dev', WLAN, 'scan'),
                                                    stderr=subprocess.DEVNULL)
        except (subprocess.CalledProcessError, OSError):
            get_ssid_list = b''  # fall back to the last known SSID below
    ssids = get_ssid_list.splitlines()
    for s in ssids:
        s = s.strip().decode('utf-8')
        if s.startswith("SSID"):
            a = s.split(": ")
            try:
                ssid_list.append(a[1])
            except:
                pass
    print(ssid_list)
    if not ssid_list:
        # A scan can fail while hostapd owns the radio; at least offer the
        # network we were connected to before.
        try:
            old = open('wpa.conf', 'r').read()
            hit = re.search(r'ssid\s*=\s*"?([^"\n]+)"?', old)
            if hit:
                ssid_list.append(hit.group(1).strip())
        except OSError:
            pass
    ssid_list = sorted(list(set(ssid_list)))
    return ssid_list

def id_generator(size=6, chars=string.ascii_lowercase + string.digits):
    return ''.join(random.choice(chars) for _ in range(size))

wpa_conf = """country=GB
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid="%s"
    %s
}"""

wpa_conf_default = """country=GB
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
"""

AP_PROFILE_ADDRESS = '192.168.4.1'


def client_ip(interface=WLAN):
    """Return a usable client address, ignoring the AP's static profile."""
    try:
        out = subprocess.check_output(
            ['ip', '-4', '-o', 'addr', 'show', interface],
            stderr=subprocess.DEVNULL).decode('utf-8', 'replace')
    except (subprocess.CalledProcessError, OSError):
        return None
    for line in out.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[2] == 'inet':
            address = fields[3].split('/')[0]
            if address == AP_PROFILE_ADDRESS or address.startswith('169.254.'):
                continue
            return address
    return None


def portal_page():
    piid = open('pi.id', 'r').read().strip()
    return render_template('index.html', ssids=getssid())

@app.route('/')
def main():
    return portal_page()

@app.route('/generate_204')
def redirect204():
    return redirect("http://192.168.4.1", code=302)

@app.route('/hotspot-detect.html')
def applecaptive():
    return redirect("http://192.168.4.1", code=302)

# Not working for Windows, needs work!
@app.route('/ncsi.txt')
def windowscaptive():
    return redirect("http://192.168.4.1", code=302)

def check_cred(ssid, password):
    '''Validates ssid and password and returns True if valid and False if not valid'''
    valid_psk=False
    wpadir = currentdir + '/wpa/'
    testconf = wpadir + 'test.conf'
    wpalog = wpadir + 'wpa.log'
    wpapid = wpadir + 'wpa.pid'

    if not os.path.exists(wpadir):
        os.mkdir(wpadir)

    for _file in [testconf, wpalog, wpapid]:
        if os.path.exists(_file):
            os.remove(_file)

    # Generate temp wpa.conf
    result = subprocess.check_output(['wpa_passphrase', ssid, password])
    with open(testconf, 'w') as f:
        f.write(result.decode('utf-8'))

    def stop_ap(stop):
        # dhcpcd only exists on older versions of Debian; on newer ones, the
        # WiFi interface is managed by systemd-networkd instead.  Never let a
        # missing unit break the sign-in form.
        units = ['hostapd', 'dnsmasq'] + (['dhcpcd'] if stop else [])
        for unit in units:
            subprocess.call(['systemctl', 'stop' if stop else 'start', unit],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not stop:
            time.sleep(15)

    # Sentences to check for
    fail = "pre-shared key may be incorrect"
    success = "WPA: Key negotiation completed"

    stop_ap(True)

    if which("nmcli") is not None:
        # If we have nmcli, we prefer that over doing things manually
        result = subprocess.check_output(['nmcli',
                                          'device',
                                          'wifi',
                                          'connect',
                                          ssid,
                                          'password',
                                          password])
        if b"successfully activated" in result:
            valid_psk=True
    else:
        result = subprocess.check_output(['wpa_supplicant',
                                          "-Dnl80211",
                                          "-i" + WLAN,
                                          "-c/" + testconf,
                                          "-f", wpalog,
                                          "-B",
                                          "-P", wpapid])

        checkwpa = True
        while checkwpa:
            with open(wpalog, 'r') as f:
                content = f.read()
                if success in content:
                    valid_psk = True
                    checkwpa = False
                elif fail in content:
                    valid_psk = False
                    checkwpa = False
                else:
                    continue

        # Kill wpa_supplicant to stop it from setting up dhcp, dns
        with open(wpapid, 'r') as p:
            pid = p.read()
            pid = int(pid.strip())
            os.kill(pid, signal.SIGTERM)

    stop_ap(False) # Restart services
    return valid_psk

@app.route('/static/<path:path>')
def send_static(path):
    return send_from_directory('static', path)

@app.route('/signin', methods=['POST'])
def signin():
    email = request.form['email']
    # The template offers a scanned list plus a free-text box for hidden or
    # not-yet-scanned networks.
    ssid = request.form.get('ssid_manual', '').strip() or request.form.get('ssid', '')
    password = request.form['password']

    pwd = 'psk="' + password + '"'
    if password == "":
        pwd = "key_mgmt=NONE" # If open AP

    print(email, ssid, password)
    valid_psk = check_cred(ssid, password)
    if not valid_psk:
        # User will not see this because they will be disconnected but we need to break here anyway
        return render_template('ap.html', message="Wrong password!")

    with open('wpa.conf', 'w') as f:
        f.write(wpa_conf % (ssid, pwd))
    with open('status.json', 'w') as f:
        f.write(json.dumps({'status':'disconnected'}))
    subprocess.Popen(["./disable_ap.sh"])
    piid = open('pi.id', 'r').read().strip()
    return render_template('index.html', message="Please wait 2 minutes to connect.")

def wificonnected():
    # iwconfig reports an ESSID even while hostapd is running in AP mode,
    # which would make the portal think it was online and hide the form.
    # `iw dev ... link` reports a station association, but a leftover
    # wpa_supplicant can stay associated while networkd still holds the AP's
    # 192.168.4.1 profile. Require a real client address as well.
    try:
        out = subprocess.check_output(['iw', 'dev', WLAN, 'link'],
                                      stderr=subprocess.DEVNULL).decode('utf-8', 'replace')
    except (subprocess.CalledProcessError, OSError):
        return False
    match = re.search(r'^\s*SSID:\s*(.+?)\s*$', out, re.MULTILINE)
    if match and client_ip():
        print("got connected to " + match.group(1))
        return True
    if match:
        print("associated to " + match.group(1) + " but no usable client IP yet")
    return False

if __name__ == "__main__":
    # things to run the first time it boots
    if not os.path.isfile('pi.id'):
        with open('pi.id', 'w') as f:
            f.write(id_generator())
        subprocess.Popen("./expand_filesystem.sh")
        time.sleep(300)
    piid = open('pi.id', 'r').read().strip()
    print(piid)
    time.sleep(15)
    # get status
    s = {'status':'disconnected'}
    if not os.path.isfile('status.json'):
        with open('status.json', 'w') as f:
            f.write(json.dumps(s))
    else:
        s = json.load(open('status.json'))

    # Check the connection. If we are associated but DHCP has not completed yet,
    # give it a short grace period instead of immediately switching to AP mode.
    connected = wificonnected()
    if not connected and s.get('status') == 'connected':
        for _ in range(6):
            time.sleep(5)
            connected = wificonnected()
            if connected:
                break

    if connected:
        s['status'] = 'connected'
    if not connected:
        if s['status'] == 'connected': # Don't change if status in status.json is hostapd
            s['status'] = 'disconnected'

    with open('status.json', 'w') as f:
        f.write(json.dumps(s))
    if s['status'] == 'disconnected':
        s['status'] = 'hostapd'
        with open('status.json', 'w') as f:
            f.write(json.dumps(s))
        with open('wpa.conf', 'w') as f:
            f.write(wpa_conf_default)
        subprocess.Popen("./enable_ap.sh")
    elif s['status'] == 'connected':
        piid = open('pi.id', 'r').read().strip()

        # Get the address from WLAN itself. Opening a socket to 8.8.8.8 just
        # to discover it crashes with "Network is unreachable" when offline.
        ipaddress = client_ip() or 'unknown'

        # Run the startup script
        subprocess.Popen("./startup.sh")
        while True:
            time.sleep(60000)
    else:
        app.run(host="0.0.0.0", port=80, threaded=True)
