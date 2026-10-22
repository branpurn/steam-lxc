# Frame shim: temporary gamescope output mode while a NON-VR game streams to the Frame (FRAME_SHIM_FLAT_STREAM_RES,
# OPT-IN, default off: known to make the crop worse, see README). Works around the Remote Play client cropping a larger-than-requested desktop
# capture to its top-left corner (the Frame asks for 1920x1080; gamescope's PipeWire node delivers the output size).
# Mechanism: the same one Steam's own external-display resolution setting uses. gamescope reads saved modes from
# $GAMESCOPE_MODE_SAVE_FILE (gamescope-session-plus: ~/.config/gamescope/modes.cfg), lines "<Make Model>:WxH@Hz",
# and re-picks the mode when GAMESCOPE_DISPLAY_MODE_NUDGE is set on the root window. The original file is saved
# first and put back when the stream or the game ends. Only steam-lxc-steamvr calls this, while yielded, so plain HDMI play (no
# Frame stream) is never touched.
# shellcheck shell=bash
MODES_FILE=${FRAME_SHIM_GAMESCOPE_MODES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/gamescope/modes.cfg}
RES_STATE=$FRAME_RUN/streamres        # our applied line; RES_STATE.orig = original modes file (or "absent" marker)

streamres_target() {   # prints "WxH@Hz" or fails when off/invalid
    local r=${STREAM_RES:-}
    [ -n "$r" ] || return 1
    [[ $r =~ ^[0-9]+x[0-9]+(@[0-9]+)?$ ]] || { flog "streamres: FRAME_SHIM_FLAT_STREAM_RES='$r' invalid (want WxH or WxH@Hz)"; return 1; }
    [[ $r == *@* ]] || r="$r@${FRAME_SHIM_FLAT_STREAM_HZ:-60}"
    echo "$r"
}
streamres_display() {  # gamescope's description of the active screen: "<Make> <Model>"
    [ -n "${FRAME_SHIM_FLAT_STREAM_DISPLAY:-}" ] && { echo "$FRAME_SHIM_FLAT_STREAM_DISPLAY"; return; }
    local info mk md
    info=$(timeout 5 env "${SENV[@]}" gamescopectl 2>/dev/null) || return 1
    mk=$(sed -n 's/^ *- Display Make: //p' <<<"$info" | head -1); md=$(sed -n 's/^ *- Display Model: //p' <<<"$info" | head -1)
    [ -n "$mk$md" ] || return 1
    echo "$mk $md"
}
streamres_nudge() {
    env "${SENV[@]}" xprop -root -f GAMESCOPE_DISPLAY_MODE_NUDGE 32c -set GAMESCOPE_DISPLAY_MODE_NUDGE 1 2>/dev/null
}
streamres_active() { [ -f "$RES_STATE" ]; }
streamres_apply() {
    local t d line
    streamres_active && return 0
    mapfile -t SENV < <(steam_env)
    t=$(streamres_target) || return 0
    d=$(streamres_display) || { flog "streamres: cannot read the display name from gamescopectl; not changing the mode"; return 1; }
    line="$d:$t"
    mkdir -p "$FRAME_RUN" "$(dirname "$MODES_FILE")"
    if [ -f "$MODES_FILE" ]; then cp -p "$MODES_FILE" "$RES_STATE.orig"; else echo "@absent@" > "$RES_STATE.orig"; fi
    { [ -f "$MODES_FILE" ] && grep -avF "$d:" "$MODES_FILE"; echo "$line"; } > "$MODES_FILE.frame-tmp"
    mv -f "$MODES_FILE.frame-tmp" "$MODES_FILE"
    echo "$line" > "$RES_STATE"
    streamres_nudge
    flog "streamres: flat stream to Frame; gamescope output set to $t (was: $(grep -aF "$d:" "$RES_STATE.orig" 2>/dev/null | cut -d: -f2- || true); empty = no saved mode, gamescope default)"
}
streamres_restore() {
    local line
    streamres_active || return 0
    mapfile -t SENV < <(steam_env)
    line=$(cat "$RES_STATE")
    if [ -f "$MODES_FILE" ] && grep -aqxF "$line" "$MODES_FILE"; then
        if [ "$(cat "$RES_STATE.orig" 2>/dev/null)" = "@absent@" ]; then : > "$MODES_FILE"; else cp -p "$RES_STATE.orig" "$MODES_FILE"; fi
        streamres_nudge
        flog "streamres: gamescope output mode restored"
    else
        flog "streamres: modes file changed meanwhile (Steam setting?); leaving it as is"
    fi
    rm -f "$RES_STATE" "$RES_STATE.orig"
}
