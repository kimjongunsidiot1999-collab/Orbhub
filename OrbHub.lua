--[[
    ORB HUB
    ─────────────────────────────────────
    Merged: Rose sync engine (best channel pull)
          + XEN PlaceId spoof + invis/lagback
          + Heresy priority + clean mobile UI
    drag panels · mobile first · no logo trash
]]

if not game:IsLoaded() then game.Loaded:Wait() end

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")
local TS                = game:GetService("TweenService")
local HS                = game:GetService("HttpService")
local RS                = game:GetService("ReplicatedStorage")
local TeleportService   = game:GetService("TeleportService")
local LP                = Players.LocalPlayer

-- ═══════════════════════════════════════
-- CONFIG
-- ═══════════════════════════════════════
local CFG_FILE = "OrbHub.json"

local function loadCfg()
    local d = {}
    if type(isfile) == "function" and isfile(CFG_FILE) then
        pcall(function()
            local t = HS:JSONDecode(readfile(CFG_FILE))
            if type(t) == "table" then d = t end
        end)
    end
    return d
end

local function saveCfg(data)
    if type(writefile) == "function" then
        pcall(function() writefile(CFG_FILE, HS:JSONEncode(data)) end)
    end
end

local cfg = loadCfg()

_G.OrbHub = _G.OrbHub or {}
local OH = _G.OrbHub

OH.InvisAngle         = cfg.InvisAngle or 225
OH.SinkDepth          = cfg.SinkDepth or 8
OH.AutoInvisOnSteal   = cfg.AutoInvisOnSteal or false
OH.AutoRecoverLagback = cfg.AutoRecoverLagback ~= false
OH.Walkspeed          = cfg.Walkspeed or 28
OH.WalkspeedEnabled   = cfg.WalkspeedEnabled ~= false
OH.PriorityList       = cfg.PriorityList or {}
OH.MutationPriority   = cfg.MutationPriority or {}
OH.AutoTP             = cfg.AutoTP ~= false
OH.FOV                = cfg.FOV or 70
OH.UIVisible          = true
OH.invisibleStealEnabled = false

local function persist()
    saveCfg({
        InvisAngle         = OH.InvisAngle,
        SinkDepth          = OH.SinkDepth,
        AutoInvisOnSteal   = OH.AutoInvisOnSteal,
        AutoRecoverLagback = OH.AutoRecoverLagback,
        Walkspeed          = OH.Walkspeed,
        WalkspeedEnabled   = OH.WalkspeedEnabled,
        PriorityList       = OH.PriorityList,
        MutationPriority   = OH.MutationPriority,
        AutoTP             = OH.AutoTP,
        FOV                = OH.FOV,
    })
end

-- ═══════════════════════════════════════
-- PLACEID SPOOF (XEN)
-- ═══════════════════════════════════════
local XEN_PLACE = 109983668079237
if game.PlaceId ~= XEN_PLACE then
    pcall(function()
        local old
        old = hookmetamethod(game, "__index", newcclosure(function(self, key)
            if key == "PlaceId" and self == game then
                return XEN_PLACE
            end
            return old(self, key)
        end))
    end)
end

-- ═══════════════════════════════════════
-- SYNCHRONIZER / CHANNEL SCAN (Rose path)
-- ═══════════════════════════════════════
local chanTable = {}
local function getPackages()
    return RS:FindFirstChild("Packages") or RS:WaitForChild("Packages", 10)
end

local function pullPlot(name)
    local pk = getPackages()
    local sy = pk and pk:FindFirstChild("Synchronizer")
    local rf = sy and sy:FindFirstChild("RequestData")
    if not rf or not rf:IsA("RemoteFunction") then return nil end
    local ok, res = pcall(function()
        return rf:InvokeServer(name)
    end)
    if ok and type(res) == "table" then
        chanTable[name] = res
        return res
    end
    return nil
end

local function animalsOf(ct)
    if type(ct) ~= "table" then return nil end
    return rawget(ct, "AnimalList") or rawget(ct, "Animals")
end

local function ownerName(o)
    if o == nil then return nil end
    if typeof(o) == "Instance" then return o.Name end
    if type(o) == "table" then return o.Name end
    if type(o) == "string" and o ~= "" and o ~= "..." then return o end
    return nil
end

