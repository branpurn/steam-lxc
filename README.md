# steam-lxc

A re-implementation, as far as an LXC container allows, of **SteamOS 3** on a Proxmox VE host with an NVIDIA GPU:
Arch Linux, selected packages from Valve's SteamOS 3.9 repos, gamescope and Steam Big Picture ("Game Mode") started
as a systemd service that drives the GPU's display directly (DRM/KMS), plus SteamOS-style switching to a KDE Plasma
Desktop Mode.

**Status: working prototype.** Verified on one NVIDIA host:
- Game Mode in embedded gamescope, with Steam signed in.
- Desktop Mode switching in both directions.
- Session restarts that leave no orphaned processes.
- A Ctrl+Shift+Esc escape hatch for hung games.

Remote Play and SteamVR are not verified yet. See [COMPATIBILITY.md](COMPATIBILITY.md) and [NOTES.md](NOTES.md).

## How it differs from real SteamOS
| SteamOS 3 | steam-lxc |
|---|---|
| Own kernel (`linux-neptune`), firmware, Deck hardware daemons | Host kernel (PVE). No kernel, firmware, fan/power/BIOS daemons |
| Read-only A/B root image, `steamos-atomupd` | Mutable Arch root; `pct snapshot` before every `pacman -Syu` ([ct/install/update.sh](ct/install/update.sh)) |
| Valve `gamescope`, Mesa/RADV (AMD) | Arch `extra/gamescope`, NVIDIA userland matched to the host kernel module |
| `gamescope-session` from `steamos-customizations` + `steam-jupiter-stable` | AUR `gamescope-session-git` + `gamescope-session-steam-git` + Arch `steam` |
| logind seat with VTs; "Switch to Desktop" goes to Plasma | logind seat without VTs; both sessions are system units with `PAMName=login`. Desktop Mode is Plasma **Wayland** (Arch's Plasma has no X11 session), switched through the `steamos-session-select` hook |
| Suspend / sleep | Not possible in a CT; disabled so Steam's idle suspend can't leave the display off |
| Everything from Valve's repos | Arch repos first; Valve repos listed after them, signatures enforced, only named packages installed (holo-keyring, holo-grant-cap-sys-nice, xdg-desktop-portal-holo) |

## Configuration
All site-specific values live in **`/etc/default/steam-lxc`** inside the CT. Start from
[`ct/etc/default/steam-lxc.example`](ct/etc/default/steam-lxc.example); `50-session.sh` installs it if missing.
The file sets:
- the output connector, mode and refresh rate for Game Mode and Desktop Mode;
- the HDR-off option;
- the NVIDIA tweaks (`composite_force`/`adaptive_sync`);
- the connectors the display keep-awake watches;
- the opt-in HDMI link watchdog (`STEAM_LXC_HDMI_WATCHDOG`, `HDMI_WATCHDOG_*`).

The host side uses env vars for `host/create-ct.sh`, plus `/etc/steam-lxc/host.conf` (`GPU_CTS`) and `/etc/steam-lxc/hook.d/`
for site-specific hooks.

## Layout
- **`host/`** runs on the PVE host:
  - `create-ct.sh` (env-configured) and `lxc.conf.fragment` (device passthrough);
  - `hookscripts/steam-lxc-hook.sh`: GPU exclusivity, GPU cgroup prep, `/etc/steam-lxc/hook.d/*`;
  - `sbin/gpu-exclusive.sh` and `sbin/steam-lxc-gpu-prep.sh`;
    `steam-lxc-gpu-prep.sh <ctid>` runs at pre-start and adds `lxc.cgroup2.devices.allow: c <major>:* rwm` for the
    *current* majors of the NVIDIA devices in `/proc/devices` (nvidia-uvm, nvidia-caps, nvidia-nvswitch, ...). These
    majors are dynamic and can change on any host reboot; a missing one shows up as EPERM opening `/dev/nvidia-uvm`
    (CUDA/Vulkan init fails, games report e.g. "failed to initialize graphics device"). It only edits the main
    section of the CT config (a line under a `[snapshot]` header has no effect) and never removes lines;
  - optional `sbin/steam-lxc-hdmi-watchdog-host` (+ `systemd/steam-lxc-hdmi-watchdog-host.service`): forwards host kernel
    HDMI link-training failures to the CT's watchdog.
- **`ct/install/`** runs inside the CT as root, in order: `10-bootstrap.sh`, `20-nvidia-hostmatched.sh`, `30-valve-repos.sh`,
  `35-user.sh`, `40-aur-session.sh`, `50-session.sh`. Optional extras:
  - `60-shared-library.sh <path>`: register an existing Steam library folder;
  - `70-compat-tool.sh <appid> <tool>`: force a Proton version for one game;
  - `update.sh`: host side, snapshot then `pacman -Syu`.
- **`ct/etc`, `ct/usr`**:
  - session units `steamos-session.service` (Game Mode, boot default) and `steamos-desktop-session.service`;
  - session switching (`/usr/libexec/os-session-select`, `steam-lxc-switch@.service`, a `steamosctl` shim);
  - `session-cleanup.sh`;
  - gamescope overrides (`/etc/gamescope-session-plus/sessions.d/steam`, `/etc/gamescope/scripts/*.lua`);
  - display keep-awake, opt-in VNC for Game Mode (`STEAM_LXC_VNC=1`), the Ctrl+Shift+Esc game killer, and the device ACL units;
  - the opt-in HDMI link watchdog (`steam-lxc-hdmi-watchdog`, see below).

## Quick start
```sh
# PVE host
CT=<ctid> BRIDGE=<bridge> SNIPPETS=<storage> GPU_CARD=/dev/dri/by-path/<gpu>-card host/create-ct.sh
pct start <ctid>                        # refused while another GPU CT runs
tar cz ct | pct exec <ctid> -- tar xz -C /root
pct push <ctid> <path-to>/NVIDIA-Linux-x86_64-<host version>.run /root/
pct exec <ctid> -- bash /root/ct/install/10-bootstrap.sh
pct exec <ctid> -- bash /root/ct/install/20-nvidia-hostmatched.sh   # version auto-detected from the host module
pct exec <ctid> -- bash /root/ct/install/30-valve-repos.sh
# put the session password in /root/.steam-lxc-pass inside the CT (mode 600), then:
pct exec <ctid> -- bash /root/ct/install/35-user.sh
pct exec <ctid> -- bash /root/ct/install/40-aur-session.sh
pct exec <ctid> -- bash /root/ct/install/50-session.sh
# edit /etc/default/steam-lxc in the CT, then:
pct reboot <ctid>
```
Then sign in to Steam on the display or over VNC (`<ct-ip>:5900`, after setting `STEAM_LXC_VNC=1` in `/etc/default/steam-lxc`; the password is the first 8 characters of the session password, or the generated one in `~/.vnc/password`). Apache Guacamole: protocol VNC, port 5900, password only (no username), color depth 24, cursor remote.

## Only one GPU container at a time
The hookscript refuses `pre-start` while another GPU CT is running. By default every CT whose config passes `/dev/nvidia0`
counts as a GPU CT; override with `GPU_CTS=` in `/etc/steam-lxc/host.conf`. To protect another existing CT, add
`/usr/local/sbin/gpu-exclusive.sh "$1" || exit 1` to its own hookscript's pre-start.

## HDMI link watchdog (opt-in)
When the host driver keeps the GPU between sessions, every session start/stop is a modeset, and an HDMI 2.1 (FRL) link
sometimes fails to train. The panel then shows artifacts or goes black until the next modeset. With
`STEAM_LXC_HDMI_WATCHDOG=1` the CT retries a clean modeset when a failed link is seen:
1. a DPMS off/on cycle through gamescope (`gamescope-display-wake sleep`, then wake), up to `HDMI_WATCHDOG_DPMS_TRIES`;
2. only with `HDMI_WATCHDOG_ALLOW_SESSION_RESTART=1`, one `steamos-session` restart.

Attempts are capped (`HDMI_WATCHDOG_MAX` per `HDMI_WATCHDOG_WINDOW`) and backed off. Every action is logged with tag
`steam-lxc-intended` (`journalctl -t steam-lxc-intended`). Signals:
- in the CT: DRM `link-status` on `HDMI_WATCHDOG_CONNECTORS`, polled (needs `modetest`, from libdrm);
- on the host (optional, recommended because the driver may report training failures only in the host kernel log):
  ```sh
  install -m 755 host/sbin/steam-lxc-hdmi-watchdog-host /usr/local/sbin/
  install -m 644 host/systemd/steam-lxc-hdmi-watchdog-host.service /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now steam-lxc-hdmi-watchdog-host.service
  ```
  It sends an event to each running GPU CT (`HDMI_WATCHDOG_CTS`, else `GPU_CTS` in `/etc/steam-lxc/host.conf`). It
  matches `HDMI_WATCHDOG_PATTERN`, which defaults to the NVIDIA "HDMI FRL link training failed" message.

**Not detectable:** a monitor/TV power cycle (or input switch) can leave the panel black while DRM `link-status`
still reads `Good` and no training failure is logged, so the watchdog cannot see it. Recovery: restart the session
(`systemctl restart steamos-session`).

Run the tests with `ct/tests/hdmi_watchdog_test.sh`. Manual trigger: `steam-lxc-hdmi-watchdog event manual`.

## Host: NVIDIA driver options (recommended)
`nvidia-drm modeset=1` is required. `fbdev=0` is recommended (optional): `/etc/modprobe.d/nvidia-drm.conf` with
`options nvidia-drm modeset=1 fbdev=0`, then `update-initramfs -u` and reboot. With the driver's fbdev emulation on,
the host console keeps a framebuffer on the panel's connector, so the host holds a mode on the output between CT
sessions and gets involved in every handover; with `fbdev=0` the host leaves the connector alone and gamescope in the
CT is the only one doing modesets. Trade-off: no host text console on that GPU (use another output, serial or SSH).

## Optional shims
- [`shims/frame/`](shims/frame/README.md): Steam Frame helpers (always-on SteamVR, headset record seeding, rtkit, Frame Wireless Adapter), pending better Steam Frame support in SteamOS from Valve. All off by default.
- An "Errata shim" (default-on bundle for generic hacky workarounds) is planned but not built yet; such workarounds
  currently live in the core session scripts or the Frame shim and are documented in NOTES.md.
