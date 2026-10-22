#!/bin/bash
# Inside the CT as root, with NVIDIA-Linux-x86_64-$V.run pushed to /root (copy it from the host).
# Userland must equal the host kernel module version exactly: cat /proc/driver/nvidia/version on the host.
set -e
# Default: the host kernel module version as seen through /proc (shared kernel).
V=${NVIDIA_VERSION:-$(awk 'NR==1{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/){print $i; exit}}' /proc/driver/nvidia/version)}
[ -n "$V" ] || { echo "cannot determine host NVIDIA version; set NVIDIA_VERSION" >&2; exit 1; }
pacman -Rdd --noconfirm nvidia-utils lib32-nvidia-utils
sh /root/NVIDIA-Linux-x86_64-$V.run --silent --no-kernel-module --no-x-check --no-nouveau-check --no-questions --install-compat32-libs --no-install-libglvnd --no-systemd --no-check-for-alternate-installs --skip-depmod > /root/nv-install.out 2>&1 || { tail -30 /var/log/nvidia-installer.log; exit 1; }
# placeholder package so pacman deps (vulkan-driver etc.) resolve to the .run userland
mkdir -p /tmp/nvstub && cd /tmp/nvstub
cat > PKGBUILD <<P
pkgname=nvidia-utils-hostmatched
pkgver=${V}
pkgrel=1
pkgdesc="Placeholder: NVIDIA \$pkgver userland installed from the .run to match the host kernel module"
arch=(x86_64)
license=(custom)
provides=(nvidia-utils=\$pkgver lib32-nvidia-utils=\$pkgver vulkan-driver lib32-vulkan-driver opengl-driver lib32-opengl-driver nvidia-libgl lib32-nvidia-libgl)
conflicts=(nvidia-utils lib32-nvidia-utils)
package() { :; }
P
chown -R nobody /tmp/nvstub; runuser -u nobody -- makepkg -f >/dev/null
pacman -U --noconfirm /tmp/nvstub/*.pkg.tar.zst
grep -q '^IgnorePkg.*nvidia' /etc/pacman.conf || sed -i 's/^#IgnorePkg.*/IgnorePkg   = nvidia-utils lib32-nvidia-utils nvidia-utils-hostmatched egl-wayland egl-gbm egl-x11/' /etc/pacman.conf
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
vulkaninfo --summary 2>&1 | grep -E "deviceName|driverInfo|apiVersion" | head
