#!/bin/bash
# Pre-start for CT 600: make sure the cgroup allows the *current* char majors of
# nvidia-uvm and nvidia-caps (dynamic majors change across kernel/driver updates).
# Also warn if the stable GPU symlinks are missing. Usage: enclave-gpu-prep.sh <ctid>
CT=${1:-600}; CONF=/etc/pve/lxc/$CT.conf
for dev in nvidia-uvm nvidia-caps; do
  maj=$(awk -v d="$dev" '$2==d{print $1}' /proc/devices)
  [ -n "$maj" ] || continue
  grep -q "^lxc.cgroup2.devices.allow: c $maj:\* rwm" "$CONF" || {
    echo "lxc.cgroup2.devices.allow: c $maj:* rwm" >> "$CONF"; echo "enclave-gpu-prep: added c $maj:* for $dev"; }
done
for l in card render; do [ -e /dev/dri/enclave-gpu-$l ] || echo "enclave-gpu-prep: WARNING /dev/dri/enclave-gpu-$l missing (udev rule 71-enclave-gpu.rules?)" >&2; done
exit 0
