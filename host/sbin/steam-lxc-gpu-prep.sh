#!/bin/bash
# Pre-start: make sure the CT's config allows the *current* char majors of the NVIDIA devices that use dynamic majors
# (nvidia-uvm, nvidia-caps, nvidia-nvswitch, ...; they can change on any host reboot or driver update).
# Pre-start edits to /etc/pve/lxc/<ctid>.conf take effect for that start. Only the main section (before the first
# [snapshot] header) is checked and edited: a line that exists only in a snapshot section has no effect. Lines are only
# added, never removed. Usage: steam-lxc-gpu-prep.sh <ctid>   (override names with STEAM_LXC_NVIDIA_DEVS="a b ...")
set -eu
CT=${1:?ctid}; CONF=/etc/pve/lxc/$CT.conf
DEVS=${STEAM_LXC_NVIDIA_DEVS:-nvidia nvidia-modeset nvidiactl nvidia-uvm nvidia-caps nvidia-caps-imex-channels nvidia-nvswitch nvidia-nvlink}
[ -f "$CONF" ] || { echo "steam-lxc-gpu-prep: no $CONF" >&2; exit 1; }
want=$(for d in $DEVS; do awk -v d="$d" '/^Block devices:/{exit} $2==d{print $1}' /proc/devices; done | sort -un)
main=$(awk '/^\[/{exit} {print}' "$CONF")
missing=""
for m in $want; do
  grep -qx "lxc.cgroup2.devices.allow: c $m:\* rwm" <<<"$main" || missing="$missing $m"
done
[ -n "$missing" ] || exit 0
tmp=$(mktemp)
awk -v add="$missing" 'BEGIN{n=split(add,a," ")}
  /^\[/ && !done {for(i=1;i<=n;i++) print "lxc.cgroup2.devices.allow: c " a[i] ":* rwm"; done=1}
  {print}
  END{if(!done) for(i=1;i<=n;i++) print "lxc.cgroup2.devices.allow: c " a[i] ":* rwm"}' "$CONF" > "$tmp"
cat "$tmp" > "$CONF"; rm -f "$tmp"
echo "steam-lxc-gpu-prep: CT $CT: added c <major>:* rwm for:$missing"
logger -t steam-lxc-gpu-prep "CT $CT: added majors:$missing" 2>/dev/null || true
exit 0
