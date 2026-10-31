--!nocheck
--[[
    Flee the Facility - break free  (press T)

    Capture is enforced only on the client:
        - the server teleports you into a sealed FreezePod model
        - TempPlayerStatsModule.Captured / .Ragdoll are set
        - the Ragdoller LocalScript answers with Humanoid.PlatformStand = true

    There is no weld to the pod, so the only things holding you are the ragdoll
    and the pod's own collision. Inside a pod you are often NOT ragdolled at all,
    so finding the right pod matters more than clearing the ragdoll.

    Press T and this:
        - finds the pod three ways: the pod's CapturedTorso ObjectValue pointing
          at your character, your position inside a pod's bounds, then the
          nearest pod within 15 studs
        - opens that pod (walls and roof stop colliding, locally only; the floor
          is kept so you do not fall through the map)
        - un-ragdolls you and clears Captured / Ragdoll / IsCrawling /
          DisableCrawl / DisableInteraction
        - restores WalkSpeed to the game's NormalWalkSpeed

    Set CONFIG.AutoRelease = true if you would rather it always happen by itself.

    Unload: run antifreeze_unload.lua, or call _G.__ftfAntiFreezeStop().
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer      = Players.LocalPlayer
local RS               = game:GetService("ReplicatedStorage")

local CONFIG = {
    Key               = Enum.KeyCode.T,
    AutoRelease       = false,   -- true = break free without pressing the key
    RestoreWalkSpeed  = true,
    OpenPod           = true,
    RestorePodWhenOut = true,
    MinHealth         = 1,
    ReleaseTicks      = 180,     -- ~3s of forcing after a press
    NearRadius        = 15,      -- fallback: nearest pod within this many studs

    -- If opening the pod locally is not enough (server still holding you),
    -- physically move the character out of the box as a last resort.
    TeleportOut       = true,
    TeleportAfter     = 15,      -- ticks after the press before trying
    TeleportDistance  = 7,
    TeleportRetries   = 8,       -- hard escapes per press before giving up the log line

    -- A second capture (server re-podding after a failed escape) restarts the
    -- escape window and teleport budget instead of leaving us stuck at 0 ticks.
    RearmOnRecapture  = true,

    WatchFlags        = { "Captured", "Ragdoll", "IsCrawling", "DisableCrawl", "DisableInteraction" },

    -- Fire the pod's own rescue trigger at ourselves. A teammate's rescue uses
    -- the same Input/Trigger call and the server does not range-check it, so
    -- this is the only attempt that can clear the *server-side* capture timer.
    CallPodRescue     = true,
    PodRescueTries    = 6,
    PodRescueEvery    = 30,
    PodReleaseTicks   = 6,
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfAntiFreezeInstance = INSTANCE_ID

local unloaded     = false
local lastMap      = nil
local lastScan     = 0
local pods         = {}      -- { model, cf, size, floorY }
local opened       = {}      -- [model] = { [part] = originalCanCollide }
local connections  = {}
local releasing    = false
local releaseTicks = 0
local activePod    = nil
local teleports    = 0
local teleportWait = 0
local releases     = 0
local recaptures   = 0
local wasCaptured  = false
local stuckLogged  = false
local escapedLogged = false
local podRescueTries = 0
local podRescueWait  = 0
local podReleaseEv   = nil
local podReleaseTicks = 0

-- ---------------------------------------------------------------- pod cache

-- The map folder survives between rounds but the pods inside it are re-cloned,
-- so a matching name is not enough: also invalidate when the pods die.
local function podsValid()
    if #pods == 0 then return false end
    for _, p in ipairs(pods) do
        if not p.model.Parent then return false end
    end
    return true
end

local function describePod(model)
    local ok, cf, size = pcall(function()
        local a, b = model:GetBoundingBox()
        return a, b
    end)
    if not ok or not cf then return nil end

    local floorY = math.huge
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            floorY = math.min(floorY, d.Position.Y)
        end
    end
    return { model = model, cf = cf, size = size, floorY = floorY }
end

local function refreshPods()
    local mapValue = RS:FindFirstChild("CurrentMap")
    local map = mapValue and mapValue.Value
    local now = os.clock()

    if map == lastMap and podsValid() and (now - lastScan) < 5 then return end
    if map ~= lastMap then opened = {} end

    lastMap, lastScan = map, now
    pods = {}
    if not map then return end

    for _, c in ipairs(map:GetChildren()) do
        if c.Name == "FreezePod" then
            local pod = describePod(c)
            if pod then table.insert(pods, pod) end
        end
    end
end

-- 1. the pod the server actually put us in: its CapturedTorso points at us.
--    Only the cached pods are checked - scanning all of workspace costs enough
--    to get the calling script killed.
local function podFromCapture(character)
    if not character then return nil end

    local function check(model)
        if not model then return nil end
        local ct = model:FindFirstChild("CapturedTorso")
        if ct and ct:IsA("ObjectValue") then
            local v = ct.Value
            if v and v:IsDescendantOf(character) then
                return describePod(model) or { model = model }
            end
        end
        return nil
    end

    for _, pod in ipairs(pods) do
        local found = check(pod.model)
        if found then return found end
    end

    -- pods outside the map folder (lobby, prefabs)
    for _, c in ipairs(workspace:GetChildren()) do
        if c.Name == "FreezePod" then
            local found = check(c)
            if found then return found end
        end
    end

    return nil
end

-- 2. our position is inside a pod's bounds
local function podAt(pos)
    for _, pod in ipairs(pods) do
        if pod.cf then
            local rel = pod.cf:PointToObjectSpace(pos)
            local h = pod.size * 0.5
            if math.abs(rel.X) <= h.X + 1.5
                and math.abs(rel.Y) <= h.Y + 2.0
                and math.abs(rel.Z) <= h.Z + 1.5 then
                return pod
            end
        end
    end
    return nil
end

-- 3. nearest pod, used when we know we are captured but bounds missed
local function nearestPod(pos, radius)
    local best, bestDist = nil, radius or CONFIG.NearRadius
    for _, pod in ipairs(pods) do
        if pod.cf then
            local dist = (pod.cf.Position - pos).Magnitude
            if dist < bestDist then
                best, bestDist = pod, dist
            end
        end
    end
    return best
end

-- ------------------------------------------------------------------ opening

local function openPod(pod)
    if not CONFIG.OpenPod or not pod or not pod.model then return end
    if opened[pod.model] then return end

    local floorY = pod.floorY
    if not floorY then
        floorY = math.huge
        for _, d in ipairs(pod.model:GetDescendants()) do
            if d:IsA("BasePart") then floorY = math.min(floorY, d.Position.Y) end
        end
    end

    local saved = {}
    for _, d in ipairs(pod.model:GetDescendants()) do
        -- keep the floor so you do not drop through the map
        if d:IsA("BasePart") and d.Position.Y > floorY + 0.3 then
            saved[d] = d.CanCollide
            d.CanCollide = false
        end
    end
    opened[pod.model] = saved
end

local function closePod(model)
    local saved = opened[model]
    if not saved then return end
    for part, wasCollide in pairs(saved) do
        if part.Parent then
            pcall(function() part.CanCollide = wasCollide end)
        end
    end
    opened[model] = nil
end

local function closeAllPods()
    for model in pairs(opened) do
        closePod(model)
    end
end

-- ------------------------------------------------------- hard escape route

-- Pick the most open horizontal direction out of the pod and return a CFrame
-- a few studs outside it. Used only when the pod is open and we are still
-- inside, i.e. something other than collision is holding us.
local function exitCFrame(pod, root)
    if not (pod and pod.cf) then return nil end

    local origin = pod.cf.Position + Vector3.new(0, 1.5, 0)
    local bestDir, bestDist = nil, -1

    for _, dir in ipairs({
        Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0),
        Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
    }) do
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { LocalPlayer.Character, pod.model }
        local hit = workspace:Raycast(origin, dir * 14, params)
        local dist = hit and (hit.Position - origin).Magnitude or 14
        if dist > bestDist then
            bestDist, bestDir = dist, dir
        end
    end

    if not bestDir then return nil end

    local travel = math.min(bestDist - 2, CONFIG.TeleportDistance)
    local target = origin + bestDir * travel + Vector3.new(0, 1.5, 0)
    return CFrame.new(target, target + bestDir)   -- face the way out
end

-- ------------------------------------------------------------------ rescue

local function stats()
    return LocalPlayer:FindFirstChild("TempPlayerStatsModule")
end

local function getCharacter()
    local ch = LocalPlayer.Character
    return ch, ch and ch:FindFirstChildOfClass("Humanoid"), ch and ch:FindFirstChild("HumanoidRootPart")
end

local function normalSpeed()
    local s = stats()
    local v = s and s:FindFirstChild("NormalWalkSpeed")
    if v and typeof(v.Value) == "number" and v.Value > 0.5 then
        return v.Value
    end
    return 16
end

local function clearFlags()
    local s = stats()
    if not s then return false end
    local any = false
    for _, name in ipairs(CONFIG.WatchFlags) do
        local v = s:FindFirstChild(name)
        if v and v.Value == true then
            any = true
            pcall(function() v.Value = false end)
        end
    end
    return any
end

local function unwrap(humanoid)
    if humanoid.PlatformStand then
        humanoid.PlatformStand = false
    end
    local state = humanoid:GetState()
    if state == Enum.HumanoidStateType.PlatformStanding
        or state == Enum.HumanoidStateType.Physics
        or state == Enum.HumanoidStateType.FallingDown then
        humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
    end
end

-- Resolve the pod we are in, using every signal we have. The second return
-- value names the signal that matched, so diagnostics say *why* a pod was
-- chosen instead of just which one.
local function resolvePod(character, root)
    local pod = podFromCapture(character)
    if pod then return pod, "captured-torso" end

    pod = podAt(root.Position)
    if pod then return pod, "bounds" end

    local s = stats()
    local captured = s and s:FindFirstChild("Captured") and s.Captured.Value
    if captured or (character and character:FindFirstChildOfClass("Humanoid") and character:FindFirstChildOfClass("Humanoid").PlatformStand) then
        pod = nearestPod(root.Position, CONFIG.NearRadius)
        if pod then return pod, "nearest" end
    end
    return nil, "none"
end

local function rescue()
    local ch, humanoid, root = getCharacter()
    if not (humanoid and root) then return nil end

    clearFlags()
    unwrap(humanoid)

    if CONFIG.RestoreWalkSpeed then
        local want = normalSpeed()
        if math.abs(humanoid.WalkSpeed - want) > 0.5 then
            humanoid.WalkSpeed = want
        end
    end

    local pod, source = resolvePod(ch, root)
    if pod then
        activePod = pod
        openPod(pod)
    end
    return pod, source
end

local function release()
    local _, humanoid = getCharacter()
    if not humanoid then return end

    releasing    = true
    releaseTicks = CONFIG.ReleaseTicks
    teleports    = 0
    teleportWait = 0
    releases     = releases + 1
    stuckLogged  = false
    escapedLogged = false
    podRescueTries = 0
    podRescueWait  = 0
    local pod, source = rescue()
    print(string.format("[FTF-ANTIFREEZE] break free (%d) pod=%s via=%s",
        releases, tostring(pod and pod.model and pod.model.Name or "none"), tostring(source)))
end

-- ------------------------------------------------------------------- loop

local unload   -- forward declaration: each instance owns its own teardown

local function step()
    if unloaded then return end

    if _G.__ftfAntiFreezeInstance ~= INSTANCE_ID then
        unload()
        return
    end

    refreshPods()

    local ch, humanoid, root = getCharacter()
    if not (humanoid and root) then return end
    if humanoid.Health < CONFIG.MinHealth then return end

    -- Capture edge: new podding while auto-release is on (or while a manual
    -- escape is still running) restarts the window so we are not left stuck
    -- with releaseTicks == 0 and no teleport budget.
    local s = stats()
    local captured = s and s:FindFirstChild("Captured") and s.Captured.Value == true
    if captured and not wasCaptured then
        recaptures = recaptures + 1
        if CONFIG.RearmOnRecapture and (CONFIG.AutoRelease or releasing) then
            releaseTicks = CONFIG.ReleaseTicks
            teleports    = 0
            teleportWait = 0
            stuckLogged  = false
            print(string.format("[FTF-ANTIFREEZE] re-captured, re-armed (capture %d)", recaptures))
        else
            print(string.format("[FTF-ANTIFREEZE] captured (capture %d)", recaptures))
        end
    end
    wasCaptured = captured

    local active = CONFIG.AutoRelease or releasing
    if not active then
        if CONFIG.RestorePodWhenOut then
            for _, p in ipairs(pods) do closePod(p.model) end
        end
        return
    end

    local inside = podAt(root.Position)
    if releaseTicks > 0 or inside or humanoid.PlatformStand or CONFIG.AutoRelease then
        -- keep the pod we opened open while we are still in it
        if inside then activePod = inside end
        if activePod and activePod.model and activePod.model.Parent then
            openPod(activePod)
        end
        rescue()

        -- Ask the server to free us the same way a teammate would. This is the
        -- only path that can stop the capture/sacrifice timer server-side.
        if CONFIG.CallPodRescue and activePod and activePod.model
            and podRescueTries < CONFIG.PodRescueTries then
            if podRescueWait > 0 then
                podRescueWait = podRescueWait - 1
            else
                local ev = activePod.model:FindFirstChild("Event", true)
                local r = RS:FindFirstChild("RemoteEvent")
                if ev and ev:IsA("BindableEvent") and r then
                    r:FireServer("Input", "Trigger", true, ev)
                    podReleaseEv = ev
                    podReleaseTicks = CONFIG.PodReleaseTicks
                    podRescueTries = podRescueTries + 1
                    podRescueWait = CONFIG.PodRescueEvery
                    print(string.format("[FTF-ANTIFREEZE] fired pod rescue on self (%d/%d)",
                        podRescueTries, CONFIG.PodRescueTries))
                end
            end
        end

        if podReleaseTicks > 0 then
            podReleaseTicks = podReleaseTicks - 1
            if podReleaseTicks == 0 and podReleaseEv then
                local r = RS:FindFirstChild("RemoteEvent")
                if r then r:FireServer("Input", "Trigger", false, podReleaseEv) end
                podReleaseEv = nil
            end
        end

        -- still boxed in after opening it: something else is holding us, so
        -- move the character out of the pod outright. Retry a couple of times
        -- in case the server snaps the character back inside.
        if teleportWait > 0 then
            teleportWait = teleportWait - 1
        elseif CONFIG.TeleportOut and inside and teleports < CONFIG.TeleportRetries
            and releaseTicks <= (CONFIG.ReleaseTicks - CONFIG.TeleportAfter) then
            local cf = exitCFrame(inside, root)
            if cf then
                teleports = teleports + 1
                teleportWait = 24
                root.CFrame = cf
                print(string.format("[FTF-ANTIFREEZE] moved out of the pod (try %d)", teleports))
            end
        end
    end

    if releaseTicks > 0 then
        releaseTicks = releaseTicks - 1
    end

    if releasing and releaseTicks <= 0 then
        local still = podAt(root.Position)
        if still and not stuckLogged then
            stuckLogged = true
            print(string.format("[FTF-ANTIFREEZE] still inside %s after %d teleport tries - raise TeleportRetries/ReleaseTicks",
                tostring(still.model and still.model.Name or "pod"), teleports))
        elseif not still and not humanoid.PlatformStand then
            if not escapedLogged then
                escapedLogged = true
                print(string.format("[FTF-ANTIFREEZE] escaped (%d teleport tries)", teleports))
            end
            releasing = false
            activePod = nil
            teleports = 0
        end
    end
end

-- --------------------------------------------------------------- keybind

-- A capture screen can make the keypress arrive as "game processed". Only the
-- chat box should block the bind, so check the focused text box instead.
local function isTyping()
    local ok, box = pcall(function() return UserInputService:GetFocusedTextBox() end)
    return ok and box ~= nil
end

table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if unloaded then return end
    if input.KeyCode ~= CONFIG.Key then return end
    if gameProcessed and isTyping() then return end
    release()
end))

-- ---------------------------------------------------------------- teardown

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
    closeAllPods()
    if _G.__ftfAntiFreezeInstance == INSTANCE_ID then
        _G.__ftfAntiFreezeInstance = nil
    end
    if _G.__ftfAntiFreezeStop == unload then
        _G.__ftfAntiFreezeStop = nil
        _G.__ftfAntiFreeze = nil
    end
    print("[FTF-ANTIFREEZE] unloaded")
end

_G.__ftfAntiFreezeStop = unload

table.insert(connections, RunService.RenderStepped:Connect(step))

_G.__ftfAntiFreeze = {
    Config   = CONFIG,
    Pods     = function() return pods end,
    Released = function() return releases end,
    Captures = function() return recaptures end,
    Release  = release,
    Step     = function() step() end,
    Stop     = function() unload() end,
}

refreshPods()
print(string.format("[FTF-ANTIFREEZE] loaded - %s breaks free (auto=%s, %d pods)",
    tostring(CONFIG.Key), tostring(CONFIG.AutoRelease), #pods))
