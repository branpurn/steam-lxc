# Compatibility

Host: Proxmox VE 9.2, kernel 7.0 (pve), NVIDIA RTX 4080, open kernel module 595.104.02, nvidia-drm modeset=1.
CT: Arch Linux (archlinux-base 2026-04-20 template, updated 2026-10-21), gamescope 3.16.31 (Arch), AUR gamescope-session-git r390, gamescope-session-steam-git r23.

| Item | Result | Status |
|---|---|---|
| NVIDIA userland 595.104.02 from `.run` (`--no-kernel-module`), `nvidia-smi` | RTX 4080, driver 595.104.02 | **verified** |
| Vulkan (`vulkaninfo --summary`) | NVIDIA GeForce RTX 4080, API 1.4.329, driver 595.104.02 | **verified** |
| pacman with Valve repos after Arch, `SigLevel = Required DatabaseOptional` | holo-keyring signature good (Valve CI key); named holo-3.9 packages install with signature checks; no Arch package replaced | **verified** |
| Valve repo DB signatures | `holo-3.9.db.sig` / `jupiter-3.9.db.sig` do not exist (404) | **verified** (hence DatabaseOptional) |
| gamescope **embedded** (DRM/KMS) on NVIDIA inside a privileged LXC | libseat via logind works; selects HDMI-A-2, 3840x2160@60; DP dummy also detected | **verified** |
| Steam Game Mode UI (`-gamepadui -steamos3`) under gamescope | Starts, bootstraps, shows the sign-in screen | **verified** |
| Session restart (`systemctl restart`) | old gamescope/Steam fully stopped (logind session terminated), exactly one gamescope afterwards | **verified** |
| Display stays on when idle | sleep disabled in logind; keepawake wakes HDMI if DPMS goes Off | **verified** (forced sleep → On within 10 s); long idle unverified |
| Steam login | signed in; kept across session restarts | **verified** |
| VNC into Game Mode | x11vnc attached to the Steam Big Picture window (`-id`); root-window capture fails on rootless Xwayland | **verified** (port open, VNC auth required, capture works); 2nd Xwayland (games with `STEAM_MULTIPLE_XWAYLANDS`) is not captured |
| Shared Steam library (bind mount, pre-registered `libraryfolders.vdf`) | mounted, registered; Steam's acceptance after login not checked | unverified |
| Native game (HL2:DM, app 320) | installed in the shared library | unverified |
| Proton game | — | unverified |
| Steam Remote Play from Game Mode on NVIDIA | upstream reports a green screen (gamescope #2489, NV12 capture) | unverified |
| Steam Frame streaming | dongle netdev moved in, NetworkManager manages it | unverified |
| SteamVR under embedded gamescope | `libdrm.so` present (Arch ships it) | unverified |
| Audio (PipeWire user units) | pipewire + wireplumber running; RTKit absent (no realtime) | partially verified (services run; sink not checked) |
| Controllers / Steam Input (`/dev/uinput`, `/dev/input`) | passed through, ACLs applied | unverified |
| hidraw | not passed through | unverified / not configured |
| gamescope `CAP_SYS_NICE` (`setcap`) | fails: CAP_SETFCAP is dropped inside the CT | **verified** (not possible) |
| HDR | permanently disabled (gamescope script hdr.supported=false + session env); SUPPORTS_HDR=0 | **verified** off |
| Output mode | 3840x2160@120 on HDMI (`-W/-H` + `-r` via wrapper) | **verified** |
| VRR | — | unverified |
| Desktop mode ("Switch to Desktop") | not installed | not implemented |
| Mutual exclusion with the other GPU CT | `pct start` of the other CT is refused while this one runs | **verified** |
