--!nocheck
--[[
    Flee the Facility - full reset

    Nuclear option when several modules are stale or duplicated:

        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/tools/reset_all.lua"))()

    Stops every module through its published teardown, then removes any GUI
    they left behind. _G handles are cleared. Then reload:

        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/loaders/ftf_loader.lua"))()

    This also restores pod collision, noclip collision and WalkSpeed on the way
    out because each module's teardown does its own cleanup.
]]

local STOPS = {
    "__ftfESPStop",
    "__ftfSpeedStop",
    "__ftfAntiFreezeStop",
    "__ftfUnfreezeStop",
    "__ftfRescueStop",
    "__ftfDoorsStop",
    "__ftfNoclipStop",
    "__ftfObjectivesStop",
    "__ftfBeastReconStop",
    "__ftfBeastwatchStop",
    "__ftfSkillProbeStop",
    "__ftfAutoSkillStop",
    "__ftfHudStop",
    "__ftfMenuStop",
}

local GUI_NAMES = {
    "FTF_MENU",
    "FTF_HUD",
    "FTF_ESP",
    "FTF_BEAST",
    "FTF_BEASTWATCH",
    "FTF_Speed",
}

local stopped = 0
for _, name in ipairs(STOPS) do
    local fn = _G[name]
    if type(fn) == "function" then
        pcall(fn)
        stopped = stopped + 1
    end
    _G[name] = nil
end

local function sweep(container)
    if not container then return end
    for _, child in ipairs(container:GetChildren()) do
        for _, name in ipairs(GUI_NAMES) do
            if child.Name == name then
                child:Destroy()
            end
        end
    end
end

local removedBefore = 0
local function countAndSweep(container)
    if not container then return end
    for _, child in ipairs(container:GetChildren()) do
        for _, name in ipairs(GUI_NAMES) do
            if child.Name == name then
                removedBefore = removedBefore + 1
                child:Destroy()
            end
        end
    end
end

pcall(function() countAndSweep(game:GetService("CoreGui")) end)
pcall(function() countAndSweep(game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")) end)

_G.__ftfMenuPos = nil

print(string.format("[FTF] full reset - %d module(s) stopped, %d leftover gui(s) removed",
    stopped, removedBefore))
