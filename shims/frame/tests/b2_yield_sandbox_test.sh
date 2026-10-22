#!/bin/bash
# B2 (offline): the single steam-lxc-steamvr loop in a sandbox. Fake Steam client (steam.pid + a process named
# steamwebhelper), a fake "steam" CLI that starts a fake vrserver inside a fake SteamVR dir, fake reaper processes
# (copies of bash with the exact comm names), a synthetic appinfo cache, a fake streaming log, and stubbed
# logger / gamescopectl / xprop. Touches nothing outside a temp dir; kills only its own PIDs.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'cleanup' EXIT
FAILS=0
ok()   { echo "PASS $*"; }
bad()  { echo "FAIL $*"; FAILS=$((FAILS+1)); }
check(){ local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
waitfor(){ local n=$1 t=$2; shift 2; for _ in $(seq $((t*10))); do "$@" && { ok "$n"; return; }; sleep 0.1; done; bad "$n"; }
MINE=()
cleanup() { [ "$FAILS" = 0 ] || { echo "--- log"; cat "$T/log"; echo "--- service"; cat "$T/svc.out"; }
            for p in "${MINE[@]}" ${SVC:-} $(vrs); do kill -KILL "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$T"; }

ROOT=$T/Steam; VRD=$ROOT/steamapps/common/SteamVR/bin/linux64
mkdir -p "$VRD" "$ROOT/appcache" "$ROOT/logs" "$T/bin" "$T/libexec" "$T/home/.steam" "$T/home/.config/gamescope" "$T/run" "$T/other"
for f in "$HERE"/bin/* "$HERE"/lib/*; do ln -s "$f" "$T/libexec/$(basename "$f")"; done
for n in vrserver vrmonitor; do cp /bin/bash "$VRD/$n"; done
cp /bin/bash "$T/bin/reaper"; cp /bin/bash "$T/other/vrmonitor"; cp /bin/bash "$T/bin/steamwebhelper"
cat > "$T/bin/logger" <<'S'
#!/bin/sh
shift 2; [ "$1" = -- ] && shift; echo "$*" >> "$LOGF"
S
cat > "$T/bin/fakesteam" <<S
#!/bin/sh
echo "steam \$*" >> "\$CALLS"
setsid "$VRD/vrserver" -c 'trap "exit 0" TERM; while :; do sleep 0.1; done' </dev/null >/dev/null 2>&1 &
setsid "$VRD/vrmonitor" -c 'trap "" TERM; while :; do sleep 0.1; done' </dev/null >/dev/null 2>&1 &
S
cat > "$T/bin/gamescopectl" <<'S'
#!/bin/sh
printf 'gamescope_control info:\n  - Connector Name: HDMI-A-1\n  - Display Make: Acme\n  - Display Model: TV9000\n'
S
cat > "$T/bin/xprop" <<'S'
#!/bin/sh
echo "xprop $*" >> "$CALLS"
S
chmod +x "$T"/bin/*
export LOGF=$T/log CALLS=$T/calls PATH="$T/bin:$PATH" HOME=$T/home XDG_CONFIG_HOME=$T/home/.config
: > "$LOGF"; : > "$CALLS"
python3 -c "
src=open('$HERE/tests/b1_vrclass_test.py').read().split('WANT = ')[0]
g={'__file__':'$HERE/tests/b1_vrclass_test.py'}; exec(src,g)
open('$ROOT/appcache/appinfo.vdf','wb').write(g['build'](29))"
cat > "$T/defaults" <<D
FRAME_SHIM_STEAMVR_ALWAYS_ON=1
FRAME_SHIM_STEAMVR_YIELD=1
FRAME_SHIM_STEAM_ROOT=$ROOT
FRAME_SHIM_STEAMVR_YIELD_FLAT="1006"
FRAME_SHIM_STEAMVR_START_DELAY=1
FRAME_SHIM_STEAMVR_RELAUNCH_DELAY=2
FRAME_SHIM_STEAMVR_RESUME_DELAY=2
FRAME_SHIM_YIELD_REAP_GRACE=0
FRAME_SHIM_ORPHAN_GRACE=1
FRAME_SHIM_ORPHAN_SETTLE=0
FRAME_SHIM_POLL=0.2
FRAME_SHIM_STEAM_CMD=$T/bin/fakesteam
D
export STEAM_LXC_DEFAULTS=$T/defaults FRAME_SHIM_LIBEXEC=$T/libexec FRAME_SHIM_RUNDIR=$T/run
SL=$ROOT/logs/streaming_log.txt; : > "$SL"
"$T/bin/steamwebhelper" -c 'while :; do sleep 0.5; done' & SPID=$!; MINE+=($SPID); echo $SPID > "$T/home/.steam/steam.pid"

vrs() { for p in $(pgrep -u "$UID" -x 'vrserver|vrmonitor'); do case "$(readlink /proc/$p/exe)" in "$VRD"/*) echo $p;; esac; done; }
vrserver_pid() { for p in $(pgrep -u "$UID" -x vrserver); do case "$(readlink /proc/$p/exe)" in "$VRD"/*) echo $p;; esac; done | head -1; }
vrup() { [ -n "$(vrserver_pid)" ]; }
vrdown() { ! vrup; }
launches() { grep -c 'steam://run/250820' "$CALLS"; }
spawn_game() { "$T/bin/reaper" -c 'while :; do sleep 0.1; done' reaper SteamLaunch "AppId=$1" -- game & G=$!; MINE+=($G); }
alive() { kill -0 "$1" 2>/dev/null; }

"$T/other/vrmonitor" -c 'while :; do sleep 0.2; done' & D1=$!; MINE+=($D1)
bash -c 'while :; do sleep 0.2; done' vrserver & D2=$!; MINE+=($D2)

echo "--- 0. one service: launch after start delay, relaunch after a crash"
bash "$HERE/bin/steam-lxc-steamvr" > "$T/svc.out" 2>&1 & SVC=$!
waitfor "SteamVR launched through steam://run/250820" 5 vrup
waitfor "service supervising" 3 grep -q 'supervising' "$T/svc.out"
V=$(vrserver_pid); kill -KILL "$V"
waitfor "crash noticed, relaunch scheduled" 3 grep -q 'vrserver exited; relaunching' "$T/svc.out"
waitfor "orphaned vrmonitor reaped before relaunch, then relaunched" 25 bash -c "[ \$(grep -c 'steam://run/250820' '$CALLS') -ge 2 ]"
waitfor "vrserver back" 5 vrup
waitfor "service supervising again" 3 bash -c "[ \$(grep -c supervising '$T/svc.out') -ge 2 ]"
check "reaped log line" grep -q 'reaping orphaned SteamVR processes' "$T/svc.out"

echo "--- 1. flat game (appinfo: no VR fields) with a VR stream already chosen"
echo "[x] >>> Starting VR stream" >> "$SL"
spawn_game 1001; G1=$G
waitfor "flat launch stops vrserver (SIGTERM)" 5 vrdown
waitfor "helpers inside SteamVR dir gone" 10 bash -c "[ -z \"\$(pgrep -u $UID -x vrmonitor | while read p; do readlink /proc/\$p/exe; done | grep -F '$VRD')\" ]"
check "decoy vrmonitor outside SteamVR dir survives" alive "$D1"
check "decoy with 'vrserver' only in argv survives" alive "$D2"
waitfor "stream-already-on-VR-path warning logged" 3 grep -q 'already started on the VR path' "$LOGF"
N=$(launches); sleep 3
check "no relaunch while the flat game runs (not treated as a crash)" test "$(launches)" = "$N"

echo "--- 2. desktop stream goes live -> 1080p mode applied, then stream stops -> restored"
echo "Acme TV9000:3840x2160@60" > "$T/home/.config/gamescope/modes.cfg"
echo "[x] >>> Stopped VR stream" >> "$SL"; echo "[x] >>> Starting desktop stream" >> "$SL"
waitfor "modes.cfg gets 1920x1080@60 for the display" 3 grep -qx 'Acme TV9000:1920x1080@60' "$T/home/.config/gamescope/modes.cfg"
check "mode nudge sent" grep -q 'GAMESCOPE_DISPLAY_MODE_NUDGE' "$CALLS"
echo "[x] >>> Stopped desktop stream" >> "$SL"
waitfor "modes.cfg restored after stream stop" 3 grep -qx 'Acme TV9000:3840x2160@60' "$T/home/.config/gamescope/modes.cfg"

echo "--- 3. flat -> flat handover keeps SteamVR down; unknown app also yields"
echo "[x] >>> Starting desktop stream" >> "$SL"
spawn_game 1007; G2=$G; sleep 0.6
kill -KILL "$G1"; sleep 3
check "no resume while unknown app 1007 still runs" vrdown

echo "--- 4. last non-VR app exits -> debounce -> resume; mode restored"
N=$(launches); kill -KILL "$G2"
sleep 1; check "no resume inside the debounce window" test "$(launches)" = "$N"
waitfor "resume relaunches SteamVR" 6 vrup
check "modes.cfg restored at resume" grep -qx 'Acme TV9000:3840x2160@60' "$T/home/.config/gamescope/modes.cfg"

echo "--- 4b. flat game on plain HDMI (no Frame stream live): output mode untouched"
echo "[x] >>> Stopped desktop stream" >> "$SL"; cp "$T/home/.config/gamescope/modes.cfg" "$T/modes.before"
spawn_game 1001; GH=$G
waitfor "yield" 5 vrdown; sleep 1
check "modes.cfg unchanged without a desktop stream" cmp -s "$T/modes.before" "$T/home/.config/gamescope/modes.cfg"

echo "--- 5. VR app while yielded -> SteamVR at once (no resume delay); VR-optional keeps it"
spawn_game 1003; G3=$G
waitfor "VR-only app 1003 starts SteamVR at once (before the resume delay would matter)" 8 vrup
spawn_game 1002; sleep 1
check "VR-optional app 1002 leaves SteamVR running" vrup
spawn_game 1006; waitfor "override FLAT app 1006 stops SteamVR" 5 vrdown
kill -KILL "$GH" "$G3" "$G" 2>/dev/null
waitfor "resume after all non-VR games exit" 8 vrup

echo "--- 6. steam-lxc-flat: stops SteamVR before exec and keeps it down even for a VR-classified app"
FRAME_SHIM_STEAMVR_YIELD_STOP_TIMEOUT=5 SteamAppId=1003 "$HERE/bin/steam-lxc-flat" bash -c 'pgrep -u "$UID" -x vrserver >/dev/null && echo VRUP > "$0/wrap.out" || echo VRDOWN > "$0/wrap.out"; sleep 4' "$T" & W=$!; MINE+=($W)
waitfor "game started only after vrserver stopped" 8 grep -qx VRDOWN "$T/wrap.out"
spawn_game 1003; GV=$G; sleep 2
check "VR reaper of the same game does not restart SteamVR while the wrapper runs" vrdown
kill -KILL "$GV"; wait "$W" 2>/dev/null
waitfor "resume after the wrapped game exits" 8 vrup

echo "--- 7. a vrserver ignoring SIGTERM is never SIGKILLed (service stopped)"
kill -TERM "$SVC"; wait "$SVC" 2>/dev/null; SVC=
for p in $(vrs); do kill -KILL "$p"; done
"$VRD/vrserver" -c 'trap "" TERM; while :; do sleep 0.1; done' & STUB=$!; MINE+=($STUB)
FRAME_SHIM_STEAMVR_YIELD_STOP_TIMEOUT=2 "$HERE/bin/steam-lxc-flat" true
check "stubborn vrserver still alive (no SIGKILL)" alive "$STUB"
check "logged that it left it running" grep -q 'no SIGKILL of vrserver' "$LOGF"
kill -KILL "$STUB" 2>/dev/null

echo "--- 8. off by default"
STEAM_LXC_DEFAULTS=/nonexistent "$HERE/bin/steam-lxc-steamvr" | grep -q 'nothing to do' && ok "service inert when ALWAYS_ON is unset" || bad "service inert when ALWAYS_ON is unset"
"$VRD/vrserver" -c 'trap "exit 0" TERM; while :; do sleep 0.1; done' & K=$!; MINE+=($K)
STEAM_LXC_DEFAULTS=/nonexistent "$HERE/bin/steam-lxc-flat" true; check "wrapper inert when off (vrserver kept)" alive "$K"
check "decisions logged under steam-lxc-intended" grep -q '^steamvr: started' "$LOGF"
echo "B2 $([ $FAILS = 0 ] && echo OK || echo "$FAILS FAILED")"; exit $(( FAILS > 0 ))
