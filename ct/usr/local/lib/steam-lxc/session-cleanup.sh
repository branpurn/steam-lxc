#!/bin/bash
# Stop every leftover Game Mode / Desktop Mode process of the session user so nothing keeps DRM master.
# Why: PAMName=login makes pam_systemd move each session into a logind scope (user-UID.slice/session-cN.scope),
# outside the service's cgroup, so systemd's KillMode=control-group on stop/restart never reaches gamescope/Plasma.
# Leaves the user manager (user@UID.service: D-Bus, PipeWire) alone. Run as root from ExecStartPre and ExecStopPost.
[ -f /etc/default/steam-lxc ] && . /etc/default/steam-lxc
u=${STEAM_LXC_USER:-steam}
in_session() { for p in $(pgrep -u "$u"); do grep -q 'session-[^/]*\.scope' "/proc/$p/cgroup" 2>/dev/null && echo "$p"; done; }
loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$u" '$3==u && $4=="seat0" {print $1}' | while read -r s; do
  loginctl terminate-session "$s" 2>/dev/null
done
for i in $(seq 20); do [ -z "$(in_session)" ] && break; sleep 0.5; done
p=$(in_session); [ -n "$p" ] && kill -9 $p 2>/dev/null
pkill -9 -u "$u" -x x11vnc 2>/dev/null
for i in $(seq 10); do pgrep -u "$u" -x 'gamescope-wl|gamescope|kwin_wayland' >/dev/null || break; sleep 0.5; done
rm -f /tmp/.X0-lock /tmp/.X1-lock
exit 0
