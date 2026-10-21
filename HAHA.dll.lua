local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")
local Debris = game:GetService("Debris")

local LocalPlayer = Players.LocalPlayer
local localName = LocalPlayer.Name
local ws = workspace
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = ws.CurrentCamera
local dataPing = Stats.Network.ServerStatsItem["Data Ping"]
local GetServerTimeNow = ws.GetServerTimeNow

ws:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = ws.CurrentCamera
end)

local CONFIG = {
    FireArg = 0.5,
    Accuracy = 85,
    AccuracyMode = "auto",
}

local remotesHook = {
    mt = {}, orig = {}, captured = {}, tokenFn = nil, firstSignal = nil,
}

do
    local ok, gc = pcall(getgc, true)
    if ok and gc then
        for _, f in next, gc do
            if type(f) ~= "function" then continue end
            local okinfo, info = pcall(debug.info, f, "s")
            if not okinfo or type(info) ~= "string" or not info:find("PRY", 1, true) then continue end
            local okup, upvals = pcall(debug.getupvalues, f)
            if not okup or type(upvals) ~= "table" then continue end
            for _, up in next, upvals do
                if type(up) == "function" then
                    remotesHook.tokenFn = up
                    break
                end
            end
            if remotesHook.tokenFn then break end
        end
    end
end

local function validArgs(args)
    return #args == 8
        and type(args[2]) == "string"
        and type(args[3]) == "string"
        and type(args[4]) == "number"
        and typeof(args[5]) == "CFrame"
        and type(args[6]) == "table"
        and type(args[7]) == "table"
        and type(args[8]) == "boolean"
end

local function unhookAll()
    for mt, idx in next, remotesHook.orig do
        pcall(function()
            setreadonly(mt, false)
            mt.__index = idx
            setreadonly(mt, true)
        end)
    end
    table.clear(remotesHook.mt)
    table.clear(remotesHook.orig)
end

local function hookRemote(inst)
    if next(remotesHook.captured) ~= nil then return end
    local ok, mt = pcall(getrawmetatable, inst)
    if not ok or remotesHook.mt[mt] then return end
    remotesHook.mt[mt] = true
    setreadonly(mt, false)
    local origIdx = mt.__index
    remotesHook.orig[mt] = origIdx
    mt.__index = function(self, key)
        if (key == "FireServer" and self:IsA("RemoteEvent"))
        or (key == "InvokeServer" and self:IsA("RemoteFunction")) then
            return function(self2, ...)
                local args = {...}
                if validArgs(args) then
                    remotesHook.captured[self] = args
                    unhookAll()
                end
                return origIdx(self, key)(self2, table.unpack(args))
            end
        end
        return origIdx(self, key)
    end
    setreadonly(mt, true)
end

if getrawmetatable and setreadonly then
    for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            pcall(hookRemote, d)
        end
    end
end

do
    local RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
    local ParrySuccessAll = RemotesFolder and RemotesFolder:FindFirstChild("ParrySuccessAll")
    if ParrySuccessAll and type(getconnections) == "function" then
        local ok, conns = pcall(getconnections, ParrySuccessAll.OnClientEvent)
        if ok and type(conns) == "table" then
            local originals = {}
            for _, conn in ipairs(conns) do
                if conn.Function then
                    table.insert(originals, conn.Function)
                    pcall(function() conn:Disable() end)
                end
            end
            if #originals > 0 then
                ParrySuccessAll.OnClientEvent:Connect(function(...)
                    for _, fn in ipairs(originals) do
                        pcall(fn, ...)
                    end
                end)
            end
        end
    end
end

local hotRemote, hotArgs1, hotArgs2, hotIsEvent
local hotSigBytes, hotSigLen

local function cacheSignature()
    if not hotArgs2 then return end
    local sig = remotesHook.tokenFn(hotArgs2, "TIME")
    hotSigLen = #sig
    if not hotSigBytes then
        hotSigBytes = table.create(hotSigLen)
    end
    for i = 1, hotSigLen do
        hotSigBytes[i] = string.byte(sig, i)
    end
end

local function refreshHot()
    for remote, args in next, remotesHook.captured do
        hotRemote = remote
        hotArgs1 = args[1]
        hotArgs2 = args[2]
        hotIsEvent = remote:IsA("RemoteEvent")
        cacheSignature()
        return
    end
