--!nocheck
--[[
    Flee the Facility - mod menu  (RightShift)

    Tabbed panel, CoreGui-only, no Drawing library.

        PLAYER   ESP overlay / computer markers / hide solved / beast alert / beast log
        MOVE     speed boost [Q] / multiplier / noclip [V] / teleport to computer [H]
        RESCUE   auto break-free / break now [T] / auto doors /
                 auto rescue / camp guard / teleport to frozen / free nearest [Y]
        SYSTEM   auto skillcheck / skillcheck snapshot / reload / unload

    Rows drive the modules through their _G APIs; a missing module is fetched from
    the local static server on first click. Toggle state resyncs from the live
    APIs ~10x per second, so keybinds and menu never disagree.

    Controls:
        RightShift   show / hide
        drag title   move panel (position persists in _G.__ftfMenuPos)
        _           minimise        x   close

    Unload: menu_unload.lua or _G.__ftfMenuStop().
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    Key        = Enum.KeyCode.RightShift,
    Width      = 302,
    TitleH     = 38,
    TabH       = 34,
    BodyH      = 324,
    FootH      = 40,
    Pad        = 10,
    BaseURL    = "http://127.0.0.1:8765/",
    RefreshHz  = 10,
    StartX     = 16,
    StartY     = 8,
    NoticeTime = 2.5,
}

local TOTAL_H = CONFIG.TitleH + CONFIG.TabH + CONFIG.BodyH + CONFIG.FootH

local THEME = {
    panel      = Color3.fromRGB(15, 16, 21),
    title      = Color3.fromRGB(20, 21, 28),
    tab        = Color3.fromRGB(17, 18, 24),
    card       = Color3.fromRGB(25, 26, 34),
    cardHover  = Color3.fromRGB(34, 36, 46),
    border     = Color3.fromRGB(45, 47, 60),
    text       = Color3.fromRGB(231, 232, 240),
    dim        = Color3.fromRGB(138, 141, 158),
    faint      = Color3.fromRGB(90, 93, 108),
    accent     = Color3.fromRGB(94, 231, 255),
    accentDim  = Color3.fromRGB(36, 86, 96),
    on         = Color3.fromRGB(125, 255, 168),
    off        = Color3.fromRGB(74, 76, 90),
    danger     = Color3.fromRGB(255, 107, 122),
    chip       = Color3.fromRGB(34, 36, 46),
}

local TABS = {
    { id = "player", label = "PLAYER" },
    { id = "move",   label = "MOVE" },
    { id = "rescue", label = "RESCUE" },
    { id = "system", label = "SYSTEM" },
}

local INSTANCE_ID = tostring(os.clock()) .. ":" .. tostring(math.random(1, 1e9))
_G.__ftfMenuInstance = INSTANCE_ID

local unloaded    = false
local refreshers  = {}
local connections = {}
local pages       = {}
local activeTab   = "player"
local minimized   = false
local tick        = 0
local gui, panel, tabBar, body, footerLabel, hintLabel, statusDot, minimizeBtn

local notice, noticeUntil = nil, 0
local pendingMultiplier = 2
local orderSeq = 0

-- ---------------------------------------------------------------- ui helpers

local function make(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props) do
        inst[k] = v
    end
    if parent then inst.Parent = parent end
    return inst
end

local function round(inst, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 6)
    c.Parent = inst
    return c
end

local function outline(inst, color, transparency)
    local s = Instance.new("UIStroke")
    s.Color        = color or THEME.border
    s.Thickness    = 1
    s.Transparency = transparency or 0.35
    s.Parent       = inst
    return s
end

local function order()
    orderSeq = orderSeq + 1
    return orderSeq
end

local function notify(text, isError)
    notice = text
    noticeUntil = os.clock() + CONFIG.NoticeTime
    if footerLabel then
        footerLabel.TextColor3 = isError and THEME.danger or THEME.accent
    end
end

-- ------------------------------------------------------------------ modules

local function httpGet(url)
    local ok, bodyText = pcall(function() return game:HttpGet(url) end)
    if ok and type(bodyText) == "string" and #bodyText > 0 then
        return bodyText
    end
    local ok2, body2 = pcall(function()
        return syn.request({ Url = url, Method = "GET" }).Body
    end)
    if ok2 and type(body2) == "string" and #body2 > 0 then
        return body2
    end
    return nil
end

local MODULE_DIR = "lua/modules/"

local function loadModule(name)
    local path = name
    if not string.find(name, "/", 1, true) then
        path = MODULE_DIR .. name
    end

    local src = httpGet(CONFIG.BaseURL .. path)
    if not src then return false, "fetch failed (server on 8765?)" end

    local fn, err = loadstring(src, "=" .. path)
    if not fn then return false, "compile: " .. tostring(err) end

    local ok, err2 = pcall(fn)
    if not ok then return false, tostring(err2) end
    return true
end

local function espCfg() return _G.__ftfESP end
local function speedApi() return _G.__ftfSpeed end
local function afApi() return _G.__ftfAntiFreeze end
local function reconApi() return _G.__ftfBeastRecon end
local function beastwatchApi() return _G.__ftfBeastwatch end
local function doorsApi() return _G.__ftfDoors end
local function noclipApi() return _G.__ftfNoclip end
local function rescueApi() return _G.__ftfRescue end
local function objectivesApi() return _G.__ftfObjectives end
local function probeApi() return _G.__ftfSkillProbe end
local function autoSkillApi() return _G.__ftfAutoSkill end

local function espFlagGet(key)
    local c = espCfg()
    if not c then return nil end
    return c[key] ~= false
end

local function espFlagSet(key, state)
    local c = espCfg()
    if not c then
        local ok, err = loadModule("esp.lua")
        if not ok then return false, err end
        c = espCfg()
    end
    if not c then return false, "esp module missing" end
    c[key] = state and true or false
    return true
end

local function espGet() return espFlagGet("Enabled") end
local function espSet(state) return espFlagSet("Enabled", state) end
local function espComputersGet() return espFlagGet("ShowComputers") end
local function espComputersSet(state) return espFlagSet("ShowComputers", state) end
local function espSolvedGet() return espFlagGet("HideSolved") end
local function espSolvedSet(state) return espFlagSet("HideSolved", state) end

local function speedGet()
    local api = speedApi()
    if not api then return nil end
    return api.IsBoosted()
end

local function speedSet(state)
    local api = speedApi()
    if not api then
        local ok, err = loadModule("speed.lua")
        if not ok then return false, err end
        api = speedApi()
    end
    if not api then return false, "speed module missing" end
    api.Config.Multiplier = pendingMultiplier
    api.Set(state and true or false)
    return true
end

local function multiplierGet()
    local api = speedApi()
    if api then return api.Config.Multiplier end
    return pendingMultiplier
end

local function multiplierSet(v)
    pendingMultiplier = v
    local api = speedApi()
    if api then api.Config.Multiplier = v end
end

local function noclipGet()
    local api = noclipApi()
    if not api then return nil end
    return api.IsOn()
end

local function noclipSet(state)
    local api = noclipApi()
    if not api then
        local ok, err = loadModule("noclip.lua")
        if not ok then return false, err end
        api = noclipApi()
    end
    if not api then return false, "noclip module missing" end
    api.Set(state and true or false)
    return true
end

local function afGet()
    local api = afApi()
    if not api then return nil end
    return api.Config.AutoRelease and true or false
end

local function afSet(state)
    local api = afApi()
    if not api then
        local ok, err = loadModule("antifreeze.lua")
        if not ok then return false, err end
        api = afApi()
    end
    if not api then return false, "antifreeze module missing" end
    api.Config.AutoRelease = state and true or false
    return true
end

local function breakFree()
    local api = afApi()
    if not api then
        local ok, err = loadModule("antifreeze.lua")
        if not ok then return false, err end
        api = afApi()
    end
    if not api then return false, "antifreeze module missing" end
    api.Release()
    notify("break free fired")
    return true
end

local function doorsGet()
    local api = doorsApi()
    if not api then return nil end
    return api.Config.Enabled and true or false
end

local function doorsSet(state)
    local api = doorsApi()
    if not api then
        local ok, err = loadModule("doors.lua")
        if not ok then return false, err end
        api = doorsApi()
    end
    if not api then return false, "doors module missing" end
    api.Set(state and true or false)
    return true
end

local function rescueGet()
    local api = rescueApi()
    if not api then return nil end
    return api.Config.AutoRescue and true or false
end

local function rescueSet(state)
    local api = rescueApi()
    if not api then
        local ok, err = loadModule("rescue.lua")
        if not ok then return false, err end
        api = rescueApi()
    end
    if not api then return false, "rescue module missing" end
    api.Config.AutoRescue = state and true or false
    return true
end

local function campGet()
    local api = rescueApi()
    if not api then return nil end
    return api.Config.CampGuard and true or false
end

local function campSet(state)
    local api = rescueApi()
    if not api then
        local ok, err = loadModule("rescue.lua")
        if not ok then return false, err end
        api = rescueApi()
    end
    if not api then return false, "rescue module missing" end
    api.Config.CampGuard = state and true or false
    return true
end

local function rescueTeleport()
    local api = rescueApi()
    if not api then
        local ok, err = loadModule("rescue.lua")
        if not ok then return false, err end
        api = rescueApi()
    end
    if not api then return false, "rescue module missing" end

    local target, err = api.TeleportNearest()
    if not target then return false, err or "no frozen teammate" end
    notify("tp -> " .. target.player.Name)
    return true
end

local function rescueFree()
    local api = rescueApi()
    if not api then
        local ok, err = loadModule("rescue.lua")
        if not ok then return false, err end
        api = rescueApi()
    end
    if not api then return false, "rescue module missing" end

    local target, err = api.FreeNearest()
    if not target then return false, err or "no frozen teammate" end
    notify("rescue fired -> " .. target.player.Name)
    return true
end

local function beastwatchGet()
    local api = beastwatchApi()
    if not api then return nil end
    return api.Config.Enabled and true or false
end

local function beastwatchSet(state)
    local api = beastwatchApi()
    if not api then
        local ok, err = loadModule("beastwatch.lua")
        if not ok then return false, err end
        api = beastwatchApi()
    end
    if not api then return false, "beastwatch module missing" end
    api.Config.Enabled = state and true or false
    return true
end

local function reconGet()
    local api = reconApi()
    if not api then return nil end
    return api.Config and api.Config.ShowPanel or false
end

local function reconSet(state)
    local api = reconApi()
    if not api then
        local ok, err = loadModule("beast_recon.lua")
        if not ok then return false, err end
        api = reconApi()
    end
    if not api then return false, "recon module missing" end
    api.Show(state and true or false)
    return true
end

local function teleportComputer()
    local api = objectivesApi()
    if not api then
        local ok, err = loadModule("objectives.lua")
        if not ok then return false, err end
        api = objectivesApi()
    end
    if not api then return false, "objectives module missing" end

    local target, err = api.TeleportNearest()
    if not target then return false, err or "no unsolved computer" end
    notify(string.format("tp -> computer (%.0f studs)", target.dist or 0))
    return true
end

local function autoSkillGet()
    local api = autoSkillApi()
    if not api then return nil end
    return api.Config.Enabled and true or false
end

local function autoSkillSet(state)
    local api = autoSkillApi()
    if not api then
        local ok, err = loadModule("skillcheck.lua")
        if not ok then return false, err end
        api = autoSkillApi()
    end
    if not api then return false, "skillcheck module missing" end
    api.Config.Enabled = state and true or false
    return true
end

local function probeCall(method, ...)
    local api = probeApi()
    if not api then
        local ok, err = loadModule("skillcheck_probe.lua")
        if not ok then return false, err end
        api = probeApi()
    end
    if not api then return false, "skillcheck probe missing" end
    return api[method](...)
end

local function skillSnapshot()
    local ok, err = probeCall("Snapshot")
    if ok == false then return false, err end
    notify("skillcheck snapshot printed")
    return true
end

local function reloadModules()
    local orderList = { "esp.lua", "speed.lua", "antifreeze.lua", "rescue.lua",
                        "doors.lua", "noclip.lua", "objectives.lua", "beast_recon.lua",
                        "beastwatch.lua", "skillcheck_probe.lua", "skillcheck.lua" }
    local okCount, lastErr = 0, nil
    for _, name in ipairs(orderList) do
        local ok, err = loadModule(name)
        if ok then okCount = okCount + 1 else lastErr = name .. ": " .. tostring(err) end
    end
    if okCount == #orderList then
        notify("modules reloaded")
        return true
    end
    return false, lastErr or "reload failed"
end

local function unloadTools()
    local names = {
        { "esp", _G.__ftfESPStop },
        { "speed", _G.__ftfSpeedStop },
        { "antifreeze", _G.__ftfAntiFreezeStop },
        { "rescue", _G.__ftfRescueStop },
        { "doors", _G.__ftfDoorsStop },
        { "noclip", _G.__ftfNoclipStop },
        { "objectives", _G.__ftfObjectivesStop },
        { "recon", _G.__ftfBeastReconStop },
        { "beastwatch", _G.__ftfBeastwatchStop },
        { "skillprobe", _G.__ftfSkillProbeStop },
        { "autoskill", _G.__ftfAutoSkillStop },
    }
    local n = 0
    for _, entry in ipairs(names) do
        if entry[2] then
            pcall(entry[2])
            n = n + 1
        end
    end
    notify(string.format("tools unloaded (%d)", n))
    return true
end

-- ------------------------------------------------------------------ ui rows

local function sectionLabel(parent, text)
    local row = make("Frame", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
    }, parent)

    make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 2, 0, 0),
        Size = UDim2.new(0, 110, 1, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = THEME.faint,
        Text = text,
    }, row)

    make("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -2, 0.5, 0),
        Size = UDim2.new(1, -118, 0, 1),
        BackgroundColor3 = THEME.border,
        BorderSizePixel = 0,
        BackgroundTransparency = 0.45,
    }, row)

    return row
