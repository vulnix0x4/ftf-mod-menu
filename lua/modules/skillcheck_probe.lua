--!nocheck
--[[
    Flee the Facility - skillcheck probe (passive)

    We know the hack is server-paced and that `TempPlayerStatsModule` mirrors
    state, but not what the timing minigame is built from. This script watches
    the client while you hack and records:

        - every change of MinigameResult / ActionProgress / ActionInput / OnTrigger
        - every new GuiObject that appears while progress is moving, with class,
          name, size, position, rotation and a short parent path
        - a snapshot command that dumps the current stats + candidate widgets

    No hooks, no remote writes, no GUI changes. It only reads.

    Typical run:
        1. load this script (or press "Skillcheck snapshot" in the menu)
        2. hack a computer; let the timing minigame appear and resolve
        3. read the console: [FTF-SKILL] lines

    API:
        _G.__ftfSkillProbe.Snapshot()   -- dump stats + candidates now
        _G.__ftfSkillProbe.Tree()       -- dump every GuiObject under PlayerGui
        _G.__ftfSkillProbe.Copy()       -- copy recent entries + tree to clipboard
        _G.__ftfSkillProbe.Log()        -- recent entries
        _G.__ftfSkillProbe.Force()      -- TEST: set MinigameResult = true once
        _G.__ftfSkillProbe.Stop()

    Unload: _G.__ftfSkillProbeStop().
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    PollFrames     = 6,
    RescanGuiFrames = 15,
    ActiveWindow   = 3,      -- seconds after progress moves to keep logging GUIDs
    MaxLog         = 200,
    TreeMax        = 160,
    TreeFocus      = { "TimingCircle", "ActionBox", "ProgressBox", "StatusBars", "SpectatorFrame", "BeastPowerBar" },
    ProgressLogStep = 0.05,   -- only log ActionProgress every 5% (resets always logged)
    WatchValues    = { "MinigameResult", "ActionProgress", "ActionInput", "OnTrigger", "Captured" },
    NamePatterns   = {
        "skill", "minigame", "timing", "zone", "target", "marker",
        "needle", "hit", "bar", "action", "progress",
    },
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfSkillProbeInstance = INSTANCE_ID

local unloaded   = false
local entries    = {}
local lastTree   = {}
local wantTree   = false
local knownGui   = {}
local lastValues = {}
local lastProgressAt = 0
local lastProgress = nil
local lastProgressLogged = -1
local tick       = 0
local conns      = {}

-- ------------------------------------------------------------------- utils

local function add(entry)
    entries[#entries + 1] = entry
    if #entries > CONFIG.MaxLog then
        table.remove(entries, 1)
    end
    print("[FTF-SKILL] " .. entry.line)
end

local function matches(name)
    local n = string.lower(name)
    for _, p in ipairs(CONFIG.NamePatterns) do
        if string.find(n, p, 1, true) then return true end
    end
    return false
end

-- Only dump gameplay-relevant subtrees by default; the shop/merch GUIs have
-- thousands of ImageLabels and drown the useful lines.
local function inFocus(obj)
    local node = obj
    for _ = 1, 7 do
        if not node then break end
        for _, name in ipairs(CONFIG.TreeFocus) do
            if node.Name == name then return true end
        end
        node = node.Parent
    end
    return matches(obj.Name)
end

local function chain(obj, depth)
    local parts = {}
    local cur = obj
    for _ = 1, depth or 3 do
        if not cur then break end
        table.insert(parts, 1, cur.Name)
        cur = cur.Parent
    end
    return table.concat(parts, "/")
end

local function stats()
    return LocalPlayer:FindFirstChild("TempPlayerStatsModule")
end

local function playerGui()
    return LocalPlayer:FindFirstChild("PlayerGui")
end

local function readStats()
    local s = stats()
    local out = {}
    if not s then return out end
    for _, name in ipairs(CONFIG.WatchValues) do
        local v = s:FindFirstChild(name)
        if v then out[name] = v.Value end
    end
    return out
end

-- Dump every GuiObject under PlayerGui, visibility ignored: the timing widget
-- usually exists all round and is merely hidden, so this works even when no
-- circle is on screen.
local function treeDump(reason, full)
    local pg = playerGui()
    lastTree = {}

    if not pg then
        lastTree[1] = "TREE: no PlayerGui"
        print("[FTF-SKILL] " .. lastTree[1])
        return
    end

    local lines = { "TREE " .. tostring(reason or "") .. (full and " [full]" or " [focus]") }
    local count = 0

    for _, obj in ipairs(pg:GetDescendants()) do
        local isGui = false
        pcall(function()
            isGui = obj:IsA("GuiObject") or obj:IsA("ScreenGui")
        end)

        if isGui then
            count = count + 1
            if (full or inFocus(obj)) and #lines <= CONFIG.TreeMax then
                local ok, line = pcall(function()
                    local size = obj.AbsoluteSize
                    local pos = obj.AbsolutePosition
                    local rot = 0
                    pcall(function() rot = obj.Rotation end)
                    return string.format("%-11s %q vis=%-5s %4dx%-4d @%5d,%-5d rot=%5.0f  %s",
                        obj.ClassName, obj.Name, tostring(obj.Visible),
                        size.X or 0, size.Y or 0, pos.X or 0, pos.Y or 0, rot or 0,
                        chain(obj.Parent, 4))
                end)
                if ok then
                    lines[#lines + 1] = "T " .. line
                end
            end
        end
    end

    if #lines > CONFIG.TreeMax then
        lines[#lines + 1] = string.format("T ... truncated (%d gui objects)", count)
    end

    lastTree = lines
    for _, l in ipairs(lines) do
        print("[FTF-SKILL] " .. l)
    end
end

-- ------------------------------------------------------------- transitions

local function watchValues()
    local s = stats()
    if not s then return end

    for _, name in ipairs(CONFIG.WatchValues) do
        local v = s:FindFirstChild(name)
        if v then
            local now = v.Value
            local before = lastValues[name]
            if before ~= now then
                lastValues[name] = now

                if name == "ActionProgress" then
                    lastProgressAt = os.clock()
                    lastProgress = now
                end

                -- Progress ticks ~450 times per hack. Log resets and 5% steps
                -- only, otherwise the useful lines scroll away.
                local shouldLog = true
                if name == "ActionProgress" then
                    shouldLog = (now == 0)
                        or (before == nil)
                        or (math.abs(now - lastProgressLogged) >= CONFIG.ProgressLogStep)
                    if shouldLog then lastProgressLogged = now end
                end

                if shouldLog then
                    local line = string.format("%s %s -> %s",
                        name, tostring(before), tostring(now))
                    add({ t = os.clock(), line = line })
                end

                -- A rising ActionInput is the closest thing we have to "the
                -- minigame just appeared": dump the GUI tree right then.
                if name == "ActionInput" and before ~= true and now == true then
                    wantTree = true
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- gui scan

local function scanGui(force)
    local pg = playerGui()
    if not pg then return end

    local active = (os.clock() - lastProgressAt) <= CONFIG.ActiveWindow
        or (lastValues.ActionInput == true)

    for _, obj in ipairs(pg:GetDescendants()) do
        if obj:IsA("GuiObject") then
            if not knownGui[obj] then
                knownGui[obj] = true

                if (force or active) and obj.Visible then
                    local rot = 0
                    pcall(function() rot = obj.Rotation end)

                    if force or matches(obj.Name) or active then
                        local ok, line = pcall(function()
                            local pos = obj.AbsolutePosition
                            local size = obj.AbsoluteSize
                            return string.format("+ %s %q  %dx%d @ %d,%d rot=%.0f  parent=%s",
                                obj.ClassName, obj.Name,
                                size.X, size.Y, pos.X, pos.Y, rot,
                                chain(obj.Parent, 3))
                        end)
                        if ok then
                            add({ t = os.clock(), line = line, gui = obj })
                        end
                    end
                end
            end
        end
    end
end

-- ------------------------------------------------------------------ public

local function snapshot()
    local values = readStats()
    local order = { "MinigameResult", "ActionProgress", "ActionInput", "OnTrigger", "Captured" }
    local bits = {}
    for _, name in ipairs(order) do
        bits[#bits + 1] = string.format("%s=%s", name, tostring(values[name]))
    end
    add({ t = os.clock(), line = "SNAPSHOT " .. table.concat(bits, " ") })

    scanGui(true)

    local pg = playerGui()
    if pg then
        local count = 0
        for _, obj in ipairs(pg:GetDescendants()) do
            if obj:IsA("GuiObject") and obj.Visible and matches(obj.Name) then
                local ok, line = pcall(function()
                    return string.format("  visible %s %q %dx%d rot=%.0f parent=%s",
                        obj.ClassName, obj.Name,
                        obj.AbsoluteSize.X, obj.AbsoluteSize.Y,
                        obj.Rotation, chain(obj.Parent, 3))
                end)
                if ok then
                    print("[FTF-SKILL] " .. line)
                    count = count + 1
                    if count >= 25 then break end
                end
            end
        end
        print(string.format("[FTF-SKILL] snapshot done (%d visible candidates)", count))
    end
end

local function force()
    local s = stats()
    local v = s and s:FindFirstChild("MinigameResult")
    if not v or not v:IsA("BoolValue") then
        add({ t = os.clock(), line = "Force failed: MinigameResult missing" })
        return false
    end
    v.Value = true
    add({ t = os.clock(), line = "FORCED MinigameResult = true (experiment)" })
    return true
end

-- -------------------------------------------------------------------- loop

local unload   -- forward declaration: step's stale-instance guard calls it

local function step()
    if unloaded then return end

    if _G.__ftfSkillProbeInstance ~= INSTANCE_ID then
        unload()
        return
    end

    tick = tick + 1
    if tick % CONFIG.PollFrames ~= 0 then return end

    watchValues()

    if wantTree then
        wantTree = false
        treeDump("auto: ActionInput rose")
    end

    if tick % CONFIG.RescanGuiFrames == 0 then
        scanGui(false)
    end
end

-- --------------------------------------------------------------- lifecycle

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    table.clear(knownGui)
    table.clear(lastValues)
    if _G.__ftfSkillProbeInstance == INSTANCE_ID then
        _G.__ftfSkillProbeInstance = nil
    end
    if _G.__ftfSkillProbeStop == unload then
        _G.__ftfSkillProbeStop = nil
        _G.__ftfSkillProbe = nil
    end
    print("[FTF-SKILL] unloaded")
end

_G.__ftfSkillProbeStop = unload

_G.__ftfSkillProbe = {
    Config   = CONFIG,
    Log      = function() return entries end,
    Snapshot = snapshot,
    Force    = force,
    Tree     = function(reason, full)
        treeDump(reason or "manual", full == true)
        return true
    end,
    Copy     = function()
        local out = {}

        if #lastTree > 0 then
            out[#out + 1] = "== GUI TREE =="
            for _, l in ipairs(lastTree) do out[#out + 1] = l end
            out[#out + 1] = "== LOG =="
        end

        for _, e in ipairs(entries) do
            out[#out + 1] = string.format("[%.1f] %s", e.t, e.line)
        end
        local text = table.concat(out, "\n")
        local ok = pcall(function() setclipboard(text) end)
        if ok then
            print(string.format("[FTF-SKILL] copied %d log entries + tree to clipboard", #entries))
        else
            print("[FTF-SKILL] clipboard unavailable - copy the lines above")
        end
        return ok
    end,
    Stop     = function() unload() end,
}

conns[#conns + 1] = RunService.RenderStepped:Connect(step)

local s = stats()
if s then
    for _, name in ipairs(CONFIG.WatchValues) do
        local v = s:FindFirstChild(name)
        if v then lastValues[name] = v.Value end
    end
end
lastProgressAt = os.clock()

print("[FTF-SKILL] loaded - hack a computer, then read [FTF-SKILL] lines")