end

local tokenBuf = table.create(24)

local function fastTokenize()
    local stamp = tostring(math.floor(GetServerTimeNow(ws) * 100))
    local n = #stamp
    local sig = hotSigBytes
    local sigLen = hotSigLen
    for i = 1, n do
        tokenBuf[i] = string.char(bit32.bxor((string.byte(stamp, i) + i) % 256, sig[(i - 1) % sigLen + 1]))
    end
    return table.concat(tokenBuf, "", 1, n)
end

local cachedScreen = {}
local cachedAim = {0, 0}
local cachedCframe
local cachedScale = 0.5
local lastPayloadRefresh = 0

local function getTarget()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local best, dist
    for _, other in ipairs(Players:GetPlayers()) do
        if other ~= LocalPlayer and other.Character then
            local otherRoot = other.Character:FindFirstChild("HumanoidRootPart")
            local humanoid = other.Character:FindFirstChildOfClass("Humanoid")
            if otherRoot and humanoid and humanoid.Health > 0 then
                local d = (otherRoot.Position - root.Position).Magnitude
                if not dist or d < dist then
                    dist, best = d, otherRoot.Position
                end
            end
        end
    end
    return best
end

local function refreshPayload()
    local now = os.clock()
    if now - lastPayloadRefresh < 0.016 then return end
    lastPayloadRefresh = now
    cachedScale = CONFIG.FireArg
    local target = getTarget()
    if target then
        cachedCframe = CFrame.new(Camera.CFrame.Position, target)
    else
        cachedCframe = Camera.CFrame
    end
    table.clear(cachedScreen)
    local aliveFolder = ws:FindFirstChild("Alive")
    if aliveFolder then
        for _, char in ipairs(aliveFolder:GetChildren()) do
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then
                cachedScreen[char.Name] = Camera:WorldToScreenPoint(hrp.Position)
            end
        end
    end
    local vp = Camera.ViewportSize
    cachedAim[1] = vp.X / 2
    cachedAim[2] = vp.Y / 2
end

local function fireServer()
    if not remotesHook.tokenFn then return false end
    if not hotRemote then refreshHot() end
    if not hotRemote then
        if not remotesHook.firstSignal then
            local okSig, SignalMod = pcall(function()
                return require(ReplicatedStorage.Packages.Signal)
            end)
            if not okSig then return false end
            local okPRY, PRY = pcall(function()
                local ctrl = ReplicatedStorage.Controllers
                local swordCtrl = ctrl:FindFirstChild("SwordsController " .. string.char(12))
                    or ctrl:FindFirstChild("SwordsController")
                return require(swordCtrl.PRY)
            end)
            if not okPRY then return false end
            remotesHook.firstSignal = SignalMod.new()
            remotesHook.firstSignal:Connect(PRY)
        end
        local vp = Camera.ViewportSize
        remotesHook.firstSignal:Fire(CONFIG.FireArg, Camera.CFrame, {}, {vp.X / 2, vp.Y / 2}, false)
        return true
    end
    refreshPayload()
    if not cachedCframe then cachedCframe = Camera.CFrame end
    local tok = fastTokenize()
    if hotIsEvent then
        hotRemote:FireServer(hotArgs1, hotArgs2, tok, cachedScale, cachedCframe, cachedScreen, cachedAim, false)
    else
        hotRemote:InvokeServer(hotArgs1, hotArgs2, tok, cachedScale, cachedCframe, cachedScreen, cachedAim, false)
    end
    return true
end

local ballPositions = {}
local ballDebounce = false
local ballUntilAt = 0
local ballState = {
    LerpRadians = 0, LastWarping = os.clock(), Curving = os.clock(), AerodynamicTime = os.clock(),
}
local ballReplicator = nil

do
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("_Index")
        and ReplicatedStorage.Packages._Index:FindFirstChild("sleitnick_net@0.1.0")
        and ReplicatedStorage.Packages._Index["sleitnick_net@0.1.0"]:FindFirstChild("net")
    if net then
        for _, child in ipairs(net:GetChildren()) do
            if child:IsA("UnreliableRemoteEvent") and child.Name ~= "URE/ReplicateBallPosition" then
                ballReplicator = child
                break
            end
        end
    end
end

