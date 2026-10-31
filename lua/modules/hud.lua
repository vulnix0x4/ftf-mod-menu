--!nocheck
--[[
    Flee the Facility - keybind HUD

    A small panel in the bottom-right corner listing the live keybinds and
    their current state:

        Q   2x speed      ON / off
        T   break free    ready
        ...

    Other scripts can add their own row at any time:

        _G.__ftfHud.Register("computer", "F", "instant hack", function()
            return "ready", false
        end)

    Register(id, key, label, statusFn); statusFn returns (text, isActive).

    Unload: run hud_unload.lua, or call _G.__ftfHudStop().
]]

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Width        = 176,
    RowHeight    = 18,
    Pad          = 9,
    TitleSize    = 10,
    TextSize     = 11,
    Accent       = Color3.fromRGB(255, 214, 84),
    TextColor    = Color3.fromRGB(225, 225, 232),
    DimColor     = Color3.fromRGB(140, 140, 152),
    ActiveColor  = Color3.fromRGB(120, 255, 145),
    Background   = Color3.fromRGB(16, 16, 20),
    Border       = Color3.fromRGB(70, 70, 85),
    UpdateFrames = 6,          -- refresh labels roughly 10x per second
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfHudInstance = INSTANCE_ID

local unloaded   = false
local order      = {}
local rows       = {}
local rowFrames  = {}
local gui, panel, titleLabel
local tick       = 0

-- ------------------------------------------------------------------- build

local function makeGui()
    local ok, core = pcall(function() return game:GetService("CoreGui") end)

    local g = Instance.new("ScreenGui")
    g.Name           = "FTF_HUD"
    g.ResetOnSpawn   = false
    g.IgnoreGuiInset = true
    g.DisplayOrder   = 129
    g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    g.Parent = (ok and core) or LocalPlayer:WaitForChild("PlayerGui")

    local f = Instance.new("Frame")
    f.Name                 = "Panel"
    f.AnchorPoint          = Vector2.new(1, 1)
    f.Position             = UDim2.new(1, -12, 1, -12)
    f.BackgroundColor3     = CONFIG.Background
    f.BackgroundTransparency = 0.2
    f.BorderSizePixel      = 0
    f.Size                 = UDim2.new(0, CONFIG.Width, 0, 40)
    f.Parent               = g

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = f

    local stroke = Instance.new("UIStroke")
    stroke.Color         = CONFIG.Border
    stroke.Thickness     = 1
    stroke.Transparency  = 0.45
    stroke.Parent        = f

    local t = Instance.new("TextLabel")
    t.Name                   = "Title"
    t.BackgroundTransparency = 1
    t.Position               = UDim2.new(0, CONFIG.Pad, 0, 5)
    t.Size                   = UDim2.new(1, -CONFIG.Pad * 2, 0, 12)
    t.Font                   = Enum.Font.GothamBold
    t.TextSize               = CONFIG.TitleSize
    t.TextXAlignment         = Enum.TextXAlignment.Left
    t.TextColor3             = CONFIG.DimColor
    t.Text                   = "FTF"
    t.Parent                 = f

    return g, f, t
end

local function ensureGui()
    if not gui or not gui.Parent then
        gui, panel, titleLabel = makeGui()
    end
end

