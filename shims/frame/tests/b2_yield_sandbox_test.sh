#!/bin/bash
# B2 (offline): the yield watcher in a sandbox with fake Steam reaper / vrserver processes (copies of bash with the
# exact comm names, SteamVR ones living inside a fake SteamVR dir), a fake appinfo cache, a fake streaming log and
# stubbed logger / systemctl / gamescopectl / xprop. Touches nothing outside a temp dir; kills only its own PIDs.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'cleanup' EXIT
FAILS=0
ok()   { echo "PASS $*"; }
bad()  { echo "FAIL $*"; FAILS=$((FAILS+1)); }
check(){ local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
waitfor(){ local n=$1; shift; for _ in $(seq 100); do "$@" && { ok "$n"; return; }; sleep 0.1; done; bad "$n"; }
MINE=()
cleanup() { [ "$FAILS" = 0 ] || { echo "--- log"; cat "$T/log"; }; for p in "${MINE[@]}" ${WPID:-}; do kill -KILL "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$T"; }

# Layout
ROOT=$T/Steam; VRD=$ROOT/steamapps/common/SteamVR/bin/linux64; mkdir -p "$VRD" "$ROOT/appcache" "$ROOT/logs" "$T/bin" "$T/libexec" "$T/home/.steam" "$T/home/.config/gamescope" "$T/run" "$T/other"
for f in "$HERE"/bin/* "$HERE"/lib/*; do ln -s "$f" "$T/libexec/$(basename "$f")"; done
cp /bin/bash "$VRD/vrserver"; cp /bin/bash "$VRD/vrmonitor"; cp /bin/bash "$T/bin/reaper"; cp /bin/bash "$T/other/vrmonitor"
cat > "$T/bin/logger" <<'S'
#!/bin/sh
shift 2; [ "$1" = -- ] && shift; echo "$*" >> "$LOGF"
S
cat > "$T/bin/systemctl" <<'S'
#!/bin/sh
echo "systemctl $*" >> "$CALLS"
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
import importlib.machinery,sys,types
src=open('$HERE/tests/b1_vrclass_test.py').read().split('WANT = ')[0]
g={'__file__':'$HERE/tests/b1_vrclass_test.py'}; exec(src,g)
open('$ROOT/appcache/appinfo.vdf','wb').write(g['build'](29))"
cat > "$T/defaults" <<D
FRAME_SHIM_STEAMVR_ALWAYS_ON=1
FRAME_SHIM_STEAMVR_YIELD=1
FRAME_SHIM_STEAM_ROOT=$ROOT
FRAME_SHIM_STEAMVR_YIELD_FLAT="1006"
FRAME_SHIM_STEAMVR_RESUME_DELAY=2
FRAME_SHIM_YIELD_REAP_GRACE=0
FRAME_SHIM_YIELD_POLL=0.2
D
export STEAM_LXC_DEFAULTS=$T/defaults FRAME_SHIM_LIBEXEC=$T/libexec FRAME_SHIM_RUNDIR=$T/run
SL=$ROOT/logs/streaming_log.txt; : > "$SL"
sleep 600 & STEAMPID=$!; MINE+=($STEAMPID); echo $STEAMPID > "$T/home/.steam/steam.pid"

spawn_vr() { "$VRD/vrserver" -c 'trap "exit 0" TERM; while :; do sleep 0.1; done' & VRS=$!; MINE+=($VRS)
             "$VRD/vrmonitor" -c 'trap "" TERM; while :; do sleep 0.1; done' & VRM=$!; MINE+=($VRM); }
spawn_game() { "$T/bin/reaper" -c 'while :; do sleep 0.1; done' reaper SteamLaunch "AppId=$1" -- game & G=$!; MINE+=($G); }
alive() { kill -0 "$1" 2>/dev/null; }
dead()  { ! alive "$1"; }

# Decoys that must survive: a vrmonitor outside the SteamVR dir, a process with "vrserver" only in its argv.
"$T/other/vrmonitor" -c 'while :; do sleep 0.2; done' & D1=$!; MINE+=($D1)
bash -c 'while :; do sleep 0.2; done' vrserver & D2=$!; MINE+=($D2)

spawn_vr
"$HERE/bin/steam-lxc-steamvr-yield" > "$T/watcher.out" 2>&1 & WPID=$!
sleep 0.6

echo "--- 1. flat game (appinfo: no VR fields) with a VR stream already chosen"
M=$(wc -l < "$SL"); echo "[x] >>> Starting VR stream" >> "$SL"
spawn_game 1001; G1=$G
waitfor "flat launch stops vrserver (SIGTERM)" dead "$VRS"
waitfor "orphaned helper inside SteamVR dir reaped" dead "$VRM"
check "decoy vrmonitor outside SteamVR dir survives" alive "$D1"
check "decoy with 'vrserver' only in argv survives" alive "$D2"
check "yield file names app 1001" grep -q '^1001 ' "$T/run/yield"
waitfor "stream-already-on-VR-path warning logged" grep -q 'already started on the VR path' "$LOGF"

echo "--- 2. desktop stream goes live -> 1080p mode applied, then stream stops -> restored"
echo "Acme TV9000:3840x2160@60" > "$T/home/.config/gamescope/modes.cfg"
echo "[x] >>> Stopped VR stream" >> "$SL"; echo "[x] >>> Starting desktop stream" >> "$SL"
waitfor "modes.cfg gets 1920x1080@60 for the display" grep -qx 'Acme TV9000:1920x1080@60' "$T/home/.config/gamescope/modes.cfg"
check "mode nudge sent" grep -q 'GAMESCOPE_DISPLAY_MODE_NUDGE' "$CALLS"
echo "[x] >>> Stopped desktop stream" >> "$SL"
waitfor "modes.cfg restored after stream stop" grep -qx 'Acme TV9000:3840x2160@60' "$T/home/.config/gamescope/modes.cfg"

echo "--- 3. flat -> flat handover keeps SteamVR down; unknown app also yields"
echo "[x] >>> Starting desktop stream" >> "$SL"
spawn_game 1007; G2=$G; sleep 0.6
kill -TERM "$G1"; sleep 2.8
check "no resume while unknown app 1007 still runs" bash -c "! grep -q 'start steam-lxc-steamvr' '$CALLS'"
check "yield adopted by app 1007" grep -q '^1007 ' "$T/run/yield"

echo "--- 4. last non-VR app exits -> debounce -> resume via unit; mode restored"
kill -TERM "$G2"
sleep 1; check "no resume inside the debounce window" bash -c "! grep -q 'start steam-lxc-steamvr' '$CALLS'"
waitfor "resume starts steam-lxc-steamvr.service" grep -q 'systemctl --user start steam-lxc-steamvr.service' "$CALLS"
check "yield file cleared" test ! -e "$T/run/yield"
check "modes.cfg restored at resume" grep -qx 'Acme TV9000:3840x2160@60' "$T/home/.config/gamescope/modes.cfg"

echo "--- 4b. flat game on plain HDMI (no Frame stream live): output mode untouched"
echo "[x] >>> Stopped desktop stream" >> "$SL"; cp "$T/home/.config/gamescope/modes.cfg" "$T/modes.before"
spawn_game 1001; GH=$G; sleep 1
check "modes.cfg unchanged without a desktop stream" cmp -s "$T/modes.before" "$T/home/.config/gamescope/modes.cfg"
kill -KILL "$GH"; sleep 2.8

echo "--- 5. VR app with SteamVR down -> start now (launch-now flag), nothing stopped"
: > "$CALLS"
spawn_game 1003; G3=$G
waitfor "VR launch starts SteamVR unit" grep -q 'start steam-lxc-steamvr.service' "$CALLS"
check "launch-now flag set" test -e "$T/run/launch-now"
spawn_vr; sleep 0.6
spawn_game 1002; sleep 0.8
check "VR-optional app 1002 leaves SteamVR running" alive "$VRS"

spawn_game 1006; waitfor "override FLAT app 1006 stops SteamVR" dead "$VRS"

echo "--- 6. steam-lxc-flat wrapper stops SteamVR synchronously before exec"
kill -TERM "$G" 2>/dev/null; sleep 0.2; spawn_vr
FRAME_SHIM_STEAMVR_YIELD_STOP_TIMEOUT=5 "$HERE/bin/steam-lxc-flat" bash -c 'pgrep -u "$UID" -x vrserver >/dev/null && echo VRUP || echo VRDOWN' > "$T/wrap.out"
check "game started only after vrserver stopped" grep -qx VRDOWN "$T/wrap.out"

echo "--- 7. a vrserver ignoring SIGTERM is never SIGKILLed"
"$VRD/vrserver" -c 'trap "" TERM; while :; do sleep 0.1; done' & STUB=$!; MINE+=($STUB)
FRAME_SHIM_STEAMVR_YIELD_STOP_TIMEOUT=2 "$HERE/bin/steam-lxc-steamvr-yield" --stop-now 1 $$ >/dev/null 2>&1
check "stubborn vrserver still alive (no SIGKILL)" alive "$STUB"
check "logged that it left it running" grep -q 'no SIGKILL of vrserver' "$LOGF"
kill -KILL "$STUB" 2>/dev/null

echo "--- 8. disabled by default: no YIELD -> watcher and wrapper do nothing"
STEAM_LXC_DEFAULTS=/nonexistent "$HERE/bin/steam-lxc-steamvr-yield" | grep -q 'nothing to do' && ok "watcher inert when off" || bad "watcher inert when off"
spawn_vr; STEAM_LXC_DEFAULTS=/nonexistent "$HERE/bin/steam-lxc-flat" true; check "wrapper inert when off (vrserver kept)" alive "$VRS"

echo "--- 9. all log lines tagged and sane"
check "logger received watcher lines" grep -q '^watcher: started' "$LOGF"
echo "B2 $([ $FAILS = 0 ] && echo OK || echo "$FAILS FAILED")"; exit $(( FAILS > 0 ))
