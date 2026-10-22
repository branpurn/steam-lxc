# steam-lxc

A re-implementation, as far as an LXC container allows, of **SteamOS 3 "Game Mode"** on a Proxmox VE host with an
NVIDIA GPU: Arch Linux + selected packages from Valve's SteamOS 3.9 repos + gamescope + Steam Big Picture,
started as a systemd service that takes the GPU's display (DRM/KMS) directly.

**Status: working prototype.** The CT boots straight into embedded gamescope on the NVIDIA GPU at 4K60 on the
HDMI panel with Steam's Game Mode UI (sign-in screen verified). Steam login, game launch, Remote Play and SteamVR are
**not yet verified** (they need an interactive Steam login). See [COMPATIBILITY.md](COMPATIBILITY.md) and [NOTES.md](NOTES.md).

## How it differs from real SteamOS
| SteamOS 3 | steam-lxc |
|---|---|
| Own kernel (`linux-neptune`), firmware, Deck hardware daemons | Host kernel (PVE). No kernel, firmware, fan/power/BIOS daemons |
| Read-only A/B root image, `steamos-atomupd` | Normal mutable Arch root; `pct snapshot` before every `pacman -Syu` ([ct/install/update.sh](ct/install/update.sh)) |
| Valve `gamescope`, Mesa/RADV (AMD) | Arch `extra/gamescope`, NVIDIA proprietary userland pinned to the host kernel module |
| `gamescope-session` from `steamos-customizations` + `steam-jupiter-stable` | AUR `gamescope-session-git` + `gamescope-session-steam-git` (OpenGamingCollective) + Arch `steam` |
| logind seat with real VTs; "Switch to Desktop" goes to Plasma | logind seat without VTs; sessions are system units with `PAMName=login`. Desktop Mode is Plasma 6.8 **Wayland** (Arch dropped X11 Plasma), switched via the steamos-session-select hook |
| Everything from Valve's repos | Arch repos first; Valve repos listed after them and only named packages installed (holo-keyring, holo-grant-cap-sys-nice, xdg-desktop-portal-holo), signatures enforced |

## Layout
- `host/` — run on the PVE host: `create-ct.sh`, `lxc-601.conf.fragment` (device passthrough),
  `hookscripts/ct601-steamos.sh` (pre-start GPU exclusivity, GPU cgroup prep, Frame dongle name), `sbin/gpu-exclusive.sh`.
- `ct/install/` — run inside the CT as root, in order: `10-bootstrap.sh`, `20-nvidia-hostmatched.sh`,
  `30-valve-repos.sh`, `35-user.sh`, `40-aur-session.sh`, `50-session.sh`, `60-shared-library.sh`; `update.sh` (host side).
- `ct/etc`, `ct/usr` — units and scripts copied into the CT by `50-session.sh`:
  `steamos-session.service` (+ `/usr/local/bin/steamos-session`), `steam-lxc-vnc.service`, device ACL units, host udev DB bind,
  NetworkManager/polkit config for the Frame dongle, gamescope-session overrides.

## Quick start
```sh
# PVE host
host/create-ct.sh                       # CT=601 by default
pct start 601                           # refused while the other GPU CT runs
tar cz ct | pct exec 601 -- tar xz -C /root
pct push 601 <path-to>/NVIDIA-Linux-x86_64-<host version>.run /root/
pct exec 601 -- bash /root/ct/install/10-bootstrap.sh
pct exec 601 -- bash /root/ct/install/20-nvidia-hostmatched.sh   # NVIDIA_VERSION=<host version>
pct exec 601 -- bash /root/ct/install/30-valve-repos.sh
# put the session password in /root/.steam-lxc-pass inside the CT (mode 600), then:
pct exec 601 -- bash /root/ct/install/35-user.sh
pct exec 601 -- bash /root/ct/install/40-aur-session.sh
pct exec 601 -- bash /root/ct/install/50-session.sh
pct exec 601 -- bash /root/ct/install/60-shared-library.sh
pct reboot 601
```
Then sign in to Steam on the panel or over VNC (`<ct-ip>:5900`, VNC password = first 8 characters of the session password).

## Only one GPU container at a time
The hookscript refuses `pre-start` while another GPU CT (default list `600 601`, `GPU_CTS` in `gpu-exclusive.sh`) is running.
Add the same `gpu-exclusive.sh "$1" || exit 1` line to the other CT's hookscript. Switch with `pct stop <a> && pct start <b>`.
