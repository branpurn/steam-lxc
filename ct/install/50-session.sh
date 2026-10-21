#!/bin/bash
# Install the steam-lxc session units/scripts from the extracted ct/ tree (run as root inside the CT, from repo ct/).
set -euo pipefail
cd "$(dirname "$0")/.."
cp -r etc usr / 
chmod +x /usr/local/bin/steamos-session /usr/local/bin/steam-lxc-vnc /usr/local/lib/steam-lxc/dev-acl.sh /usr/local/sbin/steam-lxc-libdrm-link
/usr/local/sbin/steam-lxc-libdrm-link
# setcap on gamescope is not possible here: PVE drops CAP_SETFCAP inside the CT (verified). gamescope runs without realtime priority.
systemctl daemon-reload
systemctl enable host-udev-db.service steam-lxc-dev-acl.service steam-lxc-dev-acl.path steam-lxc-dev-acl.timer steamos-session.service steam-lxc-vnc.service
loginctl enable-linger steam || true
