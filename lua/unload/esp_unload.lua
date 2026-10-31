--!nocheck
-- Stops the ESP started by esp.lua: removes its GUI and lets the running
-- instance tear itself down (it watches _G.__ftfESPInstance).
do
    local function clear(container)
        if not container then return end
        local g = container:FindFirstChild("FTF_ESP")
        if g then g:Destroy() end
    end

    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok then clear(core) end
    clear(game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui"))
end

if _G.__ftfESPStop then
    pcall(_G.__ftfESPStop)
end

_G.__ftfESPInstance = nil
_G.__ftfESPStop = nil
_G.__ftfESP = nil

print("[FTF-ESP] unload requested")