local ballsFolder = ws:FindFirstChild("Balls")
if ballReplicator and ballsFolder then
    ballReplicator.OnClientEvent:Connect(function(ball, pos)
        if ball and ball.Parent == ballsFolder and ball:GetAttribute("realBall") == true then
            ballPositions[ball] = pos
        end
    end)
end

local function getRealBalls()
    local balls = ws:FindFirstChild("Balls")
    if not balls then return {} end
    local list = {}
    for _, b in ipairs(balls:GetChildren()) do
        if b:GetAttribute("realBall") == true then
            table.insert(list, b)
        end
    end
    return list
end

local function getBallPosition(ball)
    return ballPositions[ball] or ball.Position
end

local triggerEnabled = false
local ballTriggerTimes = setmetatable({}, {__mode = "k"})

local function triggerFire(ball)
    if not triggerEnabled then return end
    if ball:GetAttribute("target") ~= localName then return end
    if not hotRemote then
        if next(remotesHook.captured) ~= nil then refreshHot() end
        if not hotRemote then
            pcall(fireServer)
            return
        end
    end
    local now = os.clock()
    if now - (ballTriggerTimes[ball] or 0) < 0.015 then return end
    ballTriggerTimes[ball] = now
    refreshPayload()
    local cf = CFrame.new(Camera.CFrame.Position, ballPositions[ball] or ball.Position)
    local tok = fastTokenize()
    if hotIsEvent then
        hotRemote:FireServer(hotArgs1, hotArgs2, tok, cachedScale, cf, cachedScreen, cachedAim, false)
    else
        hotRemote:InvokeServer(hotArgs1, hotArgs2, tok, cachedScale, cf, cachedScreen, cachedAim, false)
    end
end

local function isCurved(ball)
    local zoomies = ball:FindFirstChild("zoomies")
    if not zoomies then return false end
    local char = LocalPlayer.Character
    if not char or not char.PrimaryPart then return false end
    local t = os.clock()
    local ping = dataPing:GetValue()
    local vel = zoomies.VectorVelocity
    local speed = vel.Magnitude
    if speed < 0.1 then return false end
    local pos = char.PrimaryPart.Position
    local ballPos = getBallPosition(ball)
    local toBall = pos - ballPos
    local dist = toBall.Magnitude
    if dist < 0.01 then return false end
    local toBallUnit = toBall / dist
    local unit = vel / speed
    local dot = toBallUnit:Dot(unit)
    local extra = math.min(speed / 100, 40)
    local n31 = dot - toBallUnit:Dot(unit - unit)
    local n32 = 0.5 - ping / 1000
    local n33 = dist / speed - ping / 1000
    local n34 = 15 - math.min(dist / 1000, 15) + extra
    ballState.LerpRadians = ballState.LerpRadians
        + (math.rad(math.asin(math.clamp(dot, -1, 1))) - ballState.LerpRadians) * 0.8
    if speed > 100 and n33 > ping / 10 then
        n34 = math.max(n34 - 15, 15)
    end
    if dist < n34 then return false end
    if n31 < n32 then return true end
    if ballState.LerpRadians < 0.018 then ballState.LastWarping = t end
    if t - ballState.LastWarping < n33 / 1.5 then return true end
    if t - ballState.Curving < n33 / 1.5 then return true end
    return dot < n32
end

local function bindBall(ball)
    local function onChange()
        ballDebounce = false
        ballUntilAt = 0
        triggerFire(ball)
    end
    ball:GetAttributeChangedSignal("target"):Connect(onChange)
    ball:GetAttributeChangedSignal("realBall"):Connect(onChange)
    onChange()
end

task.spawn(function()
    local balls = ws:WaitForChild("Balls", 10)
    if not balls then return end
    balls.ChildAdded:Connect(function(child)
        ballDebounce = false
        ballUntilAt = 0
        bindBall(child)
    end)
    balls.ChildRemoved:Connect(function(child)
        ballPositions[child] = nil
        ballDebounce = false
        ballUntilAt = 0
    end)
    for _, child in ipairs(balls:GetChildren()) do
        bindBall(child)
    end
end)

local spamState = {
    enabled = false,
    interval = 0.022,
    accumulator = 0,
    lastFrame = os.clock(),
    maxPerFrame = 2,
}

