#!/bin/bash
# Inside the CT as root: init keys, enable multilib, pacman sandbox off (no Landlock in the CT), base + session packages.
set -e
grep -q "^DisableSandbox" /etc/pacman.conf || sed -i "/^\[options\]/a DisableSandbox" /etc/pacman.conf
pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
pacman -Syu --noconfirm
pacman -S --noconfirm --needed base-devel git sudo vim openssh acl x11vnc xorg-server xorg-xinit xterm steam gamescope pipewire pipewire-pulse wireplumber lib32-pipewire vulkan-tools vulkan-icd-loader lib32-vulkan-icd-loader ttf-liberation noto-fonts xorg-xrandr seatd libva xdg-desktop-portal python lib32-libdrm libdrm xorg-xwininfo networkmanager wpa_supplicant iw polkit
echo BOOT_DONE
