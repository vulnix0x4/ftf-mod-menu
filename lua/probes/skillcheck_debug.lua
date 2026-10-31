--!nocheck
--[[
    Flee the Facility - skillcheck debug (45s)

        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/probes/skillcheck_debug.lua"))()

    Hack one computer while this runs, then paste the [FTF-SKDEBUG] lines.

    Logs, ~4x per second while anything is happening:
        ScreenGui.Enabled, TimingCircle/Base/Pin visibility
        pin Rotation, AbsolutePosition, Size, AnchorPoint, ImageRectOffset/Size
        base Rotation/Position
        MinigameResult, ActionInput, ActionProgress, OnTrigger, Captured
        progress resets (failed checks)

    This tells us whether the pin rotates, whether the circle is detected, and
    whether MinigameResult is being reset by the game.
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Duration     = 90,
    LogEvery     = 15,     -- frames
    IdleEvery    = 120,    -- frames when nothing is happening
}

local started = os.clock()
local tick    = 0
local lastProgress = nil
local lastActive   = false
local lines = 0

local function playerGui()
    return LocalPlayer:FindFirstChild("PlayerGui")
end

local function screenGui()
    local pg = playerGui()
    if not pg then return nil end
    local sg = pg:FindFirstChild("ScreenGui")
    if sg then return sg end
    for _, c in ipairs(pg:GetChildren()) do
        if c:IsA("ScreenGui") and c:FindFirstChild("TimingCircle") then return c end
    end
    return nil
end

local function stats()
    return LocalPlayer:FindFirstChild("TempPlayerStatsModule")
end

local function val(name)
    local s = stats()
    local v = s and s:FindFirstChild(name)
    return v and tostring(v.Value) or "?"
end

local function prop(obj, name, default)
    if not obj then return default end
    local ok, v = pcall(function() return obj[name] end)
    if ok and v ~= nil then return v end
    return default
end

local function vec(v)
    if v == nil then return "?" end
    local ok, s = pcall(function() return string.format("%.0f,%.0f", v.X, v.Y) end)
    return ok and s or "?"
end

local function sample()
    local pg = playerGui()
    local sg = screenGui()
    local circle = sg and sg:FindFirstChild("TimingCircle")
    local base = circle and circle:FindFirstChild("TimingBase")
    local pin = circle and circle:FindFirstChild("TimingPin")

    local progress = tonumber(val("ActionProgress")) or 0
    if lastProgress and progress + 0.01 < lastProgress then
        print(string.format("[FTF-SKDEBUG] RESET progress %.3f -> %.3f", lastProgress, progress))
    end
    lastProgress = progress

    local active = (circle ~= nil and circle.Visible == true)
        or val("ActionInput") == "true"
        or val("OnTrigger") == "true"
        or progress > 0.001

    if not active and (tick % CONFIG.IdleEvery ~= 0) then return end
    if active and (tick % CONFIG.LogEvery ~= 0) and not lastActive then
        -- fall through: log the first active frame immediately
    elseif active and (tick % CONFIG.LogEvery ~= 0) then
        return
    end

    lines = lines + 1
    if lines > 400 then return end

    print(string.format(
        "[FTF-SKDEBUG] sgEn=%s cirVis=%s baseVis=%s pinVis=%s pinRot=%s pinPos=%s pinSz=%s pinRect=%s baseRot=%s result=%s action=%s prog=%.3f trig=%s cap=%s",
        tostring(prop(sg, "Enabled", "?")),
        tostring(prop(circle, "Visible", "?")),
        tostring(prop(base, "Visible", "?")),
        tostring(prop(pin, "Visible", "?")),
        tostring(prop(pin, "Rotation", 0)),
        vec(prop(pin, "AbsolutePosition", nil)),
        vec(prop(pin, "AbsoluteSize", nil)),
        vec(prop(pin, "ImageRectOffset", nil)),
        tostring(prop(base, "Rotation", 0)),
        val("MinigameResult"), val("ActionInput"), progress,
        val("OnTrigger"), val("Captured")))

    lastActive = active
end

local function step()
    tick = tick + 1
    if (os.clock() - started) > CONFIG.Duration then
        print("[FTF-SKDEBUG] window ended - paste the lines above")
        if _G.__ftfSkillDebugStop then _G.__ftfSkillDebugStop() end
        return
    end
    sample()
end

local conn = RunService.RenderStepped:Connect(step)

local function stop()
    pcall(function() conn:Disconnect() end)
    _G.__ftfSkillDebugStop = nil
    print("[FTF-SKDEBUG] stopped")
end

_G.__ftfSkillDebugStop = stop

local pg = playerGui()
local sg = screenGui()
local circle = sg and sg:FindFirstChild("TimingCircle")
print(string.format("[FTF-SKDEBUG] PlayerGui=%s ScreenGui=%s TimingCircle=%s",
    tostring(pg ~= nil), tostring(sg ~= nil), tostring(circle ~= nil)))
print("[FTF-SKDEBUG] running 90s - press H, then hold E at a computer while this runs")
