--!nocheck
--[[
    Flee the Facility - beast remote recon (passive)

    The two ability remotes live *inside the beast's character*, not in
    ReplicatedStorage:

        Workspace.<BeastPlayer>.Hammer.HammerEvent
        Workspace.<BeastPlayer>.BeastPowers.PowersEvent

    They are destroyed at round end, so this script polls the player list (cheap:
    no workspace walks) and attaches an OnClientEvent listener whenever a beast
    character appears. It never hooks FireServer and never fires anything - it
    only records what the server sends.

    Console:
        [FTF-BEAST] hooked <player>.Hammer.HammerEvent
        [FTF-BEAST] HammerEvent <- 2 args | number:1 | table{...}

    On-screen (optional, off by default):
        _G.__ftfBeastRecon.Show(true)    -- bottom-left log panel
        _G.__ftfBeastRecon.Show(false)

    API:
        _G.__ftfBeastRecon.Beast()       -- current beast player name or nil
        _G.__ftfBeastRecon.Log()         -- array of {t, remote, owner, text}
        _G.__ftfBeastRecon.Remotes()     -- connected remote instances
        _G.__ftfBeastRecon.Stop()

    Unload: _G.__ftfBeastReconStop().
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Markers    = { "Hammer", "BeastPowers" },
    PollFrames = 20,      -- ~0.33s at 60fps
    MaxLog     = 60,
    ShowPanel  = false,
    PanelLines = 6,
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfBeastReconInstance = INSTANCE_ID

local unloaded  = false
local entries   = {}
local watched   = {}       -- [RemoteEvent] = { label, owner }
local conns     = {}
local beastName = nil
local tick      = 0

local panel, panelFrame, panelTitle, lineLabels

-- ------------------------------------------------------------------ format

local function fmtValue(v, depth)
    local t = typeof(v)

    if t == "Instance" then
        local ok, full = pcall(function() return v:GetFullName() end)
        return "Inst:" .. (ok and full or v.Name)

    elseif t == "table" then
        if (depth or 0) >= 2 then return "{...}" end
        local parts = {}
        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 6 then
                parts[#parts + 1] = "..."
                break
            end
            parts[#parts + 1] = tostring(k) .. "=" .. fmtValue(val, (depth or 0) + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"

    elseif t == "string" then
        return string.format("%q", v)
    end

    return t .. ":" .. tostring(v)
end

local function fmtArgs(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        parts[i] = fmtValue((select(i, ...)))
    end
    return n, table.concat(parts, " | ")
end

-- ------------------------------------------------------------------- panel

local function makePanel()
    local ok, core = pcall(function() return game:GetService("CoreGui") end)

    local gui = Instance.new("ScreenGui")
    gui.Name           = "FTF_BEAST"
    gui.ResetOnSpawn   = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder   = 129
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local frame = Instance.new("Frame")
    frame.Name             = "Panel"
    frame.AnchorPoint      = Vector2.new(0, 1)
    frame.Position         = UDim2.new(0, 12, 1, -12)
    frame.Size             = UDim2.new(0, 320, 0, 0)
    frame.AutomaticSize    = Enum.AutomaticSize.Y
    frame.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
    frame.BackgroundTransparency = 0.08
    frame.BorderSizePixel  = 0
    frame.Visible          = CONFIG.ShowPanel
    frame.Parent           = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color         = Color3.fromRGB(70, 70, 85)
    stroke.Transparency  = 0.35
    stroke.Thickness     = 1
    stroke.Parent        = frame

    local pad = Instance.new("UIPadding")
    pad.PaddingTop    = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 6)
    pad.PaddingLeft   = UDim.new(0, 8)
    pad.PaddingRight  = UDim.new(0, 8)
    pad.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.Padding  = UDim.new(0, 2)
    layout.Parent   = frame

    local title = Instance.new("TextLabel")
    title.Name                   = "Title"
    title.BackgroundTransparency = 1
    title.Size                   = UDim2.new(1, 0, 0, 14)
    title.Font                   = Enum.Font.GothamBold
    title.TextSize               = 11
    title.TextXAlignment         = Enum.TextXAlignment.Left
    title.TextColor3             = Color3.fromRGB(255, 214, 84)
    title.Text                   = "BEAST RECON  waiting..."
    title.Parent                 = frame

    local lines = {}
    for i = 1, CONFIG.PanelLines do
        local l = Instance.new("TextLabel")
        l.Name                   = "Line" .. i
        l.BackgroundTransparency = 1
        l.Size                   = UDim2.new(1, 0, 0, 13)
        l.Font                   = Enum.Font.Code
        l.TextSize               = 10
        l.TextXAlignment         = Enum.TextXAlignment.Left
        l.TextTruncate           = Enum.TextTruncate.AtEnd
        l.TextColor3             = Color3.fromRGB(210, 210, 220)
        l.Text                   = ""
        l.Parent                 = frame
        lines[i] = l
    end

    gui.Parent = (ok and core) or LocalPlayer:WaitForChild("PlayerGui")
    return gui, frame, title, lines
end

local function refreshPanel()
    if not panel or not panel.Parent then
        panel, panelFrame, panelTitle, lineLabels = makePanel()
    end
    panelFrame.Visible = CONFIG.ShowPanel

    panelTitle.Text = string.format("BEAST RECON  %s", beastName or "waiting...")

    local first = math.max(1, #entries - CONFIG.PanelLines + 1)
    local row = 1
    for i = first, #entries do
        local e = entries[i]
        if row <= CONFIG.PanelLines then
            lineLabels[row].Text = string.format("%s %s <- %s", e.t, e.remote, e.text)
            lineLabels[row].TextColor3 = e.owner == LocalPlayer.Name
                and Color3.fromRGB(255, 214, 84)
                or Color3.fromRGB(190, 190, 200)
            row = row + 1
        end
    end
    for i = row, CONFIG.PanelLines do
        lineLabels[i].Text = ""
    end
end

-- -------------------------------------------------------------------- log

local function record(remoteName, owner, ...)
    if unloaded then return end

    local n, text = fmtArgs(...)
    local line = string.format("%d args | %s", n, text)

    local entry = {
        t      = string.format("%6.1f", os.clock()),
        remote = remoteName,
        owner  = owner,
        n      = n,
        text   = line,
    }
    entries[#entries + 1] = entry
    if #entries > CONFIG.MaxLog then
        table.remove(entries, 1)
    end

    print(string.format("[FTF-BEAST] %s <- %s", remoteName, line))
    refreshPanel()
end

-- ---------------------------------------------------------------- discovery

local function watchRemote(remote, label, owner)
    if watched[remote] then return end
    watched[remote] = { label = label, owner = owner }

    local ok, conn = pcall(function()
        return remote.OnClientEvent:Connect(function(...)
            record(label, owner, ...)
        end)
    end)

    if ok and conn then
        conns[#conns + 1] = conn
        print(string.format("[FTF-BEAST] hooked %s.%s (owner %s)", owner, remote.Name, owner))
        refreshPanel()
    else
        watched[remote] = nil
    end
end

local function scanBeast()
    local foundName = nil

    for _, player in ipairs(Players:GetPlayers()) do
        local ch = player.Character
        if ch then
            for _, marker in ipairs(CONFIG.Markers) do
                local model = ch:FindFirstChild(marker)
                if model then
                    foundName = foundName or player.Name
                    for _, child in ipairs(model:GetChildren()) do
                        if child:IsA("RemoteEvent") then
                            watchRemote(child, marker .. "." .. child.Name, player.Name)
                        end
                    end
                end
            end
        end
    end

    if foundName ~= beastName then
        beastName = foundName
        print("[FTF-BEAST] beast = " .. tostring(beastName))
        refreshPanel()
    end
end

-- --------------------------------------------------------------- lifecycle

local unload

local function step()
    if unloaded then return end

    if _G.__ftfBeastReconInstance ~= INSTANCE_ID then
        unload()
        return
    end

    tick = tick + 1
    if tick % CONFIG.PollFrames == 0 then
        scanBeast()
    end

    if CONFIG.ShowPanel and (not panel or not panel.Parent) then
        refreshPanel()
    end
end

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    table.clear(watched)
    if panel then pcall(function() panel:Destroy() end) end
    if _G.__ftfBeastReconInstance == INSTANCE_ID then
        _G.__ftfBeastReconInstance = nil
    end
    if _G.__ftfBeastReconStop == unload then
        _G.__ftfBeastReconStop = nil
        _G.__ftfBeastRecon = nil
    end
    print("[FTF-BEAST] unloaded")
end

_G.__ftfBeastReconStop = unload

_G.__ftfBeastRecon = {
    Config  = CONFIG,
    Beast   = function() return beastName end,
    Log     = function() return entries end,
    Remotes = function() return watched end,
    Show    = function(state)
        CONFIG.ShowPanel = state and true or false
        refreshPanel()
    end,
    Stop    = function() unload() end,
}

conns[#conns + 1] = RunService.Heartbeat:Connect(step)

scanBeast()
refreshPanel()
print(string.format("[FTF-BEAST] loaded - watching %s (panel=%s)",
    table.concat(CONFIG.Markers, "/"), tostring(CONFIG.ShowPanel)))
