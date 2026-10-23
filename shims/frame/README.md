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
| SteamVR yields to non-VR games (+ 1080p flat stream) | `FRAME_SHIM_STEAMVR_YIELD*`, `FRAME_SHIM_STEAMVR_RESUME_DELAY`, `FRAME_SHIM_FLAT_STREAM_*` (see `steam-lxc.frame-yield.example`) | `bin/steam-lxc-steamvr` (same service), `bin/steam-lxc-vrclass`, `bin/steam-lxc-flat`, `lib/`, `tests/` |

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
3. supervises in one loop (poll 1 s):
   - if vrserver dies on its own, it relaunches after `FRAME_SHIM_STEAMVR_RELAUNCH_DELAY` (30 s);
   - if the Steam client goes away (session switch), it waits for the next one and launches again;
   - with `FRAME_SHIM_STEAMVR_YIELD=1`, it also yields to non-VR games (section 6).

   - repeated vrserver crashes back off: the relaunch delay doubles per crash (cap 600 s), and after
     `FRAME_SHIM_STEAMVR_MAX_CRASHES` (4) crashes within `FRAME_SHIM_STEAMVR_CRASH_WINDOW` (600 s) it stops
     relaunching until the Steam client restarts.

   Only `FRAME_SHIM_STEAMVR_MAX_FAILS` (5) failed launches in a row end the process. `Restart=on-failure`
   (RestartSec=30) then restarts it.

Steam picks SteamVR's runtime (SteamLinuxRuntime_sniper, app 1628350, which Steam installs into any library). Running
`bin/vrstartup.sh` directly outside Steam fails with `no steam runtime environment set, no sniper SLR found`.

**Orphan cleanup:** if vrserver dies (crash or watchdog abort) but vrmonitor or other SteamVR helpers stay alive,
Steam still considers 250820 running and `steam://run` does nothing. Before launching, the service reaps such orphans
only when all of these hold:
- no vrserver is running;
- the process has the same UID, an exact comm (`vrmonitor`, `vrdashboard`, `vrwebhelper`, `vrcompositor`,
  `vrstartup`) and an executable inside the SteamVR install;
- it is still orphaned after a 20-second grace period.

It sends TERM, then KILL. It never uses `pkill -f` and never touches anything while a vrserver is up.

**Never kill a SteamVR you didn't start.** An earlier version stopped a "leftover" vrserver whose DISPLAY differed.
That killed a Steam-launched SteamVR seconds after it started (`Lost master process … Quitting all`). The service
now leaves an already-running SteamVR alone and only supervises it.

**Game Mode and Desktop Mode:**
- SteamVR started through Steam runs in the session's logind scope.
- When the session ends or switches, SteamVR ends with Steam.
- The service notices Steam is gone, waits for the next session's Steam (without restarting), and launches again.
- Linger keeps the user unit alive across switches.

**HDMI / gamescope:** the Frame is a streamed (vrlink) HMD, not a DRM connector. SteamVR does not need a DRM lease and
should not take the display over. The risk is SteamVR's own desktop windows (vrmonitor status window, mirror view,
SteamVR Home) appearing on gamescope's Xwayland and taking focus from the game or Big Picture.
Mitigations:
- `FRAME_SHIM_STEAMVR_QUIET=1` sets `steamvr.showMirrorView=false` and `steamvr.enableHomeApp=false` before each
  start, while SteamVR is stopped.
- In SteamVR settings, turn off "Start SteamVR when an application starts" style popups and "Show the SteamVR
  window on startup", if your build has them.

**Focus / Big Picture stall (seen):** every relaunch is a `steam://run/250820`, and Big Picture treats SteamVR as a
running game. After a relaunch Big Picture once stalled in that game-running state: black screen with the cursor and
notifications, the startup animation frozen on its first frame. Restarting `steamwebhelper` (Steam restarts it)
recovered it. This is why crashes back off instead of relaunching in a loop. Disable the shim if it recurs.

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

### Host side of the adapter (`host/adapter/`)
The in-kernel `rtw89_8852cu` (seen on 7.0-series kernels) fails to associate with the adapter's AP:
`failed to insert STA entry for the AP (error -22)`. Working setup, all on the host:
1. `build-rtw89-git.sh [ref]` builds the out-of-tree driver (github.com/morrownr/rtw89, modules `rtw89_*_git`),
   through DKMS when available so kernel updates rebuild it. Without DKMS, the plain `make install` puts the modules
   in `/lib/modules/<kver>/updates/` for the running kernel only: re-run after every kernel update (copied `.ko`
   files do not load on another kernel).
2. `rtw89-git-frame.conf` -> `/etc/modprobe.d/`: blacklists the in-kernel rtw89 modules, `install rtw89_8852cu
   /bin/false`, and `options rtw89_core_git disable_ps_mode=1` (power save off). `led_class_multicolor.conf` ->
   `/etc/modules-load.d/` (a dependency of the _git modules). Then `update-initramfs -u`.
3. `71-steam-frame-adapter.rules` -> `/etc/udev/rules.d/`: USB `28de:2432` gets `MODE=0666` so Steam in the CT can
   open the device.
