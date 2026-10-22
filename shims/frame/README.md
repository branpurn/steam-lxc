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
| setcap compositor | `FRAME_SHIM_STEAMVR_SETCAP` | `bin/steamvr-setcap`, `systemd/steam-lxc-steamvr-setcap.*`, `host/` |
| rtkit | `FRAME_SHIM_RTKIT` | (pacman package) |
| Frame Wireless Adapter | `FRAME_SHIM_DONGLE_NM`, `FRAME_DONGLE_IFACE` | `dongle/` |

## 1. Always-on SteamVR
**Why:** a Proton VR game (for example VRChat) launched from the Frame does not start SteamVR on Linux. Steam logs
`Failed to init SteamVR because it isn't installed`, the game gets `VRInitError 109`, and it falls back to desktop
mode. If SteamVR is already running, the game attaches to it.

**How:** `steam-lxc-steamvr.service` is a systemd **user** unit for the Steam user. Its `ExecCondition` skips it
unless the toggle is 1. The script:
1. waits until `~/.steam/steam.pid` is alive and `steamwebhelper` runs;
2. if no `vrserver` runs, waits `FRAME_SHIM_STEAMVR_START_DELAY` seconds, then asks the **running Steam client** to
   start SteamVR with `steam -ifrunning steam://run/250820` (the same as pressing Play), using the Steam process's
   display and D-Bus environment;
3. supervises: it exits non-zero when vrserver or the Steam client goes away, and `Restart=on-failure`
   (RestartSec=30) launches it again through the next Steam client.

Steam picks SteamVR's runtime (SteamLinuxRuntime_sniper, app 1628350, which Steam installs into any library). Running
`bin/vrstartup.sh` directly outside Steam fails with `no steam runtime environment set, no sniper SLR found`.

**Never kill a SteamVR you didn't start.** An earlier version stopped a "leftover" vrserver whose DISPLAY differed.
That killed a Steam-launched SteamVR seconds after it started (`Lost master process … Quitting all`). The service
now leaves an already-running SteamVR alone and only supervises it.

**Game Mode and Desktop Mode:**
- SteamVR started through Steam runs in the session's logind scope.
- When the session ends or switches, SteamVR ends with Steam.
- The service notices Steam is gone, restarts, waits for the next session's Steam, and launches again.
- Linger keeps the user unit alive across switches.

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

## 4. setcap on vrcompositor-launcher: only after fixing the CT's capability bounding set
SteamVR's `vrsetup.sh` runs at every start. It relaunches itself outside pressure-vessel through the Steam launcher
service and checks `getcap vrcompositor-launcher` for `cap_sys_nice`. If that is missing, it tries
`holo-grant-cap-sys-nice`, then `pkexec setcap CAP_SYS_NICE=eip` (the zenity/superuser prompt). So unattended
always-on SteamVR needs the capability to be present.

**Root cause of the earlier failure (`Operation not permitted`, SteamVR -201):**
- Proxmox `ostype: archlinux` includes `/usr/share/lxc/config/archlinux.common.conf`. That file runs
  `lxc.cap.drop = setfcap sys_nice sys_pacct sys_rawio`, so every process in the CT has a bounding set without
  CAP_SYS_NICE (bit 23) and CAP_SETFCAP (bit 31). For example `CapBnd: 000001fc7d6cffff`.
- On exec of a file whose capabilities have the effective bit set, the kernel requires that all of the file's
  permitted capabilities end up in the new permitted set. With CAP_SYS_NICE outside the bounding set, it cannot, so
  `execve` returns EPERM. No AppArmor, nosuid or NoNewPrivs is involved: the Steam launcher service runs with
  `NoNewPrivs: 0`.
- The same missing CAP_SETFCAP is why `vrsetup.sh` logs `unable to set CAP_SETFCAP effective capability`.
- It is also why systemd units with `PrivateUsers=yes` (upower) fail with `Failed to set up user namespacing`:
  mapping uid 0 in a new user namespace needs CAP_SETFCAP.
- Containers with `ostype: debian` do not drop these capabilities, which is why setcap worked there.

**Fix:**
1. On the host, add `host/lxc-caps-archlinux.conf.example` to the CT config and restart the CT.
2. Set `FRAME_SHIM_STEAMVR_SETCAP=1` and run `install.sh`.
   - `bin/steamvr-setcap` refuses (and strips an unsafe capability) unless both capabilities are in the bounding set.
   - `steam-lxc-steamvr-setcap.path` re-applies the capability when a SteamVR update replaces the binary.

Never setcap the launcher while the bounding set still lacks CAP_SYS_NICE: that makes it unexecutable (-201).
Giving the CT these two capabilities back slightly widens what root inside a privileged CT can do (realtime
priorities, setting file capabilities). It matches Proxmox's non-Arch default.

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