local function rebuild()
    if unloaded then return end
    ensureGui()

    -- clear by name as well as by reference, so a failed heal can never leave
    -- orphaned rows stacked on top of each other
    for _, fr in pairs(rowFrames) do
        if fr and fr.Parent then fr:Destroy() end
    end
    for _, child in ipairs(panel:GetChildren()) do
        if string.sub(child.Name, 1, 4) == "row_" then child:Destroy() end
    end
    rowFrames = {}

    local y = 20
    for _, id in ipairs(order) do
        local row = rows[id]
        if row then
            local fr = Instance.new("Frame")
            fr.Name                 = "row_" .. id
            fr.BackgroundTransparency = 1
            fr.Position             = UDim2.new(0, CONFIG.Pad, 0, y)
            fr.Size                 = UDim2.new(1, -CONFIG.Pad * 2, 0, CONFIG.RowHeight - 4)
            fr.Parent               = panel

            local key = Instance.new("TextLabel")
            key.Name                   = "Key"
            key.BackgroundTransparency = 1
            key.Position               = UDim2.new(0, 0, 0, 0)
            key.Size                   = UDim2.new(0, 20, 1, 0)
            key.Font                   = Enum.Font.GothamBold
            key.TextSize               = CONFIG.TextSize
            key.TextXAlignment         = Enum.TextXAlignment.Left
            key.TextColor3             = CONFIG.Accent
            key.Text                   = row.key
            key.Parent                 = fr

            local desc = Instance.new("TextLabel")
            desc.Name                   = "Label"
            desc.BackgroundTransparency = 1
            desc.Position               = UDim2.new(0, 26, 0, 0)
            desc.Size                   = UDim2.new(1, -26 - 52, 1, 0)
            desc.Font                   = Enum.Font.GothamMedium
            desc.TextSize               = CONFIG.TextSize
            desc.TextXAlignment         = Enum.TextXAlignment.Left
            desc.TextColor3             = CONFIG.TextColor
            desc.TextTruncate           = Enum.TextTruncate.AtEnd
            desc.Text                   = row.label
            desc.Parent                 = fr

            local status = Instance.new("TextLabel")
            status.Name                   = "Status"
            status.BackgroundTransparency = 1
            status.AnchorPoint            = Vector2.new(1, 0)
            status.Position               = UDim2.new(1, 0, 0, 0)
            status.Size                   = UDim2.new(0, 50, 1, 0)
            status.Font                   = Enum.Font.GothamBold
            status.TextSize               = CONFIG.TextSize
            status.TextXAlignment         = Enum.TextXAlignment.Right
            status.TextColor3             = CONFIG.DimColor
            status.Text                   = ""
            status.Parent                 = fr

            rowFrames[id] = { frame = fr, status = status }
            y = y + CONFIG.RowHeight
        end
    end

    panel.Size = UDim2.new(0, CONFIG.Width, 0, y + 4)
end

-- ------------------------------------------------------------------ content

local function refresh()
    ensureGui()

    for _, id in ipairs(order) do
        local row = rows[id]
        local widgets = rowFrames[id]
        if row and widgets and widgets.status then
            local ok, text, active = pcall(row.status)
            if ok then
                widgets.status.Text = tostring(text or "")
                widgets.status.TextColor3 = active and CONFIG.ActiveColor or CONFIG.DimColor
            else
                widgets.status.Text = "?"
                widgets.status.TextColor3 = CONFIG.DimColor
            end
        end
    end
end

local function register(id, key, label, statusFn)
    if unloaded then return end
    if not rows[id] then
        table.insert(order, id)
    end
    rows[id] = { key = key, label = label, status = statusFn or function() return "", false end }
    rebuild()
    refresh()
end

-- ------------------------------------------------------------------ defaults

register("speed", "Q", "2x speed", function()
    local s = _G.__ftfSpeed
    if not s then return "offline", false end
    return s.IsBoosted() and "ON" or "off", s.IsBoosted()
end)

register("freeze", "T", "break free", function()
    local a = _G.__ftfAntiFreeze
    if not a then return "offline", false end
    return "ready", false
end)

-- -------------------------------------------------------------------- loop

local unload   -- forward declaration: each instance owns its own teardown

local function step()
    if unloaded then return end

    if _G.__ftfHudInstance ~= INSTANCE_ID then
        unload()
        return
    end

    if not gui or not gui.Parent then
        gui, panel, titleLabel = nil, nil, nil
        rebuild()
        refresh()
        return
    end

    tick = tick + 1
    if tick >= CONFIG.UpdateFrames then
        tick = 0
        refresh()
    end
end

local connections = { RunService.RenderStepped:Connect(step) }

-- ---------------------------------------------------------------- teardown

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
    if gui then pcall(function() gui:Destroy() end) end
    if _G.__ftfHudInstance == INSTANCE_ID then
        _G.__ftfHudInstance = nil
    end
    if _G.__ftfHudStop == unload then
        _G.__ftfHudStop = nil
        _G.__ftfHud = nil
    end
    print("[FTF-HUD] unloaded")
end

_G.__ftfHudStop = unload

_G.__ftfHud = {
    Config   = CONFIG,
    Register = register,
    Refresh  = refresh,
    Rows     = function() return order end,
    Stop     = function() unload() end,
}

rebuild()
refresh()
print("[FTF-HUD] loaded")