4. Optional hot-plug instead of (or as well as) the static phys NIC: `steam-lxc-frame-wifi` ->
   `/usr/local/sbin/`, `70-steam-lxc-frame-wifi.rules` -> `/etc/udev/rules.d/`, and `frame-host.conf.example` ->
   `/etc/steam-lxc/frame-host.conf` with `FRAME_HOST_CTID` set (empty = never moves anything). On add, it renames the
   netdev to `FRAME_HOST_IFACE_HOST` and moves the phy into the running CT's netns as `FRAME_HOST_IFACE_CT`
   (`wlframe0`). Matches by USB ID only. Use `steam-lxc-frame-wifi rename` in the hook (`dongle/hook-rename.example`).

Observed once: after the adapter disappeared from Steam, a full CT restart brought it back; the cause is unconfirmed.

## 6. SteamVR yields to non-VR games (pending better Steam Frame support in SteamOS by Valve)
**Why:** with always-on SteamVR (section 1), a flat game streamed to the Frame takes the VR stream path and shows
nothing: `streaming_log.txt` has `>>> Starting VR stream` / `Switching video stream from NONE to VR_MovieStream`, an
audio encoder only, no NVENC video encoder and no capture method. Without SteamVR the same launch gives
`>>> Starting desktop stream` and `Capture method set to Desktop PipeWire NV12 + NVENC H264`. But without SteamVR,
VR games launched from the Frame do not start SteamVR on Linux (section 1). This piece gives you both.

**One service:** everything runs in the single loop of `steam-lxc-steamvr.service` (section 1): launch, crash
relaunch, orphan cleanup, following Steam across session switches, the VR/non-VR watcher and the 1080p stream mode.
State is internal to that process. There is no second unit and no hand-over file between units (earlier builds had a
separate `steam-lxc-steamvr-yield.service`; `install.sh` removes it). `FRAME_SHIM_STEAMVR_YIELD=1` (needs
`FRAME_SHIM_STEAMVR_ALWAYS_ON=1`) turns the watcher part on.

**Rule:**
- When a game launches, it is matched by the game's Steam `reaper` process: exact comm, same UID, `AppId=<n>` in the
  argv. The reaper exists before the game window.
- **Confirmed VR** → SteamVR must run. If it doesn't, the loop launches it at once, with no start delay.
- **Anything else (flat or unknown)** → SteamVR is stopped if it runs. Otherwise nothing happens.
- When the last non-VR game exits, the loop waits `FRAME_SHIM_STEAMVR_RESUME_DELAY` seconds (default 15), then launches
  SteamVR again. If a second non-VR game started meanwhile, it takes over the yield.
- `FRAME_SHIM_STEAMVR_YIELD_VR` / `FRAME_SHIM_STEAMVR_YIELD_FLAT` (appid lists) win over everything else.

**Classifier (`bin/steam-lxc-vrclass APPID…`, read-only):** reads `<Steam root>/appcache/appinfo.vdf` (binary
appinfo, format `0x07564429` with a string table (current) or `0x07564428`). An app is VR when it has any of these
in `appinfo.common`:
- `openvrsupport`, `openxrsupport` or `onlyvrsupport` = 1;
- `category.category_53` ("VR Support") or `category.category_54` ("VR Only").

Checked against a real cache:
- Half-Life 2: Deathmatch (320) has none of these.
- VRChat (438100) has `openvrsupport`, `openxrsupport` and `category_53`.
- Half-Life: Alyx (546560) has `onlyvrsupport`, `openvrsupport` and `category_54`.
- SteamVR (250820) is `type Tool` with `category_53` and is ignored, as are its runtimes.

`--dump` shows the fields. Apps missing from the cache, or an unreadable cache, count as non-VR. Results are cached
per appid and appinfo mtime in `$XDG_RUNTIME_DIR/steam-lxc-frame/vrclass`.

**Stopping SteamVR:** SteamVR on Linux has no supported "quit" command line (`vrcmd` has none; vrmonitor only quits
from its UI). The steps are:
1. Run `FRAME_SHIM_STEAMVR_YIELD_QUIT_CMD`, if set.
2. Send SIGTERM to the exact vrmonitor PID(s) (same UID, exact comm, executable inside the SteamVR install). vrmonitor
   is SteamVR's UI process, and ending it shuts the whole tree down like SteamVR's own Quit. vrserver on its own can
   ignore SIGTERM while its vrmonitor lives. The wait is `FRAME_SHIM_STEAMVR_MONITOR_WAIT` (10 s).
3. If vrserver is still up, send SIGTERM to the exact vrserver PID(s) and wait `FRAME_SHIM_STEAMVR_YIELD_STOP_TIMEOUT` (15 s).
4. Check that vrcompositor is gone (`FRAME_SHIM_STEAMVR_COMPOSITOR_WAIT`, 10 s). Then reap any SteamVR helpers left
   without a vrserver (TERM, then KILL), as in section 1.

A vrserver that survives both is left running and logged. It is SIGKILLed only with
`FRAME_SHIM_STEAMVR_YIELD_SIGKILL=1` (off by default). Nothing uses `pkill`/`killall`. If the stop fails, the yield
still holds: SteamVR is not relaunched while that game runs.

