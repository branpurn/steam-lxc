#!/bin/bash
# Pre-start: make sure the CT's cgroup allows the *current* char majors of nvidia-uvm and nvidia-caps
# (dynamic majors change across kernel/driver updates). Usage: steam-lxc-gpu-prep.sh <ctid>
CT=${1:?ctid}; CONF=/etc/pve/lxc/$CT.conf
for dev in nvidia-uvm nvidia-caps; do
  maj=$(awk -v d="$dev" '$2==d{print $1}' /proc/devices)
  [ -n "$maj" ] || continue
  grep -q "^lxc.cgroup2.devices.allow: c $maj:\* rwm" "$CONF" || {
    sed -i "0,/^\[/s//lxc.cgroup2.devices.allow: c $maj:* rwm\n[/" "$CONF"
    grep -q "^lxc.cgroup2.devices.allow: c $maj:\* rwm" "$CONF" || echo "lxc.cgroup2.devices.allow: c $maj:* rwm" >> "$CONF"
    echo "steam-lxc-gpu-prep: added c $maj:* for $dev"; }
done
exit 0
