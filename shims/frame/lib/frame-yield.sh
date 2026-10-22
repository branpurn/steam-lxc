# Frame shim: shared helpers for "SteamVR yields to flat games" (sourced by bin/steam-lxc-steamvr-yield,
# bin/steam-lxc-flat and bin/steam-lxc-steamvr). Pending better Steam Frame support in SteamOS from Valve.
# Everything is overridable for the offline tests: STEAM_LXC_DEFAULTS (config file), FRAME_SHIM_RUNDIR,
# FRAME_SHIM_STEAM_ROOT, FRAME_SHIM_STEAMVR_DIR, FRAME_SHIM_LIBEXEC.
# shellcheck shell=bash
FRAME_DEFAULTS=${STEAM_LXC_DEFAULTS:-/etc/default/steam-lxc}
[ -r "$FRAME_DEFAULTS" ] && . "$FRAME_DEFAULTS"
FRAME_LIBEXEC=${FRAME_SHIM_LIBEXEC:-/usr/local/lib/steam-lxc/frame}
FRAME_STEAM_ROOT=${FRAME_SHIM_STEAM_ROOT:-$HOME/.local/share/Steam}
VRDIR=$(realpath -m "${FRAME_SHIM_STEAMVR_DIR:-$FRAME_STEAM_ROOT/steamapps/common/SteamVR}")
FRAME_RUN=${FRAME_SHIM_RUNDIR:-${XDG_RUNTIME_DIR:-/run/user/$UID}/steam-lxc-frame}
YIELD_FILE=$FRAME_RUN/yield           # "<appid> <pid> <epoch>" while SteamVR stands aside for a non-VR app
LAUNCH_NOW=$FRAME_RUN/launch-now      # a VR app is starting: steam-lxc-steamvr skips its start delay
STREAM_RES=${FRAME_SHIM_FLAT_STREAM_RES-1920x1080}   # shim default; empty = off. Only used by the yield watcher.

flog() { logger -t steam-lxc-intended -- "$*" 2>/dev/null; echo "$*" >&2; }

vr_pids() { pgrep -u "$UID" -x vrserver; }
vr_up() { vr_pids >/dev/null; }

# Exact-match SteamVR processes: our UID, exact comm, executable inside the SteamVR install. Never pkill -f.
steamvr_procs() {   # $1 = comm regex for pgrep -x
    local p exe
    for p in $(pgrep -u "$UID" -x "$1"); do
        exe=$(readlink "/proc/$p/exe" 2>/dev/null) || continue
        case "$exe" in "$VRDIR"/*) echo "$p" ;; esac
    done
}

# Yield state ---------------------------------------------------------------------------------------------------------
yield_set() { mkdir -p "$FRAME_RUN"; echo "$1 $2 $(date +%s)" > "$YIELD_FILE.tmp" && mv -f "$YIELD_FILE.tmp" "$YIELD_FILE"; }
yield_clear() { rm -f "$YIELD_FILE"; }
# Active when the file exists. The watcher removes it; a stale file (watcher gone, pid dead for >2 min) is ignored so a
# crashed watcher can never keep SteamVR down for good.
yield_active() {
    local a p t
    [ -f "$YIELD_FILE" ] || return 1
    read -r a p t < "$YIELD_FILE" 2>/dev/null || return 1
    kill -0 "$p" 2>/dev/null && return 0
    [ $(( $(date +%s) - ${t:-0} )) -lt 120 ]
}

# Graceful stop. SteamVR on Linux has no supported "quit" command line (vrcmd/vrmonitor only offer in-app quit), so:
# 1. an optional site command (FRAME_SHIM_STEAMVR_YIELD_QUIT_CMD), 2. SIGTERM to the exact vrserver PID(s), which
# shuts SteamVR down like its own Quit, 3. helpers left behind are TERMed (then KILLed) only once no vrserver runs.
# vrserver itself is never SIGKILLed.
stop_steamvr() {
    local why=$1 p a b
    vr_up || return 0
    flog "yield: stopping SteamVR ($why)"
    if [ -n "${FRAME_SHIM_STEAMVR_YIELD_QUIT_CMD:-}" ]; then
        timeout 10 sh -c "$FRAME_SHIM_STEAMVR_YIELD_QUIT_CMD" >/dev/null 2>&1
        for _ in $(seq 10); do vr_up || break; sleep 1; done
    fi
    if vr_up; then
        a=$(steamvr_procs vrserver)
        [ -n "$a" ] && kill -TERM $a 2>/dev/null
        for _ in $(seq "${FRAME_SHIM_STEAMVR_YIELD_STOP_TIMEOUT:-15}"); do vr_up || break; sleep 1; done
    fi
    if vr_up; then flog "yield: SteamVR still running after SIGTERM; leaving it (no SIGKILL of vrserver)"; return 1; fi
    sleep "${FRAME_SHIM_YIELD_REAP_GRACE:-3}"
    vr_up && return 0
    a=$(steamvr_procs 'vrmonitor|vrdashboard|vrwebhelper|vrcompositor|vrstartup')
    if [ -n "$a" ]; then
        kill -TERM $a 2>/dev/null
        for _ in 1 2 3 4 5; do b=$(for p in $a; do kill -0 "$p" 2>/dev/null && echo "$p"; done); [ -z "$b" ] && break; sleep 1; done
        [ -n "$b" ] && kill -KILL $b 2>/dev/null
    fi
    flog "yield: SteamVR stopped"
    return 0
}

# Streams --------------------------------------------------------------------------------------------------------------
STREAM_LOG=${FRAME_SHIM_STREAMING_LOG:-$FRAME_STEAM_ROOT/logs/streaming_log.txt}
# Prints desktop|vr|none from the last ">>> Starting/Stopped ... stream" line of Steam's streaming log.
stream_state() {
    local l
    l=$(grep -aE '>>> (Starting|Stopped) (desktop|VR) stream' "$STREAM_LOG" 2>/dev/null | tail -1)
    case "$l" in *"Starting desktop stream"*) echo desktop ;; *"Starting VR stream"*) echo vr ;; *) echo none ;; esac
}
# Line count now, so later checks only look at what was logged after an event.
stream_mark() { wc -l < "$STREAM_LOG" 2>/dev/null || echo 0; }
stream_vr_since() { tail -n +"$(( $1 + 1 ))" "$STREAM_LOG" 2>/dev/null | grep -aq '>>> Starting VR stream'; }

# Steam session environment (display, D-Bus) taken from the running Steam client.
steam_env() {
    local pid v val
    pid=$(cat "$HOME/.steam/steam.pid" 2>/dev/null) || return 1
    for v in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XDG_CONFIG_HOME; do
        val=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n "s/^$v=//p" | head -1)
        [ -n "$val" ] && printf '%s=%s\n' "$v" "$val"
    done
}
