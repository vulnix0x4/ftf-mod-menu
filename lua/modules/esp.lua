--!nocheck
--[[
    Flee the Facility - player + computer ESP
    Place 893973440 / Game 372226183

    Players
        The beast's character is the only one carrying the "Hammer" (Model) and
        "BeastPowers" (Model) children; survivors only have the cosmetic
        "PackedHammer" accessory. Beast = red, survivors = green.

    Computers
        Map objects named "ComputerTable". A computer is solved when its
        "Screen" part turns green (G is the dominant channel); solved ones are
        hidden, so only the objectives still worth doing stay on screen.
        Computers = blue.

    Rendering
        No Drawing library in this executor, so boxes are Frames with a UIStroke
        outline inside a ScreenGui. Player boxes are built in HumanoidRootPart
        space (so they hug the body instead of widening when a player turns);
        computer boxes are a cached world-space AABB, since those never move.

    Beast  = red      Normal = green      Computer = blue

    Unload: run esp_unload.lua, call _G.__ftfESPStop(), or set
    _G.__ftfESPInstance = nil.
]]

-- kill any previous instance of this script's output
do
    local function clearAll(container)
        if not container then return end
        local old = container:FindFirstChild("FTF_ESP")
        if old then old:Destroy() end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok then clearAll(core) end
    clearAll(game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui"))
end

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    -- master switch, driven by menu.lua (_G.__ftfESP.Enabled)
    Enabled           = true,
    -- players
    BeastColor        = Color3.fromRGB(255, 45, 45),   -- beast
    SurvivorColor     = Color3.fromRGB(60, 255, 110),  -- normal players
    Thickness         = 1.6,
    NameSize          = 13,
    ShowName          = true,
    ShowDistance      = true,
    TagBeast          = true,
    IncludeSelf       = false,
    HideDead          = true,
    PlayerMaxDistance = 2000,
    Padding           = 1,       -- px of breathing room around the body
    BeastMarkers      = { "BeastPowers", "Hammer" },

    -- computers
    ShowComputers     = true,
    HideSolved        = true,    -- solved computers are green; hide them
    ComputerColor     = Color3.fromRGB(70, 150, 255),
    ComputerThickness = 1.6,
    ComputerTag       = "COMPUTER",
    ComputerName      = "ComputerTable",
    ComputerMaxDistance = 2000,

    Parent            = "CoreGui",   -- "CoreGui" (survives the game wiping PlayerGui) or "PlayerGui"
}

-- Every run gets an id. A newer run claims _G.__ftfESPInstance, which makes any
-- older instance disconnect itself instead of tearing down the new GUI.
local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfESPInstance = INSTANCE_ID

-- Older builds of this tool call _G.__ftfESPUnload() from their own render loop
-- whenever their GUI is gone, which would keep killing the newest run. Clearing
-- it disarms those strays; this build publishes _G.__ftfESPStop instead.
_G.__ftfESPUnload = nil

-- ---------------------------------------------------------------- ui setup

local function makeGui()
    local g = Instance.new("ScreenGui")
    g.Name          = "FTF_ESP"
    g.ResetOnSpawn  = false
    g.IgnoreGuiInset = true
    g.DisplayOrder  = 127
    g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local parent
    if CONFIG.Parent == "CoreGui" then
        local ok, core = pcall(function() return game:GetService("CoreGui") end)
        if ok and core then parent = core end
    end
    g.Parent = parent or LocalPlayer:WaitForChild("PlayerGui")
    return g
end

local gui = makeGui()

local boxes        = {}   -- [Player] = { box, stroke, label }
local computerBoxes = {}  -- [Model]  = { box, stroke, label, bounds... }
local computerModels = {}
local lastMap, lastScan = nil, 0
local connections  = {}
local unloaded     = false
local lastBeast    = nil

