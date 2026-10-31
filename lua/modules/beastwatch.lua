--!nocheck
--[[
    Flee the Facility - beast watch

    The beast is the only character carrying `BeastPowers` / `Hammer` (LEARNINGS
    §2.1). This module tracks it every few frames and shows a compact banner at
    the top of the screen:

        BEAST 24m  ↗
        POWER 68

    - banner appears only when the beast is within AlertRadius
    - arrow is relative to your camera (8 directions)
    - POWER reads BeastPowers.PowerProgressPercent when present
    - hidden when you are the beast yourself

    No remotes, no hooks: purely reading replicated state.

    Config: Enabled, AlertRadius (60), ShowPower (true), UpdateFrames (6)
    API:    _G.__ftfBeastwatch.Config / .Beast() / .Distance() / .Stop()
    Unload: _G.__ftfBeastwatchStop()
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Enabled      = true,
    AlertRadius  = 60,
    ShowPower    = true,
    UpdateFrames = 6,
    Color        = Color3.fromRGB(255, 70, 70),
    CloseColor   = Color3.fromRGB(255, 30, 30),
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfBeastwatchInstance = INSTANCE_ID

local unloaded  = false
local gui, banner, line1, line2, stroke
local tick      = 0
local beastName = nil
local beastDist = nil
local conns     = {}

local ARROWS = { "↑", "↗", "→", "↘", "↓", "↙", "←", "↖" }

-- --------------------------------------------------------------------- gui

local function makeGui()
    local ok, core = pcall(function() return game:GetService("CoreGui") end)

    local g = Instance.new("ScreenGui")
    g.Name           = "FTF_BEASTWATCH"
    g.ResetOnSpawn   = false
    g.IgnoreGuiInset = true
    g.DisplayOrder   = 210
    g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local frame = Instance.new("Frame")
    frame.Name             = "Banner"
    frame.AnchorPoint      = Vector2.new(0.5, 0)
    frame.Position         = UDim2.new(0.5, 0, 0, 8)
    frame.Size             = UDim2.fromOffset(230, 44)
    frame.BackgroundColor3 = Color3.fromRGB(32, 8, 10)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel  = 0
    frame.Visible          = false
    frame.Parent           = g

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = frame

    local s = Instance.new("UIStroke")
    s.Color        = CONFIG.Color
    s.Thickness    = 1.4
    s.Transparency = 0.15
    s.Parent       = frame

    local title = Instance.new("TextLabel")
    title.Name                   = "Line1"
    title.BackgroundTransparency = 1
    title.Position               = UDim2.new(0, 8, 0, 3)
    title.Size                   = UDim2.new(1, -16, 0, 22)
    title.Font                   = Enum.Font.GothamBold
    title.TextSize               = 16
    title.TextXAlignment         = Enum.TextXAlignment.Left
    title.TextColor3             = CONFIG.Color
    title.Text                   = "BEAST"
    title.Parent                 = frame

    local sub = Instance.new("TextLabel")
    sub.Name                   = "Line2"
    sub.BackgroundTransparency = 1
    sub.Position               = UDim2.new(0, 9, 0, 24)
    sub.Size                   = UDim2.new(1, -18, 0, 15)
    sub.Font                   = Enum.Font.GothamMedium
    sub.TextSize               = 10
    sub.TextXAlignment         = Enum.TextXAlignment.Left
    sub.TextColor3             = Color3.fromRGB(200, 200, 210)
    sub.Text                   = ""
    sub.Parent                 = frame

    g.Parent = (ok and core) or LocalPlayer:WaitForChild("PlayerGui")
    return g, frame, title, sub, s
end

-- ------------------------------------------------------------------ beast

local function findBeast()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local ch = player.Character
            if ch and (ch:FindFirstChild("BeastPowers") or ch:FindFirstChild("Hammer")) then
                local root = ch:FindFirstChild("HumanoidRootPart")
                return player, ch, root
            end
        end
    end
    return nil
end

local function powerText(ch)
    if not CONFIG.ShowPower then return "" end
    local bp = ch:FindFirstChild("BeastPowers")
    local pct = bp and bp:FindFirstChild("PowerProgressPercent")
    if pct and typeof(pct.Value) == "number" then
        local v = pct.Value
        if v <= 1 then v = v * 100 end
        return string.format("POWER %d", math.floor(v + 0.5))
    end
    return ""
end

local function arrowFor(cam, targetPos)
    if not cam then return "" end

    local ok, arrow = pcall(function()
        local origin = cam.CFrame.Position
        local to = Vector3.new(targetPos.X - origin.X, 0, targetPos.Z - origin.Z)
        if to.Magnitude < 0.01 then return "" end

        local fwd = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
        local right = Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z)
        local bearing = math.deg(math.atan2(to:Dot(right), to:Dot(fwd)))
        local index = math.floor((bearing + 22.5) / 45) % 8 + 1
        return ARROWS[index]
    end)

    return ok and arrow or ""
end

local function update()
    if not CONFIG.Enabled then
        if banner then banner.Visible = false end
        return
    end

    if not gui or not gui.Parent then
        gui, banner, line1, line2, stroke = makeGui()
    end

    local player, ch, root = findBeast()
    if not player or not root then
        beastName, beastDist = nil, nil
        banner.Visible = false
        return
    end

    local myChar = LocalPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then
        banner.Visible = false
        return
    end

    beastName = player.Name
    beastDist = (root.Position - myRoot.Position).Magnitude

    if beastDist > CONFIG.AlertRadius then
        banner.Visible = false
        return
    end

    local cam = Workspace.CurrentCamera
    line1.Text = string.format("BEAST  %dm  %s", math.floor(beastDist + 0.5), arrowFor(cam, root.Position))
    line2.Text = powerText(ch)

    local close = beastDist <= 15
    stroke.Color = close and CONFIG.CloseColor or CONFIG.Color
    line1.TextColor3 = close and CONFIG.CloseColor or CONFIG.Color

    banner.Visible = true
end

-- ------------------------------------------------------------------- loop

local unload   -- forward declaration: step's stale-instance guard calls it

local function step()
    if unloaded then return end

    if _G.__ftfBeastwatchInstance ~= INSTANCE_ID then
        unload()
        return
    end

    tick = tick + 1
    if tick % CONFIG.UpdateFrames == 0 then
        update()
    end
end

-- --------------------------------------------------------------- lifecycle

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    if gui then pcall(function() gui:Destroy() end) end
    if _G.__ftfBeastwatchInstance == INSTANCE_ID then
        _G.__ftfBeastwatchInstance = nil
    end
    if _G.__ftfBeastwatchStop == unload then
        _G.__ftfBeastwatchStop = nil
        _G.__ftfBeastwatch = nil
    end
    print("[FTF-BEASTWATCH] unloaded")
end

_G.__ftfBeastwatchStop = unload

_G.__ftfBeastwatch = {
    Config   = CONFIG,
    Beast    = function() return beastName end,
    Distance = function() return beastDist end,
    Stop     = function() unload() end,
}

conns[#conns + 1] = RunService.RenderStepped:Connect(step)

gui, banner, line1, line2, stroke = makeGui()
update()
print(string.format("[FTF-BEASTWATCH] loaded - alert within %d studs", CONFIG.AlertRadius))
