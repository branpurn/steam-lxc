#!/bin/bash
# Refuse to start a GPU CT while another GPU CT is running. Usage: gpu-exclusive.sh <ctid>
# GPU CTs: $GPU_CTS (or GPU_CTS= in /etc/steam-lxc/host.conf); default = every CT whose config passes /dev/nvidia0.
[ -r /etc/steam-lxc/host.conf ] && . /etc/steam-lxc/host.conf
if [ -z "${GPU_CTS:-}" ]; then
  GPU_CTS=$(grep -l 'dev/nvidia0' /etc/pve/lxc/*.conf 2>/dev/null | xargs -rn1 basename | sed 's/\.conf$//')
fi
for o in $GPU_CTS; do
  [ "$o" = "$1" ] && continue
  if pct status "$o" 2>/dev/null | grep -q running; then
    echo "gpu-exclusive: CT $o is running and owns the GPU; stop it before starting CT $1" >&2; exit 1
  fi
done
exit 0
