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
- the connectors the display keep-awake watches.

The host side uses env vars for `host/create-ct.sh`, plus `/etc/steam-lxc/host.conf` (`GPU_CTS`) and `/etc/steam-lxc/hook.d/`
for site-specific hooks.

## Layout
- **`host/`** runs on the PVE host:
  - `create-ct.sh` (env-configured) and `lxc.conf.fragment` (device passthrough);
  - `hookscripts/steam-lxc-hook.sh`: GPU exclusivity, GPU cgroup prep, `/etc/steam-lxc/hook.d/*`;
  - `sbin/gpu-exclusive.sh` and `sbin/steam-lxc-gpu-prep.sh`.
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
  - display keep-awake, VNC for Game Mode, the Ctrl+Shift+Esc game killer, and the device ACL units.

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
Then sign in to Steam on the display or over VNC (`<ct-ip>:5900`; the VNC password is the first 8 characters of the session password).

## Only one GPU container at a time
The hookscript refuses `pre-start` while another GPU CT is running. By default every CT whose config passes `/dev/nvidia0`
counts as a GPU CT; override with `GPU_CTS=` in `/etc/steam-lxc/host.conf`. To protect another existing CT, add
`/usr/local/sbin/gpu-exclusive.sh "$1" || exit 1` to its own hookscript's pre-start.

## Optional shims
- [`shims/frame/`](shims/frame/README.md): Steam Frame helpers (always-on SteamVR, headset record seeding, rtkit, Frame Wireless Adapter), pending better Steam Frame support in SteamOS from Valve. All off by default.
