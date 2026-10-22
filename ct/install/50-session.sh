#!/bin/bash
# Install the steam-lxc session units/scripts from the extracted ct/ tree (run as root inside the CT, from repo ct/).
set -euo pipefail
cd "$(dirname "$0")/.."
cp -r etc usr /
rm -rf /etc/skel-steam-lxc
# Site configuration: keep an existing /etc/default/steam-lxc, otherwise start from the example.
[ -e /etc/default/steam-lxc ] || install -m 644 etc/default/steam-lxc.example /etc/default/steam-lxc
. /etc/default/steam-lxc
# Desktop Mode user files (autostart: display setup + Steam; 'Return to Gaming Mode' on the desktop)
U=${STEAM_LXC_USER:-steam}; H=$(getent passwd "$U" | cut -d: -f6)
cp -rT etc/skel-steam-lxc "$H"; chown -R "$U:$U" "$H/.config/autostart" "$H/Desktop"
chmod +x /usr/libexec/os-session-select /usr/local/bin/* /usr/local/sbin/* /usr/local/lib/steam-lxc/*
pacman -S --noconfirm --needed wayland python-evdev >/dev/null
bash src/gamescope-display-wake/build.sh
/usr/local/sbin/steam-lxc-libdrm-link
# setcap on gamescope is not possible here: PVE drops CAP_SETFCAP inside the CT (verified). gamescope runs without realtime priority.
systemctl daemon-reload
systemctl enable host-udev-db.service steam-lxc-dev-acl.service steam-lxc-dev-acl.path steam-lxc-dev-acl.timer \
  steamos-session.service steam-lxc-vnc.service steam-lxc-display-keepawake.service steam-lxc-game-killer.service
loginctl enable-linger "$U" || true
