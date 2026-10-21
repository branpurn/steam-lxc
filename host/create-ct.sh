#!/bin/bash
# Run ON THE PVE HOST. Creates the steam-lxc CT from the Proxmox archlinux-base template with GPU/input/USB/FUSE/
# ntsync passthrough, the shared Steam library and the Frame Wi-Fi dongle, then installs the hookscript.
# Edit the variables below. Assumes the host prep from the gaming-enclave project (nvidia modules with
# nvidia-drm modeset=1, 71-enclave-gpu.rules stable /dev/dri/enclave-gpu-* names, enclave-wifi.sh).
set -euo pipefail
CT=${CT:-601}
TEMPLATE=${TEMPLATE:-archlinux-base_20260420-1_amd64.tar.zst}
STORAGE=${STORAGE:-local-lvm}; DISK_GB=${DISK_GB:-64}
BRIDGE=${BRIDGE:-vmbr1}
SNIPPETS=${SNIPPETS:-iso_images}          # PVE storage with "snippets" content
STEAMLIB_HOST=${STEAMLIB_HOST:-/mnt/fast_storage/steamlib}
here=$(cd "$(dirname "$0")" && pwd)

pveam update >/dev/null; pveam list local | grep -q "$TEMPLATE" || pveam download local "$TEMPLATE"
install -m 755 "$here/sbin/gpu-exclusive.sh" /usr/local/sbin/gpu-exclusive.sh
[ -x /usr/local/sbin/enclave-gpu-prep.sh ] || install -m 755 "$here/sbin/enclave-gpu-prep.sh" /usr/local/sbin/
snipdir=$(pvesm path "$SNIPPETS:snippets/x" | xargs dirname)
install -m 755 "$here/hookscripts/ct601-steamos.sh" "$snipdir/ct${CT}-steamos.sh"

pct create "$CT" "local:vztmpl/$TEMPLATE" --hostname steam-lxc --unprivileged 0 --ostype archlinux \
  --cores 16 --memory 32768 --swap 8192 --rootfs "$STORAGE:$DISK_GB" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth" --features nesting=1 --onboot 0 \
  --hookscript "$SNIPPETS:snippets/ct${CT}-steamos.sh"

# Raw LXC lines must go before any [snapshot] section, so append them right after creation.
# The Steam library is a raw bind mount (not mpN) so that `pct snapshot` keeps working.
cat "$here/lxc-601.conf.fragment" | sed "s|@STEAMLIB_HOST@|$STEAMLIB_HOST|" >> "/etc/pve/lxc/$CT.conf"
echo "Created CT $CT. Next: pct start $CT, push ct/ and run ct/install/*.sh in order (see README)."