end

local function cardRow(parent, text, keyText)
    local r = make("Frame", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        LayoutOrder = order(),
    }, parent)
    round(r, 6)
    outline(r, THEME.border, 0.45)

    local dot = make("Frame", {
        Size = UDim2.fromOffset(6, 6),
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 11, 0.5, 0),
        BackgroundColor3 = THEME.off,
        BorderSizePixel = 0,
    }, r)
    round(dot, 3)

    local lbl = make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 25, 0, 0),
        Size = UDim2.new(1, -84, 1, 0),
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        TextColor3 = THEME.text,
        Text = text,
    }, r)

    local key = nil
    if keyText then
        key = make("Frame", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -48, 0.5, 0),
            Size = UDim2.fromOffset(22, 18),
            BackgroundColor3 = THEME.chip,
            BorderSizePixel = 0,
        }, r)
        round(key, 4)
        make("TextLabel", {
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 1, 0),
            Font = Enum.Font.GothamBold,
            TextSize = 9,
            TextColor3 = THEME.dim,
            Text = keyText,
        }, key)
    end

    return r, dot, lbl, key
end

local function attachRowHit(r)
    local hit = make("TextButton", {
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0),
        Text = "",
        AutoButtonColor = false,
    }, r)

    hit.MouseEnter:Connect(function() r.BackgroundColor3 = THEME.cardHover end)
    hit.MouseLeave:Connect(function() r.BackgroundColor3 = THEME.card end)
    return hit
