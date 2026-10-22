-- steam-lxc: never expose HDR on any display (HDR caused artifacting on this panel + RTX 4080).
-- gamescope loads /etc/gamescope/scripts after its own scripts, and package updates don't touch /etc.
-- Without this, gamescope reads HDR support from the panel's EDID and Steam can turn HDR output on through the
-- GAMESCOPE_DISPLAY_HDR_ENABLED root property, even when --hdr-enabled isn't passed
-- (the log showed "xwm: HDR output enabled").
-- A known-display entry that has an `hdr` table overrides the EDID-derived HDR info.
gamescope.config.known_displays.steam_lxc_no_hdr = {
    pretty_name = "steam-lxc (HDR disabled)",
    hdr = {
        supported = false,
        force_enabled = false,
        eotf = gamescope.eotf.gamma22,
    },
    matches = function(display)
        -- Low score: matches every display; a specific known-display script with a higher score still wins.
        debug("[steam_lxc_no_hdr] matched vendor: "..tostring(display.vendor).." model: "..tostring(display.model))
        return 1
    end
}