local function scanAllAnimals()
    local out = {}
    local plots = workspace:FindFirstChild("Plots")
    if not plots then return out end

    for _, plot in ipairs(plots:GetChildren()) do
        local ct = chanTable[plot.Name]
        if not ct then
            ct = pullPlot(plot.Name)
        end
        if type(ct) == "table" then
            local al = animalsOf(ct)
            local owner = ownerName(rawget(ct, "Owner"))
            if type(al) == "table" then
                for slot, animal in pairs(al) do
                    if type(animal) == "table" and animal.Index then
                        local gen = 0
                        pcall(function()
                            if _G._xenGen then
                                gen = _G._xenGen(animal.Index, animal.Mutation, animal.Traits) or 0
                            elseif _G.JAF_SafeGen then
                                gen = _G.JAF_SafeGen(animal.Index, animal.Mutation, animal.Traits) or 0
                            end
                        end)
                        table.insert(out, {
                            name     = animal.Index,
                            mutation = animal.Mutation,
                            traits   = animal.Traits,
                            gen      = gen,
                            owner    = owner,
                            plot     = plot.Name,
                            slot     = tostring(slot),
                            uid      = plot.Name .. "_" .. tostring(slot),
                        })
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.gen or 0) > (b.gen or 0) end)
    return out
end

-- warm pull
task.spawn(function()
    local plots = workspace:WaitForChild("Plots", 12)
    if not plots then return end
    for _, p in ipairs(plots:GetChildren()) do
        task.spawn(pullPlot, p.Name)
    end
    plots.ChildAdded:Connect(function(p)
        task.wait(0.4)
        pullPlot(p.Name)
    end)
end)

-- ═══════════════════════════════════════
-- INVISIBLE STEAL CORE (XEN + Heresy hybrid)
-- ═══════════════════════════════════════
local invisConn, cloneRoot
local function cleanupInvis()
    if invisConn then pcall(function() invisConn:Disconnect() end) invisConn = nil end
    if cloneRoot then pcall(function() cloneRoot:Destroy() end) cloneRoot = nil end
    OH.invisibleStealEnabled = false
end

local function enableInvisibleSteal()
    if OH.invisibleStealEnabled then return end
    local char = LP.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return end

    OH.invisibleStealEnabled = true

    cloneRoot = Instance.new("Part")
    cloneRoot.Name = "OrbInvisRoot"
    cloneRoot.Size = Vector3.new(2, 2, 1)
    cloneRoot.Transparency = 1
    cloneRoot.CanCollide = false
    cloneRoot.Anchored = false
    cloneRoot.CFrame = hrp.CFrame
    cloneRoot.Parent = workspace.CurrentCamera

    local angle = math.rad(OH.InvisAngle or 225)
    local sink  = (OH.SinkDepth or 8) * 0.5

    invisConn = RunService.Heartbeat:Connect(function()
        if not OH.invisibleStealEnabled or not char.Parent or not hrp.Parent then
            cleanupInvis()
            return
        end
        local targetCF = hrp.CFrame - Vector3.new(0, sink, 0)
        targetCF = targetCF * CFrame.Angles(angle, 0, 0)
        if cloneRoot and cloneRoot.Parent then
            cloneRoot.CFrame = targetCF
            cloneRoot.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity
        end
        pcall(function()
            hrp.CanCollide = false
        end)
    end)
end

local function disableInvisibleSteal()
    cleanupInvis()
    local char = LP.Character
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then
            pcall(function() hrp.CanCollide = true end)
        end
    end
end

_G.toggleInvisibleSteal = function()
    if OH.invisibleStealEnabled then
        disableInvisibleSteal()
    else
        enableInvisibleSteal()
    end
end

-- auto invis on steal attribute
task.spawn(function()
    LP:GetAttributeChangedSignal("Stealing"):Connect(function()
        if LP:GetAttribute("Stealing") then
            if OH.AutoInvisOnSteal and not OH.invisibleStealEnabled then
                pcall(_G.toggleInvisibleSteal)
            end
        else
            if OH.AutoInvisOnSteal and OH.invisibleStealEnabled then
                pcall(_G.toggleInvisibleSteal)
            end
        end
    end)
end)

LP.CharacterAdded:Connect(function()
    cleanupInvis()
end)

-- ═══════════════════════════════════════
-- UI COLORS
-- ═══════════════════════════════════════
local C = {
    BG      = Color3.fromRGB(10, 12, 18),
    PANEL   = Color3.fromRGB(16, 18, 26),
    ROW     = Color3.fromRGB(26, 28, 38),
    BTN     = Color3.fromRGB(36, 40, 54),
    ACCENT  = Color3.fromRGB(0, 190, 255),
    ACCENT2 = Color3.fromRGB(80, 220, 255),
    TEXT    = Color3.fromRGB(235, 240, 255),
    MUTED   = Color3.fromRGB(130, 145, 170),
    DANGER  = Color3.fromRGB(230, 70, 95),
    GREEN   = Color3.fromRGB(40, 210, 130),
}