end

local function toggleRow(parent, text, getter, setter, keyText)
    local r, dot, lbl = cardRow(parent, text, keyText)

    local pill = make("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -9, 0.5, 0),
        Size = UDim2.fromOffset(36, 18),
        BackgroundColor3 = THEME.off,
        BorderSizePixel = 0,
    }, r)
    round(pill, 9)

    local knob = make("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 3, 0.5, 0),
        Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
    }, pill)
    round(knob, 7)

    local state = false
    local function paint(on)
        state = on and true or false
        pill.BackgroundColor3 = state and THEME.accent or THEME.off
        knob.Position = state and UDim2.new(0, 19, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
        dot.BackgroundColor3 = state and THEME.on or THEME.off
        lbl.TextColor3 = state and THEME.text or THEME.dim
    end

    local hit = attachRowHit(r)
    hit.MouseButton1Click:Connect(function()
        local nextState = not state
        local ok, err = true, nil
        if setter then
            local called, a, b = pcall(setter, nextState)
            if called then ok, err = a, b else ok, err = false, a end
        end
        if ok == false then
            notify(tostring(err or "failed"), true)
            return
        end
        paint(nextState)
    end)

    table.insert(refreshers, function()
        if getter then
            local v = getter()
            if v ~= nil then paint(v) end
        end
    end)

    return paint
end

local function buttonRow(parent, text, keyText, onClick)
    local r, dot, lbl = cardRow(parent, text, keyText)
    dot.BackgroundColor3 = THEME.accentDim

    local chip = make("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -9, 0.5, 0),
        Size = UDim2.fromOffset(32, 18),
        BackgroundColor3 = THEME.chip,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 8,
        TextColor3 = THEME.accent,
        Text = "RUN",
    }, r)
    round(chip, 4)

    local hit = attachRowHit(r)
    hit.MouseButton1Click:Connect(function()
        chip.TextColor3 = THEME.text
        local called, ok, err = pcall(onClick)
        if not called then ok, err = false, ok end
        if ok == false then
            notify(tostring(err or "failed"), true)
            chip.TextColor3 = THEME.danger
        else
            chip.TextColor3 = THEME.accent
        end
    end)

    return chip
