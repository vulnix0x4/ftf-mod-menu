--!nocheck
--[[
    Flee the Facility - menu unload

    Stops the live menu instance and removes its GUI. The tool modules
    (esp / speed / antifreeze / recon) keep running; use the menu's own
    "Unload tools" row, or _G.__ftf<Name>Stop(), for those.

    Safe to run whether or not the menu is loaded.
]]

local removed = 0

local function destroyGui(container)
    if not container then return end
    local old = container:FindFirstChild("FTF_MENU")
    if old then
        old:Destroy()
        removed = removed + 1
    end
end

if _G.__ftfMenuStop then
    pcall(_G.__ftfMenuStop)
end
_G.__ftfMenuStop = nil
_G.__ftfMenu = nil
_G.__ftfMenuInstance = nil

local ok, core = pcall(function() return game:GetService("CoreGui") end)
if ok then destroyGui(core) end

local player = game:GetService("Players").LocalPlayer
if player then destroyGui(player:FindFirstChild("PlayerGui")) end

print(string.format("[FTF-MENU] unloaded (%d gui removed)", removed))