local function createBox(name, text, color, thickness)
    local box = Instance.new("Frame")
    box.Name                 = name
    box.BackgroundTransparency = 1
    box.BorderSizePixel      = 0
    box.Visible              = false

    local stroke = Instance.new("UIStroke")
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.LineJoinMode    = Enum.LineJoinMode.Miter
    stroke.Thickness       = thickness or CONFIG.Thickness
    stroke.Color           = color
    stroke.Transparency    = 0
    stroke.Parent          = box

    local label = Instance.new("TextLabel")
    label.Name                 = "Label"
    label.BackgroundTransparency = 1
    label.AnchorPoint          = Vector2.new(0.5, 1)
    label.Position             = UDim2.new(0.5, 0, 0, -2)
    label.Size                 = UDim2.new(1, 90, 0, 15)
    label.Font                 = Enum.Font.GothamMedium
    label.TextSize             = CONFIG.NameSize
    label.TextXAlignment       = Enum.TextXAlignment.Center
    label.TextColor3           = color
    label.TextStrokeColor3     = Color3.new(0, 0, 0)
    label.TextStrokeTransparency = 0.35
    label.Text                 = text or ""
    label.Parent               = box

    box.Parent = gui
    return { box = box, stroke = stroke, label = label }
end

local function entry(player)
    local b = boxes[player]
    if not b or not b.box.Parent then
        b = createBox("esp_" .. player.Name, player.Name, CONFIG.SurvivorColor, CONFIG.Thickness)
        boxes[player] = b
    end
    return b
end

-- ------------------------------------------------------------ detection

local function isBeast(character)
    for _, marker in ipairs(CONFIG.BeastMarkers) do
        if character:FindFirstChild(marker) then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------ projection

-- Project 8 world-space box corners into a screen rect. nil if off camera.
local function rectFromPoints(points)
    local cam = Workspace.CurrentCamera
    if not cam then return nil end

    local sMinX, sMinY = math.huge, math.huge
    local sMaxX, sMaxY = -math.huge, -math.huge
    local visible = 0

    for i = 1, 8 do
        local sp = cam:WorldToViewportPoint(points[i])
        if sp.Z > 0.05 then
            visible += 1
            if sp.X < sMinX then sMinX = sp.X end
            if sp.Y < sMinY then sMinY = sp.Y end
            if sp.X > sMaxX then sMaxX = sp.X end
            if sp.Y > sMaxY then sMaxY = sp.Y end
        end
    end

    if visible < 4 then return nil end     -- mostly behind the camera

    local vp = cam.ViewportSize
    sMinX = math.clamp(sMinX, 0, vp.X)
    sMaxX = math.clamp(sMaxX, 0, vp.X)
    sMinY = math.clamp(sMinY, 0, vp.Y)
    sMaxY = math.clamp(sMaxY, 0, vp.Y)

    local w = sMaxX - sMinX
    local h = sMaxY - sMinY
    if w < 1 or h < 1 then return nil end  -- degenerate

    return sMinX, sMinY, w, h
end

local function corners(minX, minY, minZ, maxX, maxY, maxZ, transform)
    local out = {}
    for i = 0, 7 do
        local p = Vector3.new(
            ((i % 2) == 0) and minX or maxX,
            ((math.floor(i / 2) % 2) == 0) and minY or maxY,
            ((math.floor(i / 4) % 2) == 0) and minZ or maxZ)
        out[i + 1] = transform and (transform * p) or p
    end
    return out
end

-- Player box, built in HumanoidRootPart space so turning never widens it.
local function playerRect(character)
    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local rootCF = root.CFrame

    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    local found = false

    for _, part in ipairs(character:GetChildren()) do
        if part:IsA("BasePart") then
            found = true
            local cf = part.CFrame
            local h  = part.Size * 0.5
            for i = 0, 7 do
                local c = rootCF:PointToObjectSpace(cf * Vector3.new(
                    ((i % 2) == 0) and -h.X or h.X,
                    ((math.floor(i / 2) % 2) == 0) and -h.Y or h.Y,
                    ((math.floor(i / 4) % 2) == 0) and -h.Z or h.Z))
                if c.X < minX then minX = c.X end
                if c.Y < minY then minY = c.Y end
                if c.Z < minZ then minZ = c.Z end
                if c.X > maxX then maxX = c.X end
                if c.Y > maxY then maxY = c.Y end
                if c.Z > maxZ then maxZ = c.Z end
            end
        end
    end
    if not found then return nil end

    return rectFromPoints(corners(minX, minY, minZ, maxX, maxY, maxZ, rootCF))