end

local function sliderRow(parent, text, min, max, step, getter, setter)
    local r = make("Frame", {
        Size = UDim2.new(1, 0, 0, 46),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        LayoutOrder = order(),
    }, parent)
    round(r, 6)
    outline(r, THEME.border, 0.45)

    make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 12, 0, 4),
        Size = UDim2.new(0.6, -12, 0, 18),
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = THEME.text,
        Text = text,
    }, r)

    local valueLabel = make("TextLabel", {
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -12, 0, 4),
        Size = UDim2.new(0.4, -12, 0, 18),
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextColor3 = THEME.accent,
        Text = string.format("%.1fx", getter and getter() or min),
    }, r)

    local track = make("Frame", {
        Position = UDim2.new(0, 12, 0, 32),
        Size = UDim2.new(1, -24, 0, 5),
        BackgroundColor3 = THEME.off,
        BorderSizePixel = 0,
    }, r)
    round(track, 3)

    local fill = make("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
    }, track)
    round(fill, 3)

    local knob = make("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        Size = UDim2.fromOffset(12, 12),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        ZIndex = 2,
    }, track)
    round(knob, 6)

    local current = getter and getter() or min

    local function paint(v)
        current = v
        local frac = 0
        if max > min then frac = math.clamp((v - min) / (max - min), 0, 1) end
        fill.Size = UDim2.new(frac, 0, 1, 0)
        knob.Position = UDim2.new(frac, 0, 0.5, 0)
        valueLabel.Text = string.format("%.1fx", v)
    end

    local function applyFromX(x)
        local abs = track.AbsolutePosition.X
        local w = track.AbsoluteSize.X
        if w <= 0 then return end
        local frac = math.clamp((x - abs) / w, 0, 1)
        local raw = min + (max - min) * frac
        local v = math.clamp(math.floor(raw / step + 0.5) * step, min, max)
        paint(v)
        if setter then setter(v) end
    end

    local dragging = false
    local hit = make("TextButton", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 6, 0, 24),
        Size = UDim2.new(1, -12, 0, 20),
        Text = "",
        AutoButtonColor = false,
    }, r)

    hit.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = true
        applyFromX(input.Position.X)
    end)

    table.insert(connections, UserInputService.InputChanged:Connect(function(input)
        if not dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        applyFromX(input.Position.X)
    end))

    table.insert(connections, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end))

    paint(current)

    table.insert(refreshers, function()
        if not dragging and getter then
            local v = getter()
            if v ~= nil and math.abs(v - current) > 0.001 then paint(v) end
        end
    end)

    return paint
