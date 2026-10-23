# Notes: what worked and what didn't

## Worked
- **archlinux-base template + privileged CT** with the device set in `host/lxc.conf.fragment`. GPU nodes, DRI card/render (best via a stable host
  udev symlink, `GPU_CARD`/`GPU_RENDER`), input, uinput, ntsync, FUSE, `/dev/bus/usb`.
- **NVIDIA userland pinned to the host module**: remove Arch's `nvidia-utils`/`lib32-nvidia-utils` (`pacman -Rdd`), run the
  matching `.run` with `--no-kernel-module --install-compat32-libs --no-install-libglvnd`, then install a tiny local placeholder
  package `nvidia-utils-hostmatched` that `provides` nvidia-utils/vulkan-driver/opengl-driver (and lib32) so Steam's
  dependencies resolve. `nvidia-utils`, `lib32-nvidia-utils`, the placeholder and `egl-*` are in `IgnorePkg`.
  After any host driver update, re-run `20-nvidia-hostmatched.sh` (it reads the host module version from
  `/proc/driver/nvidia/version`; override with `NVIDIA_VERSION`).
- **holo-keyring bootstrap**: checked the package's SHA256 against the repo DB (fetched over HTTPS), installed it once without
  signature checking, ran `pacman-key --populate holo`, then verified the package's detached signature: good signature from
  Valve's CI package builder key. All later installs from holo-3.9/jupiter-3.9 go through normal signature checking.
- **Valve packages actually taken**: `holo-keyring`, `holo-grant-cap-sys-nice`, `xdg-desktop-portal-holo`. Most of the rest is
  Deck hardware, the atomic updater, firmware, AMD Mesa, or forks of Arch packages (systemd, pipewire, xorg-server) that we
  deliberately do not take. `steam-jupiter-stable` conflicts with Arch `steam` and adds nothing needed here.
  `steamos-customizations-git` depends on partitioning/initramfs tooling for the image; skipped.
- **Embedded gamescope on NVIDIA in LXC**: `steamos-session.service` runs as the session user with `PAMName=login`; logind
  creates the session and libseat (logind backend) hands gamescope DRM master on the passed-through card. The host udev DB is
  bind-mounted read-only so logind/libinput can enumerate devices. Caps are dropped before exec so Steam's `srt-bwrap` works.
- **VNC** (opt-in, `STEAM_LXC_VNC=1`): gamescope's Xwayland is rootless, so plain `x11vnc -display :0` dies with `X_GetImage` BadMatch.
  Attaching to the "Steam Big Picture Mode" window (`x11vnc -id <wid>`) works and gives input via XTEST.
- **Snapshots with a shared library** (`STEAMLIB_HOST` in `create-ct.sh`, then `60-shared-library.sh`): an `mpN:` bind mount disables `pct snapshot` ("snapshot feature is not available").
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
- Remote Play from embedded gamescope on NVIDIA (upstream green-screen bug), SteamVR,
  audio sink routing, hidraw passthrough, VNC in Desktop Mode.

## Display keep-awake: panel blanked after idle (DPMS Off while the session was running)
- **Cause:** Steam Game Mode's idle suspend (default about 1 h, even at the sign-in screen). Steam asks gamescope to
  put the display to sleep (gamescope-control `display_sleep`) and then calls logind Suspend. Inside the CT,
  suspend fails (`/sys/power/state`: EROFS, logged by Steam as "Issuing Suspend Command"), so nothing wakes the panel again.
- **Fix:**
  1. `/etc/systemd/sleep.conf.d/10-steam-lxc.conf` disallows every sleep mode, so logind's `CanSuspend` reports `no`.
  2. `steam-lxc-display-keepawake.service` checks the connectors in `KEEPAWAKE_CONNECTORS`
     (`/etc/default/steam-lxc`; empty = off) every `KEEPAWAKE_INTERVAL` s. If it is connected and DPMS is Off, it sends gamescope-control
     `display_sleep(WAKE)` with the small client in `ct/src/gamescope-display-wake/`.
  Gamescope has no setting or env var to ignore `display_sleep` (checked in its 3.16.31 source). Steam's own idle
  settings are per user and only show up after sign-in.
