#!/bin/bash
# Inside the CT as root: build the AUR gamescope-session packages as the session user (temporary pacman-only sudo).
set -e
echo "steam ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/99-aur-build-temp
trap 'rm -f /etc/sudoers.d/99-aur-build-temp' EXIT
for p in gamescope-session-git gamescope-session-steam-git; do
  runuser -u steam -- bash -c "set -e; mkdir -p ~/aur && cd ~/aur && rm -rf $p && git clone -q https://aur.archlinux.org/$p.git && cd $p && grep -E '^(depends|makedepends|source|conflicts|provides)' PKGBUILD && makepkg -si --noconfirm --needed 2>&1 | tail -4"
done
pacman -Q gamescope-session-git gamescope-session-steam-git
pacman -Ql gamescope-session-git gamescope-session-steam-git | grep -v '/$'