end

-- -------------------------------------------------------------------- panel

local function makePanel()
    local ok, core = pcall(function() return game:GetService("CoreGui") end)

    local g = make("ScreenGui", {
        Name = "FTF_MENU",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 200,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    g.Parent = (ok and core) or LocalPlayer:WaitForChild("PlayerGui")

    local saved = _G.__ftfMenuPos
    local p = make("Frame", {
        Name = "Panel",
        Position = UDim2.fromOffset(
            saved and saved.X or CONFIG.StartX,
            saved and saved.Y or CONFIG.StartY),
        Size = UDim2.fromOffset(CONFIG.Width, TOTAL_H),
        BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, g)
    round(p, 10)
    outline(p, THEME.border, 0.25)

    -- accent hairline
    make("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = THEME.accent,
        BackgroundTransparency = 0.35,
        BorderSizePixel = 0,
    }, p)

    -- title bar
    local bar = make("Frame", {
        Name = "TitleBar",
        Size = UDim2.new(1, 0, 0, CONFIG.TitleH),
        BackgroundColor3 = THEME.title,
        BorderSizePixel = 0,
    }, p)

    statusDot = make("Frame", {
        Size = UDim2.fromOffset(7, 7),
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 13, 0.5, 0),
        BackgroundColor3 = THEME.on,
        BorderSizePixel = 0,
    }, bar)
    round(statusDot, 4)

    make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 26, 0, 2),
        Size = UDim2.new(0, 36, 1, 0),
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = THEME.accent,
        Text = "FTF",
    }, bar)

    make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 62, 0, 3),
        Size = UDim2.new(1, -130, 1, 0),
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = THEME.faint,
        Text = "flee the facility",
    }, bar)

    make("TextLabel", {
        BackgroundTransparency = 1,
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -74, 0.5, 0),
        Size = UDim2.fromOffset(30, 16),
        Font = Enum.Font.GothamBold,
        TextSize = 8,
        TextColor3 = THEME.dim,
        Text = "v2",
    }, bar)

    minimizeBtn = make("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -34, 0.5, 0),
        Size = UDim2.fromOffset(22, 22),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = THEME.dim,
        Text = "_",
        ZIndex = 5,
    }, bar)

    local close = make("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.fromOffset(22, 22),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = THEME.dim,
        Text = "x",
        ZIndex = 5,
    }, bar)

    local dragHit = make("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, bar)

    -- tabs
    tabBar = make("Frame", {
        Name = "Tabs",
        Position = UDim2.fromOffset(0, CONFIG.TitleH),
        Size = UDim2.new(1, 0, 0, CONFIG.TabH),
        BackgroundColor3 = THEME.tab,
        BorderSizePixel = 0,
    }, p)
    make("UIPadding", {
        PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 8),
        PaddingTop = UDim.new(0, 4),
        PaddingBottom = UDim.new(0, 0),
    }, tabBar)
    make("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, tabBar)

    pages = {}

    for _, def in ipairs(TABS) do
        local btn = make("TextButton", {
            Size = UDim2.new(0.25, -3, 1, -4),
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Font = Enum.Font.GothamBold,
            TextSize = 9,
            TextColor3 = THEME.faint,
            Text = def.label,
        }, tabBar)

        local underline = make("Frame", {
            Size = UDim2.new(1, -8, 0, 2),
            Position = UDim2.new(0, 4, 1, -2),
            BackgroundColor3 = THEME.accent,
            BorderSizePixel = 0,
            Visible = false,
        }, btn)
        round(underline, 1)

        pages[def.id] = { tab = btn, underline = underline, page = nil }
    end

    -- body
    body = make("Frame", {
        Name = "Body",
        Position = UDim2.fromOffset(0, CONFIG.TitleH + CONFIG.TabH),
        Size = UDim2.new(1, 0, 0, CONFIG.BodyH),
        BackgroundTransparency = 1,
    }, p)

    for _, def in ipairs(TABS) do
        local page = make("Frame", {
            Name = def.id,
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Visible = false,
        }, body)
        make("UIPadding", {
            PaddingLeft = UDim.new(0, CONFIG.Pad),
            PaddingRight = UDim.new(0, CONFIG.Pad),
            PaddingTop = UDim.new(0, 9),
            PaddingBottom = UDim.new(0, 8),
        }, page)
        make("UIListLayout", {
            Padding = UDim.new(0, 5),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }, page)
        pages[def.id].page = page
    end

    -- footer
    local foot = make("Frame", {
        Name = "Footer",
        Position = UDim2.fromOffset(0, TOTAL_H - CONFIG.FootH),
        Size = UDim2.new(1, 0, 0, CONFIG.FootH),
        BackgroundColor3 = THEME.title,
        BorderSizePixel = 0,
    }, p)
    make("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = THEME.border,
        BackgroundTransparency = 0.4,
        BorderSizePixel = 0,
    }, foot)

    footerLabel = make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 11, 0, 3),
        Size = UDim2.new(1, -22, 0, 14),
        Font = Enum.Font.GothamMedium,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = THEME.dim,
        Text = "loading...",
    }, foot)

    hintLabel = make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 11, 0, 18),
        Size = UDim2.new(1, -22, 0, 13),
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = THEME.faint,
        Text = "Q speed   V noclip   Y free   T escape   H computer",
    }, foot)

    -- drag
    local dragStart, startPos

    dragHit.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        dragStart = Vector2.new(input.Position.X, input.Position.Y)
        startPos = Vector2.new(p.Position.X.Offset, p.Position.Y.Offset)
    end)

    table.insert(connections, UserInputService.InputChanged:Connect(function(input)
        if not dragStart or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local d = Vector2.new(input.Position.X, input.Position.Y) - dragStart
        local vp = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
        local pos = startPos + d
        pos = Vector2.new(
            math.clamp(pos.X, -(CONFIG.Width - 70), vp.X - 70),
            math.clamp(pos.Y, 0, vp.Y - CONFIG.TitleH))
        p.Position = UDim2.fromOffset(pos.X, pos.Y)
        _G.__ftfMenuPos = pos
    end))

    table.insert(connections, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragStart = nil
        end
    end))

    close.MouseButton1Click:Connect(function()
        p.Visible = false
    end)

    return g, p, tabBar, body, footerLabel, hintLabel
