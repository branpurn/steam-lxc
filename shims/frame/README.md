# Frame shim (pending better Steam Frame support in SteamOS from Valve)

Temporary pieces that make a Steam Frame usable with a steam-lxc container. Each piece is off by default and has its
own toggle in `/etc/default/steam-lxc` (see `ct/etc/default/steam-lxc.example`). Remove the shim once SteamOS handles
these cases itself.

Install, inside the CT as root: `shims/frame/install.sh`. It only installs files and symlinks. It never starts,
stops or restarts Steam, gamescope, SteamVR or the session.

| Piece | Toggle | Files |
|---|---|---|
| Always-on SteamVR | `FRAME_SHIM_STEAMVR_ALWAYS_ON`, `FRAME_SHIM_STEAMVR_START_DELAY`, `FRAME_SHIM_STEAMVR_QUIET` | `systemd-user/steam-lxc-steamvr.service`, `bin/steam-lxc-steamvr` |
| Headset record seeding | `FRAME_SHIM_LASTKNOWN_SEED`, `FRAME_LASTKNOWN_*` | `bin/vrsettings-merge` |
| rtkit | `FRAME_SHIM_RTKIT` | (pacman package) |
| Frame Wireless Adapter | `FRAME_SHIM_DONGLE_NM`, `FRAME_DONGLE_IFACE` | `dongle/` |

## 1. Always-on SteamVR
**Why:** a Proton VR game (for example VRChat) launched from the Frame does not start SteamVR on Linux. Steam logs
`Failed to init SteamVR because it isn't installed`, the game gets `VRInitError 109`, and it falls back to desktop
mode. If SteamVR is already running, the game attaches to it.

**How:** `steam-lxc-steamvr.service` is a systemd **user** unit for the Steam user. Its `ExecCondition` skips it
unless the toggle is 1. The script:
1. waits until `~/.steam/steam.pid` is alive and `steamwebhelper` runs;
2. copies `DISPLAY`/`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`/D-Bus from the Steam process;
3. waits `FRAME_SHIM_STEAMVR_START_DELAY` seconds;
4. runs `steamapps/common/SteamVR/bin/vrstartup.sh` (verified path; it starts vrmonitor, which starts vrserver);
5. exits non-zero when `vrserver` goes away, so `Restart=on-failure` restarts it (at most 5 times in 10 min).

It is enabled through `~/.config/systemd/user/default.target.wants/`. The user manager (`user@UID.service`) runs
because the session units use `PAMName=login`.

**HDMI / gamescope:** the Frame is a streamed (vrlink) HMD, not a DRM connector. SteamVR does not need a DRM lease and
should not take the display over. The risk is SteamVR's own desktop windows (vrmonitor status window, mirror view,
SteamVR Home) appearing on gamescope's Xwayland and taking focus from the game or Big Picture.
Mitigations:
- `FRAME_SHIM_STEAMVR_QUIET=1` sets `steamvr.showMirrorView=false` and `steamvr.enableHomeApp=false` before each
  start, while SteamVR is stopped.
- In SteamVR settings, turn off "Start SteamVR when an application starts" style popups and "Show the SteamVR
  window on startup", if your build has them.

**Untested:**
- whether vrmonitor's window gets focus in gamescope Game Mode;
- whether `vrcompositor` runs cleanly under gamescope without a lease device (it got one from kwin under Plasma);
- starting before Steam has fully signed in (the start delay is a guess);
- how this interacts with Steam's own "launch SteamVR" when Valve fixes auto-start.

## 2. Headset record seeding (LastKnown)
**Why:** a fresh SteamVR install does not accept the Frame until `config/steamvr.vrsettings` has a `LastKnown`
block (`ActualHMDDriver`=`vrlink`, `HMDManufacturer`, `HMDModel`, `HMDSerialNumber`, `RemoteClientID`). Copying that
block from a working install fixed detection.

**How:** put the values in `/etc/default/steam-lxc` (`FRAME_LASTKNOWN_*`; never commit them) and set
`FRAME_SHIM_LASTKNOWN_SEED=1`. Then run `vrsettings-merge lastknown` as the Steam user. The installer and the
unit's `ExecStartPre` also run it. The helper:
- skips when the toggle is off or the serial or client ID is empty;
- refuses while vrserver, vrmonitor or vrcompositor runs (vrserver rewrites the file on exit);
- only writes when something changes (idempotent);
- keeps `steamvr.vrsettings.bak-frame-shim-<timestamp>`;
- never prints values.

## 3. rtkit
SteamVR asks for realtime thread priorities over D-Bus. Without rtkit it logs
`org.freedesktop.RealtimeKit1 ServiceUnknown` and runs unprioritised.
- `FRAME_SHIM_RTKIT=1` runs `pacman -S --needed --noconfirm rtkit`, with no `-y`/`-u` and no full upgrade, so
  `IgnorePkg` holds stay in place.
- rtkit-daemon is D-Bus activated. The installer asks the bus to `ReloadConfig`, which is not a restart.
- If the sync DB is too old for the current rtkit, the install fails. Do not "fix" that with `-Sy`; plan a normal
  update.
- Processes that are already running only benefit the next time SteamVR starts.

## 4. Do NOT setcap vrcompositor-launcher (lesson)
`setcap cap_sys_nice=eip .../bin/linux64/vrcompositor-launcher` (what SteamVR's first-run prompt does) breaks it in
this setup. Steam's runtime (pressure-vessel / no_new_privs) can no longer exec a file-capability binary:
`Operation not permitted`, and SteamVR error **-201**. Remove it again with `setcap -r`.

**Open item:** without the capability, SteamVR shows a superuser prompt ("SteamVR requires superuser access to
finish setup") at start. No documented SteamVR setting to suppress it was found. Dismissing it leaves the
compositor at normal priority (rtkit, piece 3, covers part of that). Do not apply any workaround live without testing
it on a spare CT first.

## 5. Steam Frame Wireless Adapter (dongle)
The Frame pairs through its USB Wi-Fi adapter. The current out-of-tree driver (rtw89 8852CU family) is **temporary**:
it lives on the host, and the container only gets the network interface.
- **Host:** give the adapter a stable name (for example `wlframehost`). Pass it in as a phys NIC named `wlframe0`
  (`dongle/frame-dongle.lxc.example`). A pre-start/post-stop hook re-applies the host name, because a phys NIC goes
  back to the host under its kernel name when the CT stops (`dongle/hook-rename.example`).
- **CT** (`FRAME_SHIM_DONGLE_NM=1`):
  - NetworkManager manages only `FRAME_DONGLE_IFACE`, with a stable MAC and no scan randomisation. eth0 stays with
    systemd-networkd.
  - A polkit rule lets the Steam user manage NetworkManager.
  - Steam creates the hidden WPA connection "Steam Frame Wireless Adapter" when pairing. It holds per-headset
    secrets, so it is not packaged here. Back it up from `/etc/NetworkManager/system-connections/` if needed.
