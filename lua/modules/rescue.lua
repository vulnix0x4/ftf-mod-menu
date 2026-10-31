--!nocheck
--[[
    Flee the Facility - frozen teammate rescue

    A captured survivor is fully identifiable from the pod itself:

        FreezePod.CapturedTorso  (ObjectValue) -> that player's torso
        FreezePod.Event          (BindableEvent) -> the rescue trigger

    So this module can:
        - list every occupied pod and who is inside
        - teleport you to the open side of a pod (button / API)
        - fire the pod's own rescue trigger, optionally with an Action hold
        - do that automatically whenever a frozen teammate is within Radius

    It is the same Input/Trigger path the game uses for doors and computers,
    with the pod's Event as the argument. No part edits, no hooks.

    Keybind: Y frees the nearest occupied pod. The handler uses the cached pod
    list, so a keypress never triggers a map scan.

    Config:
        AutoRescue    false   free occupied pods within Radius
        Radius        14
        Cooldown      2.5     seconds between attempts on the same pod
        HoldTicks     45      ~0.75s Action hold after the trigger
        UseActionHold true    also pulse Input/Action (rescue may be a hold)
        TeleportDistance 4    studs out from the pod centre
        RescanSeconds 2

    API:
        _G.__ftfRescue.Targets()        -- { {player, pod, cf, size, lastTry}, ... }
        _G.__ftfRescue.Nearest()
        _G.__ftfRescue.TeleportNearest()
        _G.__ftfRescue.TeleportTo(name)
        _G.__ftfRescue.FreeNearest()
        _G.__ftfRescue.Free(target)
    Unload: _G.__ftfRescueStop()
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local RS               = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    AutoRescue       = false,
    Radius           = 14,
    Cooldown         = 2.5,
    HoldTicks        = 45,
    UseActionHold    = true,
    ReleaseTicks     = 6,
    TeleportDistance = 4,
    RescanSeconds    = 2,
    FreeKey          = Enum.KeyCode.Y,
    KeyCooldown      = 0.5,

    -- cross-map camp guard: if the beast sits on an occupied pod for CampDelay
    -- seconds, free that teammate automatically (rescue is not range-checked)
    CampGuard        = false,
    CampRadius       = 20,
    CampDelay        = 3,
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfRescueInstance = INSTANCE_ID

local unloaded  = false
local targets   = {}
local lastMap   = nil
local lastScan  = 0
local pending   = {}      -- { kind = "trigger"|"action", ev = ?, ticks = n }
local attempts  = {}      -- [pod] = last attempt, survives rescans
local rescues   = 0
local lastKey   = -math.huge
local campTimers = {}     -- [pod] = seconds the beast has been camping it
local lastStep   = os.clock()
local conns     = {}

-- ---------------------------------------------------------------- pod scan

local function podBox(pod)
    local ok, cf, size = pcall(function()
        local a, b = pod:GetBoundingBox()
        return a, b
    end)
    if ok and cf then return cf, size end

    -- fallback: average of the pod's parts
    local sum, n = Vector3.new(0, 0, 0), 0
    local minY, maxY = math.huge, -math.huge
    for _, d in ipairs(pod:GetDescendants()) do
        if d:IsA("BasePart") then
            sum = sum + d.Position
            n = n + 1
            minY = math.min(minY, d.Position.Y)
            maxY = math.max(maxY, d.Position.Y)
        end
    end
    if n == 0 then return nil, nil end

    local center = sum / n
    local height = math.max(maxY - minY, 2)
    return CFrame.new(center), Vector3.new(6, height, 6)
end

local function collectPods(map)
    local pods, seen = {}, {}

    local function add(inst)
        if inst and not seen[inst] then
            seen[inst] = true
            pods[#pods + 1] = inst
        end
    end

    if map then
        for _, c in ipairs(map:GetChildren()) do
            if c.Name:lower():find("freezepod") then add(c) end
        end
        -- CapturedTorso is the authoritative marker; it may be nested inside
        -- the pod's trigger part instead of sitting on the model directly.
        for _, d in ipairs(map:GetDescendants()) do
            if d:IsA("ObjectValue") and d.Name == "CapturedTorso" then
                add(d.Parent)
            end
        end
    end

    for _, c in ipairs(Workspace:GetChildren()) do
        if c.Name:lower():find("freezepod") then add(c) end
    end

    return pods
end

local function playerFor(captured)
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            if captured == p.Character or captured:IsDescendantOf(p.Character) then
                return p
            end
        end
    end

    -- fallback: walk ancestry and match a player name (captured ragdolls can
    -- live under a clone that is no longer Player.Character)
    local node = captured
    for _ = 1, 5 do
        node = node.Parent
        if not node then break end
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Name == node.Name then
                return p
            end
        end
    end

    return nil
end

local function refresh(force)
    local mapValue = RS:FindFirstChild("CurrentMap")
    local map = mapValue and mapValue.Value
    local now = os.clock()

    if not force and map == lastMap and (now - lastScan) < CONFIG.RescanSeconds then return end
    local mapChanged = map ~= lastMap
    lastMap, lastScan = map, now
    if mapChanged then attempts = {} end

    targets = {}

    for _, pod in ipairs(collectPods(map)) do
        local torso = pod:FindFirstChild("CapturedTorso", true)
        local captured = torso and torso:IsA("ObjectValue") and torso.Value

        if captured then
            local player = playerFor(captured)

            local ev = pod:FindFirstChild("Event", true)
            if ev and not ev:IsA("BindableEvent") then ev = nil end

            if player and ev then
                local cf, size = podBox(pod)
                targets[#targets + 1] = {
                    pod     = pod,
                    ev      = ev,
                    player  = player,
                    cf      = cf,
                    size    = size,
                    lastTry = attempts[pod] or 0,
                }
            end
        end
    end
end

-- ----------------------------------------------------------------- helper

local function character()
    local ch = LocalPlayer.Character
    return ch, ch and ch:FindFirstChildOfClass("Humanoid"), ch and ch:FindFirstChild("HumanoidRootPart")
end

local function myPosition()
    local _, _, root = character()
    return root and root.Position
end

local function nearest()
    local pos = myPosition()
    local best, bestDist = nil, nil

    for _, t in ipairs(targets) do
        if t.pod.Parent and t.cf then
            local dist = pos and (t.cf.Position - pos).Magnitude or 0
            if not bestDist or dist < bestDist then
                best, bestDist = t, dist
            end
        end
    end

    if best then best.dist = bestDist end
    return best
end

-- A point just outside the pod, in the direction the player is approaching
-- from (fallback: +X), raised enough to clear the floor.
local function spotFor(target)
    if not target or not target.cf then return nil end

    local center = target.cf.Position
    local pos = myPosition()

    local dir
    if pos then
        dir = center - pos
        dir = Vector3.new(dir.X, 0, dir.Z)
        if dir.Magnitude < 1 then dir = Vector3.new(1, 0, 0) end
    else
        dir = Vector3.new(1, 0, 0)
    end
    dir = dir.Unit

    local travel = CONFIG.TeleportDistance

    local ok, hit = pcall(function()
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { LocalPlayer.Character, target.pod }
        return Workspace:Raycast(center + Vector3.new(0, 1.5, 0), dir * 8, params)
    end)

    if ok and hit then
        local clearance = (hit.Position - center).Magnitude - 1.5
        travel = math.clamp(clearance, 1.5, CONFIG.TeleportDistance)
    end

    return center + dir * travel + Vector3.new(0, 1.5, 0), center
end

-- ------------------------------------------------------------------ firing

local function remote()
    local r = RS:FindFirstChild("RemoteEvent")
    if r and r:IsA("RemoteEvent") then return r end
    return nil
end

local function fireTrigger(ev, state)
    local r = remote()
    if not r then return false end
    r:FireServer("Input", "Trigger", state and true or false, ev)
    return true
end

local function fireAction(state)
    local r = remote()
    if not r then return false end
    r:FireServer("Input", "Action", state and true or false)
    return true
end

local function flush()
    for i = #pending, 1, -1 do
        local item = pending[i]
        item.ticks = item.ticks - 1
        if item.ticks <= 0 then
            if item.kind == "trigger" then
                fireTrigger(item.ev, false)
            else
                fireAction(false)
            end
            table.remove(pending, i)
        end
    end
end

local function free(target)
    if not target or not target.pod or not target.pod.Parent then return false, "pod gone" end

    local ev = target.ev or target.pod:FindFirstChild("Event", true)
    if not ev then return false, "pod has no Event" end
    if not remote() then return false, "no RemoteEvent" end

    fireTrigger(ev, true)
    pending[#pending + 1] = { kind = "trigger", ev = ev, ticks = CONFIG.ReleaseTicks }

    if CONFIG.UseActionHold then
        fireAction(true)
        pending[#pending + 1] = { kind = "action", ticks = CONFIG.HoldTicks }
    end

    target.lastTry = os.clock()
    attempts[target.pod] = target.lastTry
    rescues = rescues + 1

    print(string.format("[FTF-RESCUE] freeing %s via %s (try %d)",
        target.player.Name, target.pod.Name, rescues))
    return true
end

-- -------------------------------------------------------------------- api

local function teleportTo(target)
    if not target then return nil, "no frozen teammate" end

    local ch, _, root = character()
    if not root then return nil, "no character" end

    local spot, look = spotFor(target)
    if not spot then return nil, "no pod position" end

    local face = Vector3.new(look.X, spot.Y, look.Z)
    root.CFrame = CFrame.new(spot, face)

    print(string.format("[FTF-RESCUE] teleported to %s (%.0f studs away)",
        target.player.Name, target.dist or 0))
    return target
end

local function teleportNearest()
    refresh(true)
    return teleportTo(nearest())
end

local function teleportNamed(name)
    refresh(true)
    for _, t in ipairs(targets) do
        if t.player.Name == name then return teleportTo(t) end
    end
    return teleportTo(nearest())
end

local function freeNearest()
    refresh(true)
    local target = nearest()
    if not target then return nil, "no frozen teammate" end
    local ok, err = free(target)
    if not ok then return nil, err end
    return target
end

-- -------------------------------------------------------------------- loop

local function localCaptured()
    local s = LocalPlayer:FindFirstChild("TempPlayerStatsModule")
    local v = s and s:FindFirstChild("Captured")
    return v and v.Value == true
end

local function beastPosition()
    for _, p in ipairs(Players:GetPlayers()) do
        local ch = p.Character
        if ch and (ch:FindFirstChild("BeastPowers") or ch:FindFirstChild("Hammer")) then
            local root = ch:FindFirstChild("HumanoidRootPart")
            if root then return root.Position end
        end
    end
    return nil
end

local unload   -- forward declaration

local function step()
    if unloaded then return end

    if _G.__ftfRescueInstance ~= INSTANCE_ID then
        unload()
        return
    end

    local now = os.clock()
    local dt = math.min(now - lastStep, 0.25)
    lastStep = now

    flush()

    -- keep the cached target list warm so the Y keybind never triggers a
    -- map scan inside an input handler (see LEARNINGS 7.1)
    refresh()

    -- camp guard runs even while AutoRescue is off: it watches the beast, not you
    if CONFIG.CampGuard then
        local bpos = beastPosition()
        if bpos then
            for _, t in ipairs(targets) do
                if t.cf then
                    local d = (t.cf.Position - bpos).Magnitude
                    if d <= CONFIG.CampRadius then
                        campTimers[t.pod] = (campTimers[t.pod] or 0) + dt
                        if campTimers[t.pod] >= CONFIG.CampDelay
                            and (now - t.lastTry) >= CONFIG.Cooldown then
                            campTimers[t.pod] = 0
                            print(string.format("[FTF-RESCUE] camp guard: beast %.0f studs from %s",
                                d, t.player.Name))
                            free(t)
                        end
                    else
                        campTimers[t.pod] = nil
                    end
                end
            end
        else
            table.clear(campTimers)
        end
    end

    if not CONFIG.AutoRescue then return end
    if localCaptured() then return end
    if #targets == 0 then return end

    local pos = myPosition()
    if not pos then return end

    for _, t in ipairs(targets) do
        if t.pod.Parent and t.cf then
            local dist = (t.cf.Position - pos).Magnitude
            t.dist = dist
            if dist <= CONFIG.Radius and (now - t.lastTry) >= CONFIG.Cooldown then
                free(t)
            end
        end
    end
end

-- --------------------------------------------------------------- lifecycle

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    table.clear(pending)
    table.clear(targets)
    if _G.__ftfRescueInstance == INSTANCE_ID then
        _G.__ftfRescueInstance = nil
    end
    if _G.__ftfRescueStop == unload then
        _G.__ftfRescueStop = nil
        _G.__ftfRescue = nil
    end
    print("[FTF-RESCUE] unloaded")
end

_G.__ftfRescueStop = unload

_G.__ftfRescue = {
    Config          = CONFIG,
    Targets         = function() return targets end,
    Nearest         = nearest,
    TeleportNearest = teleportNearest,
    TeleportTo      = teleportNamed,
    FreeNearest     = freeNearest,
    Free            = free,
    Rescues         = function() return rescues end,
    Debug           = function()
        local mapValue = RS:FindFirstChild("CurrentMap")
        local map = mapValue and mapValue.Value
        local pods = collectPods(map)
        refresh(true)

        print(string.format("[FTF-RESCUE] debug: map=%s pods=%d targets=%d",
            tostring(map and map:GetFullName() or "nil"), #pods, #targets))

        for _, pod in ipairs(pods) do
            local ok, line = pcall(function()
                local torso = pod:FindFirstChild("CapturedTorso", true)
                local val = torso and torso:IsA("ObjectValue") and torso.Value
                local ev = pod:FindFirstChild("Event", true)
                return string.format("  POD %-42s torso=%-16s value=%-45s event=%s",
                    pod:GetFullName(),
                    torso and torso.Name or "none",
                    val and val:GetFullName() or "nil",
                    ev and ev:GetFullName() or "none")
            end)
            print("[FTF-RESCUE] " .. tostring(line))
        end

        for _, p in ipairs(Players:GetPlayers()) do
            print(string.format("[FTF-RESCUE]   PLAYER %-20s char=%s",
                p.Name, p.Character and p.Character:GetFullName() or "nil"))
        end

        for _, t in ipairs(targets) do
            print(string.format("[FTF-RESCUE]   TARGET %s -> %s",
                t.player.Name, t.pod:GetFullName()))
        end
    end,
    Stop            = function() unload() end,
}

-- ----------------------------------------------------------------- keybind

local function isTyping()
    local ok, box = pcall(function() return UserInputService:GetFocusedTextBox() end)
    return ok and box ~= nil
end

conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if unloaded then return end
    if input.KeyCode ~= CONFIG.FreeKey then return end
    if gameProcessed and isTyping() then return end

    local now = os.clock()
    if (now - lastKey) < CONFIG.KeyCooldown then return end
    lastKey = now

    local target = nearest()
    if not target then
        print("[FTF-RESCUE] Y: no frozen teammate in scan")
        return
    end

    local ok, err = free(target)
    if not ok then
        print("[FTF-RESCUE] Y: " .. tostring(err))
    end
end)

conns[#conns + 1] = RunService.RenderStepped:Connect(step)

refresh(true)
print(string.format("[FTF-RESCUE] loaded - %d frozen teammate(s), auto=%s, %s frees nearest",
    #targets, tostring(CONFIG.AutoRescue), tostring(CONFIG.FreeKey)))
