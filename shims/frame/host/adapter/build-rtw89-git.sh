#!/bin/bash
# Host: build + install the out-of-tree rtw89 driver (github.com/morrownr/rtw89; modules named *_git) for the
# Steam Frame Wireless Adapter. Prefers DKMS so kernel updates rebuild it; falls back to a plain build for the
# running kernel (then RE-RUN THIS AFTER EVERY KERNEL UPDATE: copied .ko files do not load on a new kernel).
# Usage: build-rtw89-git.sh [git-ref]   (default: the repo's default branch). Needs: git, build-essential,
# kernel headers for each target kernel (Proxmox: proxmox-headers-$(uname -r)), and dkms for the DKMS path.
set -euo pipefail
REF=${1:-}; SRC=/usr/src/rtw89-git
[ -d "$SRC/.git" ] || git clone https://github.com/morrownr/rtw89 "$SRC"
git -C "$SRC" fetch --all -q; [ -n "$REF" ] && git -C "$SRC" checkout -q "$REF" || git -C "$SRC" pull -q --ff-only || true
echo "rtw89-git source: $(git -C "$SRC" rev-parse --short HEAD)"
if command -v dkms >/dev/null && [ -f "$SRC/dkms.conf" ]; then
  VER=$(sed -n 's/^PACKAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$SRC/dkms.conf"); NAME=$(sed -n 's/^PACKAGE_NAME="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$SRC/dkms.conf")
  dkms remove "$NAME/$VER" --all >/dev/null 2>&1 || true
  rm -rf "/usr/src/$NAME-$VER"; cp -a "$SRC" "/usr/src/$NAME-$VER"
  dkms add "$NAME/$VER" && dkms install "$NAME/$VER"
  echo "installed via DKMS ($NAME/$VER); rebuilt automatically on kernel updates"
else
  make -C "$SRC" -j"$(nproc)" && make -C "$SRC" install
  echo "installed for $(uname -r) only (no DKMS): re-run after kernel updates"
fi
depmod -a
echo "next: install rtw89-git-frame.conf + led_class_multicolor.conf, then replug the adapter (or reboot)"