RunService.PreSimulation:Connect(function()
    refreshPayload()

    if not spamState.enabled then return end
    if not hotRemote then return end

    local now = os.clock()
    local dt = now - spamState.lastFrame
    spamState.lastFrame = now
    if dt > 0.08 then dt = 0 end
    spamState.accumulator = spamState.accumulator + dt

    local fired = 0
    while spamState.accumulator >= spamState.interval and fired < spamState.maxPerFrame do
        spamState.accumulator = spamState.accumulator - spamState.interval
        local tok = fastTokenize()
        if hotIsEvent then
            hotRemote:FireServer(hotArgs1, hotArgs2, tok, cachedScale, cachedCframe, cachedScreen, cachedAim, false)
        else
            hotRemote:InvokeServer(hotArgs1, hotArgs2, tok, cachedScale, cachedCframe, cachedScreen, cachedAim, false)
        end
        fired = fired + 1
    end
    if fired >= spamState.maxPerFrame then
        spamState.accumulator = math.min(spamState.accumulator, spamState.interval * 0.5)
    end
end)

local C = {
    bg = Color3.fromRGB(28, 28, 32),
    card = Color3.fromRGB(40, 40, 46),
    cardHover = Color3.fromRGB(48, 48, 55),
    stroke = Color3.fromRGB(52, 52, 58),
    text = Color3.fromRGB(240, 240, 245),
    textDim = Color3.fromRGB(150, 150, 160),
    accent = Color3.fromRGB(95, 200, 130),
    toggleOff = Color3.fromRGB(58, 58, 64),
    knob = Color3.fromRGB(210, 210, 215),
    danger = Color3.fromRGB(225, 95, 95),
    warnColor = Color3.fromRGB(230, 180, 90),
}

local function tween(obj, props)
    TweenService:Create(obj, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "HAHA_dll"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 999
ScreenGui.Parent = PlayerGui

local Shadow = Instance.new("Frame")
Shadow.Size = UDim2.new(0, 264, 0, 420)
Shadow.Position = UDim2.new(0.5, -132, 0.5, -210)
Shadow.BackgroundColor3 = Color3.new(0, 0, 0)
Shadow.BackgroundTransparency = 0.5
Shadow.BorderSizePixel = 0
Shadow.Parent = ScreenGui
Instance.new("UICorner", Shadow).CornerRadius = UDim.new(0, 14)

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 260, 0, 416)
MainFrame.Position = UDim2.new(0.5, -130, 0.5, -208)
MainFrame.BackgroundColor3 = C.bg
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 12)

local frameStroke = Instance.new("UIStroke")
frameStroke.Color = C.stroke
frameStroke.Thickness = 1
frameStroke.Parent = MainFrame

local frameGrad = Instance.new("UIGradient")
frameGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(32, 32, 36)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(24, 24, 28))
})
frameGrad.Rotation = 90
frameGrad.Parent = MainFrame

local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 40)
TitleBar.BackgroundTransparency = 1
TitleBar.Parent = MainFrame

local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.new(0, 8, 0, 8)
statusDot.Position = UDim2.new(0, 16, 0.5, -4)
statusDot.BackgroundColor3 = remotesHook.tokenFn and C.accent or C.warnColor
statusDot.BorderSizePixel = 0
statusDot.Parent = TitleBar
Instance.new("UICorner", statusDot).CornerRadius = UDim.new(1, 0)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.new(0, 32, 0, 0)
title.BackgroundTransparency = 1
title.Text = "HAHA.dll"
title.TextColor3 = C.text
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = TitleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -34, 0.5, -12)
closeBtn.BackgroundColor3 = Color3.fromRGB(46, 46, 52)
closeBtn.BorderSizePixel = 0
closeBtn.Text = "×"
closeBtn.TextColor3 = C.textDim
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 18
closeBtn.AutoButtonColor = false
closeBtn.Parent = TitleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -32, 0, 1)
divider.Position = UDim2.new(0, 16, 0, 40)
divider.BackgroundColor3 = C.stroke
divider.BackgroundTransparency = 0.3
divider.BorderSizePixel = 0
divider.Parent = MainFrame