end

-- ------------------------------------------------------------------- pages

local function buildPages()
    orderSeq = 0

    local playerPage = pages.player.page
    sectionLabel(playerPage, "VISION")
    toggleRow(playerPage, "ESP overlay", espGet, espSet)
    toggleRow(playerPage, "Computer markers", espComputersGet, espComputersSet)
    toggleRow(playerPage, "Hide solved computers", espSolvedGet, espSolvedSet)
    sectionLabel(playerPage, "BEAST")
    toggleRow(playerPage, "Beast alert", beastwatchGet, beastwatchSet)
    toggleRow(playerPage, "Beast log panel", reconGet, reconSet)

    local movePage = pages.move.page
    sectionLabel(movePage, "MOVEMENT")
    toggleRow(movePage, "Speed boost", speedGet, speedSet, "Q")
    sliderRow(movePage, "Speed multiplier", 1.5, 5, 0.5, multiplierGet, multiplierSet)
    sectionLabel(movePage, "MOBILITY")
    toggleRow(movePage, "Noclip", noclipGet, noclipSet, "V")
    buttonRow(movePage, "Teleport to nearest computer", "H", teleportComputer)

    local rescuePage = pages.rescue.page
    sectionLabel(rescuePage, "SELF")
    toggleRow(rescuePage, "Auto break-free", afGet, afSet)
    buttonRow(rescuePage, "Break free now", "T", breakFree)
    sectionLabel(rescuePage, "TEAM")
    toggleRow(rescuePage, "Auto rescue nearby", rescueGet, rescueSet)
    toggleRow(rescuePage, "Camp guard (auto-free)", campGet, campSet)
    buttonRow(rescuePage, "Teleport to frozen", "TP", rescueTeleport)
    buttonRow(rescuePage, "Free nearest frozen", "Y", rescueFree)
    sectionLabel(rescuePage, "WORLD")
    toggleRow(rescuePage, "Auto doors", doorsGet, doorsSet)

    local systemPage = pages.system.page
    sectionLabel(systemPage, "SKILLCHECK")
    toggleRow(systemPage, "Auto skillcheck", autoSkillGet, autoSkillSet)
    buttonRow(systemPage, "Dump skillcheck tree", "LOG", skillSnapshot)
    sectionLabel(systemPage, "SUITE")
    buttonRow(systemPage, "Reload modules", "LOAD", reloadModules)
    buttonRow(systemPage, "Unload tools", "STOP", unloadTools)
