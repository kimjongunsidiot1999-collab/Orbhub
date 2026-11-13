--[[
    ORB HUB · AC soft bypass edition (quieter path)
    ─────────────────────────────────────
    quieter invis for current SAB AC
    mobile UI kept
    removed loud PlaceId metamethod hook
    softened sink/angle + gated heavy work
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

OH.InvisAngle         = cfg.InvisAngle or 178          -- softer, less extreme
OH.SinkDepth          = cfg.SinkDepth or 4.2          -- shallower = quieter
OH.AutoInvisOnSteal   = cfg.AutoInvisOnSteal or true
OH.AutoRecoverLagback = cfg.AutoRecoverLagback ~= false
OH.Walkspeed          = cfg.Walkspeed or 26
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
-- PLACEID spoof removed (was instant flag)
-- ═══════════════════════════════════════

-- ═══════════════════════════════════════
-- CHANNEL SCAN
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

task.spawn(function()
    local plots = workspace:WaitForChild("Plots", 12)
    if not plots then return end
    for _, p in ipairs(plots:GetChildren()) do
        task.spawn(pullPlot, p.Name)
    end
    plots.ChildAdded:Connect(function(p)
        task.wait(0.35)
        pullPlot(p.Name)
    end)
end)

-- ═══════════════════════════════════════
-- QUIETER INVISIBLE STEAL
-- ═══════════════════════════════════════
local invisConn, cloneRoot, humanoidRootPart, lastGoodCF, lagbackConn
local lastToggle = 0
local lastOffsetJitter = 0

local function cleanupInvis()
    if invisConn then pcall(function() invisConn:Disconnect() end) invisConn = nil end
    if lagbackConn then pcall(function() lagbackConn:Disconnect() end) lagbackConn = nil end
    if cloneRoot then
        pcall(function() cloneRoot:Destroy() end)
        cloneRoot = nil
    end
    humanoidRootPart = nil
    OH.invisibleStealEnabled = false
end

local function enableInvisibleSteal()
    if OH.invisibleStealEnabled then return end
    if tick() - lastToggle < 0.75 then return end -- slightly longer anti-spam
    lastToggle = tick()

    local char = LP.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return end

    OH.invisibleStealEnabled = true
    lastGoodCF = hrp.CFrame

    -- soft clone only while active
    cloneRoot = Instance.new("Part")
    cloneRoot.Name = "OrbTempRoot"
    cloneRoot.Size = Vector3.new(1.6, 1.6, 0.8) -- slightly smaller
    cloneRoot.Transparency = 1
    cloneRoot.CanCollide = false
    cloneRoot.Anchored = false
    cloneRoot.CFrame = hrp.CFrame
    cloneRoot.Parent = workspace.CurrentCamera

    humanoidRootPart = hrp

    local baseAngle = math.rad(OH.InvisAngle or 178)
    local baseSink  = (OH.SinkDepth or 4.2)

    invisConn = RunService.Heartbeat:Connect(function()
        if not OH.invisibleStealEnabled or not char.Parent or not hrp.Parent then
            cleanupInvis()
            return
        end

        local isStealing = LP:GetAttribute("Stealing") == true
        local now = tick()

        -- only do heavy offset while actually stealing
        local targetCF
        if isStealing then
            -- soft random jitter, refreshed occasionally
            if now - lastOffsetJitter > 0.18 then
                lastOffsetJitter = now
            end
            local jitterY = (math.random() * 0.28 - 0.14)
            local jitterA = (math.random() * 0.05 - 0.025)

            targetCF = hrp.CFrame - Vector3.new(0, baseSink + jitterY, 0)
            targetCF = targetCF * CFrame.Angles(baseAngle + jitterA, 0, 0)
        else
            targetCF = hrp.CFrame
        end

        if cloneRoot and cloneRoot.Parent then
            cloneRoot.CFrame = targetCF
            local vel = hrp.AssemblyLinearVelocity
            -- damp velocity softer
            cloneRoot.AssemblyLinearVelocity = Vector3.new(vel.X * 0.94, vel.Y * 0.62, vel.Z * 0.94)
        end

        -- only kill collision while actively stealing
        pcall(function()
            if isStealing then
                hrp.CanCollide = false
            else
                hrp.CanCollide = true
            end
        end)

        lastGoodCF = hrp.CFrame
    end)

    if OH.AutoRecoverLagback then
        lagbackConn = RunService.Heartbeat:Connect(function()
            if not OH.invisibleStealEnabled or not hrp or not hrp.Parent then return end
            local dist = (hrp.Position - lastGoodCF.Position).Magnitude
            if dist > 26 then -- slightly higher threshold
                pcall(function()
                    hrp.CFrame = lastGoodCF * CFrame.new(0, 0.55, 0)
                end)
            end
        end)
    end
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

-- auto only when attribute flips (with small delay)
task.spawn(function()
    LP:GetAttributeChangedSignal("Stealing"):Connect(function()
        if LP:GetAttribute("Stealing") then
            if OH.AutoInvisOnSteal and not OH.invisibleStealEnabled then
                task.wait(0.22) -- tiny delay so AC doesn’t see instant toggle
                pcall(_G.toggleInvisibleSteal)
            end
        else
            if OH.AutoInvisOnSteal and OH.invisibleStealEnabled then
                task.wait(0.28)
                pcall(_G.toggleInvisibleSteal)
            end
        end
    end)
end)

LP.CharacterAdded:Connect(function()
    cleanupInvis()
end)

-- ═══════════════════════════════════════
-- UI (mobile kept)
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
    GOLD    = Color3.fromRGB(255, 200, 60),
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

local function isMobile()
    return UIS.TouchEnabled and not UIS.KeyboardEnabled
end

local scale = isMobile() and 0.92 or 1
local panelW = math.floor(300 * scale)
local panelH = math.floor(isMobile() and 420 or 460)

local logoBtn = Instance.new("ImageButton")
logoBtn.Name = "OrbToggle"
logoBtn.Size = UDim2.fromOffset(isMobile() and 64 or 58, isMobile() and 64 or 58)
logoBtn.Position = UDim2.new(0, 14, 0.38, 0)
logoBtn.BackgroundTransparency = 1
logoBtn.Image = ""
logoBtn.ScaleType = Enum.ScaleType.Fit
logoBtn.ZIndex = 120
logoBtn.Parent = mainSG

local glow = Instance.new("Frame")
glow.Size = UDim2.fromScale(1, 1)
glow.BackgroundColor3 = C.ACCENT
glow.BackgroundTransparency = 0.5
glow.Parent = logoBtn
corner(glow, 18)
stroke(glow, C.ACCENT2, 2)

local starLbl = Instance.new("TextLabel")
starLbl.Size = UDim2.fromScale(1, 1)
starLbl.BackgroundTransparency = 1
starLbl.Text = "✦"
starLbl.TextColor3 = C.ACCENT2
starLbl.TextSize = isMobile() and 28 or 26
starLbl.Font = Enum.Font.GothamBlack
starLbl.Parent = logoBtn

local panel = Instance.new("Frame")
panel.Name = "MainPanel"
panel.Size = UDim2.fromOffset(panelW, panelH)
panel.Position = UDim2.new(0.5, -panelW/2, 0.5, -panelH/2)
panel.BackgroundColor3 = C.PANEL
panel.BorderSizePixel = 0
panel.Visible = true
panel.ClipsDescendants = true
panel.Parent = mainSG
corner(panel, 16)
stroke(panel, Color3.fromRGB(30, 45, 70), 1.4)

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, isMobile() and 52 or 46)
header.BackgroundColor3 = Color3.fromRGB(12, 14, 22)
header.BorderSizePixel = 0
header.Parent = panel
corner(header, 16)

local accentBar = Instance.new("Frame")
accentBar.Size = UDim2.new(0, 4, 1, -18)
accentBar.Position = UDim2.fromOffset(12, 9)
accentBar.BackgroundColor3 = C.ACCENT
accentBar.BorderSizePixel = 0
accentBar.Parent = header
corner(accentBar, 2)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.fromOffset(24, 0)
title.BackgroundTransparency = 1
title.Text = "ORB HUB"
title.Font = Enum.Font.GothamBlack
title.TextSize = isMobile() and 18 or 17
title.TextColor3 = C.ACCENT2
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(isMobile() and 36 or 30, isMobile() and 36 or 30)
closeBtn.Position = UDim2.new(1, isMobile() and -44 or -38, 0.5, isMobile() and -18 or -15)
closeBtn.BackgroundColor3 = C.BTN
closeBtn.Text = "×"
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = isMobile() and 22 or 18
closeBtn.TextColor3 = C.MUTED
closeBtn.AutoButtonColor = false
closeBtn.Parent = header
corner(closeBtn, 10)

local body = Instance.new("ScrollingFrame")
body.Size = UDim2.new(1, -16, 1, isMobile() and -64 or -58)
body.Position = UDim2.fromOffset(8, isMobile() and 58 or 52)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = isMobile() and 4 or 3
body.ScrollBarImageColor3 = C.ACCENT
body.CanvasSize = UDim2.new(0, 0, 0, 0)
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.Parent = panel

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, isMobile() and 9 or 7)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = body
pad(body, 2, 4, 2, 12)

