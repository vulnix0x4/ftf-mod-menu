--!nocheck
--[[
    Flee the Facility - 2x speed boost

    Press Q to toggle between normal speed and double speed.

    Mode = "toggle"  -> tap Q to turn it on, tap again to turn it off
    Mode = "hold"    -> speed only while Q is held down

    The base speed comes from the game's own
    Player.TempPlayerStatsModule.NormalWalkSpeed (16 for a survivor), not from
    whatever Humanoid.WalkSpeed happens to be at the time. That matters because
    the game lowers WalkSpeed to 8 while you are frozen in a pod, and doubling
    that would only get you back to normal speed.

    Unload: run speed_unload.lua, or call _G.__ftfSpeedStop().
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer      = Players.LocalPlayer

local CONFIG = {
    Key            = Enum.KeyCode.Q,
    Multiplier     = 2,
    Mode           = "toggle",   -- "toggle" or "hold"

    ShowIndicator  = true,
    IndicatorText  = "2X SPEED",
    IndicatorColor = Color3.fromRGB(255, 220, 80),
}

-- Every run owns its own teardown closure, so a stale copy can only ever
-- disconnect itself instead of killing the newest instance.
local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfSpeedInstance = INSTANCE_ID

local boosted      = false
local baseSpeed    = 16
local writing      = false
local humanoid     = nil
local humanoidConn = nil
local connections  = {}
local unloaded     = false
local gui, badge   = nil, nil

-- ---------------------------------------------------------------- indicator

local function makeBadge()
    local ok, core = pcall(function() return game:GetService("CoreGui") end)

    local g = Instance.new("ScreenGui")
    g.Name           = "FTF_Speed"
    g.ResetOnSpawn   = false
    g.IgnoreGuiInset = true
    g.DisplayOrder   = 128
    g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local label = Instance.new("TextLabel")
    label.Name                   = "Badge"
    label.AnchorPoint            = Vector2.new(0.5, 1)
    label.Position               = UDim2.new(0.5, 0, 1, -10)
    label.Size                   = UDim2.new(0, 130, 0, 20)
    label.BackgroundTransparency = 1
    label.Font                   = Enum.Font.GothamBold
    label.TextSize               = 15
    label.Text                   = CONFIG.IndicatorText
    label.TextColor3             = CONFIG.IndicatorColor
    label.TextStrokeColor3       = Color3.new(0, 0, 0)
    label.TextStrokeTransparency = 0.3
    label.Visible                = false
    label.Parent                 = g

    g.Parent = (ok and core) or LocalPlayer:WaitForChild("PlayerGui")
    return g, label
end

local function refreshBadge()
    if not CONFIG.ShowIndicator then
        if badge then badge.Visible = false end
        return
    end
    if not gui or not gui.Parent then
        gui, badge = makeBadge()
    end
    badge.Text    = CONFIG.IndicatorText
    badge.Visible = boosted
end

-- ------------------------------------------------------------------ speed

-- The game's own idea of your normal speed. This is the number that must be
-- doubled, even while WalkSpeed is temporarily lowered by a freeze.
local function gameNormalSpeed()
    local stats = LocalPlayer:FindFirstChild("TempPlayerStatsModule")
    local v = stats and stats:FindFirstChild("NormalWalkSpeed")
    if v and typeof(v.Value) == "number" and v.Value > 0.5 then
        return v.Value
    end
    return nil
end

local function resolveBase(h)
    local normal = gameNormalSpeed()
    if normal then return normal end
    if h and h.WalkSpeed > 0.5 then return h.WalkSpeed end
    return 16
end

local function apply(state)
    if unloaded or not humanoid or not humanoid.Parent then return end
    writing = true
    humanoid.WalkSpeed = state and (baseSpeed * CONFIG.Multiplier) or baseSpeed
    writing = false
end

local function watchHumanoid(h)
    if humanoidConn then pcall(function() humanoidConn:Disconnect() end) end
    humanoidConn = nil
    if not h then return end
    humanoidConn = h:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
        if not writing and not boosted then
            baseSpeed = resolveBase(h)
        end
    end)
end

local function setBoost(state)
    if unloaded then return end
    humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end

    baseSpeed = resolveBase(humanoid)
    boosted   = state and true or false
    apply(boosted)
    refreshBadge()
end

local function bindCharacter()
    local ch = LocalPlayer.Character
    local h  = ch and ch:FindFirstChildOfClass("Humanoid")
    humanoid  = h
    boosted   = false
    baseSpeed = resolveBase(h)
    watchHumanoid(h)
    refreshBadge()
end

-- ---------------------------------------------------------------- keybinds

local unload   -- forward declaration: each instance owns its own teardown

table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed or unloaded then return end
    if input.KeyCode ~= CONFIG.Key then return end

    if CONFIG.Mode == "hold" then
        setBoost(true)
    else
        setBoost(not boosted)
    end
end))

table.insert(connections, UserInputService.InputEnded:Connect(function(input, gameProcessed)
    if unloaded or CONFIG.Mode ~= "hold" then return end
    if input.KeyCode ~= CONFIG.Key then return end
    setBoost(false)
end))

-- --------------------------------------------------------------- lifecycle

table.insert(connections, LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.15)   -- let the game apply its spawn state first
    bindCharacter()
end))

table.insert(connections, LocalPlayer.CharacterRemoving:Connect(function()
    humanoid = nil
    boosted  = false
    refreshBadge()
end))

-- Re-apply if the game resets WalkSpeed mid-boost, and heal the badge GUI.
table.insert(connections, RunService.RenderStepped:Connect(function()
    if unloaded then return end

    if _G.__ftfSpeedInstance ~= INSTANCE_ID then
        unload()
        return
    end

    if boosted and humanoid and humanoid.Parent then
        local target = baseSpeed * CONFIG.Multiplier
        if math.abs(humanoid.WalkSpeed - target) > 0.01 and not writing then
            apply(true)
        end
    end

    if CONFIG.ShowIndicator and (not gui or not gui.Parent) then
        refreshBadge()
    end
end))

-- ---------------------------------------------------------------- teardown

unload = function()
    if unloaded then return end
    unloaded = true
    if boosted and humanoid and humanoid.Parent then
        pcall(function() humanoid.WalkSpeed = baseSpeed end)
    end
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
    if humanoidConn then pcall(function() humanoidConn:Disconnect() end) end
    if gui then pcall(function() gui:Destroy() end) end
    if _G.__ftfSpeedInstance == INSTANCE_ID then _G.__ftfSpeedInstance = nil end
    if _G.__ftfSpeedStop == unload then
        _G.__ftfSpeedStop = nil
        _G.__ftfSpeed = nil
    end
    print("[FTF-SPEED] unloaded")
end

_G.__ftfSpeedStop = unload

_G.__ftfSpeed = {
    Config    = CONFIG,
    IsBoosted = function() return boosted end,
    Base      = function() return baseSpeed end,
    Set       = function(state) setBoost(state) end,
    Toggle    = function() setBoost(not boosted) end,
    Stop      = function() unload() end,
}

bindCharacter()
refreshBadge()
print(string.format("[FTF-SPEED] loaded - press %s for %gx (base %.0f)", tostring(CONFIG.Key), CONFIG.Multiplier, baseSpeed))
