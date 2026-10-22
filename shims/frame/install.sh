#!/bin/bash
# Frame shim installer. Inside the CT as root, from shims/frame/. Idempotent. Installs files only; it never starts,
# stops or restarts SteamVR, Steam, gamescope or the session. Each piece follows its toggle in /etc/default/steam-lxc.
set -e
cd "$(dirname "$0")"
. /etc/default/steam-lxc
U=${STEAM_LXC_USER:-steam}
LIB=/usr/local/lib/steam-lxc/frame

# Always installed (inert unless toggled): helper scripts and the user unit.
install -d "$LIB"
install -m 755 bin/steam-lxc-steamvr bin/vrsettings-merge bin/steamvr-setcap \
    bin/steam-lxc-vrclass bin/steam-lxc-flat bin/steam-lxc-stream-diag "$LIB/"
install -m 644 lib/frame-yield.sh lib/frame-streamres.sh "$LIB/"
install -m 644 systemd/steam-lxc-steamvr-setcap.path systemd/steam-lxc-steamvr-setcap.service /etc/systemd/system/
install -m 644 systemd-user/steam-lxc-steamvr.service /etc/systemd/user/
# Earlier builds had a separate yield unit; everything now runs inside steam-lxc-steamvr.service.
rm -f "$LIB/steam-lxc-steamvr-yield" /etc/systemd/user/steam-lxc-steamvr-yield.service

# 1. Always-on SteamVR: enable for the Steam user (takes effect at its next login, or after the steps in README).
WANTS=$(getent passwd "$U" | cut -d: -f6)/.config/systemd/user/default.target.wants
if [ "${FRAME_SHIM_STEAMVR_ALWAYS_ON:-0}" = 1 ]; then
    install -d -o "$U" -g "$U" "$(dirname "$WANTS")" "$WANTS"
    ln -sfn /etc/systemd/user/steam-lxc-steamvr.service "$WANTS/steam-lxc-steamvr.service"
    echo "steamvr: enabled for $U (not started)"
else
    rm -f "$WANTS/steam-lxc-steamvr.service"
fi
rm -f "$WANTS/steam-lxc-steamvr-yield.service"   # old separate yield unit (now part of steam-lxc-steamvr)
if [ "${FRAME_SHIM_STEAMVR_YIELD:-0}" = 1 ]; then echo "steamvr: yield to non-VR games on (inside steam-lxc-steamvr.service)"; fi

# 2. LastKnown seeding: only when SteamVR is not running (the helper checks and makes a backup).
if [ "${FRAME_SHIM_LASTKNOWN_SEED:-0}" = 1 ]; then
    runuser -u "$U" -- "$LIB/vrsettings-merge" lastknown || echo "lastknown: not merged (see message above)"
fi

# 3. rtkit for SteamVR's realtime thread requests. --needed, no -y/-u: never a (partial) system upgrade.
if [ "${FRAME_SHIM_RTKIT:-0}" = 1 ]; then
    pacman -Q rtkit >/dev/null 2>&1 || pacman -S --needed --noconfirm rtkit
    # rtkit-daemon is D-Bus activated; the bus only needs to re-read its service files (no restart).
    busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig >/dev/null 2>&1 || true
fi

# 4. setcap vrcompositor-launcher: only when the CT's bounding set has CAP_SYS_NICE + CAP_SETFCAP (helper checks).
if [ "${FRAME_SHIM_STEAMVR_SETCAP:-0}" = 1 ]; then
    "$LIB/steamvr-setcap" && systemctl enable steam-lxc-steamvr-setcap.path steam-lxc-steamvr-setcap.service >/dev/null 2>&1 \
        && echo "setcap: applied; re-apply path unit enabled (starts at next boot or 'systemctl start steam-lxc-steamvr-setcap.path')"
else
    systemctl disable steam-lxc-steamvr-setcap.path steam-lxc-steamvr-setcap.service >/dev/null 2>&1 || true
fi

# 5. Frame Wireless Adapter: NetworkManager owns only the dongle interface.
if [ "${FRAME_SHIM_DONGLE_NM:-0}" = 1 ]; then
    IF=${FRAME_DONGLE_IFACE:-wlframe0}
    pacman -Q networkmanager >/dev/null 2>&1 || pacman -S --needed --noconfirm networkmanager
    sed "s/wlframe0/$IF/g" dongle/90-steam-lxc-networkmanager.conf > /etc/NetworkManager/conf.d/90-steam-lxc-networkmanager.conf
    sed "s/@STEAM_LXC_USER@/$U/" dongle/50-steam-lxc-networkmanager.rules > /etc/polkit-1/rules.d/50-steam-lxc-networkmanager.rules
    systemctl enable NetworkManager.service >/dev/null 2>&1 || true
    echo "dongle: NetworkManager config installed (enable only; run 'systemctl start NetworkManager' yourself)"
fi
echo FRAME_SHIM_DONE
