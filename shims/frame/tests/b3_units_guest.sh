#!/bin/bash
# B3 guest part: run as root INSIDE a throwaway systemd machine (see b3_units_nspawn.sh). Installs the shim with the
# real install.sh, fakes a Steam client / SteamVR / game with systemd-run --user, and checks how
# steam-lxc-steamvr.service and steam-lxc-steamvr-yield.service hand over to each other.
set -u
SRC=${1:-/src/shims/frame}
FAILS=0; ok(){ echo "PASS $*"; }; bad(){ echo "FAIL $*"; FAILS=$((FAILS+1)); }
check(){ local n=$1; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
waitfor(){ local n=$1 t=$2; shift 2; for _ in $(seq $((t*5))); do "$@" && { ok "$n"; return; }; sleep 0.2; done; bad "$n"; }

id steam >/dev/null 2>&1 || useradd -m steam
U=$(id -u steam); H=/home/steam; ST=$H/.local/share/Steam; VRB=$ST/steamapps/common/SteamVR/bin/linux64
conf() { cat > /etc/default/steam-lxc <<D
STEAM_LXC_USER=steam
FRAME_SHIM_STEAMVR_ALWAYS_ON=$1
FRAME_SHIM_STEAMVR_YIELD=$2
FRAME_SHIM_STEAMVR_START_DELAY=1
FRAME_SHIM_STEAMVR_RESUME_DELAY=3
FRAME_SHIM_YIELD_REAP_GRACE=0
FRAME_SHIM_SUPERVISE_POLL=1
D
}
conf 1 1
bash "$SRC/install.sh" | sed 's/^/install: /'
check "install.sh enabled both user units" test -L $H/.config/systemd/user/default.target.wants/steam-lxc-steamvr-yield.service
check "units verify" systemd-analyze verify /etc/systemd/user/steam-lxc-steamvr.service /etc/systemd/user/steam-lxc-steamvr-yield.service

# Fakes: SteamVR's vrserver, Steam's reaper, a "steam" CLI that starts SteamVR, a running Steam client.
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
us systemd-run --user --unit fakesteam -q $H/bin/steamwebhelper -c 'while :; do sleep 1; done'
us sh -c "systemctl --user show -p MainPID --value fakesteam > $H/.steam/steam.pid"
us systemctl --user daemon-reload
us systemctl --user start steam-lxc-steamvr.service steam-lxc-steamvr-yield.service

echo "--- always-on start"
waitfor "SteamVR launched through steam://run/250820" 20 grep -q 'steam://run/250820' /tmp/steam-calls
waitfor "vrserver up" 10 vrup
check "steamvr unit active" test "$(prop steam-lxc-steamvr.service ActiveState)" = active
check "yield unit active" test "$(prop steam-lxc-steamvr-yield.service ActiveState)" = active
sleep 2

echo "--- flat game -> SteamVR yields, unit stops cleanly without restart loop"
us systemd-run --user --unit fakegame -q $H/bin/reaper -c 'while :; do sleep 0.2; done' reaper SteamLaunch AppId=4242 -- game
waitfor "vrserver stopped" 20 bash -c '! pgrep -u steam -x vrserver >/dev/null'
waitfor "steamvr unit inactive (exit 0 on yield)" 15 state_is steam-lxc-steamvr.service inactive
check "steamvr unit result success" test "$(prop steam-lxc-steamvr.service Result)" = success
sleep 4
check "no relaunch while the game runs" bash -c '! pgrep -u steam -x vrserver >/dev/null'
us systemctl --user start steam-lxc-steamvr.service; sleep 3
check "manual unit start waits while yielded (no SteamVR)" bash -c '! pgrep -u steam -x vrserver >/dev/null'

echo "--- game exits -> resume"
us systemctl --user stop fakegame
waitfor "SteamVR back after resume delay" 30 vrup
check "steamvr unit active again" test "$(prop steam-lxc-steamvr.service ActiveState)" = active

echo "--- VR game while yielded -> immediate start"
us systemd-run --user --unit fakegame2 -q $H/bin/reaper -c 'while :; do sleep 0.2; done' reaper SteamLaunch AppId=4242 -- game
waitfor "yield again" 20 bash -c '! pgrep -u steam -x vrserver >/dev/null'
sed -i 's/^FRAME_SHIM_STEAMVR_YIELD=1$/FRAME_SHIM_STEAMVR_YIELD=1\nFRAME_SHIM_STEAMVR_YIELD_VR=4343/' /etc/default/steam-lxc
us systemd-run --user --unit fakevrgame -q $H/bin/reaper -c 'while :; do sleep 0.2; done' reaper SteamLaunch AppId=4343 -- game
waitfor "VR override app starts SteamVR at once (no resume delay)" 12 vrup
us systemctl --user stop fakegame2 fakevrgame

echo "--- toggles off -> ExecCondition skips both units"
conf 1 0; us systemctl --user restart steam-lxc-steamvr-yield.service; sleep 1
check "yield unit skipped when FRAME_SHIM_STEAMVR_YIELD=0" test "$(prop steam-lxc-steamvr-yield.service ActiveState)" = inactive
conf 0 0; us systemctl --user restart steam-lxc-steamvr.service; sleep 1
check "steamvr unit skipped when ALWAYS_ON=0" test "$(prop steam-lxc-steamvr.service ActiveState)" = inactive
bash "$SRC/install.sh" >/dev/null
check "install.sh with toggles off removes the enable links" test ! -e $H/.config/systemd/user/default.target.wants/steam-lxc-steamvr-yield.service
echo "--- journal (steam-lxc-intended)"; journalctl -t steam-lxc-intended --no-pager -o cat | tail -20
[ $FAILS = 0 ] || journalctl _SYSTEMD_USER_UNIT=steam-lxc-steamvr.service --no-pager -o short-monotonic | tail -30; echo "--- steam stub calls"; cat /tmp/steam-calls
echo "B3 $([ $FAILS = 0 ] && echo OK || echo "$FAILS FAILED")"
