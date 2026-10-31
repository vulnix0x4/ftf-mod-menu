--!nocheck
--[[
    Flee the Facility - suite loader

    One paste loads the whole mod menu straight from the local static server:

        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/loaders/ftf_loader.lua"))()

    Order matters: the modules publish their _G APIs, and menu.lua is last so it
    can see all of them on its first refresh.

        esp.lua         -> _G.__ftfESP
        speed.lua       -> _G.__ftfSpeed
        antifreeze.lua  -> _G.__ftfAntiFreeze
        rescue.lua      -> _G.__ftfRescue
        doors.lua       -> _G.__ftfDoors
        noclip.lua      -> _G.__ftfNoclip
        objectives.lua  -> _G.__ftfObjectives
        beast_recon.lua -> _G.__ftfBeastRecon
        beastwatch.lua  -> _G.__ftfBeastwatch
        skillcheck_probe.lua -> _G.__ftfSkillProbe
        skillcheck.lua  -> _G.__ftfAutoSkill
        menu.lua        -> _G.__ftfMenu   (GUI, last)

    Re-running this file while the suite is live is safe: every module owns an
    instance id, so the older copy disconnects itself instead of tearing down
    the newer one.
]]

local BASE = "http://127.0.0.1:8765/"

-- The menu supersedes the keybind HUD. If the stable suite is already live,
-- retire the HUD first so the screen does not carry both.
if _G.__ftfHudStop then
    pcall(_G.__ftfHudStop)
end

local MODULES = {
    "lua/modules/esp.lua",
    "lua/modules/speed.lua",
    "lua/modules/antifreeze.lua",
    "lua/modules/rescue.lua",
    "lua/modules/doors.lua",
    "lua/modules/noclip.lua",
    "lua/modules/objectives.lua",
    "lua/modules/beast_recon.lua",
    "lua/modules/beastwatch.lua",
    "lua/modules/skillcheck_probe.lua",
    "lua/modules/skillcheck.lua",
    "lua/menu.lua",
}

local function fetchHttp(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and type(body) == "string" and #body > 0 then
        return body
    end

    local ok2, body2 = pcall(function() return syn.request({ Url = url, Method = "GET" }).Body end)
    if ok2 and type(body2) == "string" and #body2 > 0 then
        return body2
    end

    return nil, tostring(body)
end

local loaded, failed = 0, 0

for _, name in ipairs(MODULES) do
    local src, fetchErr = fetchHttp(BASE .. name)

    if not src then
        failed = failed + 1
        warn(string.format("[FTF-LOADER] %s: fetch failed (%s) - is the server on 8765 running?", name, fetchErr))
    else
        local fn, compileErr = loadstring(src, "=" .. name)
        if not fn then
            failed = failed + 1
            warn(string.format("[FTF-LOADER] %s: compile failed (%s)", name, tostring(compileErr)))
        else
            local ok, runErr = pcall(fn)
            if ok then
                loaded = loaded + 1
            else
                failed = failed + 1
                warn(string.format("[FTF-LOADER] %s: runtime error (%s)", name, tostring(runErr)))
            end
        end
    end
end

print(string.format("[FTF-LOADER] %d loaded, %d failed", loaded, failed))
