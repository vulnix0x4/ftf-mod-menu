--!nocheck
--[[
    Flee the Facility - auto skillcheck

    The timing minigame is:

        PlayerGui.ScreenGui.TimingCircle
            TimingBase   (ImageLabel, the circle)
            TimingPin    (ImageLabel, the rotating pin)
            ActionKeyIcon

    Two independent modes, both configurable:

    1. SetResult (default true)
       While TimingCircle is visible, force TempPlayerStatsModule.MinigameResult
       to true. If the client result is what the hack consumes, this passes the
       check without touching timing. Repeated every poll in case the game
       resets it.

    2. ActionPulse (default false)
       On the rising edge of TimingCircle.Visible, fire Input/Action true then
       false N frames later. This is the same remote the hack uses; test it if
       SetResult alone is not accepted.

    It also logs TimingPin/TimingBase rotation and position changes while the
    circle is up, so we can build a real timing hit if the result flag is not
    trusted by the server.

    Config:
        Enabled      true
        SetResult    true
        ActionPulse  false
        PulseTicks   3
        LogPin       true

    API: _G.__ftfAutoSkill.Config / .Checks() / .Stop()
    Unload: _G.__ftfAutoSkillStop()
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Enabled     = true,
    SetResult   = true,        -- write MinigameResult only on the timing hit
    ForceWhileAction = false,  -- constant forcing did not move the hack
    TimingHit   = true,        -- fire when TimingPin crosses TimingBase.Rotation
    HitTolerance = 2,          -- degrees either side of the crossing
    HitOffset   = 0,           -- tune if the success arc is offset from TimingBase.Rotation
    HitPressTicks = 2,
    HitDelayTicks = 2,         -- press this many frames after the crossing (2 frames ≈ 8° later)
    HitMethod   = "all",       -- "all" = remote + keypress + click
    HitKey      = Enum.KeyCode.E,
    ActionPulse = false,
    AutoPress   = false,       -- pulse Input/Action repeatedly while the circle is up
    PressEvery  = 8,
    PulseTicks  = 3,
    PollFrames  = 1,
    LogPin      = true,
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfAutoSkillInstance = INSTANCE_ID

local unloaded    = false
local visible     = false
local checks      = 0
local forced      = 0
local pulseTicks  = 0
local tick        = 0
local lastRot     = nil
local lastPos     = nil
local lastDelta   = nil
local lastHit     = -math.huge
local pendingHitTicks = 0
local conns       = {}

-- ------------------------------------------------------------------ helpers

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

local function timingCircle()
    local sg = screenGui()
    return sg and sg:FindFirstChild("TimingCircle")
end

-- A child can be Visible=true while a parent Frame or the ScreenGui is hidden.
local function effectivelyVisible(obj)
    local pg = playerGui()
    local node = obj
    while node and node ~= pg do
        if node:IsA("ScreenGui") and node.Enabled == false then return false end
        if node:IsA("GuiObject") and node.Visible == false then return false end
        node = node.Parent
    end
    return true
end

local function actionActive()
    local s = LocalPlayer:FindFirstChild("TempPlayerStatsModule")
    local v = s and s:FindFirstChild("ActionInput")
    return v ~= nil and v.Value == true
end

local function stats()
    return LocalPlayer:FindFirstChild("TempPlayerStatsModule")
end

local function remote()
    local RS = game:GetService("ReplicatedStorage")
    local r = RS:FindFirstChild("RemoteEvent")
    if r and r:IsA("RemoteEvent") then return r end
    return nil
end

local function fireAction(state)
    local r = remote()
    if r then r:FireServer("Input", "Action", state and true or false) end
end

local vim
pcall(function() vim = game:GetService("VirtualInputManager") end)

-- The hack skillcheck is handled locally by the client; the RemoteEvent only
-- mirrors the hold. So on a hit we synthesize the real input as well:
-- executor keypress (if exposed), VirtualInputManager key event, and a click.
local function synthPress()
    local did = false

    if type(keypress) == "function" then
        pcall(keypress, CONFIG.HitKey)
        did = true
    end

    if vim then
        pcall(function() vim:SendKeyEvent(true, CONFIG.HitKey, false, game) end)
        did = true
    end

    if type(mouse1click) == "function" then
        pcall(mouse1click)
        did = true
    end

    if vim then
        local circle = timingCircle()
        if circle then
            local pos, size = circle.AbsolutePosition, circle.AbsoluteSize
            local x, y = pos.X + size.X * 0.5, pos.Y + size.Y * 0.5
            pcall(function() vim:SendMouseButtonEvent(x, y, 0, true, game, 0) end)
            pcall(function() vim:SendMouseButtonEvent(x, y, 0, false, game, 0) end)
            did = true
        end
    end

    return did
end

local function synthRelease()
    if type(keyrelease) == "function" then
        pcall(keyrelease, CONFIG.HitKey)
    end
    if vim then
        pcall(function() vim:SendKeyEvent(false, CONFIG.HitKey, false, game) end)
    end
end

local function setResult()
    local s = stats()
    local v = s and s:FindFirstChild("MinigameResult")
    if v and v:IsA("BoolValue") then
        if v.Value ~= true then
            v.Value = true
            forced = forced + 1
        end
        return true
    end
    return false
end

local function samplePin(circle)    if not CONFIG.LogPin then return end
    local pin = circle:FindFirstChild("TimingPin")
    local base = circle:FindFirstChild("TimingBase")
    if not pin then return end

    local ok, rot, x, y = pcall(function()
        local p = pin.AbsolutePosition
        return pin.Rotation, p.X, p.Y
    end)
    if not ok then return end

    local changed = lastRot == nil
        or math.abs(rot - lastRot) >= 4
        or math.abs(x - (lastPos and lastPos.X or x)) >= 0.5
        or math.abs(y - (lastPos and lastPos.Y or y)) >= 0.5

    if changed then
        lastRot = rot
        lastPos = Vector2.new(x, y)
        local brot = 0
        if base then pcall(function() brot = base.Rotation end) end
        print(string.format("[FTF-AUTOSKILL] pin rot=%.1f pos=%.0f,%.0f baseRot=%.1f",
            rot, x, y, brot))
    end
end

local function rotationOf(obj)
    if not obj then return nil end
    local ok, v = pcall(function() return obj.Rotation end)
    if ok and type(v) == "number" then return v end
    return nil
end

-- -------------------------------------------------------------------- loop

local unload   -- forward declaration: step's stale-instance guard calls it

local function step()
    if unloaded then return end

    if _G.__ftfAutoSkillInstance ~= INSTANCE_ID then
        unload()
        return
    end

    tick = tick + 1
    if tick % CONFIG.PollFrames ~= 0 then return end

    if not CONFIG.Enabled then return end

    local circle = timingCircle()
    local up = circle ~= nil and effectivelyVisible(circle)

    if up and not visible then
        visible = true
        checks = checks + 1
        lastRot, lastPos = nil, nil
        lastDelta = nil
        pendingHitTicks = 0
        print("[FTF-AUTOSKILL] timing circle up")

        if CONFIG.ActionPulse then
            fireAction(true)
            pulseTicks = CONFIG.PulseTicks
        end
    elseif not up and visible then
        visible = false
        lastDelta = nil
        pendingHitTicks = 0
        print("[FTF-AUTOSKILL] timing circle down")
    end

    if up then
        samplePin(circle)

        if CONFIG.TimingHit then
            local pr = rotationOf(circle:FindFirstChild("TimingPin"))
            local br = rotationOf(circle:FindFirstChild("TimingBase"))

            if pr and br then
                local delta = ((pr - br - CONFIG.HitOffset + 180) % 360) - 180
                local jumped = lastDelta ~= nil and math.abs(delta - lastDelta) >= 90
                local crossed = (lastDelta ~= nil) and not jumped
                    and ((lastDelta < 0 and delta >= 0) or (lastDelta > 0 and delta <= 0))
                local near = math.abs(delta) <= CONFIG.HitTolerance

                if (crossed or near) and pulseTicks == 0 and pendingHitTicks == 0
                    and (os.clock() - lastHit) > 0.12 then
                    if CONFIG.HitDelayTicks > 0 then
                        pendingHitTicks = CONFIG.HitDelayTicks
                        print(string.format(
                            "[FTF-AUTOSKILL] timing armed pin=%.1f base=%.1f delta=%.1f delay=%d",
                            pr, br, delta, CONFIG.HitDelayTicks))
                    else
                        lastHit = os.clock()
                        fireAction(true)
                        local did = synthPress()
                        pulseTicks = CONFIG.HitPressTicks
                        if CONFIG.SetResult then setResult() end
                        print(string.format(
                            "[FTF-AUTOSKILL] TIMING HIT pin=%.1f base=%.1f delta=%.1f input=%s",
                            pr, br, delta, tostring(did)))
                    end
                end

                lastDelta = delta
            end
        end

        if CONFIG.AutoPress and pulseTicks == 0 and (tick % CONFIG.PressEvery == 0) then
            fireAction(true)
            pulseTicks = 1
        end
    end

    if pendingHitTicks > 0 then
        pendingHitTicks = pendingHitTicks - 1
        if pendingHitTicks == 0 then
            lastHit = os.clock()
            fireAction(true)
            local did = synthPress()
            pulseTicks = CONFIG.HitPressTicks
            if CONFIG.SetResult then setResult() end

            local c2 = timingCircle()
            local pr2 = c2 and rotationOf(c2:FindFirstChild("TimingPin")) or 0
            local br2 = c2 and rotationOf(c2:FindFirstChild("TimingBase")) or 0
            local d2 = ((pr2 - br2 - CONFIG.HitOffset + 180) % 360) - 180
            print(string.format(
                "[FTF-AUTOSKILL] TIMING HIT pin=%.1f base=%.1f delta=%.1f input=%s delay=%d",
                pr2, br2, d2, tostring(did), CONFIG.HitDelayTicks))
        end
    end

    if pulseTicks > 0 then
        pulseTicks = pulseTicks - 1
        if pulseTicks == 0 then
            fireAction(false)
            synthRelease()
        end
    end
end

-- --------------------------------------------------------------- lifecycle

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    if _G.__ftfAutoSkillInstance == INSTANCE_ID then
        _G.__ftfAutoSkillInstance = nil
    end
    if _G.__ftfAutoSkillStop == unload then
        _G.__ftfAutoSkillStop = nil
        _G.__ftfAutoSkill = nil
    end
    print("[FTF-AUTOSKILL] unloaded")
end

_G.__ftfAutoSkillStop = unload

_G.__ftfAutoSkill = {
    Config  = CONFIG,
    Checks  = function() return checks end,
    Forced  = function() return forced end,
    Status  = function()
        return {
            visible = visible,
            checks = checks,
            forced = forced,
            circle = timingCircle() ~= nil,
        }
    end,
    Stop    = function() unload() end,
}

conns[#conns + 1] = RunService.RenderStepped:Connect(step)

print(string.format("[FTF-AUTOSKILL] loaded - setResult=%s pulse=%s",
    tostring(CONFIG.SetResult), tostring(CONFIG.ActionPulse)))