- **Verified:** after `gamescope-display-wake sleep`, the panel's DPMS read Off, then went back to On within 10 s. The 1 h idle path has not been re-observed yet.

## Session cleanup: `systemctl restart steamos-session` left the old gamescope running
- **Cause:** with `PAMName=login`, pam_systemd moves the session into a logind scope (`user-<uid>.slice/session-cN.scope`).
  That scope is outside the service's cgroup, so `KillMode=control-group` only killed the main bash script.
  gamescope, Xwayland and Steam stayed alive and kept DRM master. The new instance then failed and ran
  `short_session_recover`, which calls `steamosctl` (it doesn't exist here).
- **Fix:** `session-cleanup.sh` runs as `ExecStartPre` and `ExecStopPost`. It terminates the user's seat0 logind
  sessions, waits, and SIGKILLs any Game Mode stragglers, but leaves the user manager, D-Bus and PipeWire alone.
  The wrapper creates the short-session tracker file. A `steamosctl` shim handles the session-switch verbs (see Desktop Mode) and
  logs and exits 0 for everything else.
- **Verified:** two real restarts. Each left exactly one gamescope and one seat0 session, NRestarts=0, panel On,
  and the Steam login was kept.

## Option `STEAM_LXC_DISABLE_HDR=1`, and the output mode
- **Finding:** `--hdr-enabled` alone is not the switch. gamescope 3.16.31 reads HDR support from the panel's EDID and
  advertises it (`GAMESCOPE_DISPLAY_SUPPORTS_HDR=1`). Steam then sets `GAMESCOPE_DISPLAY_HDR_ENABLED=1` (a persisted Steam
  setting), and the log showed `xwm: HDR output enabled` even without the flag and with `ENABLE_GAMESCOPE_HDR` unset.
- **Fix (when the option is on):** all in `/etc`, which pacman/AUR updates don't touch.
  - `/etc/gamescope/scripts/50-steam-lxc-no-hdr.lua` adds a catch-all known-display entry with `hdr.supported = false`.
    gamescope then advertises `GAMESCOPE_DISPLAY_SUPPORTS_HDR=0`, so HDR can't activate whatever Steam's setting says.
  - `/etc/gamescope-session-plus/sessions.d/steam`, sourced after the package's file, sets `ENABLE_GAMESCOPE_HDR=0`,
    `STEAM_GAMESCOPE_HDR_SUPPORTED=0`, `ENABLE_HDR_WSI=0` and `DXVK_HDR=0`.
  - The `steam-lxc-gamescope` wrapper (`GAMESCOPE_BIN`) also strips any `--hdr-*` flag.
- **Mode:** `GAME_OUTPUT_WIDTH/HEIGHT` become `SCREEN_WIDTH/HEIGHT`, i.e. `-W/-H`. For the refresh, the DRM backend's preferred refresh comes from
  `-r`, and gamescope-session-plus has no variable for it, so the wrapper adds `-r $GAME_OUTPUT_REFRESH`.
  The connector preference is `GAME_OUTPUT_CONNECTOR` (gamescope `--prefer-output`, default `*`).
- **Refresh: leave `GAME_OUTPUT_REFRESH` empty (soft default).** Without `-r` gamescope starts at the driver's preferred
  mode, and the refresh is then picked in Steam's display settings. If set, `-r` must match an exposed mode: at 4K the
  NVIDIA driver exposes 119.88 Hz, not 120.000. Changing the refresh live in Steam can black-screen an HDMI 2.1 FRL
  link (recovery: restart the session); prefer setting it once and restarting the session.
- **Saved mode (`GAME_OUTPUT_SAVED_MODE`):** gamescope keeps the last mode per display in
  `~/.config/gamescope/modes.cfg` (`<Make Model>:WxH@Hz`), and Steam re-applies it after start. A stale 1080p line
  there made the session drop to 1920x1080 shortly after starting at 4K (seen as games, e.g. a Source game, running at
  1080p). When set, `steamos-session` rewrites that display's line before gamescope starts. Empty = untouched.
- **Verified:** after restarting the session there was one gamescope with `-r/-W/-H` from the config, the log showed
  `drm: selecting mode <W>x<H>@<R>Hz`, `Got known display: steam_lxc_no_hdr`, with no `HDR output enabled`. The root properties were
  `SUPPORTS_HDR=0` and `HDR_ENABLED=1` (Steam's setting, now ineffective). DPMS was On and Steam was still signed in.
- **Other log lines (benign):** `Immediate flips disabled from environment` (`GAMESCOPE_DISABLE_ASYNC_FLIPS=1` from session-plus)
  and `zero modifiers for DRM format AB48/XB48` (16-bit formats the NVIDIA driver doesn't export). No NV12/import/commit failures were logged.
  The green-screen-on-NVIDIA issue concerns Remote Play capture (NV12 over PipeWire), not the local panel.
- **Steam FPS cap:** no frame-limit setting is stored in Steam's config. The default is unlimited, but the per-game QAM setting is not checked yet.

## Option `STEAM_LXC_NVIDIA_TWEAKS=1`: composite_force=1, adaptive_sync=0
Visual artifacting in Game Mode on an NVIDIA RTX GPU went away with these, matching a SteamOS-on-NVIDIA VM workaround
(which re-ran `gamescopectl` for ~60 s after start). With `STEAM_LXC_DISABLE_HDR=1` it also pins `hdr_enabled=0`.
- **Why `gamescopectl` seemed to do nothing:** it connects to `$GAMESCOPE_WAYLAND_DISPLAY`, not `WAYLAND_DISPLAY`. With
  only `XDG_RUNTIME_DIR` set, nothing reaches gamescope. Even when it does connect, command output and convar values go
  to gamescope's own log, not the terminal. Also, the protocol always sends a value, so `gamescopectl composite_force`
  with no value **sets it to false**; you can't read a convar that way.
  Use `/usr/local/bin/steam-lxc-gamescopectl` (correct env, runs as the session user) and read the session journal.
- **Fix:** `/etc/gamescope/scripts/60-steam-lxc-nvidia-tweaks.lua` sets the convars at startup and re-checks them
  after every painted frame (`OnPostPaint` hook). This is stronger than a 60 s gamescopectl loop, since Steam flips them at runtime.
  It logs every correction and a status line (`[steam-lxc-tweaks] status: ...`) at about 5 s and then about every 10 min.
- **Verified after `pct reboot`:** one gamescope; the tweak script logged
  `startup: composite_force false -> true` and then Steam flipping `hdr_enabled true -> false` (twice) and `composite_force false -> true`
  at runtime. Setting `adaptive_sync 1` by hand was reverted at once (`runtime: adaptive_sync true -> false`).
  Status was `adaptive_sync=false composite_force=true hdr_enabled=false`; `GAMESCOPE_DISPLAY_SUPPORTS_HDR=0`,
  `GAMESCOPE_VRR_FEEDBACK=0`; host `dmesg | grep -c hdr=1` returned 0; DPMS On; Steam still signed in.

## Desktop Mode (SteamOS-style session switching)
- **Plasma is Wayland only here.** Arch's Plasma 6.8 no longer ships an X11 session (no `kwin-x11`). Valve's
  holo-3.9 `plasma-x11-session` is 6.7.3 and needs a matching `kwin-x11`/`plasma-workspace` 6.7, which would mean
  downgrading Arch's Plasma to Valve's builds, so it isn't used. Desktop Mode is `startplasma-wayland` (Arch 6.8.1) under
  `dbus-run-session`, with `startkderc systemdBoot=false` so the whole desktop stays in the logind session that
  `session-cleanup.sh` stops.
- **Switching:** Steam's "Switch to Desktop" calls `/usr/bin/steamos-session-select plasma` (from gamescope-session-steam).
  That script execs the unowned hook `/usr/libexec/os-session-select`, which starts `steam-lxc-switch@desktop.service`.
  A polkit rule lets the steam user start only `steam-lxc-switch@*`. The switch unit starts `steamos-desktop-session.service`;
  it Conflicts with `steamos-session.service`, so Game Mode is stopped first and its cleanup runs.
  "Return to Gaming Mode" (desktop icon and app menu) runs `steamos-session-select gamescope`. `steamosctl switch-to-desktop-mode`
  and `switch-to-game-mode` do the same. The desktop unit is not enabled, so boot always lands in Game Mode, and
  `OnFailure=` sends a crashed desktop back to Game Mode.
- **Display in Desktop Mode:** `steam-lxc-desktop-display` (Plasma autostart) runs kscreen-doctor with `DESKTOP_OUTPUT`,
  `DESKTOP_MODE`, `DESKTOP_SCALE`, HDR/WCG off with `STEAM_LXC_DISABLE_HDR=1`, other outputs off with
  `DESKTOP_DISABLE_OTHER_OUTPUTS=1`. Note KScreen may list a 120 Hz mode as 119.88.
  Steam autostarts in the desktop (caps dropped) and stays signed in.
- **Verified:** two full game→desktop→game cycles plus a `pct reboot` into Game Mode, then desktop→game again. Each time there was
  exactly one compositor (gamescope or kwin_wayland), one seat0 session, DPMS On, `hdr=1` count 0, and Steam signed in.
  This used the same command Steam runs (`steamos-session-select plasma|gamescope`); the Steam button itself was not clicked.
- **Not working: VNC in Desktop Mode.** x11vnc can't capture a Wayland session. krfb waits on the xdg-desktop-portal
  RemoteDesktop consent, which shows on the panel; pre-seeding the `kde-authorized/remote-desktop` permission did not
  make it listen. VNC on 5900 works in Game Mode only. Options: approve the krfb portal dialog on the panel, or KRDP
  (RDP with H.264; works with native RDP clients, not with Guacamole).
- **The NVIDIA `.run` userland installs its own `libOpenCL.so.1`**, which conflicts with `ocl-icd` (a Plasma dependency).
  Install with `--overwrite "/usr/lib/libOpenCL.so*"` so `ocl-icd` owns the loader.

## Escape hatch: Ctrl+Shift+Esc force-quits the running game
- gamescope (and kwin) grab input, so this is a root daemon (`steam-lxc-game-killer.service`, python-evdev) reading every
  keyboard under `/dev/input` directly, **non-exclusive** (keys still reach the session), rescanning for hotplug.
- On Ctrl+Shift+Esc it finds the session user's Steam `reaper SteamLaunch AppId=...` processes and their whole tree, plus
  Wine/Proton helpers that reparent away (`wineserver`, `*.exe`, ...). It sends SIGTERM, waits 3 s, then SIGKILLs anything
  left. Steam, steamwebhelper, gamescope, Xwayland and kwin/plasmashell are never touched, so Steam returns to its UI.
  Works the same in Desktop Mode. Log: `journalctl -u steam-lxc-game-killer`.
- **Partly verified:** the daemon runs and sees the keyboards; a native game exited on SIGTERM and Steam/gamescope
  stayed up. The SIGKILL path (a game that ignores SIGTERM) is **untested**.

## Per-game Proton version
Some games only work on a specific Proton build (e.g. a black screen on Proton Experimental that `proton-stable` fixes).
`ct/install/70-compat-tool.sh <appid> <tool>` writes Steam's `CompatToolMapping` in `config.vdf` with the session stopped
(Steam rewrites the file on exit), keeping a backup and the sign-in. Same effect as Properties → Compatibility.
Keep the list of games you map in your own notes, not here.
