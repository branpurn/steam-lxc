#!/bin/bash
# Run ON THE PVE HOST. Creates a privileged steam-lxc CT from the Proxmox archlinux-base template with GPU/input/
# USB/FUSE/ntsync passthrough and installs the hookscript. Settings via env (defaults below).
# Host prerequisites: NVIDIA driver with nvidia-drm modeset=1 and nvidia-modprobe'd device nodes.
set -euo pipefail
CT=${CT:?set CT=<new ctid>}
TEMPLATE=${TEMPLATE:-archlinux-base_20260420-1_amd64.tar.zst}
STORAGE=${STORAGE:-local-lvm}; DISK_GB=${DISK_GB:-64}; CORES=${CORES:-8}; MEMORY=${MEMORY:-16384}
BRIDGE=${BRIDGE:-vmbr0}
SNIPPETS=${SNIPPETS:-local}               # PVE storage with "snippets" content
GPU_CARD=${GPU_CARD:-/dev/dri/card1}      # host DRM card of the GPU (prefer a stable udev symlink)
GPU_RENDER=${GPU_RENDER:-/dev/dri/renderD128}
STEAMLIB_HOST=${STEAMLIB_HOST:-}          # optional: host dir bind-mounted at /mnt/steamlib (shared Steam library)
EXTRA_LXC_CONF=${EXTRA_LXC_CONF:-}        # optional: file with more raw lxc.* lines (site-specific, e.g. a phys NIC)
here=$(cd "$(dirname "$0")" && pwd)

pveam update >/dev/null; pveam list local | grep -q "$TEMPLATE" || pveam download local "$TEMPLATE"
install -m 755 "$here/sbin/gpu-exclusive.sh" "$here/sbin/steam-lxc-gpu-prep.sh" /usr/local/sbin/
install -d /etc/steam-lxc/hook.d
snipdir=$(dirname "$(pvesm path "$SNIPPETS:snippets/x")")
install -D -m 755 "$here/hookscripts/steam-lxc-hook.sh" "$snipdir/steam-lxc-hook.sh"

pct create "$CT" "local:vztmpl/$TEMPLATE" --hostname steam-lxc --unprivileged 0 --ostype archlinux \
  --cores "$CORES" --memory "$MEMORY" --swap 8192 --rootfs "$STORAGE:$DISK_GB" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp,type=veth" --features nesting=1 --onboot 0 \
  --hookscript "$SNIPPETS:snippets/steam-lxc-hook.sh"

# Raw LXC lines must go before any [snapshot] section, so append them right after creation.
sed -e "s|@GPU_CARD@|$GPU_CARD|" -e "s|@GPU_RENDER@|$GPU_RENDER|" "$here/lxc.conf.fragment" | grep -v '^#' >> "/etc/pve/lxc/$CT.conf"
# The Steam library is a raw bind mount (not mpN) so that `pct snapshot` keeps working.
[ -n "$STEAMLIB_HOST" ] && echo "lxc.mount.entry: $STEAMLIB_HOST mnt/steamlib none bind,create=dir 0 0" >> "/etc/pve/lxc/$CT.conf"
[ -n "$EXTRA_LXC_CONF" ] && grep '^lxc\.' "$EXTRA_LXC_CONF" >> "/etc/pve/lxc/$CT.conf"
echo "Created CT $CT. Next: pct start $CT, push ct/ and run ct/install/*.sh in order (see README)."