local function makeToggleRow(yPos, label, onChanged)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -32, 0, 44)
    row.Position = UDim2.new(0, 16, 0, yPos)
    row.BackgroundColor3 = C.card
    row.BorderSizePixel = 0
    row.Text = ""
    row.AutoButtonColor = false
    row.Parent = MainFrame
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -80, 1, 0)
    lbl.Position = UDim2.new(0, 14, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.text
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 14
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local bg = Instance.new("Frame")
    bg.Size = UDim2.new(0, 40, 0, 22)
    bg.Position = UDim2.new(1, -54, 0.5, -11)
    bg.BackgroundColor3 = C.toggleOff
    bg.BorderSizePixel = 0
    bg.Parent = row
    Instance.new("UICorner", bg).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 16, 0, 16)
    knob.Position = UDim2.new(0, 3, 0.5, -8)
    knob.BackgroundColor3 = C.knob
    knob.BorderSizePixel = 0
    knob.Parent = bg
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local state = false
    local function setState(s)
        state = s
        tween(knob, {
            Position = s and UDim2.new(0, 21, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
        })
        TweenService:Create(bg, TweenInfo.new(0.2), {
            BackgroundColor3 = s and C.accent or C.toggleOff
        }):Play()
        if onChanged then onChanged(s) end
    end

    row.MouseButton1Click:Connect(function() setState(not state) end)
    row.MouseEnter:Connect(function()
        if not state then tween(row, { BackgroundColor3 = C.cardHover }) end
    end)
    row.MouseLeave:Connect(function()
        if not state then tween(row, { BackgroundColor3 = C.card }) end
    end)

    return { set = setState, get = function() return state end }
end

local function makeSlider(yPos, label, min, max, initial, onChanged)
    local container = Instance.new("Frame")
    container.Size = UDim2.new(1, -32, 0, 56)
    container.Position = UDim2.new(0, 16, 0, yPos)
    container.BackgroundColor3 = C.card
    container.BorderSizePixel = 0
    container.Parent = MainFrame
    Instance.new("UICorner", container).CornerRadius = UDim.new(0, 8)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.6, 0, 0, 16)
    lbl.Position = UDim2.new(0, 12, 0, 3)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.text
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = container

    local valLabel = Instance.new("TextLabel")
    valLabel.Size = UDim2.new(0.35, 0, 0, 16)
    valLabel.Position = UDim2.new(0.65, 0, 0, 3)
    valLabel.BackgroundTransparency = 1
    valLabel.Text = tostring(initial)
    valLabel.TextColor3 = C.accent
    valLabel.Font = Enum.Font.GothamBold
    valLabel.TextSize = 13
    valLabel.TextXAlignment = Enum.TextXAlignment.Right
    valLabel.Parent = container

    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1, -24, 0, 12)
    sub.Position = UDim2.new(0, 12, 0, 19)
    sub.BackgroundTransparency = 1
    sub.Text = ""
    sub.TextColor3 = C.textDim
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 10
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.Parent = container

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -24, 0, 6)
    track.Position = UDim2.new(0, 12, 1, -14)
    track.BackgroundColor3 = C.toggleOff
    track.BorderSizePixel = 0
    track.Parent = container
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new((initial - min) / (max - min), 0, 1, 0)
    fill.BackgroundColor3 = C.accent
    fill.BorderSizePixel = 0
    fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = UDim2.new((initial - min) / (max - min), 0, 0.5, -7)
    knob.AnchorPoint = Vector2.new(0.5, 0)
    knob.BackgroundColor3 = C.knob
    knob.BorderSizePixel = 0
    knob.Parent = track
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local value = initial
    local dragging = false

    local function setValue(v)
        v = math.clamp(v, min, max)
        value = v
        local pct = (v - min) / (max - min)
        fill.Size = UDim2.new(pct, 0, 1, 0)
        knob.Position = UDim2.new(pct, 0, 0.5, -7)
        valLabel.Text = tostring(math.floor(v + 0.5))
        if onChanged then onChanged(v) end
    end

    local function trackToValue(x)
        local abs = track.AbsolutePosition.X
        local size = track.AbsoluteSize.X
        local pct = math.clamp((x - abs) / size, 0, 1)
        setValue(min + pct * (max - min))
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            trackToValue(input.Position.X)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            trackToValue(input.Position.X)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    return { set = setValue, get = function() return value end, sub = sub, val = valLabel }
end

local AutoParry = false