**Every Remote Play client is affected, not only the Frame.** While SteamVR runs, Steam streams a launched game on the
VR path (`VR_MovieStream`) to any Remote Play client, including a desktop client. That client then gets no video. A
failed stop is logged with this note.

A vrserver the loop stopped itself is not treated as a crash. A vrserver that dies on its own is relaunched after
`FRAME_SHIM_STEAMVR_RELAUNCH_DELAY` seconds (default 30) inside the loop. The unit is only restarted by systemd after
`FRAME_SHIM_STEAMVR_MAX_FAILS` (5) launches in a row that bring up no vrserver.

**Race with the stream type:** the Frame picks VR or desktop streaming about a second after the launch, often before
SteamVR has finished stopping. If the log already shows `>>> Starting VR stream` for that launch, the service logs
`yield: the Frame stream had already started on the VR path; restart the stream on the Frame (or relaunch app N)`.
There is no supported way to make the client renegotiate. To stop SteamVR *before* Steam starts a particular game,
put the optional wrapper in its launch options:
`/usr/local/lib/steam-lxc/frame/steam-lxc-flat %command%`
It registers its PID in `$XDG_RUNTIME_DIR/steam-lxc-frame/flat.d/` and stops SteamVR synchronously. It takes the
service's lock (`steamvr.lock`), so the loop cannot launch in between. Then it `exec`s the game under the same PID. The
service keeps SteamVR down until that PID exits, even if appinfo says the game is VR, so you can play a VR-optional game
flat. Whether this beats the Frame's stream-type decision is to be
confirmed live.

**Flat streams use stock gamescope scaling.** gamescope sizes its PipeWire capture buffer to the size the Remote
Play client requests (aspect kept) and composites the focused game window scaled into it, so any client resolution
gets the whole frame with no help from the shim. If a client shows only the top-left part, check the game's
Xwayland size against what the game renders (`steam-lxc-stream-diag`, below) before changing anything.

**Opt-in, known to crop: fixed output mode while a non-VR game streams (`FRAME_SHIM_FLAT_STREAM_RES`, default empty =
off).** Kept only for experiments. Observed effect: the mode nudge resized the game's Xwayland under a running
fullscreen game, which then showed only its top-left quarter on HDMI and on every Remote Play client. Older notes:
 the Remote Play client crops a larger-than-requested desktop capture to its top-left corner. For example, the
Frame asks for `1920x1080`, gamescope's PipeWire node delivers 3840x2160, and you see the top-left quarter. While
**both** of these hold:
- a yield is active (non-VR game running);
- `streaming_log.txt` shows a live `>>> Starting desktop stream`;

the service sets gamescope's output mode to that size. It uses the mechanism Steam's own external-display resolution
setting uses:
1. write the line `"<Make> <Model>:WxH@Hz"` (display name from `gamescopectl`, or `FRAME_SHIM_FLAT_STREAM_DISPLAY`)
   into `$GAMESCOPE_MODE_SAVE_FILE` (`~/.config/gamescope/modes.cfg` with gamescope-session-plus);
2. set `GAMESCOPE_DISPLAY_MODE_NUDGE` on the root window.

The original file is saved and put back when the stream stops, the game exits, or the service stops. If Steam changed
the file meanwhile, it is left alone.

Trade-offs:
- The HDMI screen also runs at that mode during the stream.
- Plain HDMI play with no Frame stream, and VR, are never touched.
- Alternatives considered:
  - a per-game nested `gamescope -w/-h` does not help, because the outer gamescope still captures at its output
    size;
  - a fixed session `-W/-H` would also affect HDMI play.
- The nudge path is what Steam uses, but it is still to be confirmed on a live session.

**Logs:** `journalctl --user -u steam-lxc-steamvr` and `journalctl -t steam-lxc-intended` (one line per
decision: `classify:`, `yield:`, `vr:`, `resume:`, `streamres:`).

**Tests (offline, nothing live):** `tests/run-offline.sh` runs:
- the lint (no `pkill`/`killall`, syntax);
- B1: classifier on synthetic v29/v28 appinfo fixtures;
- B2: the whole service loop in a temp sandbox (launch, crash relaunch with orphan reaping, yield/resume, wrapper) with fake reaper/vrserver processes, decoys, a fake streaming log and stubbed
  logger/systemctl/gamescopectl/xprop.

B3 (`sudo tests/b3_units_nspawn.sh ROOT`) boots a throwaway systemd container, runs the real `install.sh`, and checks
the two user units hand over correctly (start, yield with exit 0, wait, resume, VR immediate start, toggles off).

### Stream diagnostics (read-only)

`/usr/local/lib/steam-lxc/frame/steam-lxc-stream-diag` (run as root in the CT, or as the Steam user) prints the
gamescope output mode, each Xwayland root size, `GAMESCOPE_XWAYLAND_MODE_CONTROL`, focused app ids, top-level game
window sizes on the game Xwayland, the PipeWire capture sizes from the journal, and the latest capture lines from
`streaming_log.txt`. It changes nothing. Run it while the stream shows the problem.