end

-- --------------------------------------------------------------- tab logic

local function selectTab(id)
    if not pages[id] then return end
    activeTab = id

    for tabId, entry in pairs(pages) do
        local active = tabId == id
        if entry.page then entry.page.Visible = active end
        entry.tab.TextColor3 = active and THEME.accent or THEME.faint
        entry.underline.Visible = active
    end
end

local function setMinimized(state)
    minimized = state and true or false
    if not panel then return end

    panel.Size = UDim2.fromOffset(CONFIG.Width, minimized and CONFIG.TitleH or TOTAL_H)
    tabBar.Visible = not minimized
    body.Visible = not minimized
    if footerLabel and footerLabel.Parent then footerLabel.Parent.Visible = not minimized end
    minimizeBtn.Text = minimized and "+" or "_"
end

-- ----------------------------------------------------------------- refresh

local function loadedTag(api)
    return api and "+" or "-"
end

local function refresh()
    for _, fn in ipairs(refreshers) do
        pcall(fn)
    end

    local esp = espCfg()
    local spd = speedApi()
    local af  = afApi()

    local espText = "esp -"
    if esp then espText = (esp.Enabled ~= false) and "esp ON" or "esp off" end

    local spdText = "spd -"
    if spd then
        spdText = string.format("%.1fx%s", spd.Config.Multiplier, spd.IsBoosted() and " ON" or "")
    end

    local afText = "af -"
    if af then afText = af.Config.AutoRelease and "af auto" or "af key" end

    local main = string.format("%s   %s   %s   %s%s%s",
        espText, spdText, afText,
        loadedTag(doorsApi()), loadedTag(rescueApi()), loadedTag(autoSkillApi()))

    if notice and os.clock() < noticeUntil then
        main = notice
    elseif notice then
        notice = nil
        footerLabel.TextColor3 = THEME.dim
    end
    footerLabel.Text = main

    if statusDot then
        local core = (esp and 1 or 0) + (spd and 1 or 0) + (af and 1 or 0)
        statusDot.BackgroundColor3 = core >= 3 and THEME.on
            or (core > 0 and THEME.accent or THEME.danger)
    end
