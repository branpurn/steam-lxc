#!/bin/bash
# B3 guest part: run as root INSIDE a throwaway systemd machine (see b3_units_nspawn.sh). Installs the shim with the
# real install.sh, fakes a Steam client / SteamVR / games with systemd-run --user, and checks that the ONE user unit
# steam-lxc-steamvr.service does launch, crash relaunch, yield/resume, VR fast start and session following in-process.
set -u
SRC=${1:-/src/shims/frame}
FAILS=0; ok(){ echo "PASS $*"; }; bad(){ echo "FAIL $*"; FAILS=$((FAILS+1)); }
check(){ local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
waitfor(){ local n=$1 t=$2; shift 2; for _ in $(seq $((t*5))); do "$@" && { ok "$n"; return; }; sleep 0.2; done; bad "$n"; }

id steam >/dev/null 2>&1 || useradd -m steam
U=$(id -u steam); H=/home/steam; ST=$H/.local/share/Steam; VRB=$ST/steamapps/common/SteamVR/bin/linux64
WANTS=$H/.config/systemd/user/default.target.wants
conf() { cat > /etc/default/steam-lxc <<D
STEAM_LXC_USER=steam
FRAME_SHIM_STEAMVR_ALWAYS_ON=$1
FRAME_SHIM_STEAMVR_YIELD=$2
FRAME_SHIM_STEAMVR_START_DELAY=1
FRAME_SHIM_STEAMVR_RELAUNCH_DELAY=2
FRAME_SHIM_STEAMVR_RESUME_DELAY=3
FRAME_SHIM_YIELD_REAP_GRACE=0
FRAME_SHIM_ORPHAN_GRACE=1
FRAME_SHIM_ORPHAN_SETTLE=0
FRAME_SHIM_POLL=0.5
${3:-}
D
}
conf 1 1
# Leftovers of the earlier two-unit build must be cleaned up by install.sh.
mkdir -p /usr/local/lib/steam-lxc/frame /etc/systemd/user "$WANTS"
touch /usr/local/lib/steam-lxc/frame/steam-lxc-steamvr-yield /etc/systemd/user/steam-lxc-steamvr-yield.service
ln -sfn /etc/systemd/user/steam-lxc-steamvr-yield.service "$WANTS/steam-lxc-steamvr-yield.service"
bash "$SRC/install.sh" | sed 's/^/install: /'
check "install.sh enabled steam-lxc-steamvr.service" test -L "$WANTS/steam-lxc-steamvr.service"
check "old yield unit link removed" test ! -e "$WANTS/steam-lxc-steamvr-yield.service" -a ! -L "$WANTS/steam-lxc-steamvr-yield.service"
check "old yield unit + script removed" test ! -e /etc/systemd/user/steam-lxc-steamvr-yield.service -a ! -e /usr/local/lib/steam-lxc/frame/steam-lxc-steamvr-yield
check "only one shim user unit installed" test "$(ls /etc/systemd/user | grep -c steam-lxc)" = 1
check "unit verifies" systemd-analyze verify /etc/systemd/user/steam-lxc-steamvr.service

install -d -o steam -g steam "$VRB" $H/.steam $H/bin
cp /bin/bash "$VRB/vrserver"; cp /bin/bash $H/bin/reaper; cp /bin/bash $H/bin/steamwebhelper; chown -R steam: $H
cat > /usr/local/bin/steam <<S
#!/bin/sh
echo "steam \$*" >> /tmp/steam-calls
systemd-run --user --no-block --unit "fakevr-\$(date +%s%N)" -q "$VRB/vrserver" -c 'trap "exit 0" TERM; while :; do sleep 0.2; done'
S
chmod +x /usr/local/bin/steam; : > /tmp/steam-calls; chmod 666 /tmp/steam-calls
loginctl enable-linger steam; for _ in $(seq 50); do [ -S /run/user/$U/bus ] && break; sleep 0.2; done
us() { runuser -u steam -- env XDG_RUNTIME_DIR=/run/user/$U DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$U/bus "$@"; }
prop() { us systemctl --user show -p "$2" --value "$1"; }
state_is() { [ "$(prop "$1" ActiveState)" = "$2" ]; }
vrup() { pgrep -u steam -x vrserver >/dev/null; }
vrdown() { ! vrup; }
launches() { grep -c 'steam://run/250820' /tmp/steam-calls; }
fake_steam() { us systemd-run --user --unit "$1" -q $H/bin/steamwebhelper -c 'while :; do sleep 1; done'
               us sh -c "systemctl --user show -p MainPID --value $1 > $H/.steam/steam.pid"; }
game() { us systemd-run --user --unit "$1" -q $H/bin/reaper -c 'while :; do sleep 0.2; done' reaper SteamLaunch "AppId=$2" -- game; }
fake_steam fakesteam
us systemctl --user daemon-reload
us systemctl --user start steam-lxc-steamvr.service
SVC=steam-lxc-steamvr.service

echo "--- launch + crash relaunch inside the one unit"
waitfor "SteamVR launched through steam://run/250820" 20 grep -q 'steam://run/250820' /tmp/steam-calls
waitfor "vrserver up" 10 vrup
waitfor "unit supervising it" 10 bash -c "journalctl _SYSTEMD_USER_UNIT=steam-lxc-steamvr.service -o cat | grep -q supervising"
for u in $(us systemctl --user list-units --plain --no-legend 'fakevr-*' | awk '{print $1}'); do us systemctl --user kill -s KILL "$u"; done
waitfor "relaunched after crash (in-loop)" 20 bash -c "[ \$(grep -c 'steam://run/250820' /tmp/steam-calls) -ge 2 ] && pgrep -u steam -x vrserver >/dev/null"
check "no unit restart for the crash" test "$(prop $SVC NRestarts)" = 0

echo "--- flat game -> SteamVR stops, unit stays active, no relaunch"
sleep 2; game fakegame 4242
waitfor "vrserver stopped" 20 vrdown
N=$(launches); sleep 5
check "unit still active (single loop)" state_is $SVC active
check "no relaunch while the game runs" test "$(launches)" = "$N"

echo "--- game exits -> resume"
us systemctl --user stop fakegame
waitfor "SteamVR back after resume delay" 30 vrup

echo "--- VR game while yielded -> immediate start"
sleep 2; game fakegame2 4242
waitfor "yield again" 20 vrdown
conf 1 1 "FRAME_SHIM_STEAMVR_YIELD_VR=4343"   # read by the classifier at each new launch
game fakevrgame 4343
waitfor "VR override app starts SteamVR at once" 8 vrup
us systemctl --user stop fakegame2 fakevrgame

echo "--- session switch: Steam client replaced -> unit follows it without restarting"
sleep 2; us systemctl --user stop fakesteam
for u in $(us systemctl --user list-units --plain --no-legend 'fakevr-*' | awk '{print $1}'); do us systemctl --user stop "$u"; done
sleep 3; N=$(launches); fake_steam fakesteam2
waitfor "SteamVR launched for the new Steam client" 20 bash -c "[ \$(grep -c 'steam://run/250820' /tmp/steam-calls) -gt $N ] && pgrep -u steam -x vrserver >/dev/null"
check "still no unit restarts" test "$(prop $SVC NRestarts)" = 0

echo "--- toggles off"
conf 0 0; us systemctl --user restart $SVC; sleep 1
check "unit skipped by ExecCondition when ALWAYS_ON=0" state_is $SVC inactive
bash "$SRC/install.sh" >/dev/null
check "install.sh with toggle off removes the enable link" test ! -e "$WANTS/steam-lxc-steamvr.service"
echo "--- journal (steam-lxc-intended)"; journalctl -t steam-lxc-intended --no-pager -o cat | tail -20
[ $FAILS = 0 ] || { journalctl _SYSTEMD_USER_UNIT=$SVC --no-pager -o short-monotonic | tail -40; echo "--- steam stub calls"; cat /tmp/steam-calls; }
echo "B3 $([ $FAILS = 0 ] && echo OK || echo "$FAILS FAILED")"
