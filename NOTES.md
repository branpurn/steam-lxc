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

## Fixed: panel blanked after idle (DPMS Off while the session was running)
- **Cause:** Steam Game Mode's idle suspend (default about 1 h, even at the sign-in screen). Steam asks gamescope to
  put the display to sleep (gamescope-control `display_sleep`) and then calls logind Suspend. Inside the CT,
  suspend fails (`/sys/power/state`: EROFS, logged by Steam as "Issuing Suspend Command"), so nothing wakes the panel again.
- **Fix:**
  1. `/etc/systemd/sleep.conf.d/10-steam-lxc.conf` disallows every sleep mode, so logind's `CanSuspend` reports `no`.
  2. `steam-lxc-display-keepawake.service` checks the watched connector (default `HDMI-A-2`, `KEEPAWAKE_CONNECTORS`
     in `/etc/default/steam-lxc`) every 10 s. If it is connected and DPMS is Off, it sends gamescope-control
     `display_sleep(WAKE)` with the small client in `ct/src/gamescope-display-wake/`.
  Gamescope has no setting or env var to ignore `display_sleep` (checked in its 3.16.31 source). Steam's own idle
  settings are per user and only show up after sign-in.
- **Verified:** after `gamescope-display-wake sleep`, HDMI DPMS read Off, then went back to On within 10 s. The 1 h idle path has not been re-observed yet.

## Fixed: `systemctl restart steamos-session` left the old gamescope running
- **Cause:** with `PAMName=login`, pam_systemd moves the session into a logind scope (`user-1000.slice/session-cN.scope`).
  That scope is outside the service's cgroup, so `KillMode=control-group` only killed the main bash script.
  gamescope, Xwayland and Steam stayed alive and kept DRM master. The new instance then failed and ran
  `short_session_recover`, which calls `steamosctl` (it doesn't exist here).
- **Fix:** `session-cleanup.sh` runs as `ExecStartPre` and `ExecStopPost`. It terminates the user's seat0 logind
  sessions, waits, and SIGKILLs any Game Mode stragglers, but leaves the user manager, D-Bus and PipeWire alone.
  The wrapper creates the short-session tracker file. A `steamosctl` shim logs and exits 0, because there is no
  desktop mode to switch to.
- **Verified:** two real restarts. Each left exactly one gamescope and one seat0 session, NRestarts=0, HDMI On,
  and the Steam login was kept.

## HDR permanently off, 4K @ 120 Hz (artifacting on the HDMI panel)
- **Finding:** `--hdr-enabled` alone is not the switch. gamescope 3.16.31 reads HDR support from the panel's EDID and
  advertises it (`GAMESCOPE_DISPLAY_SUPPORTS_HDR=1`). Steam then sets `GAMESCOPE_DISPLAY_HDR_ENABLED=1` (a persisted Steam
  setting), and the log showed `xwm: HDR output enabled` even without the flag and with `ENABLE_GAMESCOPE_HDR` unset.
- **Fix:** all in `/etc`, which pacman/AUR updates don't touch.
  - `/etc/gamescope/scripts/50-steam-lxc-no-hdr.lua` adds a catch-all known-display entry with `hdr.supported = false`.
    gamescope now advertises `GAMESCOPE_DISPLAY_SUPPORTS_HDR=0`, so HDR can't activate whatever Steam's setting says.
  - `/etc/gamescope-session-plus/sessions.d/steam`, sourced after the package's file, sets `ENABLE_GAMESCOPE_HDR=0`,
    `STEAM_GAMESCOPE_HDR_SUPPORTED=0`, `ENABLE_HDR_WSI=0` and `DXVK_HDR=0`.
  - The `steam-lxc-gamescope` wrapper (`GAMESCOPE_BIN`) also strips any `--hdr-*` flag.
- **Mode:** `SCREEN_WIDTH=3840 SCREEN_HEIGHT=2160` gives `-W/-H`. For the refresh, the DRM backend's preferred refresh comes from
  `-r`, and gamescope-session-plus has no variable for it, so the wrapper adds `-r $GAMESCOPE_OUTPUT_REFRESH` (120).
  The panel also offers 3840x2160@144; set `GAMESCOPE_OUTPUT_REFRESH=144` to use it.
- **Verified:** after restarting the session there was one gamescope (`/usr/bin/gamescope -r 120 -W 3840 -H 2160 ...`) and the log showed
  `drm: selecting mode 3840x2160@120Hz`, `Got known display: steam_lxc_no_hdr`, with no `HDR output enabled`. The root properties were
  `SUPPORTS_HDR=0` and `HDR_ENABLED=1` (Steam's setting, now ineffective). HDMI DPMS was On and Steam was still signed in.
- **Other log lines (benign):** `Immediate flips disabled from environment` (`GAMESCOPE_DISABLE_ASYNC_FLIPS=1` from session-plus)
  and `zero modifiers for DRM format AB48/XB48` (16-bit formats the NVIDIA driver doesn't export). No NV12/import/commit failures were logged.
  The green-screen-on-NVIDIA issue concerns Remote Play capture (NV12 over PipeWire), not the local panel.
- **Steam FPS cap:** no frame-limit setting is stored in Steam's config. The default is unlimited, but the per-game QAM setting is not checked yet.
