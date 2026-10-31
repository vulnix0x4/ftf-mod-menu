--!nocheck
--[[
    Flee the Facility - emergency unfreeze

    Run this while frozen:

        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/modules/unfreeze.lua"))()

    It is deliberately more aggressive than antifreeze.lua:

        - disables any LocalScript named *ragdoll* / *captur* under the character,
          PlayerScripts and PlayerGui (these are what re-apply PlatformStand)
        - clears Captured / Ragdoll / IsCrawling / DisableCrawl / DisableInteraction
          every Heartbeat (Heartbeat runs after most RenderStepped game scripts)
        - forces PlatformStand = false and ChangeState(GettingUp) every frame
        - disables the PlatformStanding / FallingDown humanoid states temporarily
        - opens the pod it finds (walls/roof CanCollide = false, floor kept)
        - teleports you ~9 studs out every 4 frames for 12 seconds, re-checking the
          pod and re-aiming each time, so a server snap-back loses the race
        - logs state every 30 frames so we can see what is still holding you

    It runs immediately on load. Logs are prefixed [FTF-UNFREEZE].

    API: _G.__ftfUnfreeze.Status() / .Stop()
    Unload: _G.__ftfUnfreezeStop()
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace  = game:GetService("Workspace")
local RS         = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Duration        = 12,
    HopEvery        = 4,
    HopDistance     = 9,
    OpenPod         = true,
    DisableRagdollScripts = true,
    DisableStates   = true,
    LogEvery        = 30,
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfUnfreezeInstance = INSTANCE_ID

local unloaded   = false
local started    = os.clock()
local pod        = nil
local hopPoint   = nil
local hopLook    = nil
local hopTicks   = 0
local hops       = 0
local savedParts = {}     -- [BasePart] = original CanCollide
local stateOff   = false
local disabledScripts = 0
local conns      = {}
local lastStatus = {}

-- -------------------------------------------------------------------- utils

local function character()
    local ch = LocalPlayer.Character
    return ch, ch and ch:FindFirstChildOfClass("Humanoid"), ch and ch:FindFirstChild("HumanoidRootPart")
end

local function stats()
    return LocalPlayer:FindFirstChild("TempPlayerStatsModule")
end

local function normalSpeed()
    local s = stats()
    local v = s and s:FindFirstChild("NormalWalkSpeed")
    if v and typeof(v.Value) == "number" and v.Value > 0.5 then return v.Value end
    return 16
end

local function clearFlags()
    local s = stats()
    if not s then return end
    for _, name in ipairs({ "Captured", "Ragdoll", "IsCrawling", "DisableCrawl", "DisableInteraction" }) do
        local v = s:FindFirstChild(name)
        if v and v.Value == true then
            pcall(function() v.Value = false end)
        end
    end
end

local function forceHumanoid(h)
    if not h or not h.Parent then return end

    if h.PlatformStand then
        h.PlatformStand = false
    end

    local ok, state = pcall(function() return h:GetState() end)
    if ok and (state == Enum.HumanoidStateType.PlatformStanding
        or state == Enum.HumanoidStateType.Physics
        or state == Enum.HumanoidStateType.FallingDown) then
        pcall(function() h:ChangeState(Enum.HumanoidStateType.GettingUp) end)
    end

    if CONFIG.DisableStates and not stateOff then
        pcall(function() h:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false) end)
        pcall(function() h:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false) end)
        stateOff = true
    end

    local want = normalSpeed()
    if math.abs(h.WalkSpeed - want) > 0.5 then
        h.WalkSpeed = want
    end
end

-- ---------------------------------------------------------------- ragdolls

local function disableRagdolls()
    if not CONFIG.DisableRagdollScripts then return end

    local roots = {
        LocalPlayer.Character,
        LocalPlayer:FindFirstChild("PlayerScripts"),
        LocalPlayer:FindFirstChild("PlayerGui"),
    }

    for _, root in ipairs(roots) do
        if root then
            for _, d in ipairs(root:GetDescendants()) do
                if d:IsA("LocalScript") then
                    local n = d.Name:lower()
                    if n:find("ragdoll") or n:find("captur") then
                        local was = false
                        pcall(function() was = d.Disabled end)
                        if not was then
                            pcall(function() d.Disabled = true end)
                            disabledScripts = disabledScripts + 1
                            print("[FTF-UNFREEZE] disabled " .. d:GetFullName())
                        end
                    end
                end
            end
        end
    end
end

-- --------------------------------------------------------------------- pod

