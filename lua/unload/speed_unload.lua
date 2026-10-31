--!nocheck
-- Flee the Facility - speed boost teardown
-- Removes the 2x boost, restores normal WalkSpeed, and deletes the badge GUI.

if _G.__ftfSpeedStop then
    _G.__ftfSpeedStop()
else
    -- fallback: no live instance, just make sure nothing is left doubled
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then
        local gui = core:FindFirstChild("FTF_Speed")
        if gui then gui:Destroy() end
    end
    local lp = game.Players.LocalPlayer
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed > 24 then
        hum.WalkSpeed = 16
    end
    _G.__ftfSpeed = nil
    _G.__ftfSpeedInstance = nil
    print("[FTF-SPEED] nothing running, cleaned up")
end