local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 10)
    c.Parent = inst
    return c
end

local function stroke(inst, col, thick)
    local s = Instance.new("UIStroke")
    s.Color = col or Color3.fromRGB(40, 55, 80)
    s.Thickness = thick or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = inst
    return s
end

local function pad(inst, l, t, r, b)
    local p = Instance.new("UIPadding")
    p.PaddingLeft   = UDim.new(0, l or 0)
    p.PaddingTop    = UDim.new(0, t or 0)
    p.PaddingRight  = UDim.new(0, r or 0)
    p.PaddingBottom = UDim.new(0, b or 0)
    p.Parent = inst
    return p
end

-- ═══════════════════════════════════════
-- MAIN GUI (no logo)
-- ═══════════════════════════════════════
local parentGui = (gethui and gethui()) or game:GetService("CoreGui") or LP:WaitForChild("PlayerGui")

pcall(function()
    local old = parentGui:FindFirstChild("OrbHub")
    if old then old:Destroy() end
end)

local mainSG = Instance.new("ScreenGui")
mainSG.Name = "OrbHub"
mainSG.ResetOnSpawn = false
mainSG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
mainSG.IgnoreGuiInset = true
mainSG.DisplayOrder = 999999
mainSG.Parent = parentGui

-- main panel
local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.Size = UDim2.fromOffset(300, 460)
panel.Position = UDim2.new(0.5, -150, 0.5, -230)
panel.BackgroundColor3 = C.PANEL
panel.BorderSizePixel = 0
panel.Visible = true
panel.ClipsDescendants = true
panel.Parent = mainSG
corner(panel, 16)
stroke(panel, Color3.fromRGB(30, 45, 70), 1.4)

-- header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 46)
header.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
header.BorderSizePixel = 0
header.Parent = panel
corner(header, 16)

local accentBar = Instance.new("Frame")
accentBar.Size = UDim2.new(0, 4, 1, -16)
accentBar.Position = UDim2.fromOffset(10, 8)
accentBar.BackgroundColor3 = C.ACCENT
accentBar.BorderSizePixel = 0
accentBar.Parent = header
corner(accentBar, 2)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -70, 1, 0)
title.Position = UDim2.fromOffset(22, 0)
title.BackgroundTransparency = 1
title.Text = "ORB HUB"
title.Font = Enum.Font.GothamBlack
title.TextSize = 17
title.TextColor3 = C.ACCENT2
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(30, 30)
closeBtn.Position = UDim2.new(1, -38, 0.5, -15)
closeBtn.BackgroundColor3 = C.BTN
closeBtn.Text = "×"
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 18
closeBtn.TextColor3 = C.MUTED
closeBtn.AutoButtonColor = false
closeBtn.Parent = header
corner(closeBtn, 8)

-- minimize / reopen button (small top-left after close)
local miniBtn = Instance.new("TextButton")
miniBtn.Size = UDim2.fromOffset(30, 30)
miniBtn.Position = UDim2.new(1, -74, 0.5, -15)
miniBtn.BackgroundColor3 = C.BTN
miniBtn.Text = "–"
miniBtn.Font = Enum.Font.GothamBold
miniBtn.TextSize = 18
miniBtn.TextColor3 = C.MUTED
miniBtn.AutoButtonColor = false
miniBtn.Parent = header
corner(miniBtn, 8)

-- body scroll
local body = Instance.new("ScrollingFrame")
body.Size = UDim2.new(1, -16, 1, -58)
body.Position = UDim2.fromOffset(8, 52)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 3
body.ScrollBarImageColor3 = C.ACCENT
body.CanvasSize = UDim2.new(0, 0, 0, 0)
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.Parent = panel

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 7)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = body
pad(body, 2, 4, 2, 10)

-- helpers
local function section(txt)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 20)
    f.BackgroundTransparency = 1
    f.LayoutOrder = #body:GetChildren() + 1
    f.Parent = body
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromScale(1, 1)
    l.BackgroundTransparency = 1
    l.Text = txt
    l.Font = Enum.Font.GothamBold
    l.TextSize = 11
    l.TextColor3 = C.MUTED
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = f
    return f
