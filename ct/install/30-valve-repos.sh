#!/bin/bash
# Inside the CT as root: bootstrap holo-keyring (sha256 checked against the repo DB over HTTPS, then its
# detached signature verified once the keys are populated), add holo-3.9/jupiter-3.9 AFTER the Arch repos.
set -e
B=https://steamdeck-packages.steamos.cloud/archlinux-mirror
cd /tmp && mkdir -p holo && cd holo
curl -sfO $B/holo-3.9/os/x86_64/holo-3.9.db
F=$(tar -xOf holo-3.9.db --wildcards 'holo-keyring-*/desc' | awk '/%FILENAME%/{getline;print}')
SUM=$(tar -xOf holo-3.9.db --wildcards 'holo-keyring-*/desc' | awk '/%SHA256SUM%/{getline;print}')
curl -sfO $B/holo-3.9/os/x86_64/$F; curl -sfO $B/holo-3.9/os/x86_64/$F.sig
echo "$SUM  $F" | sha256sum -c
bsdtar -tf $F | grep -v '^\.'
mv $F.sig sig.tmp; pacman -U --noconfirm --config <(sed -E "s/^(LocalFile)?SigLevel.*/SigLevel = Never/" /etc/pacman.conf) $F >/dev/null; mv sig.tmp $F.sig
pacman-key --populate holo
pacman-key --verify $F.sig $F 2>&1 | tail -2
cat >> /etc/pacman.conf <<'C'

# --- Valve SteamOS 3.9 repos (AFTER Arch repos so Arch wins name clashes). ---
# Install only explicitly named packages from these. Packages are signed by holo-keyring keys;
# repo DBs are not signed (no .db.sig), hence DatabaseOptional.
[holo-3.9]
SigLevel = Required DatabaseOptional
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch

[jupiter-3.9]
SigLevel = Required DatabaseOptional
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch
C
pacman -Sy
# Valve pieces we take (session/UX only); verify signatures via normal pacman
pacman -S --noconfirm --needed holo-3.9/holo-grant-cap-sys-nice holo-3.9/xdg-desktop-portal-holo
pacman -Sl holo-3.9 | grep installed; pacman -Sl jupiter-3.9 | grep installed || true
