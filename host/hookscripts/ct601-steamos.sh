#!/bin/bash
# Proxmox hookscript for CT 601 (steam-lxc): GPU exclusivity, GPU cgroup prep, Frame Wi-Fi dongle stable host name.
case "$2" in
  pre-start)
    /usr/local/sbin/gpu-exclusive.sh "$1" || exit 1
    /usr/local/sbin/enclave-gpu-prep.sh "$1"
    [ -x /usr/local/sbin/enclave-wifi.sh ] && /usr/local/sbin/enclave-wifi.sh rename ;;
  post-stop)
    [ -x /usr/local/sbin/enclave-wifi.sh ] && /usr/local/sbin/enclave-wifi.sh rename ;;
esac
exit 0