end

-- ------------------------------------------------------------ computers

-- Parts that should not count toward the computer's visual box.
local COMPUTER_SKIP = {
    ClearWall = true,
    ComputerTrigger1 = true,
    ComputerTrigger2 = true,
    ComputerTrigger3 = true,
}

local function computerBounds(model)
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    local found = false

    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") and not COMPUTER_SKIP[part.Name] then
            found = true
            local cf = part.CFrame
            local h  = part.Size * 0.5
            for i = 0, 7 do
                local c = cf * Vector3.new(
                    ((i % 2) == 0) and -h.X or h.X,
                    ((math.floor(i / 2) % 2) == 0) and -h.Y or h.Y,
                    ((math.floor(i / 4) % 2) == 0) and -h.Z or h.Z)
                if c.X < minX then minX = c.X end
                if c.Y < minY then minY = c.Y end
                if c.Z < minZ then minZ = c.Z end
                if c.X > maxX then maxX = c.X end
                if c.Y > maxY then maxY = c.Y end
                if c.Z > maxZ then maxZ = c.Z end
            end
        end
    end

    if not found then return nil end
    return minX, minY, minZ, maxX, maxY, maxZ
end

-- Solved computers have a green screen (G dominant). Unsolved are blue.
local function isSolved(model)
    local screen = model:FindFirstChild("Screen")
    if not screen or not screen:IsA("BasePart") then return false end
    local c = screen.Color
    return c.G > c.R and c.G > c.B
end

local function computerEntry(model)
    local b = computerBoxes[model]
    if b and b.box.Parent then return b end

    local minX, minY, minZ, maxX, maxY, maxZ = computerBounds(model)
    if not minX then return nil end

    b = createBox("esp_computer", CONFIG.ComputerTag, CONFIG.ComputerColor, CONFIG.ComputerThickness)
    b.minX, b.minY, b.minZ = minX, minY, minZ
    b.maxX, b.maxY, b.maxZ = maxX, maxY, maxZ
    b.center = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
    computerBoxes[model] = b
    return b
end

local function scanComputers()
    local mapValue = ReplicatedStorage:FindFirstChild("CurrentMap")
    local map = mapValue and mapValue.Value
    local now = os.clock()

    -- re-scan on map change, and every 2s in case a round re-clones them
    if map == lastMap and (now - lastScan) < 2 then return end
    lastMap, lastScan = map, now

    local list = {}
    if map then
        for _, inst in ipairs(map:GetDescendants()) do
            if inst.Name == CONFIG.ComputerName and inst:IsA("Model") then
                table.insert(list, inst)
            end
        end
    end
    computerModels = list
end

local function hideAllComputers()
    for _, b in pairs(computerBoxes) do
        b.box.Visible = false
    end
end

local function updateComputers(myPos)
    if not CONFIG.ShowComputers then
        hideAllComputers()
        return
    end

    local active = ReplicatedStorage:FindFirstChild("IsGameActive")
    if not (active and active.Value) then
        hideAllComputers()
        return
    end

    scanComputers()

    for _, model in ipairs(computerModels) do
        local b = computerBoxes[model]

        if not model.Parent then
            if b then
                b.box:Destroy()
                computerBoxes[model] = nil
            end
        elseif CONFIG.HideSolved and isSolved(model) then
            if b then b.box.Visible = false end
        else
            b = computerEntry(model)
            if b then
                local dist = myPos and (b.center - myPos).Magnitude or 0
                local rx, ry, rw, rh = nil, nil, nil, nil
                if dist <= CONFIG.ComputerMaxDistance then
                    rx, ry, rw, rh = rectFromPoints(corners(b.minX, b.minY, b.minZ, b.maxX, b.maxY, b.maxZ))
                end

                if rx then
                    b.box.Position = UDim2.fromOffset(math.floor(rx) - CONFIG.Padding, math.floor(ry) - CONFIG.Padding)
                    b.box.Size     = UDim2.fromOffset(math.floor(rw) + CONFIG.Padding * 2, math.floor(rh) + CONFIG.Padding * 2)
                    b.box.Visible  = true

                    local text = CONFIG.ComputerTag
                    if CONFIG.ShowDistance then
                        text = string.format("%s  [%dm]", text, math.floor(dist + 0.5))
                    end
                    b.label.Text = text
                else
                    b.box.Visible = false
                end
            end
        end
    end

    -- drop entries for computers that vanished
    for model, b in pairs(computerBoxes) do
        if not model.Parent then
            b.box:Destroy()
            computerBoxes[model] = nil
        end
    end
