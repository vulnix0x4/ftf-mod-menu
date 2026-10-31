--!nocheck
--[[
    Flee the Facility - noclip

    Client-side collision bypass: every BasePart of your own character gets
    CanCollide = false while active. Locally this is invisible to the server and
    to other players; it just stops the local physics solver from pushing you
    out of walls. Original values are restored on toggle-off, respawn, or unload.

    Toggle with V (ignored while a TextBox has focus, and never while dead).

    API: _G.__ftfNoclip.Config / .IsOn() / .Set(bool) / .Toggle() / .Stop()
    Unload: _G.__ftfNoclipStop()
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Key     = Enum.KeyCode.V,
    Enabled = false,
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfNoclipInstance = INSTANCE_ID

local unloaded = false
local enabled  = false
local saved    = {}       -- [BasePart] = original CanCollide
local conns    = {}

local function character()
    return LocalPlayer.Character
end

local function restore()
    for part, value in pairs(saved) do
        if part.Parent then
            pcall(function() part.CanCollide = value end)
        end
    end
    table.clear(saved)
end

local function apply()
    local ch = character()
    if not ch then return end

    for _, inst in ipairs(ch:GetDescendants()) do
        if inst:IsA("BasePart") then
            if saved[inst] == nil then
                saved[inst] = inst.CanCollide
            end
            if inst.CanCollide then
                inst.CanCollide = false
            end
        end
    end
end

local function setState(state)
    if unloaded then return end
    enabled = state and true or false
    if enabled then
        apply()
    else
        restore()
    end
    print("[FTF-NOCLIP] " .. (enabled and "on" or "off"))
end

local function isTyping()
    local ok, box = pcall(function() return UserInputService:GetFocusedTextBox() end)
    return ok and box ~= nil
end

-- -------------------------------------------------------------------- loop

local unload   -- forward declaration: step's stale-instance guard calls it

local function step()
    if unloaded then return end

    if _G.__ftfNoclipInstance ~= INSTANCE_ID then
        unload()
        return
    end

    if enabled then
        local ch = character()
        local humanoid = ch and ch:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health > 0 then
            apply()
        end
    end
end

-- --------------------------------------------------------------- lifecycle

unload = function()
    if unloaded then return end
    unloaded = true
    restore()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    if _G.__ftfNoclipInstance == INSTANCE_ID then
        _G.__ftfNoclipInstance = nil
    end
    if _G.__ftfNoclipStop == unload then
        _G.__ftfNoclipStop = nil
        _G.__ftfNoclip = nil
    end
    print("[FTF-NOCLIP] unloaded")
end

_G.__ftfNoclipStop = unload

_G.__ftfNoclip = {
    Config = CONFIG,
    IsOn   = function() return enabled end,
    Set    = setState,
    Toggle = function() setState(not enabled) end,
    Stop   = function() unload() end,
}

conns[#conns + 1] = RunService.RenderStepped:Connect(step)

conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if unloaded then return end
    if input.KeyCode ~= CONFIG.Key then return end
    if gameProcessed and isTyping() then return end
    setState(not enabled)
end)

conns[#conns + 1] = LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.2)
    if enabled then
        table.clear(saved)
        apply()
    end
end)

print(string.format("[FTF-NOCLIP] loaded - %s toggles (off)", tostring(CONFIG.Key)))
