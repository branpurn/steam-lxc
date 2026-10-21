#!/bin/sh
# Grant the session user rw on input/DRI/ntsync/uinput nodes (re-run when DRM cards are recreated).
set -eu
[ -f /etc/default/steam-lxc ] && . /etc/default/steam-lxc
u=${STEAM_LXC_USER:-steam}
id "$u" >/dev/null 2>&1 || exit 0
for d in /dev/uinput /dev/ntsync /dev/dri/card* /dev/dri/renderD* /dev/input/event* /dev/hidraw*; do
  [ -e "$d" ] || continue
  setfacl -m "u:$u:rw" "$d" || true
done
