-- steam-lxc: with STEAM_LXC_DISABLE_HDR=1, never expose HDR on any display.
-- Without this, gamescope reads HDR support from the EDID and Steam can switch HDR output on through the
-- GAMESCOPE_DISPLAY_HDR_ENABLED root property even when --hdr-enabled isn't passed.
-- A known-display entry with an `hdr` table overrides the EDID-derived HDR info. /etc survives package updates.
if os.getenv("STEAM_LXC_DISABLE_HDR") ~= "1" then return end
gamescope.config.known_displays.steam_lxc_no_hdr = {
    pretty_name = "steam-lxc (HDR disabled)",
    hdr = { supported = false, force_enabled = false, eotf = gamescope.eotf.gamma22 },
    matches = function(display)
        -- Low score: matches every display; a more specific known-display script still wins.
        return 1
    end
}