local function getEffectiveAccuracy()
    if CONFIG.AccuracyMode ~= "auto" then
        return CONFIG.Accuracy
    end
    local ping = dataPing:GetValue()
    
    if ping <= 80 then
        return CONFIG.Accuracy
    elseif ping >= 2580 then
        return CONFIG.Accuracy * 0.35
    else
        local range = ping - 80
        local factor = 1 - (range / 2500)
        return CONFIG.Accuracy * math.max(factor, 0.35)
    end
end

local function getAccuracyMultiplier()
    local eff = getEffectiveAccuracy()
    return 100 / eff
end

makeToggleRow(52, "Auto parry", function(s)
    AutoParry = s
end)

makeToggleRow(104, "Manual spam", function(s)
    spamState.enabled = s
    spamState.accumulator = 0
    spamState.lastFrame = os.clock()
end)

makeToggleRow(156, "Triggerbot", function(s)
    triggerEnabled = s
    if s then
        for _, ball in ipairs(getRealBalls()) do
            triggerFire(ball)
        end
    end
end)

local accuracySlider = makeSlider(208, "Accuracy", 40, 100, CONFIG.Accuracy, function(v)
    CONFIG.Accuracy = math.floor(v + 0.5)
end)

makeToggleRow(272, "Auto accuracy", function(s)
    CONFIG.AccuracyMode = s and "auto" or "manual"
end)

local StatsCard = Instance.new("Frame")
StatsCard.Size = UDim2.new(1, -32, 0, 56)
StatsCard.Position = UDim2.new(0, 16, 0, 344)
StatsCard.BackgroundColor3 = C.card
StatsCard.BorderSizePixel = 0
StatsCard.Parent = MainFrame
Instance.new("UICorner", StatsCard).CornerRadius = UDim.new(0, 8)

local statsGrad = Instance.new("UIGradient")
statsGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(44, 44, 50)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(38, 38, 44))
})
statsGrad.Rotation = 90
statsGrad.Parent = StatsCard

local VelocityLabel = Instance.new("TextLabel")
VelocityLabel.Size = UDim2.new(0.5, 0, 0.5, 0)
VelocityLabel.Position = UDim2.new(0, 14, 0, 5)
VelocityLabel.BackgroundTransparency = 1
VelocityLabel.Text = "Ball velocity"
VelocityLabel.TextColor3 = C.textDim
VelocityLabel.Font = Enum.Font.Gotham
VelocityLabel.TextSize = 11
VelocityLabel.TextXAlignment = Enum.TextXAlignment.Left
VelocityLabel.Parent = StatsCard

local VelocityValue = Instance.new("TextLabel")
VelocityValue.Size = UDim2.new(0.5, 0, 0.5, 0)
VelocityValue.Position = UDim2.new(0.5, -14, 0, 5)
VelocityValue.BackgroundTransparency = 1
VelocityValue.Text = "--"
VelocityValue.TextColor3 = C.text
VelocityValue.Font = Enum.Font.GothamBold
VelocityValue.TextSize = 13
VelocityValue.TextXAlignment = Enum.TextXAlignment.Right
VelocityValue.Parent = StatsCard

local PingLabel = Instance.new("TextLabel")
PingLabel.Size = UDim2.new(0.5, 0, 0.5, 0)
PingLabel.Position = UDim2.new(0, 14, 0.5, 5)
PingLabel.BackgroundTransparency = 1
PingLabel.Text = "Ping"
PingLabel.TextColor3 = C.textDim
PingLabel.Font = Enum.Font.Gotham
PingLabel.TextSize = 11
PingLabel.TextXAlignment = Enum.TextXAlignment.Left
PingLabel.Parent = StatsCard

local PingValue = Instance.new("TextLabel")
PingValue.Size = UDim2.new(0.5, 0, 0.5, 0)
PingValue.Position = UDim2.new(0.5, -14, 0.5, 5)
PingValue.BackgroundTransparency = 1
PingValue.Text = "--"
PingValue.TextColor3 = C.text
PingValue.Font = Enum.Font.GothamBold
PingValue.TextSize = 13
PingValue.TextXAlignment = Enum.TextXAlignment.Right
PingValue.Parent = StatsCard

closeBtn.MouseEnter:Connect(function()
    tween(closeBtn, { BackgroundColor3 = C.danger, TextColor3 = Color3.fromRGB(255, 255, 255) })
end)