end

local function toggle(label, getter, setter)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 38)
    row.BackgroundColor3 = C.ROW
    row.LayoutOrder = #body:GetChildren() + 1
    row.Parent = body
    corner(row, 10)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -78, 1, 0)
    lbl.Position = UDim2.fromOffset(12, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 13
    lbl.TextColor3 = C.TEXT
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(56, 26)
    btn.Position = UDim2.new(1, -66, 0.5, -13)
    btn.BackgroundColor3 = getter() and C.GREEN or C.BTN
    btn.Text = getter() and "ON" or "OFF"
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.TextColor3 = C.TEXT
    btn.AutoButtonColor = false
    btn.Parent = row
    corner(btn, 8)

    btn.MouseButton1Click:Connect(function()
        local v = not getter()
        setter(v)
        btn.Text = v and "ON" or "OFF"
        btn.BackgroundColor3 = v and C.GREEN or C.BTN
        persist()
    end)
    return row, btn
end

local function action(label, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 36)
    btn.BackgroundColor3 = C.BTN
    btn.Text = label
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.TextColor3 = C.TEXT
    btn.AutoButtonColor = false
    btn.LayoutOrder = #body:GetChildren() + 1
    btn.Parent = body
    corner(btn, 10)
    btn.MouseButton1Click:Connect(callback)
    return btn
end

-- ═══════════════════════════════════════
-- BUILD SECTIONS
-- ═══════════════════════════════════════
section("STEAL / INVIS")

toggle("Invisible Steal", function()
    return OH.invisibleStealEnabled
end, function(v)
    if v then enableInvisibleSteal() else disableInvisibleSteal() end
end)

toggle("Auto Invis on Steal", function()
    return OH.AutoInvisOnSteal
end, function(v)
    OH.AutoInvisOnSteal = v
end)

toggle("Lagback Recover", function()
    return OH.AutoRecoverLagback
end, function(v)
    OH.AutoRecoverLagback = v
end)

section("MOVEMENT")

toggle("Walkspeed", function()
    return OH.WalkspeedEnabled
end, function(v)
    OH.WalkspeedEnabled = v
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if hum then
        hum.WalkSpeed = v and OH.Walkspeed or 16
    end
end)

toggle("Auto TP", function()
    return OH.AutoTP
end, function(v)
    OH.AutoTP = v
end)

section("ACTIONS")

action("Scan All Animals", function()
    local list = scanAllAnimals()
    local top = {}
    for i = 1, math.min(8, #list) do
        top[#top + 1] = (list[i].name or "?") .. "  $" .. tostring(list[i].gen or 0)
    end
    print("[ORB] scanned", #list, "animals")
    if #top > 0 then
        print(table.concat(top, "
"))
    end
end)

action("Priority Editor", function()
    print("[ORB] priority list:", table.concat(OH.PriorityList, ", "))
end)

action("Rejoin Server", function()
    TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
end)

action("Server Hop", function()
    TeleportService:Teleport(game.PlaceId, LP)
end)

-- ═══════════════════════════════════════
-- CLOSE / MINIMIZE + DRAG
-- ═══════════════════════════════════════
local isMinimized = false

closeBtn.MouseButton1Click:Connect(function()
    panel.Visible = false
end)

miniBtn.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        body.Visible = false
        panel.Size = UDim2.fromOffset(300, 46)
        miniBtn.Text = "+"
    else
        body.Visible = true
        panel.Size = UDim2.fromOffset(300, 460)
        miniBtn.Text = "–"
    end
end)

-- keybind to reopen (LeftControl)
UIS.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.LeftControl then
        panel.Visible = not panel.Visible
        if panel.Visible and isMinimized then
            isMinimized = false
            body.Visible = true
            panel.Size = UDim2.fromOffset(300, 460)
            miniBtn.Text = "–"
        end
    end
end)

-- drag from header
do
    local dragging, startMouse, startPos
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startMouse = input.Position
            startPos = panel.Position
        end
    end)
    header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - startMouse
            panel.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

-- FOV
pcall(function()
    workspace.CurrentCamera.FieldOfView = OH.FOV
end)

-- walkspeed on respawn
LP.CharacterAdded:Connect(function(char)
    task.wait(0.4)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum and OH.WalkspeedEnabled then
        hum.WalkSpeed = OH.Walkspeed
    end
end)

print("[ORB HUB] loaded · no logo · LeftCtrl toggles UI")
