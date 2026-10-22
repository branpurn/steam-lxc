#!/bin/bash
# Offline tests for ct/usr/local/sbin/steam-lxc-hdmi-watchdog and host/sbin/steam-lxc-hdmi-watchdog-host.
# Everything external (clock, sleep, logger, gamescope, systemctl, modetest, pct) is stubbed; no root needed.
cd "$(dirname "$0")/../.." || exit 1
WD=$PWD/ct/usr/local/sbin/steam-lxc-hdmi-watchdog; HOSTWD=$PWD/host/sbin/steam-lxc-hdmi-watchdog-host
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; pass=0
ok() { if eval "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; sed 's/^/    /' "$T/log" 2>/dev/null; fi; }

setup() {   # $1 = extra config lines
  rm -rf "$T/run"; : >"$T/log"; : >"$T/actions"; echo 1000 >"$T/clock"
  printf 'STEAM_LXC_HDMI_WATCHDOG=1\nHDMI_WATCHDOG_MAX=3\nHDMI_WATCHDOG_BACKOFF=10\nHDMI_WATCHDOG_SETTLE=1\nHDMI_WATCHDOG_VERIFY=5\n%s\n' "$1" >"$T/conf"
  cat >"$T/now" <<S
#!/bin/bash
cat "$T/clock"
S
  cat >"$T/sleep" <<S
#!/bin/bash
echo \$(( \$(cat "$T/clock") + \$1 )) >"$T/clock"
S
  cat >"$T/logger" <<S
#!/bin/bash
shift 2; echo "\$*" >>"$T/log"
S
  # gamescope-display-wake stub; FAIL_AGAIN=n: the first n "sleep" calls cause a new link failure (queued event)
  cat >"$T/wake" <<S
#!/bin/bash
echo "wake \${1:-wake}" >>"$T/actions"
if [ "\${1:-}" = sleep ] && [ "\$(grep -c 'wake sleep' "$T/actions")" -le "\${FAIL_AGAIN:-0}" ]; then : >"$T/run/hdmi-watchdog.pending"; fi
S
  cat >"$T/systemctl" <<S
#!/bin/bash
[ "\$1" = is-active ] && exit \${SESSION_DOWN:-0}
echo "systemctl \$*" >>"$T/actions"
S
  chmod +x "$T"/{now,sleep,logger,wake,systemctl}
}
run() { STEAM_LXC_CONF=$T/conf HDMI_WATCHDOG_STATE_DIR=$T/run WD_NOW_CMD=$T/now WD_SLEEP=$T/sleep WD_LOGGER=$T/logger \
        WD_WAKE=$T/wake WD_SYSTEMCTL=$T/systemctl "$WD" "$@" >>"$T/out" 2>&1; }

# 1. disabled by default: no action
setup ""; sed -i 's/WATCHDOG=1/WATCHDOG=0/' "$T/conf"; run event test
ok "disabled does nothing" '[ ! -s "$T/actions" ]'

# 2. one failure -> one DPMS cycle (sleep then wake), logged
setup ""; run event test
ok "dpms cycle" '[ "$(tr "\n" " " <"$T/actions")" = "wake sleep wake wake " ]'
ok "logged attempt" 'grep -q "attempt 1/3: DPMS cycle" "$T/log" && grep -q "no new link failure" "$T/log"'

# 3. the retry fails again -> queued event retried after backoff, until MAX, then gives up; no session restart
setup ""; FAIL_AGAIN=9 run event test
ok "max attempts" '[ "$(grep -c "wake sleep" "$T/actions")" = 3 ]'
ok "gave up" 'grep -q "gave up (3 attempts" "$T/log"'
ok "backoff waited" 'grep -q "backoff, waiting" "$T/log"'
ok "no restart without opt-in" '! grep -q systemctl "$T/actions"'

# 4. session restart only with opt-in and after DPMS_TRIES
setup "HDMI_WATCHDOG_ALLOW_SESSION_RESTART=1
HDMI_WATCHDOG_DPMS_TRIES=2"; FAIL_AGAIN=9 run event test
ok "restart on attempt 3" '[ "$(grep -c "wake sleep" "$T/actions")" = 2 ] && grep -q "systemctl restart steamos-session.service" "$T/actions"'

# 5. session not active -> ignored
setup ""; SESSION_DOWN=3 run event test
ok "ignored when session down" '[ ! -s "$T/actions" ] && grep -q "not active" "$T/log"'

# 6. window resets the counter
setup "HDMI_WATCHDOG_WINDOW=100"; FAIL_AGAIN=9 run event a
echo 5000 >"$T/clock"; : >"$T/actions"; run event b
ok "window reset" '[ "$(grep -c "wake sleep" "$T/actions")" -ge 1 ]'

# 7. link-status parsing from modetest output
cat >"$T/modetest" <<'S'
#!/bin/bash
printf 'Connectors:\nid\tencoder\tstatus\t\tname\t\tsize (mm)\tmodes\tencoders\n'
printf '120\t0\tconnected\tDP-4\t0x0\t1\t0\n  props:\n\t5 link-status:\n\t\tflags: enum\n\t\tenums: Good=0 Bad=1\n\t\tvalue: 0\n'
printf '129\t128\tconnected\tHDMI-A-1\t600x340\t33\t128\n  props:\n\t5 link-status:\n\t\tflags: enum\n\t\tenums: Good=0 Bad=1\n\t\tvalue: %s\n' "${LINK:-1}"
S
chmod +x "$T/modetest"
ok "link Bad" '[ "$(STEAM_LXC_CONF=$T/conf WD_MODETEST=$T/modetest "$WD" link-status HDMI-A-1)" = "HDMI-A-1 Bad" ]'
ok "link Good" '[ "$(LINK=0 STEAM_LXC_CONF=$T/conf WD_MODETEST=$T/modetest "$WD" link-status HDMI-A-1)" = "HDMI-A-1 Good" ]'
ok "other connector" '[ "$(STEAM_LXC_CONF=$T/conf WD_MODETEST=$T/modetest "$WD" link-status DP-4)" = "DP-4 Good" ]'

# 8. poll -> event on Bad
setup "HDMI_WATCHDOG_CONNECTORS=HDMI-A-1"
STEAM_LXC_CONF=$T/conf HDMI_WATCHDOG_STATE_DIR=$T/run WD_NOW_CMD=$T/now WD_SLEEP=$T/sleep WD_LOGGER=$T/logger WD_WAKE=$T/wake \
  WD_SYSTEMCTL=$T/systemctl WD_MODETEST=$T/modetest WD_POLL_ONCE=1 "$WD" poll >>"$T/out" 2>&1
ok "poll triggers" 'grep -q "link-status Bad on HDMI-A-1" "$T/log" && grep -q "wake sleep" "$T/actions"'

# 9. host helper: matching kernel lines -> pct exec event for running CTs only
cat >"$T/pct" <<S
#!/bin/bash
case "\$1" in status) [ "\$2" = 201 ] && echo "status: running" || echo "status: stopped" ;; exec) echo "pct \$*" >>"$T/pct.log" ;; esac
S
cat >"$T/src" <<'S'
#!/bin/bash
printf 'nvidia-modeset: something else\nnvidia-modeset: WARNING: GPU:0: HDMI FRL link training failed.\n'
S
chmod +x "$T/pct" "$T/src"; : >"$T/pct.log"; : >"$T/log"
HDMI_WATCHDOG_CTS="200 201" WD_PCT=$T/pct WD_LOGGER=$T/logger WD_SOURCE=$T/src "$HOSTWD"
ok "host forwards to running CT" '[ "$(cat "$T/pct.log")" = "pct exec 201 -- /usr/local/sbin/steam-lxc-hdmi-watchdog event host kernel: link training failed" ]'
ok "host logs intent" 'grep -q "event to CT 201" "$T/log"'

echo "HDMI watchdog: $pass passed, $fail failed"; [ $fail = 0 ]
