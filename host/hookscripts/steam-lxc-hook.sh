#!/bin/bash
# Proxmox hookscript for a steam-lxc CT: GPU exclusivity and GPU cgroup prep, then any site-specific hooks in
# /etc/steam-lxc/hook.d/ (executable files, called as: <hook> <ctid> <phase>), e.g. passing a USB Wi-Fi adapter.
case "$2" in
  pre-start)
    /usr/local/sbin/gpu-exclusive.sh "$1" || exit 1
    /usr/local/sbin/steam-lxc-gpu-prep.sh "$1" ;;
esac
for h in /etc/steam-lxc/hook.d/*; do
  [ -x "$h" ] && { "$h" "$1" "$2" || [ "$2" != pre-start ] || exit 1; }
done
exit 0
