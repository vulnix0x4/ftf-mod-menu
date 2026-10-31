--!nocheck
--[[
    Flee the Facility - auto doors

    The game opens a door when the client sends:

        RemoteEvent:FireServer("Input", "Trigger", true, DoorTrigger.Event)

    and releases it with the same call carrying false. Door triggers are parts
    under the current map with an `Event` BindableEvent child (the same shape
    ComputerTrigger uses, but named DoorTrigger*).

    This script walks up to a door and fires the trigger for you, once per door
    per map by default. It does not teleport, does not edit door parts, and does
    not hook anything - it is the game's own open path, just fired early and
    automatically, so the door is already swinging when you reach it.

    No workspace scan in the frame path: the door list is rebuilt from
    CurrentMap only on map change / every few seconds, and the per-frame loop
    touches the cached parts.

    Config:
        Enabled      true
        Radius       10     studs
        FacingDot    -0.1   camera must roughly face the door (1 = dead centre)
        FireOnce     true   never re-toggle a door that was already opened
        ReopenAfter  0      seconds; >0 allows re-firing a closed door
        ReleaseTicks 6      frames until the matching "false" pulse

    API: _G.__ftfDoors.Config / .Doors() / .Dump() / .Set(bool) / .Stop()
    Unload: _G.__ftfDoorsStop()
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local RS         = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Enabled      = true,
    Radius       = 10,
    FacingDot    = -0.1,
    FireOnce     = true,
    ReopenAfter  = 0,
    ReleaseTicks = 6,
    RescanSeconds = 4,
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfDoorsInstance = INSTANCE_ID

local unloaded   = false
local doors      = {}
local lastMap    = nil
local lastScan   = 0
local releases   = {}    -- { ev = BindableEvent, ticks = n }
local firedCount = 0
local conns      = {}

-- ---------------------------------------------------------------- discovery

local function looksLikeDoor(part)
    local ev = part:FindFirstChild("Event")
    if not (ev and ev:IsA("BindableEvent")) then return nil, nil end

    local name = part.Name:lower()
    if name:find("computer") then return nil, nil end

    local parentName = part.Parent and part.Parent.Name:lower() or ""
    if name:find("door") or parentName:find("door") then
        return ev, "named"
    end
    return ev, "event"   -- possible door, weaker signal
end

local function refreshDoors(force)
    local mapValue = RS:FindFirstChild("CurrentMap")
    local map = mapValue and mapValue.Value
    local now = os.clock()

    if not force and map == lastMap and (now - lastScan) < CONFIG.RescanSeconds then return end
    lastMap, lastScan = map, now

    doors = {}
    if not map then return end

    local named, other = {}, {}

    for _, inst in ipairs(map:GetDescendants()) do
        if inst:IsA("BasePart") then
            local ev, kind = looksLikeDoor(inst)
            if ev then
                local entry = {
                    part  = inst,
                    ev    = ev,
                    kind  = kind,
                    inside = false,
                    fired = false,
                    lastFire = 0,
                }
                if kind == "named" then
                    named[#named + 1] = entry
                else
                    other[#other + 1] = entry
                end
            end
        end
    end

    if #named > 0 then
        doors = named
    else
        -- No name matched "door". Rather than silently doing nothing, fall back
        -- to every non-computer Event trigger under the map: those are the only
        -- other instances that speak the Input/Trigger protocol.
        doors = other
        if #other > 0 then
            print(string.format("[FTF-DOORS] no door-named triggers; using all %d Event parts", #other))
        end
    end
end

-- ------------------------------------------------------------------ firing

local function remote()
    local r = RS:FindFirstChild("RemoteEvent")
    if r and r:IsA("RemoteEvent") then return r end
    return nil
end

local function press(trigger, state)
    local r = remote()
    if not r then return false end
    r:FireServer("Input", "Trigger", state and true or false, trigger.ev)
    return true
end

local function openDoor(door)
    if not press(door.part, true) then return end
    door.fired = true
    door.lastFire = os.clock()
    firedCount = firedCount + 1
    releases[#releases + 1] = { ev = door.part, ticks = CONFIG.ReleaseTicks }
    print(string.format("[FTF-DOORS] opened %s (%.1f studs)",
        door.part:GetFullName(), door.dist or 0))
end

local function flushReleases()
    for i = #releases, 1, -1 do
        local item = releases[i]
        item.ticks = item.ticks - 1
        if item.ticks <= 0 then
            press({ ev = item.ev }, false)
            table.remove(releases, i)
        end
    end
end

-- -------------------------------------------------------------------- loop

local function stats()
    return LocalPlayer:FindFirstChild("TempPlayerStatsModule")
end

local function disabledByState(humanoid)
    if not humanoid or humanoid.Health <= 0 then return true end
    local s = stats()
    local captured = s and s:FindFirstChild("Captured")
    return captured and captured.Value == true
end

local unload   -- forward declaration: step's stale-instance guard calls it

local function step()
    if unloaded then return end

    if _G.__ftfDoorsInstance ~= INSTANCE_ID then
        unload()
        return
    end

    flushReleases()

    if not CONFIG.Enabled then return end

    refreshDoors()
    if #doors == 0 then return end

    local ch = LocalPlayer.Character
    local humanoid = ch and ch:FindFirstChildOfClass("Humanoid")
    local root = ch and ch:FindFirstChild("HumanoidRootPart")
    if not (root and humanoid) then return end
    if disabledByState(humanoid) then return end

    local cam = Workspace.CurrentCamera
    local camPos = cam and cam.CFrame.Position
    local look = cam and cam.CFrame.LookVector
    local pos = root.Position
    local now = os.clock()

    for _, door in ipairs(doors) do
        local part = door.part
        if part.Parent then
            local dist = (part.Position - pos).Magnitude
            door.dist = dist
            local inside = dist <= CONFIG.Radius

            if inside and not door.inside then
                local facing = true
                if camPos and look then
                    local dir = (part.Position - camPos)
                    if dir.Magnitude > 0.01 then
                        facing = (dir.Unit):Dot(look) >= CONFIG.FacingDot
                    end
                end

                local cooled = CONFIG.ReopenAfter <= 0
                    or (now - door.lastFire) >= CONFIG.ReopenAfter
                local allowed = (not CONFIG.FireOnce) or not door.fired

                if facing and cooled and allowed then
                    openDoor(door)
                end
            end

            door.inside = inside
        end
    end
end

-- --------------------------------------------------------------- lifecycle

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    table.clear(releases)
    table.clear(doors)
    if _G.__ftfDoorsInstance == INSTANCE_ID then
        _G.__ftfDoorsInstance = nil
    end
    if _G.__ftfDoorsStop == unload then
        _G.__ftfDoorsStop = nil
        _G.__ftfDoors = nil
    end
    print("[FTF-DOORS] unloaded")
end

_G.__ftfDoorsStop = unload

_G.__ftfDoors = {
    Config = CONFIG,
    Doors  = function() return doors end,
    Fired  = function() return firedCount end,
    Set    = function(state) CONFIG.Enabled = state and true or false end,
    Toggle = function() CONFIG.Enabled = not CONFIG.Enabled end,
    Test   = function()
        refreshDoors(true)
        local ch = LocalPlayer.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")

        local best, bestDist = nil, nil
        for _, d in ipairs(doors) do
            if d.part.Parent then
                local dist = root and (d.part.Position - root.Position).Magnitude or 0
                if not bestDist or dist < bestDist then
                    best, bestDist = d, dist
                end
            end
        end

        if not best then
            print("[FTF-DOORS] test: no triggers found - run doors_probe.lua")
            return false
        end

        press(best.part, true)
        best.fired = true
        releases[#releases + 1] = { ev = best.part, ticks = CONFIG.ReleaseTicks }
        print(string.format("[FTF-DOORS] test fired %s (%.1f studs) - did it move?",
            best.part:GetFullName(), bestDist or 0))
        return true
    end,
    Dump   = function()
        refreshDoors(true)
        local ch = LocalPlayer.Character
        local root = ch and ch:FindFirstChild("HumanoidRootPart")
        local pos = root and root.Position
        print(string.format("[FTF-DOORS] %d triggers, enabled=%s", #doors, tostring(CONFIG.Enabled)))
        for _, d in ipairs(doors) do
            local dist = pos and (d.part.Position - pos).Magnitude or 0
            print(string.format("  %-46s kind=%-5s dist=%.1f fired=%s",
                d.part:GetFullName(), tostring(d.kind), dist, tostring(d.fired)))
        end
    end,
    Stop   = function() unload() end,
}

conns[#conns + 1] = RunService.RenderStepped:Connect(step)

refreshDoors()
print(string.format("[FTF-DOORS] loaded - %d door triggers, auto=%s radius=%d",
    #doors, tostring(CONFIG.Enabled), CONFIG.Radius))