end

-- ------------------------------------------------------------------ keybind

local function isTyping()
    local ok, box = pcall(function() return UserInputService:GetFocusedTextBox() end)
    return ok and box ~= nil
end

table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if unloaded then return end
    if input.KeyCode ~= CONFIG.Key then return end
    if gameProcessed and isTyping() then return end

    if not panel or not panel.Parent then
        build()
        panel.Visible = true
        return
    end

    panel.Visible = not panel.Visible
end))

-- --------------------------------------------------------------- lifecycle

local function build()
    table.clear(refreshers)
    orderSeq = 0
    if gui then pcall(function() gui:Destroy() end) end

    gui, panel, tabBar, body, footerLabel, hintLabel = makePanel()
    buildPages()

    for id, entry in pairs(pages) do
        local tabId = id
        entry.tab.MouseButton1Click:Connect(function()
            selectTab(tabId)
        end)
    end

    selectTab(activeTab)
    setMinimized(minimized)
end

local unload

local function step()
    if unloaded then return end

    if _G.__ftfMenuInstance ~= INSTANCE_ID then
        unload()
        return
    end

    if not gui or not gui.Parent then
        build()
    end

    tick = tick + 1
    if tick % 6 == 0 then
        refresh()
    end
end

unload = function()
    if unloaded then return end
    unloaded = true
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    table.clear(connections)
    table.clear(refreshers)
    if gui then pcall(function() gui:Destroy() end) end
    if _G.__ftfMenuInstance == INSTANCE_ID then
        _G.__ftfMenuInstance = nil
    end
    if _G.__ftfMenuStop == unload then
        _G.__ftfMenuStop = nil
        _G.__ftfMenu = nil
    end
    print("[FTF-MENU] unloaded")
end

_G.__ftfMenuStop = unload

_G.__ftfMenu = {
    Config = CONFIG,
    Show   = function(state) if panel then panel.Visible = state and true or false end end,
    Toggle = function() if panel then panel.Visible = not panel.Visible end end,
    Tab    = selectTab,
    Load   = loadModule,
    Stop   = function() unload() end,
}

build()
refresh()

_G.__ftfMenuTick = RunService.Heartbeat:Connect(step)
table.insert(connections, _G.__ftfMenuTick)

print(string.format("[FTF-MENU] loaded - %s toggles the menu", tostring(CONFIG.Key)))
