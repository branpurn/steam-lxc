# Frame shim: shared helpers for always-on SteamVR and "SteamVR yields to non-VR games" (sourced by
# bin/steam-lxc-steamvr, the single service process, and by the bin/steam-lxc-flat launch wrapper). Pending better Steam Frame support in SteamOS from Valve.
# Everything is overridable for the offline tests: STEAM_LXC_DEFAULTS (config file), FRAME_SHIM_RUNDIR,
# FRAME_SHIM_STEAM_ROOT, FRAME_SHIM_STEAMVR_DIR, FRAME_SHIM_LIBEXEC.
# shellcheck shell=bash
FRAME_DEFAULTS=${STEAM_LXC_DEFAULTS:-/etc/default/steam-lxc}
[ -r "$FRAME_DEFAULTS" ] && . "$FRAME_DEFAULTS"
FRAME_LIBEXEC=${FRAME_SHIM_LIBEXEC:-/usr/local/lib/steam-lxc/frame}
FRAME_STEAM_ROOT=${FRAME_SHIM_STEAM_ROOT:-$HOME/.local/share/Steam}
VRDIR=$(realpath -m "${FRAME_SHIM_STEAMVR_DIR:-$FRAME_STEAM_ROOT/steamapps/common/SteamVR}")
FRAME_RUN=${FRAME_SHIM_RUNDIR:-${XDG_RUNTIME_DIR:-/run/user/$UID}/steam-lxc-frame}
STREAM_RES=${FRAME_SHIM_FLAT_STREAM_RES-1920x1080}   # shim default; empty = off. Only used while yielded.

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

# Runtime dir: steamvr.lock serialises stop/launch between the service and the steam-lxc-flat wrapper; flat.d/<pid>
# (content: appid) is how the wrapper tells the service "this process is a non-VR game" (no second service involved).
LOCK_FILE=$FRAME_RUN/steamvr.lock
FLAT_SPOOL=$FRAME_RUN/flat.d

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

# Games --------------------------------------------------------------------------------------------------------------
reapers() {    # "<pid> <appid>" for each Steam reaper of ours (exact comm, AppId=<n> in its argv)
    local p a
    for p in $(pgrep -u "$UID" -x reaper); do
        a=$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | sed -n 's/^AppId=\([0-9]\+\)$/\1/p' | head -1)
        [ -n "$a" ] && echo "$p $a"
    done
}
flat_requests() {   # "<pid> <appid>" registered by steam-lxc-flat; dead entries are dropped
    local f p
    for f in "$FLAT_SPOOL"/*; do
        [ -f "$f" ] || continue
        p=${f##*/}
        if kill -0 "$p" 2>/dev/null; then echo "$p $(cat "$f" 2>/dev/null)"; else rm -f "$f"; fi
    done
}
classify() {   # prints vr|flat|unknown|ignore, cached per appid + appinfo mtime
    local app=$1 m c why
    m=$(stat -c %Y "$FRAME_STEAM_ROOT/appcache/appinfo.vdf" 2>/dev/null || echo 0)
    c=$(awk -v a="$app" -v m="$m" '$1==a && $2==m {print $3; exit}' "$FRAME_RUN/vrclass" 2>/dev/null)
    if [ -z "$c" ]; then
        read -r _ c why < <("$FRAME_LIBEXEC/steam-lxc-vrclass" "$app" 2>/dev/null)
        c=${c:-unknown}
        mkdir -p "$FRAME_RUN"; echo "$app $m $c" >> "$FRAME_RUN/vrclass"
        flog "classify: app $app -> $c (${why:-appinfo unreadable})"
    fi
    echo "$c"
}
