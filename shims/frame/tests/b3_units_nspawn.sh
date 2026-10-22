#!/bin/bash
# B3 (offline): boot a throwaway Debian systemd container with systemd-nspawn and run b3_units_guest.sh in it.
# Needs root, systemd-nspawn and a debootstrapped root: sudo debootstrap --variant=minbase \
#   --include=systemd,systemd-sysv,dbus,dbus-user-session,procps,python3,util-linux,x11-utils,bsdutils trixie ROOT
# Usage: sudo tests/b3_units_nspawn.sh ROOT     (ROOT is copied; the original stays clean)
set -eu
ROOT=$1; SRC=$(cd "$(dirname "$0")/.." && pwd); W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp -a "$ROOT" "$W/root"
mkdir -p "$W/root/src/shims" "$W/out"
cp -a "$SRC" "$W/root/src/shims/frame"
cat > "$W/root/etc/systemd/system/b3.service" <<U
[Unit]
After=multi-user.target systemd-logind.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'bash /src/shims/frame/tests/b3_units_guest.sh > /out/b3.log 2>&1; systemctl poweroff'
[Install]
WantedBy=multi-user.target
U
ln -sf /etc/systemd/system/b3.service "$W/root/etc/systemd/system/multi-user.target.wants/b3.service"
timeout 300 systemd-nspawn -q -b --keep-unit --register=no -D "$W/root" --bind="$W/out:/out" > "$W/out/console.log" 2>&1 || true
[ -f "$W/out/b3.log" ] || { echo "guest did not run; console:"; tail -30 "$W/out/console.log"; exit 1; }
cat "$W/out/b3.log"
grep -q '^B3 OK' "$W/out/b3.log"