end

-- -------------------------------------------------------------- players

local function updatePlayer(player, myPos)
    local character = player.Character
    local humanoid  = character and character:FindFirstChildOfClass("Humanoid")
    local root      = character and character:FindFirstChild("HumanoidRootPart")

    local b = boxes[player]

    if not (character and character.Parent and humanoid and root) then
        if b then b.box.Visible = false end
        return
    end

    if CONFIG.HideDead and humanoid.Health <= 0 then
        if b then b.box.Visible = false end
        return
    end

    local dist = myPos and (root.Position - myPos).Magnitude or 0
    if dist > CONFIG.PlayerMaxDistance then
        if b then b.box.Visible = false end
        return
    end

    local x, y, w, h = playerRect(character)
    if not x then
        if b then b.box.Visible = false end
        return
    end

    b = entry(player)

    local beast = isBeast(character)
    local color = beast and CONFIG.BeastColor or CONFIG.SurvivorColor

    b.stroke.Color      = color
    b.label.TextColor3  = color
    b.box.Position      = UDim2.fromOffset(math.floor(x) - CONFIG.Padding, math.floor(y) - CONFIG.Padding)
    b.box.Size          = UDim2.fromOffset(math.floor(w) + CONFIG.Padding * 2, math.floor(h) + CONFIG.Padding * 2)
    b.box.Visible       = true

    if CONFIG.ShowName then
        local text = player.Name
        if beast and CONFIG.TagBeast then text = "BEAST - " .. text end
        if CONFIG.ShowDistance then
            text = string.format("%s  [%dm]", text, math.floor(dist + 0.5))
        end
        b.label.Text = text
    else
        b.label.Text = ""
    end
end

-- --------------------------------------------------------------- loop

local unload

local function step()
    if unloaded then return end

    if _G.__ftfESPInstance ~= INSTANCE_ID then
        unload()
        return
    end

    if not gui or not gui.Parent then
        gui = makeGui()
    end

    if not CONFIG.Enabled then
        for _, b in pairs(boxes) do
            if b.box.Visible then b.box.Visible = false end
        end
        hideAllComputers()
        return
    end

    local myChar = LocalPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    local myPos  = myRoot and myRoot.Position

    local beastName = nil

    for _, player in ipairs(Players:GetPlayers()) do
        if player == LocalPlayer and not CONFIG.IncludeSelf then
            local b = boxes[player]
            if b then b.box.Visible = false end
        else
            updatePlayer(player, myPos)
            local ch = player.Character
            if ch and isBeast(ch) then beastName = player.Name end
        end
    end

    updateComputers(myPos)

    if beastName ~= lastBeast then
        lastBeast = beastName
        print("[FTF-ESP] beast = " .. tostring(beastName))
    end
end

function unload()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(connections)
    table.clear(boxes)
    for _, b in pairs(computerBoxes) do
        pcall(function() b.box:Destroy() end)
    end
    table.clear(computerBoxes)
    if gui then gui:Destroy() end
    if _G.__ftfESPInstance == INSTANCE_ID then
        _G.__ftfESPInstance = nil
    end
    if _G.__ftfESPStop == unload then
        _G.__ftfESPStop = nil
        _G.__ftfESP = nil
    end
    print("[FTF-ESP] unloaded")
end

_G.__ftfESPStop = unload

table.insert(connections, RunService.RenderStepped:Connect(step))

table.insert(connections, Players.PlayerRemoving:Connect(function(player)
    local b = boxes[player]
    if b then
        b.box:Destroy()
        boxes[player] = nil
    end
end))

_G.__ftfESP = CONFIG
print("[FTF-ESP] loaded")
