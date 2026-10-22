#!/bin/bash
# Stop every leftover Game Mode process of the session user so no orphaned gamescope keeps DRM master.
# Why: PAMName=login makes pam_systemd move the session into a logind scope (user-UID.slice/session-cN.scope),
# outside the service's cgroup, so systemd's KillMode=control-group on stop/restart never reaches gamescope/Steam.
# Run as root from ExecStartPre and ExecStopPost.
[ -f /etc/default/steam-lxc ] && . /etc/default/steam-lxc
u=${STEAM_LXC_USER:-steam}
# 1) terminate the user's seat0/x11 logind sessions (stops their scopes = whole process tree)
loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$u" '$3==u && $4=="seat0" {print $1}' | while read -r s; do
  loginctl terminate-session "$s" 2>/dev/null
done
# 2) wait for gamescope/Steam to go, then SIGKILL stragglers (not the user's systemd manager/D-Bus/PipeWire)
pat='gamescope|gamescope-wl|Xwayland|steam|steamwebhelper|steam\.sh|reaper|pressure-vessel|srt-logger|mangoapp|x11vnc'
for i in $(seq 20); do pgrep -u "$u" -f "$pat" >/dev/null || break; sleep 0.5; done
pkill -9 -u "$u" -f "$pat" 2>/dev/null
for i in $(seq 10); do pgrep -u "$u" -x gamescope-wl >/dev/null || pgrep -u "$u" -x gamescope >/dev/null || break; sleep 0.5; done
rm -f /tmp/.X0-lock /tmp/.X1-lock
exit 0
