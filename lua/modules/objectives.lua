--!nocheck
--[[
    Flee the Facility - objectives

    Nearest unsolved computer teleport.

    Computer tables are map models named "ComputerTable" with a "Screen" part
    (solved = green-dominant) and one or more "ComputerTrigger*" parts. This
    module keeps a cached list (rescan every 3 s on RenderStepped, never in the
    click/key path), picks the nearest unsolved one, and puts you on the open
    side of its trigger.

    Controls:
        H                          teleport to nearest unsolved computer
        menu SYSTEM -> button      same thing

    API:
        _G.__ftfObjectives.Computers()      -- cached {model, trigger, screen, solved}
        _G.__ftfObjectives.Nearest()
        _G.__ftfObjectives.TeleportNearest()
        _G.__ftfObjectives.Teleports()
        _G.__ftfObjectives.Stop()

    Unload: _G.__ftfObjectivesStop()
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local RS               = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Key            = Enum.KeyCode.H,
    Cooldown       = 0.5,
    RescanSeconds  = 3,
    TeleportDistance = 4,
    MaxDistance    = 2000,   -- ignore template/prefab tables parked far off-map
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfObjectivesInstance = INSTANCE_ID

local unloaded  = false
local computers = {}
local lastMap   = nil
local lastScan  = 0
local lastKey   = -math.huge
local teleports = 0
local conns     = {}

-- ------------------------------------------------------------------- scan

local function triggerFor(model)
    local fallback
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            if d.Name:find("ComputerTrigger") then
                return d
            end
            if not fallback and d.Name:find("Trigger") then
                fallback = d
            end
        end
    end
    return fallback
end

local function isSolved(model)
    local screen = model:FindFirstChild("Screen")
    if not screen or not screen:IsA("BasePart") then return false end
    local c = screen.Color
    return c.G > c.R and c.G > c.B
end

local function refresh(force)
    local mapValue = RS:FindFirstChild("CurrentMap")
    local map = mapValue and mapValue.Value
    local now = os.clock()

    if not force and map == lastMap and (now - lastScan) < CONFIG.RescanSeconds then return end
    lastMap, lastScan = map, now

    computers = {}
    if not map then return end

    for _, inst in ipairs(map:GetDescendants()) do
        if inst.Name == "ComputerTable" and inst:IsA("Model") then
            local trigger = triggerFor(inst)

            -- Reject triggers parked far from their own model: those are
            -- prefab/template parts, the source of the 259k-stud teleports.
            local plausible = true
            if trigger then
                local okBox, cf, size = pcall(function()
                    local a, b = inst:GetBoundingBox()
                    return a, b
                end)
                if okBox and cf then
                    local rel = cf:PointToObjectSpace(trigger.Position)
                    local h = size * 0.5
                    if math.abs(rel.X) > h.X + 50
                        or math.abs(rel.Y) > h.Y + 50
                        or math.abs(rel.Z) > h.Z + 50 then
                        plausible = false
                    end
                end
            end

            if trigger and plausible then
                computers[#computers + 1] = {
                    model   = inst,
                    trigger = trigger,
                    solved  = isSolved(inst),
                    dist    = math.huge,
                }
            end
        end
    end
end

-- ------------------------------------------------------------------ target

local function character()
    local ch = LocalPlayer.Character
    return ch, ch and ch:FindFirstChild("HumanoidRootPart")
end

local function nearest()
    local _, root = character()
    local pos = root and root.Position
    local best, bestDist = nil, nil

    for _, c in ipairs(computers) do
        if not c.solved and c.trigger.Parent then
            local dist = pos and (c.trigger.Position - pos).Magnitude or 0
            c.dist = dist
            if dist <= CONFIG.MaxDistance and (not bestDist or dist < bestDist) then
                best, bestDist = c, dist
            end
        end
    end

    if best then best.dist = bestDist end
    return best
end

local function safeSpot(trigger, model)
    local myChar = LocalPlayer.Character
    local origin = trigger.Position + Vector3.new(0, 1.5, 0)

    local bestDir, bestDist = Vector3.new(0, 0, 1), -1

    for _, dir in ipairs({
        Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0),
        Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
    }) do
        local cleared = -1
        pcall(function()
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { myChar, model }
            local hit = Workspace:Raycast(origin, dir * 10, params)
            cleared = hit and (hit.Position - origin).Magnitude or 10
        end)
        if cleared > bestDist then
            bestDist, bestDir = cleared, dir
        end
    end

    local travel = math.clamp(bestDist - 2, 1.5, CONFIG.TeleportDistance)
    return origin + bestDir * travel
end

local function teleportNearest()
    local _, root = character()
    if not root then return nil, "no character" end

    refresh()
    local target = nearest()
    if not target then
        return nil, string.format("no unsolved computer within %d studs", CONFIG.MaxDistance)
    end

    local spot = safeSpot(target.trigger, target.model)
    local look = Vector3.new(target.trigger.Position.X, spot.Y, target.trigger.Position.Z)
    root.CFrame = CFrame.new(spot, look)

    teleports = teleports + 1
    print(string.format("[FTF-OBJ] teleported to computer (%.0f studs, %d total)",
        target.dist or 0, teleports))
    return target
end

-- -------------------------------------------------------------------- loop

local function forceScan()
    -- keep the cache warm from RenderStepped only
    refresh()
end

local function isTyping()
    local ok, box = pcall(function() return UserInputService:GetFocusedTextBox() end)
    return ok and box ~= nil
end

local unload   -- forward declaration

local function step()
    if unloaded then return end

    if _G.__ftfObjectivesInstance ~= INSTANCE_ID then
        unload()
        return
    end

    forceScan()
end

-- --------------------------------------------------------------- lifecycle

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    table.clear(computers)
    if _G.__ftfObjectivesInstance == INSTANCE_ID then
        _G.__ftfObjectivesInstance = nil
    end
    if _G.__ftfObjectivesStop == unload then
        _G.__ftfObjectivesStop = nil
        _G.__ftfObjectives = nil
    end
    print("[FTF-OBJ] unloaded")
end

_G.__ftfObjectivesStop = unload

_G.__ftfObjectives = {
    Config          = CONFIG,
    Computers       = function() return computers end,
    Nearest         = nearest,
    TeleportNearest = teleportNearest,
    Teleports       = function() return teleports end,
    Stop            = function() unload() end,
}

conns[#conns + 1] = RunService.RenderStepped:Connect(step)

conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if unloaded then return end
    if input.KeyCode ~= CONFIG.Key then return end
    if gameProcessed and isTyping() then return end

    local now = os.clock()
    if (now - lastKey) < CONFIG.Cooldown then return end
    lastKey = now

    local target, err = teleportNearest()
    if not target then
        print("[FTF-OBJ] H: " .. tostring(err or "no unsolved computer"))
    end
end)

refresh(true)
print(string.format("[FTF-OBJ] loaded - %d computer(s), %s teleports to nearest unsolved",
    #computers, tostring(CONFIG.Key)))