local function findPod()
    local ch = LocalPlayer.Character
    if not ch then return nil end

    local mapValue = RS:FindFirstChild("CurrentMap")
    local map = mapValue and mapValue.Value

    local pods, seen = {}, {}
    local function add(p)
        if p and not seen[p] then seen[p] = true; pods[#pods + 1] = p end
    end

    if map then
        for _, c in ipairs(map:GetChildren()) do
            if c.Name == "FreezePod" then add(c) end
        end
    end
    for _, c in ipairs(Workspace:GetChildren()) do
        if c.Name == "FreezePod" then add(c) end
    end

    for _, p in ipairs(pods) do
        local ct = p:FindFirstChild("CapturedTorso", true)
        if ct and ct:IsA("ObjectValue") and ct.Value and ct.Value:IsDescendantOf(ch) then
            return p
        end
    end

    return nil
end

local function openPod(p)
    if not CONFIG.OpenPod or not p then return end

    local floorY = math.huge
    for _, d in ipairs(p:GetDescendants()) do
        if d:IsA("BasePart") then floorY = math.min(floorY, d.Position.Y) end
    end
    if floorY == math.huge then return end

    for _, d in ipairs(p:GetDescendants()) do
        if d:IsA("BasePart") and d.Position.Y > floorY + 0.3 then
            if savedParts[d] == nil then savedParts[d] = d.CanCollide end
            if d.CanCollide then d.CanCollide = false end
        end
    end
end

local function chooseExit(p, root)
    local ok, cf = pcall(function()
        local a = p:GetBoundingBox()
        return a
    end)

    local center
    if ok and cf then
        center = cf.Position
    else
        center = root.Position
    end

    local origin = center + Vector3.new(0, 1.5, 0)
    local bestDir, bestDist = Vector3.new(0, 0, 1), -1

    for _, dir in ipairs({
        Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0),
        Vector3.new(0, 0, 1), Vector3.new(0, 0, -1),
    }) do
        local cleared = -1
        pcall(function()
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { LocalPlayer.Character, p }
            local hit = Workspace:Raycast(origin, dir * 14, params)
            cleared = hit and (hit.Position - origin).Magnitude or 14
        end)
        if cleared > bestDist then
            bestDist, bestDir = cleared, dir
        end
    end

    local travel = math.clamp(bestDist - 2, 2, CONFIG.HopDistance)
    local point = origin + bestDir * travel + Vector3.new(0, 0.5, 0)
    return point, point + bestDir
end

-- -------------------------------------------------------------------- loop

local function logStatus(h, inside)
    local s = stats()
    local function flag(name)
        local v = s and s:FindFirstChild(name)
        return v and tostring(v.Value) or "?"
    end

    lastStatus = {
        state = tostring(h and h:GetState() or "?"),
        platformStand = h and tostring(h.PlatformStand) or "?",
        walkSpeed = h and h.WalkSpeed or 0,
        captured = flag("Captured"),
        ragdoll = flag("Ragdoll"),
        inside = tostring(inside),
        hops = hops,
    }

    print(string.format("[FTF-UNFREEZE] state=%s ps=%s ws=%.0f captured=%s ragdoll=%s inside=%s hops=%d",
        lastStatus.state, lastStatus.platformStand, lastStatus.walkSpeed,
        lastStatus.captured, lastStatus.ragdoll, lastStatus.inside, hops))
end

local unload   -- forward declaration

local function step()
    if unloaded then return end

    if _G.__ftfUnfreezeInstance ~= INSTANCE_ID then
        unload()
        return
    end

    if (os.clock() - started) > CONFIG.Duration then
        print("[FTF-UNFREEZE] window ended")
        unload()
        return
    end

    local ch, h, root = character()
    if not (h and root) then return end

    clearFlags()
    forceHumanoid(h)

    if not pod or not pod.Parent then
        pod = findPod()
        if pod then
            hopPoint, hopLook = chooseExit(pod, root)
            openPod(pod)
            print("[FTF-UNFREEZE] pod = " .. pod:GetFullName() .. " - hopping out")
        end
    else
        openPod(pod)
    end

    hopTicks = hopTicks + 1
    if pod and hopPoint and (hopTicks % CONFIG.HopEvery == 0) then
        root.CFrame = CFrame.new(hopPoint, hopLook)
        hops = hops + 1
    end

    if hopTicks % CONFIG.LogEvery == 0 then
        logStatus(h, pod ~= nil)
        disableRagdolls()
    end
end

-- --------------------------------------------------------------- lifecycle

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)

    for part, value in pairs(savedParts) do
        if part.Parent then pcall(function() part.CanCollide = value end) end
    end
    table.clear(savedParts)

    local _, h = character()
    if stateOff and h then
        pcall(function() h:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, true) end)
        pcall(function() h:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true) end)
    end

    if _G.__ftfUnfreezeInstance == INSTANCE_ID then
        _G.__ftfUnfreezeInstance = nil
    end
    if _G.__ftfUnfreezeStop == unload then
        _G.__ftfUnfreezeStop = nil
        _G.__ftfUnfreeze = nil
    end
    print("[FTF-UNFREEZE] stopped")
end

_G.__ftfUnfreezeStop = unload

_G.__ftfUnfreeze = {
    Config = CONFIG,
    Status = function() return lastStatus end,
    Hops   = function() return hops end,
    Stop   = function() unload() end,
}

conns[#conns + 1] = RunService.Heartbeat:Connect(step)

disableRagdolls()
pod = findPod()
local ch, h, root = character()
if pod and root then
    hopPoint, hopLook = chooseExit(pod, root)
    openPod(pod)
end

print(string.format("[FTF-UNFREEZE] running %ds - pod=%s scripts_disabled=%d",
    CONFIG.Duration, tostring(pod and pod:GetFullName() or "not found"), disabledScripts))
