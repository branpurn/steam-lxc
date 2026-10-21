#!/bin/bash
# Inside the CT as root. Creates the session user (UID 1000 = owner of the shared Steam library) and sets the
# login + VNC password from a root-only file that is shredded afterwards. Never pass the password on a command line.
#   install -m600 /dev/stdin /root/.steam-lxc-pass   # paste password, Ctrl-D
set -euo pipefail
U=${STEAM_LXC_USER:-steam}; PF=/root/.steam-lxc-pass
[ -s "$PF" ] || { echo "missing $PF" >&2; exit 1; }
id "$U" >/dev/null 2>&1 || useradd -m -u 1000 -U -G wheel,video,render,input,audio -s /bin/bash "$U"
printf '%s:%s\n' "$U" "$(cat "$PF")" | chpasswd
install -d -o "$U" -g "$U" -m 700 "/home/$U/.vnc"
x11vnc -storepasswd "$(head -c8 "$PF")" "/home/$U/.vnc/passwd" >/dev/null 2>&1   # VNC uses only 8 chars
chown "$U:$U" "/home/$U/.vnc/passwd"; chmod 600 "/home/$U/.vnc/passwd"
shred -u "$PF"
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel; chmod 440 /etc/sudoers.d/10-wheel
ln -sf /usr/share/zoneinfo/${TZ_NAME:-America/New_York} /etc/localtime