closeBtn.MouseLeave:Connect(function()
    tween(closeBtn, { BackgroundColor3 = Color3.fromRGB(46, 46, 52), TextColor3 = C.textDim })
end)

local dragging = false
local dragInput, dragStart, startPos, shadowStartPos

TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local p = input.Position
    local cPos = closeBtn.AbsolutePosition
    local cSize = closeBtn.AbsoluteSize
    if p.X >= cPos.X and p.X <= cPos.X + cSize.X
        and p.Y >= cPos.Y and p.Y <= cPos.Y + cSize.Y then return end
    dragging = true
    dragStart = input.Position
    startPos = MainFrame.Position
    shadowStartPos = Shadow.Position
    input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End then dragging = false end
    end)
end)

TitleBar.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
        Shadow.Position = UDim2.new(
            shadowStartPos.X.Scale, shadowStartPos.X.Offset + delta.X,
            shadowStartPos.Y.Scale, shadowStartPos.Y.Offset + delta.Y
        )
    end
end)

local function checkParry()
    local char = LocalPlayer.Character
    local hrp = char and char.PrimaryPart
    if not hrp then return end
    local t = os.clock()
    if ballDebounce or t < ballUntilAt then return end
    if not remotesHook.tokenFn then return end
    local pos = hrp.Position
    local pingVal = dataPing:GetValue()
    local pingRange = math.clamp(pingVal / 100, 5, 18)
    local accuracyMult = getAccuracyMultiplier()
    local allBalls = getRealBalls()
    if #allBalls == 0 then return end
    local firstBall = allBalls[1]
    local firstTarget = firstBall:GetAttribute("target")
    local runtime = ws:FindFirstChild("Runtime")
    local tornado = runtime and runtime:FindFirstChild("Tornado")
    local tornadoTime = (tornado and tornado:GetAttribute("TornadoTime")) or 0
    for _, ball in ipairs(allBalls) do
        local zoomies = ball:FindFirstChild("zoomies")
        if zoomies then
            local target = ball:GetAttribute("target")
            local speed = zoomies.VectorVelocity.Magnitude
            local dist = (pos - getBallPosition(ball)).Magnitude
            local divisor = 2.4 + math.min(math.max(speed - 9.5, 0), 650) * 0.002
            divisor = divisor / accuracyMult
            if divisor <= 0.01 then divisor = 0.01 end
            local threshold = pingRange + math.max(speed / divisor, 9.5)
            local aero = ball:FindFirstChild("AeroDynamicSlashVFX")
            if aero then
                Debris:AddItem(aero, 0)
                ballState.AerodynamicTime = t
            end
            if tornado and (t - ballState.AerodynamicTime < tornadoTime + 0.314159) then continue end
            if firstTarget == localName and isCurved(firstBall) then continue end
            if target ~= localName then continue end
            if dist > threshold then continue end
            if accuracyMult > 2 then continue end
            if pcall(fireServer) then
                ballDebounce = true
                ballUntilAt = t + 1
            end
            return
        end
    end
end

RunService.PostSimulation:Connect(function()
    if not AutoParry then return end
    checkParry()
end)

local alive = true
task.spawn(function()
    while alive do
        local maxSpeed = 0
        for _, ball in ipairs(getRealBalls()) do
            local z = ball:FindFirstChild("zoomies")
            if z then
                local s = z.VectorVelocity.Magnitude
                if s > maxSpeed then maxSpeed = s end
            end
        end
        if maxSpeed > 0 then
            VelocityValue.Text = string.format("%.0f", maxSpeed)
            VelocityValue.TextColor3 = maxSpeed >= 2200 and C.warnColor or C.text
        else
            VelocityValue.Text = "--"
            VelocityValue.TextColor3 = C.textDim
        end

        local ping = dataPing:GetValue()
        PingValue.Text = string.format("%.0fms", ping)
        PingValue.TextColor3 = ping > 200 and C.warnColor or C.text
        
        if CONFIG.AccuracyMode == "auto" then
            local eff = getEffectiveAccuracy()
            accuracySlider.sub.Text = string.format("auto | eff: %.0f%%", eff)
        else
            accuracySlider.sub.Text = "manual"
        end

        task.wait(0.05)
    end
end)

closeBtn.MouseButton1Click:Connect(function()
    alive = false
    spamState.enabled = false
    triggerEnabled = false
    ScreenGui:Destroy()
end)
