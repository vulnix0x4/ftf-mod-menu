--!nocheck
--[[
    Flee the Facility - live suite (stable set, no menu yet)

    One line, paste into Potassium and execute:

        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/loaders/ftf_suite.lua"))()

    Loads, in order:
        esp.lua         Q? no - ESP is always on
        speed.lua       Q   2x speed
        antifreeze.lua  T   break free
        hud.lua         keybind panel (bottom right)

    Re-running is safe: each module owns an instance id, so an older copy
    disconnects itself instead of killing the newer one.
]]

local BASE = "http://127.0.0.1:8765/"

local MODULES = {
    "lua/modules/esp.lua",
    "lua/modules/speed.lua",
    "lua/modules/antifreeze.lua",
    "lua/modules/hud.lua",
}

local loaded, failed = 0, 0

for _, name in ipairs(MODULES) do
    local ok, src = pcall(function() return game:HttpGet(BASE .. name) end)

    if not ok or type(src) ~= "string" or #src == 0 then
        failed = failed + 1
        warn(string.format("[FTF] %s: fetch failed (%s)", name, tostring(src)))
    else
        local fn, err = loadstring(src, "=" .. name)
        if not fn then
            failed = failed + 1
            warn(string.format("[FTF] %s: compile failed (%s)", name, tostring(err)))
        else
            local ran, runErr = pcall(fn)
            if ran then
                loaded = loaded + 1
            else
                failed = failed + 1
                warn(string.format("[FTF] %s: runtime error (%s)", name, tostring(runErr)))
            end
        end
    end
end

print(string.format("[FTF] suite: %d loaded, %d failed  (Q speed / T break free)", loaded, failed))
