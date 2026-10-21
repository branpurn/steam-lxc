# Notes: what worked and what didn't

## Worked
- **archlinux-base template + privileged CT** with the gaming-enclave device set. GPU nodes, DRI card/render via the host's
  stable `/dev/dri/enclave-gpu-*` symlinks, input, uinput, ntsync, FUSE, `/dev/bus/usb`.
- **NVIDIA userland pinned to the host module**: remove Arch's `nvidia-utils`/`lib32-nvidia-utils` (`pacman -Rdd`), run the
  matching `.run` with `--no-kernel-module --install-compat32-libs --no-install-libglvnd`, then install a tiny local placeholder
  package `nvidia-utils-hostmatched` that `provides` nvidia-utils/vulkan-driver/opengl-driver (and lib32) so Steam's
  dependencies resolve. `nvidia-utils`, `lib32-nvidia-utils`, the placeholder and `egl-*` are in `IgnorePkg`.
  After any host driver update, re-run `20-nvidia-hostmatched.sh` with the new version.
- **holo-keyring bootstrap**: checked the package's SHA256 against the repo DB (fetched over HTTPS), installed it once without
  signature checking, ran `pacman-key --populate holo`, then verified the package's detached signature: good signature from
  Valve's CI package builder key. All later installs from holo-3.9/jupiter-3.9 go through normal signature checking.
- **Valve packages actually taken**: `holo-keyring`, `holo-grant-cap-sys-nice`, `xdg-desktop-portal-holo`. Most of the rest is
  Deck hardware, the atomic updater, firmware, AMD Mesa, or forks of Arch packages (systemd, pipewire, xorg-server) that we
  deliberately do not take. `steam-jupiter-stable` conflicts with Arch `steam` and adds nothing needed here.
  `steamos-customizations-git` depends on partitioning/initramfs tooling for the image; skipped.
- **Embedded gamescope on NVIDIA in LXC**: `steamos-session.service` runs as the session user with `PAMName=login`; logind
  creates the session and libseat (logind backend) hands gamescope DRM master on `/dev/dri/card1`. The host udev DB is
  bind-mounted read-only so logind/libinput can enumerate devices. Caps are dropped before exec so Steam's `srt-bwrap` works.
- **VNC**: gamescope's Xwayland is rootless, so plain `x11vnc -display :0` dies with `X_GetImage` BadMatch.
  Attaching to the "Steam Big Picture Mode" window (`x11vnc -id <wid>`) works and gives input via XTEST.
- **Snapshots with a shared library**: an `mpN:` bind mount disables `pct snapshot` ("snapshot feature is not available").
  The library is mounted with a raw `lxc.mount.entry` instead, which keeps snapshots working.

## Didn't work / gotchas
- **pacman 7 sandbox**: `restricting filesystem access failed because Landlock is not supported` + `switching to sandbox user
  'alpm' failed` → set `DisableSandbox` in `[options]`.
- **`pacman -U` with a `.sig` next to the package** still checks it (`LocalFileSigLevel`) even when `SigLevel = Never`;
  move the `.sig` aside for the one bootstrap install.
- **`pct set` / appending to `/etc/pve/lxc/<ct>.conf` after a snapshot exists** puts lines into the last `[snapshot]` section.
  Raw `lxc.*` lines must go before the first `[...]` section.
- **`setcap` inside the CT** fails (`unable to set CAP_SETFCAP`), so gamescope runs without realtime priority; RTKit is absent too.
- `gamescope-session-plus` (the wrapper) uses `systemctl --user` units; we call the inner
  `/usr/share/gamescope-session-plus/gamescope-session-plus steam` directly from a system unit instead.
- Harmless at first boot: `touch ... SteamAppData.vdf: No such file`, missing short-session tracker file.
- `x11vnc -storepasswd <pw> <file>` puts the password on the CT's process list for a moment; acceptable inside a single-user CT,
  but don't run it on a shared host.

## Open
- Remote Play from embedded gamescope on NVIDIA (upstream green-screen bug), Steam Frame streaming, SteamVR, Proton titles,
  audio sink routing, hidraw passthrough, a desktop-mode fallback (Plasma X11 + Big Picture, as in the gaming-enclave CT).
