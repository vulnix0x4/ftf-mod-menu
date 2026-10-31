--!nocheck
--[[
    Flee the Facility - door structure probe

    Run this standing near a door while the map is loaded:

        loadstring(game:HttpGet("http://127.0.0.1:8765/lua/probes/doors_probe.lua"))()

    It prints (and copies to the clipboard when the executor supports it):
        - current map name and its direct children
        - every instance under the map that has an `Event` child, grouped by
          name + parent name
        - the 15 nearest such parts with distance and full path
        - any door-named models directly under Workspace
        - whether the RemoteEvent exists
        - what doors.lua currently sees

    Paste the output (or just Ctrl+V after it says "copied") and we can fix the
    discovery rule in one pass.

    If doors.lua is loaded, also try:
        _G.__ftfDoors.Dump()
        _G.__ftfDoors.Test()      -- fires nearest trigger, bypassing radius/facing
]]

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RS        = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local lines = {}
local function say(text)
    lines[#lines + 1] = text
    print("[FTF-DOORPROBE] " .. text)
end

local mapValue = RS:FindFirstChild("CurrentMap")
local map = mapValue and mapValue.Value

say("place=" .. tostring(game.PlaceId) .. "  map=" .. tostring(map and map:GetFullName() or "nil"))

if map then
    local kids = {}
    for _, c in ipairs(map:GetChildren()) do
        kids[#kids + 1] = c.Name .. " (" .. c.ClassName .. ")"
        if #kids >= 40 then
            kids[#kids + 1] = "..."
            break
        end
    end
    say("map children: " .. table.concat(kids, ", "))

    local eventParts = {}
    local byKey = {}
    local anyEvent = 0

    for _, d in ipairs(map:GetDescendants()) do
        if d:FindFirstChild("Event") then
            anyEvent = anyEvent + 1
        end
        if d:IsA("BasePart") then
            local ev = d:FindFirstChild("Event")
            if ev and ev:IsA("BindableEvent") then
                eventParts[#eventParts + 1] = d
                local key = string.format("%s   parent=%s", d.Name, d.Parent and d.Parent.Name or "?")
                byKey[key] = (byKey[key] or 0) + 1
            end
        end
    end

    say(string.format("instances with an Event child (any class): %d", anyEvent))
    say(string.format("BaseParts with a BindableEvent Event: %d", #eventParts))

    for key, count in pairs(byKey) do
        say(string.format("  %-58s x%d", key, count))
    end

    local ch = LocalPlayer.Character
    local root = ch and ch:FindFirstChild("HumanoidRootPart")
    local pos = root and root.Position

    if pos then
        table.sort(eventParts, function(a, b)
            return (a.Position - pos).Magnitude < (b.Position - pos).Magnitude
        end)

        local limit = math.min(15, #eventParts)
        say(string.format("nearest %d trigger parts:", limit))
        for i = 1, limit do
            local p = eventParts[i]
            local dist = (p.Position - pos).Magnitude
            say(string.format("  %5.1f  %-34s  %s", dist, p.Name, p:GetFullName()))
        end
    else
        say("no HumanoidRootPart - spawn in before running this")
    end
else
    say("CurrentMap is nil - join a round first")
end

local wsdoors = {}
for _, c in ipairs(Workspace:GetChildren()) do
    if c.Name:lower():find("door") then
        wsdoors[#wsdoors + 1] = c.Name .. " (" .. c.ClassName .. ")"
    end
end
say("door-named Workspace children: " .. (#wsdoors > 0 and table.concat(wsdoors, ", ") or "none"))
say("ReplicatedStorage.RemoteEvent present: " .. tostring(RS:FindFirstChild("RemoteEvent") ~= nil))

local api = _G.__ftfDoors
if api then
    local okCount, count = pcall(function() return #api.Doors() end)
    say(string.format("doors.lua: triggers=%s fired=%s enabled=%s",
        tostring(okCount and count or "?"),
        tostring(api.Fired()),
        tostring(api.Config.Enabled)))
else
    say("doors.lua: NOT LOADED")
end

local text = table.concat(lines, "\n")
local copied = pcall(function() setclipboard(text) end)
if copied then
    print("[FTF-DOORPROBE] report copied to clipboard - Ctrl+V it in chat")
else
    print("[FTF-DOORPROBE] clipboard unavailable - copy the lines above")
end
