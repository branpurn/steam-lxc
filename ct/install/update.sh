#!/bin/bash
# Run ON THE PVE HOST: snapshot CT first, then pacman -Syu inside it. Usage: update.sh <ctid>
set -euo pipefail
CT=${1:?ctid}
pct snapshot "$CT" "pre-syu-$(date +%Y%m%d-%H%M%S)"
pct exec "$CT" -- pacman -Syu --noconfirm
pct exec "$CT" -- nvidia-smi --query-gpu=driver_version --format=csv,noheader
