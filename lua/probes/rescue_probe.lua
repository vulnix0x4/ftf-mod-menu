--!nocheck
--[[
    Flee the Facility - rescue structure probe

    Run while a teammate is frozen:

        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/probes/rescue_probe.lua"))()

    Dumps, and copies to the clipboard:
        - current map and every FreezePod-ish instance (direct and nested)
        - pod children/classes, Event presence, CapturedTorso value + full path
        - every player's Character full name
        - what rescue.lua currently maps as targets
        - the raw list of all ObjectValues named CapturedTorso in the map

    Paste the clipboard here if the menu says "no frozen teammate" while a pod
    is visibly occupied.
]]

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RS        = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local lines = {}
local function say(text)
    lines[#lines + 1] = text
    print("[FTF-RESCUEPROBE] " .. text)
end

local mapValue = RS:FindFirstChild("CurrentMap")
local map = mapValue and mapValue.Value

say("place=" .. tostring(game.PlaceId) .. "  map=" .. tostring(map and map:GetFullName() or "nil"))

local function describe(inst, prefix)
    local ok, line = pcall(function()
        local bits = {}
        for _, c in ipairs(inst:GetChildren()) do
            bits[#bits + 1] = c.Name .. "(" .. c.ClassName .. ")"
            if #bits >= 14 then
                bits[#bits + 1] = "..."
                break
            end
        end
        return string.format("%s %s [%s] children: %s",
            prefix, inst:GetFullName(), inst.ClassName, table.concat(bits, ", "))
    end)
    if ok then say(line) end
end

local caps = {}

local function scanContainer(container, label, deep)
    if not container then return end

    for _, c in ipairs(container:GetChildren()) do
        if c.Name:lower():find("freezepod") or c.Name:lower():find("pod") then
            describe(c, label)
        end
        if c:IsA("ObjectValue") and c.Name == "CapturedTorso" then
            caps[#caps + 1] = c
        end
    end

    if not deep then return end

    for _, d in ipairs(container:GetDescendants()) do
        if d:IsA("ObjectValue") and d.Name == "CapturedTorso" then
            caps[#caps + 1] = d
            local pod = d.Parent
            say(string.format("%s CapturedTorso at %s  value=%s",
                label,
                d:GetFullName(),
                d.Value and d.Value:GetFullName() or "nil"))
            if pod then describe(pod, label .. " pod") end
        end
    end
end

-- deep scan only the map folder; Workspace is too large and has killed
-- scripts before when walked from event handlers (see LEARNINGS 7.1)
scanContainer(map, "MAP", true)
scanContainer(Workspace, "WS", false)

say(string.format("CapturedTorso ObjectValues found: %d", #caps))

for _, p in ipairs(Players:GetPlayers()) do
    say(string.format("PLAYER %-22s char=%s", p.Name,
        p.Character and p.Character:GetFullName() or "nil"))
end

local api = _G.__ftfRescue
if api then
    local ok, targets = pcall(api.Targets)
    if ok and targets then
        say(string.format("rescue.lua: %d target(s)", #targets))
        for _, t in ipairs(targets) do
            say(string.format("  TARGET %s -> %s", t.player.Name, t.pod:GetFullName()))
        end
    else
        say("rescue.lua: Targets() failed")
    end
    if api.Config then
        say(string.format("rescue.lua: auto=%s radius=%s useActionHold=%s",
            tostring(api.Config.AutoRescue), tostring(api.Config.Radius),
            tostring(api.Config.UseActionHold)))
    end
else
    say("rescue.lua: NOT LOADED")
end

local text = table.concat(lines, "\n")
local copied = pcall(function() setclipboard(text) end)
if copied then
    print("[FTF-RESCUEPROBE] report copied to clipboard - Ctrl+V it in chat")
else
    print("[FTF-RESCUEPROBE] clipboard unavailable - copy the lines above")
end
