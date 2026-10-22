-- steam-lxc: NVIDIA display tweaks, enforced continuously inside gamescope (survives package updates: /etc).
-- Same intent as the SteamOS VM's gamescope-nvidia-tweaks.service (which re-ran gamescopectl for ~60 s), but
-- in-process: Steam can flip these at any time (e.g. GAMESCOPE_VRR_ENABLED / HDR atoms), so re-check every frame.
--   composite_force = true   always composite, never direct scanout of client buffers
--   adaptive_sync   = false  no VRR
--   hdr_enabled     = false  no HDR output
-- Changes and a periodic status line go to the gamescope log ("[steam-lxc-tweaks]"), which is the readback:
-- gamescopectl cannot read a convar (it always sends a value; `gamescopectl composite_force` with no value SETS it false).
local wanted = { composite_force = true, adaptive_sync = false, hdr_enabled = false }
local frames, status_every = 0, 120 * 600   -- status about every 10 min at 120 Hz

local function enforce(tag)
    for name, v in pairs(wanted) do
        local cv = gamescope.convars[name]
        if cv and cv.value ~= v then
            warn("[steam-lxc-tweaks] "..tag..": "..name.." "..tostring(cv.value).." -> "..tostring(v))
            cv.value = v
        end
    end
end

local function status()
    local s = {}
    for name, _ in pairs(wanted) do s[#s+1] = name.."="..tostring(gamescope.convars[name] and gamescope.convars[name].value) end
    table.sort(s)
    info("[steam-lxc-tweaks] status: "..table.concat(s, " "))
end

enforce("startup")

gamescope.hook("OnPostPaint", function()
    enforce("runtime")
    frames = frames + 1
    if frames == 600 or frames % status_every == 0 then status() end
end)
