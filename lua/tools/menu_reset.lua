--!nocheck
--[[
    Flee the Facility - menu reset

    Use when the menu is duplicated, off-screen, or stale:

        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/tools/menu_reset.lua"))()

    It:
        - stops the live menu instance (if any)
        - destroys every FTF_MENU ScreenGui in CoreGui and PlayerGui
        - clears _G.__ftfMenuPos so the next load starts at the default spot
        - leaves every gameplay module running

    Then reload the menu/suite:
        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/loaders/ftf_loader.lua"))()
]]

local removed = 0
local stopped = false

if _G.__ftfMenuStop then
    pcall(_G.__ftfMenuStop)
    stopped = true
end

_G.__ftfMenuStop = nil
_G.__ftfMenu = nil
_G.__ftfMenuInstance = nil
_G.__ftfMenuPos = nil

local function sweep(container)
    if not container then return end
    for _, child in ipairs(container:GetChildren()) do
        if child.Name == "FTF_MENU" then
            child:Destroy()
            removed = removed + 1
        end
    end
end

pcall(function() sweep(game:GetService("CoreGui")) end)
pcall(function() sweep(game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")) end)

print(string.format("[FTF-MENU] reset - stopped=%s gui_removed=%d position=default",
    tostring(stopped), removed))
