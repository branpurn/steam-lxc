#!/bin/bash
# Refuse to start a GPU CT while another GPU CT is running. Usage: gpu-exclusive.sh <ctid>
GPU_CTS="${GPU_CTS:-600 601}"
for o in $GPU_CTS; do
  [ "$o" = "$1" ] && continue
  if pct status "$o" 2>/dev/null | grep -q running; then
    echo "gpu-exclusive: CT $o is running and owns the GPU; stop it before starting CT $1" >&2; exit 1
  fi
done
exit 0
