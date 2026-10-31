--!nocheck
--[[
    Flee the Facility - HUD unload

    Stops whichever hud.lua instance is currently live and removes its GUI.
    The HUD publishes its own teardown as _G.__ftfHudStop, so this file is only
    needed when you want a single script to paste that does not care which
    instance owns the panel.

    Safe to run whether or not the HUD is loaded.
]]

local removed = 0

local function destroyGui(container)
    if not container then return end
    local old = container:FindFirstChild("FTF_HUD")
    if old then
        old:Destroy()
        removed = removed + 1
    end
end

-- 1. let the owning instance disconnect its render loop first
if _G.__ftfHudStop then
    pcall(_G.__ftfHudStop)
end
_G.__ftfHudStop = nil
_G.__ftfHud = nil
_G.__ftfHudInstance = nil

-- 2. sweep any GUI left behind (stale instance, failed teardown, rejoin)
local ok, core = pcall(function() return game:GetService("CoreGui") end)
if ok then destroyGui(core) end

local player = game:GetService("Players").LocalPlayer
if player then destroyGui(player:FindFirstChild("PlayerGui")) end

print(string.format("[FTF-HUD] unloaded (%d gui removed)", removed))
