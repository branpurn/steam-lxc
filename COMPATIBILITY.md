# Compatibility

Verified on one host: Proxmox VE 9 (kernel 7.0 pve), an NVIDIA RTX 40-series GPU with the open kernel module (595 series),
nvidia-drm modeset=1. CT: Arch Linux (archlinux-base template, updated 2026-10), gamescope 3.16.31 (Arch),
AUR gamescope-session-git, gamescope-session-steam-git.

| Item | Result | Status |
|---|---|---|
| NVIDIA userland from `.run` (`--no-kernel-module`) matched to the host module, `nvidia-smi` | driver matches host | **verified** |
| Vulkan (`vulkaninfo --summary`) | NVIDIA device, API 1.4 | **verified** |
| pacman with Valve repos after Arch, `SigLevel = Required DatabaseOptional` | holo-keyring signature good (Valve CI key); named holo-3.9 packages install with signature checks; no Arch package replaced | **verified** |
| Valve repo DB signatures | `holo-3.9.db.sig` / `jupiter-3.9.db.sig` do not exist (404) | **verified** (hence DatabaseOptional) |
| gamescope **embedded** (DRM/KMS) on NVIDIA inside a privileged LXC | libseat via logind works; honours `--prefer-output` | **verified** |
| Steam Game Mode UI (`-gamepadui -steamos3`) under gamescope | starts, sign-in, library | **verified** |
| Session restart (`systemctl restart`) | old session fully stopped, exactly one gamescope afterwards | **verified** |
| Display keep-awake (`KEEPAWAKE_CONNECTORS`) | sleep disabled in logind; forced sleep → On within 10 s | **verified**; long idle unverified |
| Steam login | kept across session restarts, mode switches and reboots | **verified** |
| VNC into Game Mode | x11vnc attached to the Steam Big Picture window (`-id`) | **verified**; a 2nd Xwayland (`STEAM_MULTIPLE_XWAYLANDS`) is not captured |
| Shared Steam library (raw bind mount + `60-shared-library.sh`) | mounted, registered in `libraryfolders.vdf` | unverified (Steam acceptance not checked) |
| Native game | runs | **verified** |
| Proton game | runs (one title needed `proton-stable`, see `70-compat-tool.sh`) | **verified** |
| Steam Remote Play from Game Mode on NVIDIA | upstream reports a green screen (gamescope #2489, NV12 capture) | unverified |
| SteamVR under embedded gamescope | `libdrm.so` present | unverified |
| Audio (PipeWire user units) | services run; RTKit absent (no realtime) | partially verified |
| Controllers / Steam Input (`/dev/uinput`, `/dev/input`) | passed through, ACLs applied | unverified |
| hidraw | ACLs applied when present | unverified |
| gamescope `CAP_SYS_NICE` (`setcap`) | fails: CAP_SETFCAP is dropped inside the CT | **verified** (not possible) |
| `STEAM_LXC_DISABLE_HDR=1` | `GAMESCOPE_DISPLAY_SUPPORTS_HDR=0`, no `HDR output enabled` | **verified** |
| Output mode (`GAME_OUTPUT_WIDTH/HEIGHT/REFRESH`) | `-W/-H` + `-r` via wrapper; mode selected as configured | **verified** |
| `STEAM_LXC_NVIDIA_TWEAKS=1` | composite_force on, adaptive_sync off, re-enforced when Steam flips them; artifacting gone | **verified** |
| Desktop Mode (Plasma 6.8 Wayland) + switching both ways | via steamos-session-select hook | **verified** (command path) |
| VNC in Desktop Mode | krfb waits on portal consent; x11vnc can't capture Wayland | **not working** |
| Ctrl+Shift+Esc game killer | TERM then KILL of the game tree; Steam/gamescope untouched | partly verified (native game exits on TERM); SIGKILL path untested |
| Mutual exclusion with another GPU CT | `pct start` of the other CT is refused while this one runs | **verified** |