local function section(txt)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, isMobile() and 22 or 20)
    f.BackgroundTransparency = 1
    f.LayoutOrder = #body:GetChildren() + 1
    f.Parent = body
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromScale(1, 1)
    l.BackgroundTransparency = 1
    l.Text = txt
    l.Font = Enum.Font.GothamBold
    l.TextSize = isMobile() and 12 or 11
    l.TextColor3 = C.MUTED
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = f
    return f
end

local function toggle(label, getter, setter)
    local rowH = isMobile() and 44 or 38
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, rowH)
    row.BackgroundColor3 = C.ROW
    row.LayoutOrder = #body:GetChildren() + 1
    row.Parent = body
    corner(row, 12)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -90, 1, 0)
    lbl.Position = UDim2.fromOffset(14, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = isMobile() and 14 or 13
    lbl.TextColor3 = C.TEXT
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(isMobile() and 64 or 56, isMobile() and 30 or 26)
    btn.Position = UDim2.new(1, isMobile() and -74 or -66, 0.5, isMobile() and -15 or -13)
    btn.BackgroundColor3 = getter() and C.GREEN or C.BTN
    btn.Text = getter() and "ON" or "OFF"
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = isMobile() and 12 or 11
    btn.TextColor3 = C.TEXT
    btn.AutoButtonColor = false
    btn.Parent = row
    corner(btn, 9)

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
    local btnH = isMobile() and 42 or 36
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, btnH)
    btn.BackgroundColor3 = C.BTN
    btn.Text = label
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = isMobile() and 14 or 13
    btn.TextColor3 = C.TEXT
    btn.AutoButtonColor = false
    btn.LayoutOrder = #body:GetChildren() + 1
    btn.Parent = body
    corner(btn, 12)
    btn.MouseButton1Click:Connect(callback)
    return btn
end

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
        print(table.concat(top, "\n"))
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

local function setUI(visible)
    OH.UIVisible = visible
    panel.Visible = visible
end

logoBtn.MouseButton1Click:Connect(function()
    setUI(not panel.Visible)
end)

closeBtn.MouseButton1Click:Connect(function()
    setUI(false)
end)

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

do
    local dragging, startMouse, startPos
    logoBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startMouse = input.Position
            startPos = logoBtn.Position
        end
    end)
    logoBtn.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - startMouse
            logoBtn.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

pcall(function()
    workspace.CurrentCamera.FieldOfView = OH.FOV
end)

LP.CharacterAdded:Connect(function(char)
    task.wait(0.4)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum and OH.WalkspeedEnabled then
        hum.WalkSpeed = OH.Walkspeed
    end
end)

print("[ORB HUB] loaded · quieter AC path · mobile ready")
