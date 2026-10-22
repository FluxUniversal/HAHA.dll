local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")

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

local PI = {
    interval = 0.01,
    integral = 0,
    integral_cap = 0.02,
    deadband = 0.00015,
    kp = 0.35,
    ki = 0.012,
    ema_alpha = 0.12,
    ema_one_minus = 0.88,
    decay = 1 - (1 / 512),
    drift_accum = 0,
    residual = 0,
    tick_n = 0,
    suppressed = 0,
    session_start = 0,
    ema_error = 0,
    phase_offset = 0,
    nano_cd = 16,
    micro_cd = 64,
    nano_clamp = 0.002,
    micro_clamp = 0.004,
    nano_gain = 0.05,
    micro_gain = 0.15,
    half_interval = 0.005,
    max_lag = 0.01,
    max_fires_per_frame = 64,
    ring_size = 1024,
    ring = table.create(1024, 0),
    ring_head = 0,
}

local S = {
    CONFIG = { FireArg = 0.5, Accuracy = 85, AccuracyMode = "auto" },
    keybinds = { spam = Enum.KeyCode.X, trigger = Enum.KeyCode.C, orbit = Enum.KeyCode.O },
    orbit = { enabled = false, angle = 0, radius = 12, speed = 6, lastTick = os.clock() },
    rageOrbit = { enabled = false, cooldown = 0, studs = 23 },
    spamState = { enabled = false, rate = 240 },
    remotesHook = { mt = {}, orig = {}, captured = {}, tokenFn = nil, firstSignal = nil, done = false, descConn = nil },
    noRender = {
        enabled = false,
        saved = setmetatable({}, {__mode = "k"}),
        descConn = nil,
        lightingConn = nil,
    },
    armingBox = nil,
    armingKey = nil,
    alive = true,
    hotRemote = nil,
    hotArgs1 = nil,
    hotArgs2 = nil,
    hotIsEvent = false,
    fireMethod = nil,
    hotSigBytes = nil,
    hotSigLen = 0,
    cachedToken = "",
    cachedTokenStamp = -1,
    lastTokenGenTime = 0,
    cachedScreen = {},
    cachedAim = {0, 0},
    cachedCframe = nil,
    cachedScale = 0.5,
    lastPayloadRefresh = 0,
    lastScreenRefresh = 0,
    payloadRefreshThreshold = 0.016,
    screenRefreshThreshold = 0.016,
    cachedTargetPos = nil,
    lastTargetRefresh = 0,
    targetRefreshInterval = 0.1,
    pingSmoothed = 0,
    pingJitter = 0,
    lastPingSample = 0,
    lastPingSampleTime = 0,
    cachedEffectiveAccuracy = 85,
    lastAccuracyCalc = 0,
    aliveFolderCache = nil,
    aliveFolderCacheAt = 0,
    refreshLoopConn = nil,
    triggerEnabled = false,
    orbBallsCache = nil,
    orbBallsCacheAt = 0,
    ballPositions = {},
    ballDebounce = false,
    ballUntilAt = 0,
    ballState = { LerpRadians = 0, LastWarping = os.clock(), Curving = os.clock(), AerodynamicTime = os.clock() },
    ballReplicator = nil,
    ballTriggerTimes = setmetatable({}, {__mode = "k"}),
    spamButton = nil,
    triggerButton = nil,
    statusVelocity = nil,
    statusPing = nil,
    statusAcc = nil,
    statusRPS = nil,
    accuracySlider = nil,
    spamToggle = nil,
    triggerToggle = nil,
    orbitToggle = nil,
    rageOrbitToggle = nil,
}

local function keyName(k)
    if not k then return "None" end
    return (tostring(k):gsub("Enum.KeyCode.", ""))
end

local function getAliveFolder()
    local now = os.clock()
    if now - S.aliveFolderCacheAt > 2 then
        S.aliveFolderCache = ws:FindFirstChild("Alive")
        S.aliveFolderCacheAt = now
    end
    return S.aliveFolderCache
end

local function updateAccuracyEstimate()
    local now = os.clock()
    if now - S.lastPingSampleTime >= 0.2 then
        S.lastPingSampleTime = now
        local raw = dataPing:GetValue()
        if S.pingSmoothed == 0 then
            S.pingSmoothed = raw
            S.lastPingSample = raw
        else
            local delta = math.abs(raw - S.lastPingSample)
            S.lastPingSample = raw
            S.pingJitter = S.pingJitter * 0.8 + delta * 0.2
            S.pingSmoothed = S.pingSmoothed * 0.7 + raw * 0.3
        end
    end
    if now - S.lastAccuracyCalc >= 0.5 then
        S.lastAccuracyCalc = now
        if S.CONFIG.AccuracyMode ~= "auto" then
            S.cachedEffectiveAccuracy = S.CONFIG.Accuracy
        else
            local p = S.pingSmoothed
            local pingFactor
            if p <= 80 then pingFactor = 1
            elseif p >= 2000 then pingFactor = 0.35
            else pingFactor = 1 - ((p - 80) / 1920) * 0.65 end
            local jitterFactor = math.clamp(1 - (S.pingJitter / 300), 0.6, 1)
            S.cachedEffectiveAccuracy = S.CONFIG.Accuracy * pingFactor * jitterFactor
        end
    end
end

local function getEffectiveAccuracy()
    updateAccuracyEstimate()
    return S.cachedEffectiveAccuracy
end

local function getAccuracyMultiplier()
    updateAccuracyEstimate()
    return 100 / S.cachedEffectiveAccuracy
end

local function getLocalHRP()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getOrbitBall()
    local now = os.clock()
    if not S.orbBallsCache or now - S.orbBallsCacheAt > 0.1 then
        S.orbBallsCacheAt = now
        S.orbBallsCache = ws:FindFirstChild("Balls")
    end
    local folder = S.orbBallsCache
    if not folder then return nil end
    local hrp = getLocalHRP()
    if not hrp then return nil end
    local pos = hrp.Position
    local closest, dist = nil, math.huge
    for _, v in ipairs(folder:GetChildren()) do
        if v:IsA("BasePart") then
            local d = (pos - v.Position).Magnitude
            if d < dist then
                dist = d
                closest = v
            end
        end
    end
    return closest
end

local function updateOrbit(dt)
    if not S.orbit.enabled then return end
    local hrp = getLocalHRP()
    if not hrp then return end
    local ball = getOrbitBall()
    if not ball then return end
    S.orbit.angle = S.orbit.angle + S.orbit.speed * dt
    if S.orbit.angle > math.pi * 2 then
        S.orbit.angle = S.orbit.angle - math.pi * 2
    end
    local center = ball.Position
    local offset = Vector3.new(
        math.cos(S.orbit.angle) * S.orbit.radius,
        math.sin(S.orbit.angle * 2) * 2,
        math.sin(S.orbit.angle) * S.orbit.radius
    )
    hrp.CFrame = CFrame.new(center + offset)
end

local function getRageOrbitBall()
    local hrp = getLocalHRP()
    if not hrp then return nil end
    local folder = ws:FindFirstChild("Balls")
    if not folder then return nil end
    local closest, dist = nil, math.huge
    for _, v in ipairs(folder:GetChildren()) do
        if v:IsA("BasePart") then
            local d = (hrp.Position - v.Position).Magnitude
            if d < dist then
                dist = d
                closest = v
            end
        end
    end
    return closest
end

local function getRageOrbitOffset()
    local angle = math.random() * math.pi * 2
    return Vector3.new(math.cos(angle) * S.rageOrbit.studs, 0, math.sin(angle) * S.rageOrbit.studs)
end

local function rageCurveSlide(target)
    local hrp = getLocalHRP()
    if not hrp then return end
    local start = hrp.Position
    local mid = (start + target) / 2
    local dir = target - start
    if dir.Magnitude == 0 then return end
    dir = dir.Unit
    local side = Vector3.new(-dir.Z, 0, dir.X)
    mid = mid + side * math.random(5, 15)
    local steps = 3
    local spin = 0
    for i = 1, steps do
        local hrp2 = getLocalHRP()
        if not hrp2 then return end
        local t = i / steps
        local pos = (1 - t) ^ 2 * start + 2 * (1 - t) * t * mid + t ^ 2 * target
        spin += 60
        hrp2.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.rad(spin), 0)
        task.wait(0.001)
    end
end

local function rageOrbitTick()
    if not S.rageOrbit.enabled then return end
    local ball = getRageOrbitBall()
    if not ball then return end
    rageCurveSlide(ball.Position + getRageOrbitOffset())
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
                    S.remotesHook.tokenFn = up
                    break
                end
            end
            if S.remotesHook.tokenFn then break end
        end
    end
end

local function unhookAll()
    local H = S.remotesHook
    for mt, idx in next, H.orig do
        pcall(function()
            setreadonly(mt, false)
            mt.__index = idx
            setreadonly(mt, true)
        end)
    end
    table.clear(H.mt)
    table.clear(H.orig)
    if H.descConn then
        H.descConn:Disconnect()
        H.descConn = nil
    end
    H.done = true
end

local function hookRemote(inst)
    local H = S.remotesHook
    if H.done then return end
    local ok, mt = pcall(getrawmetatable, inst)
    if not ok or H.mt[mt] then return end
    H.mt[mt] = true
    setreadonly(mt, false)
    local origIdx = mt.__index
    H.orig[mt] = origIdx
    mt.__index = function(self, key)
        if not H.done and (key == "FireServer" or key == "InvokeServer") then
            local realFn = origIdx(self, key)
            if realFn then
                return function(self2, ...)
                    if not H.done then
                        local cls = self2.ClassName
                        if (key == "FireServer" and cls == "RemoteEvent")
                        or (key == "InvokeServer" and cls == "RemoteFunction") then
                            local args = {...}
                            if validArgs(args) then
                                H.captured[self2] = args
                                task.defer(unhookAll)
                            end
                        end
                    end
                    return realFn(self2, ...)
                end
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
    S.remotesHook.descConn = ReplicatedStorage.DescendantAdded:Connect(function(d)
        if S.remotesHook.done then return end
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            pcall(hookRemote, d)
        end
    end)
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

local function cacheSignature()
    if not S.hotArgs2 then return end
    local sig = S.remotesHook.tokenFn(S.hotArgs2, "TIME")
    S.hotSigLen = #sig
    if not S.hotSigBytes then
        S.hotSigBytes = table.create(S.hotSigLen)
    end
    for i = 1, S.hotSigLen do
        S.hotSigBytes[i] = string.byte(sig, i)
    end
end

local function refreshHot()
    for remote, args in next, S.remotesHook.captured do
        S.hotRemote = remote
        S.hotArgs1 = args[1]
        S.hotArgs2 = args[2]
        S.hotIsEvent = remote:IsA("RemoteEvent")
        if S.hotIsEvent then
            S.fireMethod = remote.FireServer
        else
            S.fireMethod = remote.InvokeServer
        end
        cacheSignature()
        return true
    end
    return false
end

local tokenBuf = table.create(24)

local function fastTokenize()
    local stamp = tostring(math.floor(GetServerTimeNow(ws) * 100))
    local n = #stamp
    local sig = S.hotSigBytes
    local sigLen = S.hotSigLen
    for i = 1, n do
        tokenBuf[i] = string.char(bit32.bxor((string.byte(stamp, i) + i) % 256, sig[(i - 1) % sigLen + 1]))
    end
    return table.concat(tokenBuf, "", 1, n)
end

local function refreshCachedToken()
    if not S.hotSigLen or not S.hotSigBytes then return end
    local now = os.clock()
    if now - S.lastTokenGenTime < 0.05 then return end
    S.lastTokenGenTime = now
    local stampNum = math.floor(GetServerTimeNow(ws) * 100)
    if stampNum == S.cachedTokenStamp then return end
    S.cachedTokenStamp = stampNum
    local stamp = tostring(stampNum)
    local n = #stamp
    local sig = S.hotSigBytes
    local sigLen = S.hotSigLen
    for i = 1, n do
        tokenBuf[i] = string.char(bit32.bxor((string.byte(stamp, i) + i) % 256, sig[(i - 1) % sigLen + 1]))
    end
    S.cachedToken = table.concat(tokenBuf, "", 1, n)
end

local function getTarget()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local best, dist
    local rootPos = root.Position
    for _, other in ipairs(Players:GetPlayers()) do
        if other ~= LocalPlayer and other.Character then
            local otherRoot = other.Character:FindFirstChild("HumanoidRootPart")
            if otherRoot then
                local humanoid = other.Character:FindFirstChildOfClass("Humanoid")
                if humanoid and humanoid.Health > 0 then
                    local d = (otherRoot.Position - rootPos).Magnitude
                    if not dist or d < dist then
                        dist, best = d, otherRoot.Position
                    end
                end
            end
        end
    end
    return best
end

local function refreshTarget()
    local now = os.clock()
    if now - S.lastTargetRefresh < S.targetRefreshInterval then return end
    S.lastTargetRefresh = now
    S.cachedTargetPos = getTarget()
end

local function refreshPayload()
    local now = os.clock()
    if now - S.lastPayloadRefresh < S.payloadRefreshThreshold then return end
    S.lastPayloadRefresh = now
    refreshTarget()
    S.cachedScale = S.CONFIG.FireArg
    local camCFrame = Camera.CFrame
    if S.cachedTargetPos then
        S.cachedCframe = CFrame.new(camCFrame.Position, S.cachedTargetPos)
    else
        S.cachedCframe = camCFrame
    end
    if now - S.lastScreenRefresh >= S.screenRefreshThreshold then
        S.lastScreenRefresh = now
        table.clear(S.cachedScreen)
        local aliveFolder = getAliveFolder()
        if aliveFolder then
            for _, char in ipairs(aliveFolder:GetChildren()) do
                local hrp = char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    S.cachedScreen[char.Name] = Camera:WorldToScreenPoint(hrp.Position)
                end
            end
        end
        local vp = Camera.ViewportSize
        S.cachedAim[1] = vp.X / 2
        S.cachedAim[2] = vp.Y / 2
    end
end

local function fireServer()
    if not S.remotesHook.tokenFn then return false end
    if not S.hotRemote or not S.fireMethod then refreshHot() end
    if not S.hotRemote or not S.fireMethod then
        if not S.remotesHook.firstSignal then
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
            S.remotesHook.firstSignal = SignalMod.new()
            S.remotesHook.firstSignal:Connect(PRY)
        end
        local vp = Camera.ViewportSize
        S.remotesHook.firstSignal:Fire(S.CONFIG.FireArg, Camera.CFrame, {}, {vp.X / 2, vp.Y / 2}, false)
        return true
    end
    refreshPayload()
    if not S.cachedCframe then S.cachedCframe = Camera.CFrame end
    local tok = fastTokenize()
    S.fireMethod(S.hotRemote, S.hotArgs1, S.hotArgs2, tok, S.cachedScale, S.cachedCframe, S.cachedScreen, S.cachedAim, false)
    return true
end

do
    local net = ReplicatedStorage:FindFirstChild("Packages")
        and ReplicatedStorage.Packages:FindFirstChild("_Index")
        and ReplicatedStorage.Packages._Index:FindFirstChild("sleitnick_net@0.1.0")
        and ReplicatedStorage.Packages._Index["sleitnick_net@0.1.0"]:FindFirstChild("net")
    if net then
        for _, child in ipairs(net:GetChildren()) do
            if child:IsA("UnreliableRemoteEvent") and child.Name ~= "URE/ReplicateBallPosition" then
                S.ballReplicator = child
                break
            end
        end
    end
end

local ballsFolder = ws:FindFirstChild("Balls")
if S.ballReplicator and ballsFolder then
    S.ballReplicator.OnClientEvent:Connect(function(ball, pos)
        if ball and ball.Parent == ballsFolder and ball:GetAttribute("realBall") == true then
            S.ballPositions[ball] = pos
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
    return S.ballPositions[ball] or ball.Position
end

local function triggerFire(ball)
    if not S.triggerEnabled then return end
    if ball:GetAttribute("target") ~= localName then return end
    if not S.hotRemote or not S.fireMethod then
        if next(S.remotesHook.captured) ~= nil then refreshHot() end
        if not S.hotRemote or not S.fireMethod then
            pcall(fireServer)
            return
        end
    end
    local now = os.clock()
    if now - (S.ballTriggerTimes[ball] or 0) < 0.015 then return end
    S.ballTriggerTimes[ball] = now
    refreshPayload()
    local cf = CFrame.new(Camera.CFrame.Position, S.ballPositions[ball] or ball.Position)
    local tok = fastTokenize()
    S.fireMethod(S.hotRemote, S.hotArgs1, S.hotArgs2, tok, S.cachedScale, cf, S.cachedScreen, S.cachedAim, false)
end

local function isCurved(ball)
    local zoomies = ball:FindFirstChild("zoomies")
    if not zoomies then return false end
    local char = LocalPlayer.Character
    if not char or not char.PrimaryPart then return false end
    local t = os.clock()
    local ping = S.pingSmoothed > 0 and S.pingSmoothed or dataPing:GetValue()
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
    S.ballState.LerpRadians = S.ballState.LerpRadians
        + (math.rad(math.asin(math.clamp(dot, -1, 1))) - S.ballState.LerpRadians) * 0.8
    if speed > 100 and n33 > ping / 10 then
        n34 = math.max(n34 - 15, 15)
    end
    if dist < n34 then return false end
    if n31 < n32 then return true end
    if S.ballState.LerpRadians < 0.018 then S.ballState.LastWarping = t end
    if t - S.ballState.LastWarping < n33 / 1.5 then return true end
    if t - S.ballState.Curving < n33 / 1.5 then return true end
    return dot < n32
end

local function bindBall(ball)
    local function onChange()
        S.ballDebounce = false
        S.ballUntilAt = 0
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
        S.ballDebounce = false
        S.ballUntilAt = 0
        bindBall(child)
    end)
    balls.ChildRemoved:Connect(function(child)
        S.ballPositions[child] = nil
        S.ballDebounce = false
        S.ballUntilAt = 0
    end)
    for _, child in ipairs(balls:GetChildren()) do
        bindBall(child)
    end
end)

local function saveProp(inst, prop)
    local s = S.noRender.saved[inst]
    if not s then
        s = {}
        S.noRender.saved[inst] = s
    end
    if s[prop] == nil then
        s[prop] = inst[prop]
    end
end

local function killEffect(inst)
    local cls = inst.ClassName
    if cls == "ParticleEmitter" or cls == "Trail" or cls == "Beam"
        or cls == "Smoke" or cls == "Fire" or cls == "Sparkles"
        or cls == "Explosion" or cls == "Highlight" then
        if inst.Enabled then
            saveProp(inst, "Enabled")
            inst.Enabled = false
        end
    elseif cls == "PointLight" or cls == "SpotLight" or cls == "SurfaceLight" then
        if inst.Enabled then
            saveProp(inst, "Enabled")
            inst.Enabled = false
        end
        if inst.Brightness ~= 0 then
            saveProp(inst, "Brightness")
            inst.Brightness = 0
        end
    elseif cls == "Decal" or cls == "Texture" then
        if inst.Transparency ~= 1 then
            saveProp(inst, "Transparency")
            inst.Transparency = 1
        end
    elseif cls == "SurfaceGui" or cls == "BillboardGui" then
        if inst.Enabled then
            saveProp(inst, "Enabled")
            inst.Enabled = false
        end
    elseif cls == "ViewportFrame" then
        if inst.Visible then
            saveProp(inst, "Visible")
            inst.Visible = false
        end
    elseif cls == "Sound" or cls == "SoundGroup" then
        if inst.Volume ~= 0 then
            saveProp(inst, "Volume")
            inst.Volume = 0
        end
        if inst.IsPlaying then pcall(function() inst:Stop() end) end
    end
end

local function killEnv(inst)
    if inst:IsA("PostEffect") then
        if inst.Enabled then
            saveProp(inst, "Enabled")
            inst.Enabled = false
        end
    elseif inst:IsA("Atmosphere") then
        if inst.Density ~= 0 then
            saveProp(inst, "Density")
            inst.Density = 0
        end
    elseif inst:IsA("Clouds") then
        if inst.Cover ~= 0 then
            saveProp(inst, "Cover")
            inst.Cover = 0
        end
    elseif inst:IsA("Sky") then
        for _, p in ipairs({"SkyboxBk","SkyboxDn","SkyboxFt","SkyboxLf","SkyboxRt","SkyboxUp","SunTextureId","MoonTextureId"}) do
            if inst[p] ~= "" then
                saveProp(inst, p)
                inst[p] = ""
            end
        end
    end
end

local function applyNoRender()
    local s = S.noRender.saved[Lighting]
    if not s then s = {}; S.noRender.saved[Lighting] = s end
    s.Ambient = Lighting.Ambient
    s.OutdoorAmbient = Lighting.OutdoorAmbient
    s.Brightness = Lighting.Brightness
    s.GlobalShadows = Lighting.GlobalShadows
    s.FogEnd = Lighting.FogEnd
    s.FogStart = Lighting.FogStart
    s.ClockTime = Lighting.ClockTime

    Lighting.Ambient = Color3.fromRGB(180, 180, 180)
    Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
    Lighting.Brightness = 2
    Lighting.GlobalShadows = false
    Lighting.FogEnd = 1e10
    Lighting.FogStart = 0
    Lighting.ClockTime = 12

    for _, c in ipairs(Lighting:GetChildren()) do
        killEnv(c)
    end

    local terrain = ws:FindFirstChildOfClass("Terrain")
    if terrain then
        if terrain.WaterWaveSize ~= 0 then
            saveProp(terrain, "WaterWaveSize")
            terrain.WaterWaveSize = 0
        end
        if terrain.WaterWaveSpeed ~= 0 then
            saveProp(terrain, "WaterWaveSpeed")
            terrain.WaterWaveSpeed = 0
        end
    end

    for _, d in ipairs(ws:GetDescendants()) do
        local cls = d.ClassName
        if cls == "ParticleEmitter" or cls == "Trail" or cls == "Beam"
            or cls == "Smoke" or cls == "Fire" or cls == "Sparkles"
            or cls == "Explosion" or cls == "Highlight"
            or cls == "PointLight" or cls == "SpotLight" or cls == "SurfaceLight"
            or cls == "Decal" or cls == "Texture"
            or cls == "SurfaceGui" or cls == "BillboardGui" or cls == "ViewportFrame"
            or cls == "Sound" or cls == "SoundGroup" then
            killEffect(d)
        elseif d:IsA("BasePart") then
            if d.CastShadow then
                saveProp(d, "CastShadow")
                d.CastShadow = false
            end
            if d:FindFirstAncestorWhichIsA("Accessory") and d.Transparency ~= 1 then
                saveProp(d, "Transparency")
                d.Transparency = 1
            end
        elseif cls == "ImageLabel" or cls == "ImageButton" then
            if not d:IsDescendantOf(PlayerGui) and d.Image ~= "" then
                saveProp(d, "Image")
                d.Image = ""
            end
        end
    end
end

local function restoreNoRender()
    for inst, s in next, S.noRender.saved do
        if inst == Lighting then
            if s.Ambient then Lighting.Ambient = s.Ambient end
            if s.OutdoorAmbient then Lighting.OutdoorAmbient = s.OutdoorAmbient end
            if s.Brightness then Lighting.Brightness = s.Brightness end
            if s.GlobalShadows ~= nil then Lighting.GlobalShadows = s.GlobalShadows end
            if s.FogEnd then Lighting.FogEnd = s.FogEnd end
            if s.FogStart then Lighting.FogStart = s.FogStart end
            if s.ClockTime then Lighting.ClockTime = s.ClockTime end
        else
            for prop, v in next, s do
                pcall(function() inst[prop] = v end)
            end
        end
    end
    table.clear(S.noRender.saved)
end

local function enableNoRender()
    if S.noRender.enabled then return end
    S.noRender.enabled = true
    task.spawn(applyNoRender)

    S.noRender.descConn = ws.DescendantAdded:Connect(function(d)
        if not S.noRender.enabled then return end
        if d:IsDescendantOf(PlayerGui) then return end
        local cls = d.ClassName
        if cls == "ParticleEmitter" or cls == "Trail" or cls == "Beam"
            or cls == "Smoke" or cls == "Fire" or cls == "Sparkles"
            or cls == "Explosion" or cls == "Highlight"
            or cls == "PointLight" or cls == "SpotLight" or cls == "SurfaceLight"
            or cls == "Decal" or cls == "Texture"
            or cls == "SurfaceGui" or cls == "BillboardGui" or cls == "ViewportFrame"
            or cls == "Sound" or cls == "SoundGroup" then
            task.defer(function()
                if S.noRender.enabled and d.Parent then
                    killEffect(d)
                end
            end)
        end
    end)

    S.noRender.lightingConn = Lighting.ChildAdded:Connect(function(c)
        if not S.noRender.enabled then return end
        task.defer(function()
            if S.noRender.enabled and c.Parent then
                killEnv(c)
            end
        end)
    end)
end

local function disableNoRender()
    if not S.noRender.enabled then return end
    S.noRender.enabled = false
    if S.noRender.descConn then
        S.noRender.descConn:Disconnect()
        S.noRender.descConn = nil
    end
    if S.noRender.lightingConn then
        S.noRender.lightingConn:Disconnect()
        S.noRender.lightingConn = nil
    end
    restoreNoRender()
end

local function resetPI()
    PI.integral = 0
    PI.residual = 0
    PI.ema_error = 0
    PI.drift_accum = 0
    PI.tick_n = 0
    PI.suppressed = 0
    PI.phase_offset = 0
    PI.nano_cd = 16
    PI.micro_cd = 64
    PI.session_start = os.clock()
    PI.ema_one_minus = 1 - PI.ema_alpha
    PI.ring_head = 0
    for i = 1, PI.ring_size do PI.ring[i] = 0 end
end

local function applyRPS(rps)
    rps = math.clamp(rps, 1, 640)
    S.spamState.rate = rps
    PI.interval = 1 / rps
    PI.integral_cap = 2 * PI.interval
    PI.deadband = PI.interval * 0.015
    PI.nano_clamp = PI.interval * 0.2
    PI.micro_clamp = PI.interval * 0.4
    PI.half_interval = PI.interval * 0.5
    PI.max_lag = PI.interval
    PI.max_fires_per_frame = math.max(20, math.floor(rps * 0.05 * 2))
end

local arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8

local function refreshSpamArgs()
    arg1 = S.hotArgs1
    arg2 = S.hotArgs2
    arg3 = S.cachedToken
    arg4 = S.cachedScale
    arg5 = S.cachedCframe
    arg6 = S.cachedScreen
    arg7 = S.cachedAim
    arg8 = false
end

local function spamTick()
    if not S.spamState.enabled then return end
    if not S.hotRemote or not S.fireMethod then
        if next(S.remotesHook.captured) ~= nil then refreshHot() end
        if not S.hotRemote or not S.fireMethod then return end
    end

    local now = os.clock()
    local ideal = PI.session_start + (PI.tick_n - PI.suppressed) * PI.interval + PI.phase_offset
    local firesDue = math.floor((now - ideal) / PI.interval) + 1
    if firesDue <= 0 then return end
    if firesDue > PI.max_fires_per_frame then firesDue = PI.max_fires_per_frame end

    refreshPayload()
    refreshCachedToken()
    refreshSpamArgs()

    local a1, a2, a3, a4, a5, a6, a7, a8 = arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8
    local remote = S.hotRemote
    local method = S.fireMethod

    for i = 1, firesDue do
        method(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        PI.tick_n = PI.tick_n + 1
        PI.ring_head = (PI.ring_head % PI.ring_size) + 1
        PI.ring[PI.ring_head] = now
    end

    local abs_elapsed = now - PI.session_start
    local abs_expected = (PI.tick_n - PI.suppressed) * PI.interval

    PI.nano_cd = PI.nano_cd - firesDue
    while PI.nano_cd <= 0 do
        PI.nano_cd = PI.nano_cd + 16
        local err = abs_elapsed - abs_expected
        if err > PI.nano_clamp then err = PI.nano_clamp
        elseif err < -PI.nano_clamp then err = -PI.nano_clamp end
        PI.phase_offset = PI.phase_offset - err * PI.nano_gain
    end

    PI.micro_cd = PI.micro_cd - firesDue
    while PI.micro_cd <= 0 do
        PI.micro_cd = PI.micro_cd + 64
        local err = abs_elapsed - abs_expected
        if err > PI.micro_clamp then err = PI.micro_clamp
        elseif err < -PI.micro_clamp then err = -PI.micro_clamp end
        PI.phase_offset = PI.phase_offset - err * PI.micro_gain
    end

    local raw_error = abs_elapsed - abs_expected
    PI.ema_error = PI.ema_one_minus * PI.ema_error + PI.ema_alpha * raw_error
    local error = PI.ema_error

    if error > PI.deadband or error < -PI.deadband then
        PI.integral = PI.integral + error
        if PI.integral > PI.integral_cap then PI.integral = PI.integral_cap
        elseif PI.integral < -PI.integral_cap then PI.integral = -PI.integral_cap end
        local correction = PI.kp * error + PI.ki * PI.integral
        PI.drift_accum = PI.drift_accum + correction
        local carry = math.floor(PI.drift_accum / PI.interval + 0.5) * PI.interval
        PI.drift_accum = PI.drift_accum - carry
        PI.residual = PI.residual + (correction - carry)
        local res_carry = math.floor(PI.residual / PI.interval + 0.5) * PI.interval
        PI.residual = PI.residual - res_carry
        PI.phase_offset = PI.phase_offset - correction
    else
        PI.integral = PI.integral * PI.decay
    end

    local next_ideal = PI.session_start + (PI.tick_n - PI.suppressed) * PI.interval + PI.phase_offset
    local lag = now - next_ideal
    if lag > PI.max_lag then
        PI.session_start = now - (PI.tick_n - PI.suppressed) * PI.interval - PI.phase_offset
        PI.suppressed = PI.suppressed + 1
    elseif lag > PI.half_interval then
        PI.session_start = PI.session_start + lag * 0.5
    end
end

local function ensureHot()
    if S.hotRemote and S.fireMethod then
        if S.refreshLoopConn then
            S.refreshLoopConn:Disconnect()
            S.refreshLoopConn = nil
        end
        return
    end
    if next(S.remotesHook.captured) ~= nil then
        refreshHot()
    end
    if S.hotRemote and S.fireMethod and S.refreshLoopConn then
        S.refreshLoopConn:Disconnect()
        S.refreshLoopConn = nil
    end
end

S.refreshLoopConn = RunService.Heartbeat:Connect(ensureHot)
RunService.PreSimulation:Connect(spamTick)
RunService.Heartbeat:Connect(spamTick)

local Theme = {
    bg          = Color3.fromRGB(16, 16, 19),
    bgGrad1     = Color3.fromRGB(24, 24, 30),
    bgGrad2     = Color3.fromRGB(14, 14, 18),
    sidebar     = Color3.fromRGB(12, 12, 15),
    card        = Color3.fromRGB(28, 28, 34),
    cardHover   = Color3.fromRGB(36, 36, 44),
    stroke      = Color3.fromRGB(44, 44, 54),
    strokeLight = Color3.fromRGB(60, 60, 72),
    text        = Color3.fromRGB(248, 248, 252),
    textDim     = Color3.fromRGB(150, 150, 160),
    textMuted   = Color3.fromRGB(96, 96, 106),
    accent      = Color3.fromRGB(110, 220, 150),
    accentDim   = Color3.fromRGB(70, 150, 100),
    danger      = Color3.fromRGB(240, 100, 100),
    warn        = Color3.fromRGB(245, 190, 100),
    toggleOff   = Color3.fromRGB(52, 52, 62),
    knob        = Color3.fromRGB(240, 240, 248),
    keybg       = Color3.fromRGB(18, 18, 22),
    chip        = Color3.fromRGB(36, 36, 44),
}

local function tween(obj, props, dur)
    TweenService:Create(obj, TweenInfo.new(dur or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local activeDrag = nil

local function hideDragBlocker()
    if DragBlocker then
        DragBlocker.Visible = false
    end
end

local function showDragBlocker()
    if DragBlocker then
        DragBlocker.Visible = true
    end
end

UserInputService.InputChanged:Connect(function(input)
    local d = activeDrag
    if not d then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
        d.onMove(input.Position.X, input.Position.Y)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
        local d = activeDrag
        activeDrag = nil
        hideDragBlocker()
        if d and d.onEnd then
            d.onEnd()
        end
    end
end)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "HAHA_dll"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 999
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent = PlayerGui

local DragBlocker = Instance.new("TextButton")
DragBlocker.Name = "DragBlocker"
DragBlocker.Size = UDim2.new(1, 0, 1, 0)
DragBlocker.Position = UDim2.new(0, 0, 0, 0)
DragBlocker.BackgroundTransparency = 1
DragBlocker.Text = ""
DragBlocker.BorderSizePixel = 0
DragBlocker.AutoButtonColor = false
DragBlocker.Visible = false
DragBlocker.ZIndex = 2147483647
DragBlocker.Parent = ScreenGui

local PANEL_W = 500
local PANEL_H = 380
local SIDEBAR_W = 140

local Shadow = Instance.new("Frame")
Shadow.Size = UDim2.new(0, PANEL_W + 8, 0, PANEL_H + 8)
Shadow.Position = UDim2.new(0.5, -(PANEL_W + 8) / 2, 0.5, -(PANEL_H + 8) / 2)
Shadow.BackgroundColor3 = Color3.new(0, 0, 0)
Shadow.BackgroundTransparency = 0.4
Shadow.BorderSizePixel = 0
Shadow.ZIndex = 1
Shadow.Parent = ScreenGui
Instance.new("UICorner", Shadow).CornerRadius = UDim.new(0, 20)

local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, PANEL_W, 0, PANEL_H)
MainFrame.Position = UDim2.new(0.5, -PANEL_W / 2, 0.5, -PANEL_H / 2)
MainFrame.BackgroundColor3 = Theme.bg
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.ZIndex = 2
MainFrame.Active = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 18)

local frameStroke = Instance.new("UIStroke")
frameStroke.Color = Theme.strokeLight
frameStroke.Thickness = 1
frameStroke.Transparency = 0.5
frameStroke.Parent = MainFrame

local frameGrad = Instance.new("UIGradient")
frameGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Theme.bgGrad1),
    ColorSequenceKeypoint.new(1, Theme.bgGrad2),
})
frameGrad.Rotation = 135
frameGrad.Parent = MainFrame

local Sidebar = Instance.new("Frame")
Sidebar.Name = "Sidebar"
Sidebar.Size = UDim2.new(0, SIDEBAR_W, 1, 0)
Sidebar.BackgroundColor3 = Theme.sidebar
Sidebar.BorderSizePixel = 0
Sidebar.ZIndex = 3
Sidebar.Active = true
Sidebar.Parent = MainFrame

local sbCorner = Instance.new("UICorner")
sbCorner.CornerRadius = UDim.new(0, 18)
sbCorner.Parent = Sidebar

local sbCover = Instance.new("Frame")
sbCover.Size = UDim2.new(0, 16, 1, 0)
sbCover.Position = UDim2.new(1, -16, 0, 0)
sbCover.BackgroundColor3 = Theme.sidebar
sbCover.BorderSizePixel = 0
sbCover.ZIndex = 3
sbCover.Parent = Sidebar

local sbStroke = Instance.new("UIStroke")
sbStroke.Color = Theme.stroke
sbStroke.Thickness = 1
sbStroke.Transparency = 0.4
sbStroke.Parent = Sidebar

local brandWrap = Instance.new("Frame")
brandWrap.Size = UDim2.new(1, -24, 0, 44)
brandWrap.Position = UDim2.new(0, 12, 0, 16)
brandWrap.BackgroundTransparency = 1
brandWrap.ZIndex = 4
brandWrap.Parent = Sidebar

local brandGlow = Instance.new("Frame")
brandGlow.Size = UDim2.new(0, 32, 0, 32)
brandGlow.Position = UDim2.new(0, 0, 0, 6)
brandGlow.BackgroundColor3 = Theme.accent
brandGlow.BackgroundTransparency = 0.85
brandGlow.BorderSizePixel = 0
brandGlow.ZIndex = 4
brandGlow.Parent = brandWrap
Instance.new("UICorner", brandGlow).CornerRadius = UDim.new(1, 0)

local brandIcon = Instance.new("Frame")
brandIcon.Size = UDim2.new(0, 26, 0, 26)
brandIcon.Position = UDim2.new(0, 3, 0, 9)
brandIcon.BackgroundColor3 = Theme.accent
brandIcon.BorderSizePixel = 0
brandIcon.ZIndex = 5
brandIcon.Parent = brandWrap
Instance.new("UICorner", brandIcon).CornerRadius = UDim.new(0, 8)

local brandIconGrad = Instance.new("UIGradient")
brandIconGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(140, 240, 170)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(70, 180, 110)),
})
brandIconGrad.Rotation = 135
brandIconGrad.Parent = brandIcon

local brandIconLbl = Instance.new("TextLabel")
brandIconLbl.Size = UDim2.new(1, 0, 1, 0)
brandIconLbl.BackgroundTransparency = 1
brandIconLbl.Text = "H"
brandIconLbl.TextColor3 = Color3.fromRGB(16, 24, 18)
brandIconLbl.Font = Enum.Font.GothamBlack
brandIconLbl.TextSize = 15
brandIconLbl.ZIndex = 6
brandIconLbl.Parent = brandIcon

local brandTitle = Instance.new("TextLabel")
brandTitle.Size = UDim2.new(1, -34, 0, 16)
brandTitle.Position = UDim2.new(0, 34, 0, 8)
brandTitle.BackgroundTransparency = 1
brandTitle.Text = "HAHA.dll"
brandTitle.TextColor3 = Theme.text
brandTitle.Font = Enum.Font.GothamBold
brandTitle.TextSize = 13
brandTitle.TextXAlignment = Enum.TextXAlignment.Left
brandTitle.ZIndex = 4
brandTitle.Parent = brandWrap

local brandSub = Instance.new("TextLabel")
brandSub.Size = UDim2.new(1, -34, 0, 12)
brandSub.Position = UDim2.new(0, 34, 0, 24)
brandSub.BackgroundTransparency = 1
brandSub.Text = "premium build"
brandSub.TextColor3 = Theme.textMuted
brandSub.Font = Enum.Font.Gotham
brandSub.TextSize = 8
brandSub.TextXAlignment = Enum.TextXAlignment.Left
brandSub.ZIndex = 4
brandSub.Parent = brandWrap

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -32, 0, 26)
closeBtn.BackgroundColor3 = Theme.card
closeBtn.BorderSizePixel = 0
closeBtn.Text = "×"
closeBtn.TextColor3 = Theme.textDim
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 18
closeBtn.AutoButtonColor = false
closeBtn.ZIndex = 4
closeBtn.Parent = Sidebar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 7)

local closeStroke = Instance.new("UIStroke")
closeStroke.Color = Theme.stroke
closeStroke.Thickness = 1
closeStroke.Parent = closeBtn

local TabList = Instance.new("Frame")
TabList.Size = UDim2.new(1, -16, 1, -160)
TabList.Position = UDim2.new(0, 8, 0, 80)
TabList.BackgroundTransparency = 1
TabList.ZIndex = 4
TabList.Parent = Sidebar
local tabListLayout = Instance.new("UIListLayout")
tabListLayout.Padding = UDim.new(0, 4)
tabListLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabListLayout.Parent = TabList

local versionTag = Instance.new("TextLabel")
versionTag.Size = UDim2.new(1, -24, 0, 16)
versionTag.Position = UDim2.new(0, 12, 1, -28)
versionTag.BackgroundTransparency = 1
versionTag.Text = "v3.0.1"
versionTag.TextColor3 = Theme.textMuted
versionTag.Font = Enum.Font.Gotham
versionTag.TextSize = 9
versionTag.TextXAlignment = Enum.TextXAlignment.Left
versionTag.ZIndex = 4
versionTag.Parent = Sidebar

local Content = Instance.new("Frame")
Content.Name = "Content"
Content.Size = UDim2.new(1, -SIDEBAR_W, 1, 0)
Content.Position = UDim2.new(0, SIDEBAR_W, 0, 0)
Content.BackgroundTransparency = 1
Content.ZIndex = 3
Content.Parent = MainFrame

local contentHeader = Instance.new("Frame")
contentHeader.Size = UDim2.new(1, -40, 0, 60)
contentHeader.Position = UDim2.new(0, 20, 0, 0)
contentHeader.BackgroundTransparency = 1
contentHeader.ZIndex = 4
contentHeader.Parent = Content

local pageTitle = Instance.new("TextLabel")
pageTitle.Size = UDim2.new(1, 0, 0, 22)
pageTitle.Position = UDim2.new(0, 0, 0, 16)
pageTitle.BackgroundTransparency = 1
pageTitle.Text = "Combat"
pageTitle.TextColor3 = Theme.text
pageTitle.Font = Enum.Font.GothamBold
pageTitle.TextSize = 18
pageTitle.TextXAlignment = Enum.TextXAlignment.Left
pageTitle.ZIndex = 4
pageTitle.Parent = contentHeader

local pageSub = Instance.new("TextLabel")
pageSub.Size = UDim2.new(1, 0, 0, 14)
pageSub.Position = UDim2.new(0, 0, 0, 38)
pageSub.BackgroundTransparency = 1
pageSub.Text = "Toggles and automation"
pageSub.TextColor3 = Theme.textMuted
pageSub.Font = Enum.Font.Gotham
pageSub.TextSize = 10
pageSub.TextXAlignment = Enum.TextXAlignment.Left
pageSub.ZIndex = 4
pageSub.Parent = contentHeader

local headerGlow = Instance.new("Frame")
headerGlow.Size = UDim2.new(0, 40, 0, 3)
headerGlow.Position = UDim2.new(0, 0, 0, 56)
headerGlow.BackgroundColor3 = Theme.accent
headerGlow.BorderSizePixel = 0
headerGlow.ZIndex = 4
headerGlow.Parent = contentHeader
Instance.new("UICorner", headerGlow).CornerRadius = UDim.new(1, 0)

local PageContainer = Instance.new("Frame")
PageContainer.Size = UDim2.new(1, -32, 1, -80)
PageContainer.Position = UDim2.new(0, 16, 0, 68)
PageContainer.BackgroundTransparency = 1
PageContainer.ClipsDescendants = true
PageContainer.ZIndex = 4
PageContainer.Parent = Content

local PageScroll = Instance.new("ScrollingFrame")
PageScroll.Size = UDim2.new(1, 0, 1, 0)
PageScroll.BackgroundTransparency = 1
PageScroll.BorderSizePixel = 0
PageScroll.ScrollBarThickness = 3
PageScroll.ScrollBarImageColor3 = Theme.strokeLight
PageScroll.ScrollBarImageTransparency = 0.3
PageScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
PageScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
PageScroll.ZIndex = 4
PageScroll.Parent = PageContainer

local pageLayout = Instance.new("UIListLayout")
pageLayout.Padding = UDim.new(0, 8)
pageLayout.SortOrder = Enum.SortOrder.LayoutOrder
pageLayout.Parent = PageScroll

local pagePadding = Instance.new("UIPadding")
pagePadding.PaddingTop = UDim.new(0, 4)
pagePadding.PaddingBottom = UDim.new(0, 16)
pagePadding.Parent = PageScroll

local pages = {}
local currentTab = nil
local pageTitleRef = pageTitle
local pageSubRef = pageSub
local headerGlowRef = headerGlow
local pageScrollRef = PageScroll
local tabListRef = TabList

local function makeToggle(parent, label, onChanged, keybindTarget)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -8, 0, 46)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.Text = ""
    row.AutoButtonColor = false
    row.ZIndex = 5
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 10)

    local rowStroke = Instance.new("UIStroke")
    rowStroke.Color = Theme.stroke
    rowStroke.Thickness = 1
    rowStroke.Transparency = 0.4
    rowStroke.Parent = row

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, keybindTarget and -136 or -80, 1, 0)
    lbl.Position = UDim2.new(0, 16, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = Theme.text
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.ZIndex = 6
    lbl.Parent = row

    if keybindTarget then
        local box = Instance.new("TextBox")
        box.Size = UDim2.new(0, 56, 0, 24)
        box.Position = UDim2.new(0, 100, 0.5, -12)
        box.BackgroundColor3 = Theme.keybg
        box.BorderSizePixel = 0
        box.Text = keyName(keybindTarget.table[keybindTarget.name])
        box.TextColor3 = Theme.accent
        box.Font = Enum.Font.GothamBold
        box.TextSize = 11
        box.TextXAlignment = Enum.TextXAlignment.Center
        box.ClearTextOnFocus = false
        box.ZIndex = 6
        box.Parent = row
        pcall(function() box.TextEditable = false end)
        Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)
        local boxStroke = Instance.new("UIStroke")
        boxStroke.Color = Theme.stroke
        boxStroke.Thickness = 1
        boxStroke.Parent = box
        box.Focused:Connect(function()
            S.armingBox = box
            S.armingKey = keybindTarget
            box.Text = "..."
            boxStroke.Color = Theme.accent
            boxStroke.Thickness = 2
        end)
        box.FocusLost:Connect(function()
            if S.armingBox == box then
                S.armingBox = nil
                S.armingKey = nil
            end
            box.Text = keyName(keybindTarget.table[keybindTarget.name])
            boxStroke.Color = Theme.stroke
            boxStroke.Thickness = 1
        end)
    end

    local bg = Instance.new("Frame")
    bg.Size = UDim2.new(0, 42, 0, 22)
    bg.Position = UDim2.new(1, -58, 0.5, -11)
    bg.BackgroundColor3 = Theme.toggleOff
    bg.BorderSizePixel = 0
    bg.ZIndex = 6
    bg.Parent = row
    Instance.new("UICorner", bg).CornerRadius = UDim.new(1, 0)

    local bgStroke = Instance.new("UIStroke")
    bgStroke.Color = Theme.stroke
    bgStroke.Thickness = 1
    bgStroke.Parent = bg

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 16, 0, 16)
    knob.Position = UDim2.new(0, 3, 0.5, -8)
    knob.BackgroundColor3 = Theme.knob
    knob.BorderSizePixel = 0
    knob.ZIndex = 7
    knob.Parent = bg
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local state = false
    local function setState(s)
        state = s
        tween(knob, {
            Position = s and UDim2.new(0, 23, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
        }, 0.2)
        TweenService:Create(bg, TweenInfo.new(0.2), {
            BackgroundColor3 = s and Theme.accent or Theme.toggleOff
        }):Play()
        TweenService:Create(bgStroke, TweenInfo.new(0.2), {
            Transparency = s and 1 or 0,
        }):Play()
        TweenService:Create(rowStroke, TweenInfo.new(0.2), {
            Color = s and Theme.accent or Theme.stroke,
            Transparency = s and 0.3 or 0.4,
        }):Play()
        if onChanged then onChanged(s) end
    end

    row.MouseButton1Click:Connect(function()
        if S.armingBox then return end
        setState(not state)
    end)
    row.MouseEnter:Connect(function()
        if not state then tween(row, { BackgroundColor3 = Theme.cardHover }, 0.12) end
    end)
    row.MouseLeave:Connect(function()
        if not state then tween(row, { BackgroundColor3 = Theme.card }, 0.12) end
    end)

    return { set = setState, get = function() return state end, row = row }
end

local function makeSlider(parent, label, min, max, initial, onChanged)
    local container = Instance.new("Frame")
    container.Size = UDim2.new(1, -8, 0, 62)
    container.BackgroundColor3 = Theme.card
    container.BorderSizePixel = 0
    container.ZIndex = 5
    container.Parent = parent
    Instance.new("UICorner", container).CornerRadius = UDim.new(0, 10)

    local rowStroke = Instance.new("UIStroke")
    rowStroke.Color = Theme.stroke
    rowStroke.Thickness = 1
    rowStroke.Transparency = 0.4
    rowStroke.Parent = container

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.6, 0, 0, 16)
    lbl.Position = UDim2.new(0, 16, 0, 6)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = Theme.text
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.ZIndex = 6
    lbl.Parent = container

    local valChip = Instance.new("Frame")
    valChip.Size = UDim2.new(0, 44, 0, 20)
    valChip.Position = UDim2.new(1, -60, 0, 5)
    valChip.BackgroundColor3 = Theme.chip
    valChip.BorderSizePixel = 0
    valChip.ZIndex = 6
    valChip.Parent = container
    Instance.new("UICorner", valChip).CornerRadius = UDim.new(0, 5)

    local valLabel = Instance.new("TextLabel")
    valLabel.Size = UDim2.new(1, 0, 1, 0)
    valLabel.BackgroundTransparency = 1
    valLabel.Text = tostring(initial)
    valLabel.TextColor3 = Theme.accent
    valLabel.Font = Enum.Font.GothamBold
    valLabel.TextSize = 12
    valLabel.ZIndex = 7
    valLabel.Parent = valChip

    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1, -32, 0, 12)
    sub.Position = UDim2.new(0, 16, 0, 24)
    sub.BackgroundTransparency = 1
    sub.Text = ""
    sub.TextColor3 = Theme.textMuted
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 9
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.ZIndex = 6
    sub.Parent = container

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -32, 0, 5)
    track.Position = UDim2.new(0, 16, 1, -14)
    track.BackgroundColor3 = Theme.toggleOff
    track.BorderSizePixel = 0
    track.ZIndex = 6
    track.Parent = container
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

    local initialPct = (initial - min) / (max - min)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(initialPct, 0, 1, 0)
    fill.BackgroundColor3 = Theme.accent
    fill.BorderSizePixel = 0
    fill.ZIndex = 7
    fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local fillGrad = Instance.new("UIGradient")
    fillGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Theme.accentDim),
        ColorSequenceKeypoint.new(1, Theme.accent),
    })
    fillGrad.Parent = fill

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = UDim2.new(initialPct, 0, 0.5, -7)
    knob.AnchorPoint = Vector2.new(0.5, 0)
    knob.BackgroundColor3 = Theme.knob
    knob.BorderSizePixel = 0
    knob.ZIndex = 8
    knob.Parent = track
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local value = initial
    local lastRounded = math.floor(initial + 0.5)
    local lastPct = initialPct
    local dragAbsX, dragSizeX

    local function setValue(v)
        v = math.clamp(v, min, max)
        if v == value then return end
        value = v
        local rounded = math.floor(v + 0.5)
        if rounded ~= lastRounded then
            lastRounded = rounded
            valLabel.Text = tostring(rounded)
            if onChanged then onChanged(rounded) end
        end
        local pct = (v - min) / (max - min)
        if math.abs(pct - lastPct) > 0.004 then
            lastPct = pct
            fill.Size = UDim2.new(pct, 0, 1, 0)
            knob.Position = UDim2.new(pct, 0, 0.5, -7)
        end
    end

    local function trackToValue(x)
        if not dragSizeX or dragSizeX == 0 then return end
        local pct = (x - dragAbsX) / dragSizeX
        if pct < 0 then pct = 0 elseif pct > 1 then pct = 1 end
        setValue(min + pct * (max - min))
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragAbsX = track.AbsolutePosition.X
            dragSizeX = track.AbsoluteSize.X
            activeDrag = {
                onMove = function(x) trackToValue(x) end,
                onEnd = function() hideDragBlocker() end,
            }
            showDragBlocker()
            trackToValue(input.Position.X)
        end
    end)

    return { set = setValue, get = function() return value end, sub = sub }
end

local function makeTab(name, subtitle, order)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 36)
    btn.BackgroundColor3 = Theme.card
    btn.BackgroundTransparency = 1
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.LayoutOrder = order
    btn.ZIndex = 4
    btn.Parent = tabListRef
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)

    local accentBar = Instance.new("Frame")
    accentBar.Size = UDim2.new(0, 3, 0, 20)
    accentBar.Position = UDim2.new(0, 0, 0.5, -10)
    accentBar.BackgroundColor3 = Theme.accent
    accentBar.BorderSizePixel = 0
    accentBar.BackgroundTransparency = 1
    accentBar.ZIndex = 5
    accentBar.Parent = btn
    Instance.new("UICorner", accentBar).CornerRadius = UDim.new(1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -26, 1, 0)
    lbl.Position = UDim2.new(0, 18, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = name
    lbl.TextColor3 = Theme.textDim
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.ZIndex = 5
    lbl.Parent = btn

    local page = Instance.new("Frame")
    page.Name = name .. "Page"
    page.Size = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency = 1
    page.Visible = false
    page.ZIndex = 5
    page.Parent = pageScrollRef

    local inner = Instance.new("Frame")
    inner.Size = UDim2.new(1, 0, 0, 0)
    inner.BackgroundTransparency = 1
    inner.AutomaticSize = Enum.AutomaticSize.Y
    inner.ZIndex = 5
    inner.Parent = page
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 8)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = inner

    pages[name] = { page = page, inner = inner, subtitle = subtitle, button = btn, accent = accentBar, label = lbl }

    btn.MouseEnter:Connect(function()
        if currentTab ~= name then
            tween(btn, { BackgroundColor3 = Theme.card, BackgroundTransparency = 0.4 }, 0.12)
        end
    end)
    btn.MouseLeave:Connect(function()
        if currentTab ~= name then
            tween(btn, { BackgroundTransparency = 1 }, 0.12)
        end
    end)
    btn.MouseButton1Click:Connect(function()
        for tabName, tab in pairs(pages) do
            tab.page.Visible = false
            tab.accent.BackgroundTransparency = 1
            tab.label.TextColor3 = Theme.textDim
            tab.button.BackgroundTransparency = 1
        end
        pages[name].page.Visible = true
        pages[name].accent.BackgroundTransparency = 0
        pages[name].label.TextColor3 = Theme.text
        pages[name].button.BackgroundColor3 = Theme.card
        pages[name].button.BackgroundTransparency = 0
        pageTitleRef.Text = name
        pageSubRef.Text = subtitle
        TweenService:Create(headerGlowRef, TweenInfo.new(0.25), {
            Size = UDim2.new(0, 60, 0, 3)
        }):Play()
        task.delay(0.1, function()
            TweenService:Create(headerGlowRef, TweenInfo.new(0.3), {
                Size = UDim2.new(0, 40, 0, 3)
            }):Play()
        end)
        currentTab = name
    end)

    return pages[name]
end

local combatTab = makeTab("Combat", "Toggles and automation", 1)
local movementTab = makeTab("Movement", "Orbit & rage", 2)
local perfTab = makeTab("Performance", "Lag reduction", 3)
local tuningTab = makeTab("Tuning", "Precision control", 4)
local statsTab = makeTab("Stats", "Live telemetry", 5)
local playerTab = makeTab("Player", "On-screen buttons", 6)

local AutoParry = false

makeToggle(combatTab.inner, "Auto parry", function(s) AutoParry = s end)
S.spamToggle = makeToggle(combatTab.inner, "Manual spam", function(s)
    S.spamState.enabled = s
    if s then
        if next(S.remotesHook.captured) ~= nil then refreshHot() end
        resetPI()
    end
end, { table = S.keybinds, name = "spam" })
S.triggerToggle = makeToggle(combatTab.inner, "Triggerbot", function(s)
    S.triggerEnabled = s
    if s then
        for _, ball in ipairs(getRealBalls()) do
            triggerFire(ball)
        end
    end
end, { table = S.keybinds, name = "trigger" })

S.orbitToggle = makeToggle(movementTab.inner, "Ball Orbit", function(s)
    S.orbit.enabled = s
    S.orbit.angle = 0
    S.orbit.lastTick = os.clock()
end, { table = S.keybinds, name = "orbit" })
S.rageOrbitToggle = makeToggle(movementTab.inner, "Rage Orbit", function(s)
    S.rageOrbit.enabled = s
    if s then
        task.spawn(function()
            while S.rageOrbit.enabled and S.alive do
                rageOrbitTick()
                task.wait(S.rageOrbit.cooldown)
            end
        end)
    end
end)

makeToggle(perfTab.inner, "No Render", function(s)
    if s then enableNoRender() else disableNoRender() end
end)

makeSlider(tuningTab.inner, "Spam rate (/s)", 100, 640, S.spamState.rate, function(v)
    applyRPS(v)
end)
S.accuracySlider = makeSlider(tuningTab.inner, "Accuracy", 40, 100, S.CONFIG.Accuracy, function(v) S.CONFIG.Accuracy = v end)
makeToggle(tuningTab.inner, "Auto accuracy", function(s)
    S.CONFIG.AccuracyMode = s and "auto" or "manual"
    S.lastAccuracyCalc = 0
end)

local StatsCard = Instance.new("Frame")
StatsCard.Size = UDim2.new(1, -8, 0, 138)
StatsCard.BackgroundColor3 = Theme.card
StatsCard.BorderSizePixel = 0
StatsCard.ZIndex = 5
StatsCard.Parent = statsTab.inner
Instance.new("UICorner", StatsCard).CornerRadius = UDim.new(0, 10)

local cardStroke = Instance.new("UIStroke")
cardStroke.Color = Theme.stroke
cardStroke.Thickness = 1
cardStroke.Transparency = 0.4
cardStroke.Parent = StatsCard

local cardGrad = Instance.new("UIGradient")
cardGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Theme.card),
    ColorSequenceKeypoint.new(1, Theme.cardHover),
})
cardGrad.Rotation = 90
cardGrad.Parent = StatsCard

local function makeStatRow(y, label)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(0.5, 0, 0, 24)
    l.Position = UDim2.new(0, 16, 0, y)
    l.BackgroundTransparency = 1
    l.Text = label
    l.TextColor3 = Theme.textDim
    l.Font = Enum.Font.Gotham
    l.TextSize = 11
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.ZIndex = 6
    l.Parent = StatsCard

    local v = Instance.new("TextLabel")
    v.Size = UDim2.new(0.5, 0, 0, 24)
    v.Position = UDim2.new(0.5, -16, 0, y)
    v.BackgroundTransparency = 1
    v.Text = "--"
    v.TextColor3 = Theme.text
    v.Font = Enum.Font.GothamBold
    v.TextSize = 14
    v.TextXAlignment = Enum.TextXAlignment.Right
    v.ZIndex = 6
    v.Parent = StatsCard

    return v
end

S.statusVelocity = makeStatRow(12, "Ball velocity")
S.statusPing = makeStatRow(44, "Ping")
S.statusAcc = makeStatRow(76, "Effective accuracy")
S.statusRPS = makeStatRow(108, "Actual RPS")

currentTab = "Combat"
pages["Combat"].page.Visible = true
pages["Combat"].accent.BackgroundTransparency = 0
pages["Combat"].label.TextColor3 = Theme.text
pages["Combat"].button.BackgroundColor3 = Theme.card
pages["Combat"].button.BackgroundTransparency = 0

local function createDraggableButton(name, label, accentColor, callback)
    local btn = Instance.new("TextButton")
    btn.Name = name
    btn.Size = UDim2.new(0, 100, 0, 100)
    btn.Position = UDim2.new(0.5, -200, 0.5, 100)
    btn.BackgroundColor3 = Theme.card
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.Visible = false
    btn.ZIndex = 50
    btn.Parent = ScreenGui
    Instance.new("UICorner", btn).CornerRadius = UDim.new(1, 0)

    local btnStroke = Instance.new("UIStroke")
    btnStroke.Color = accentColor
    btnStroke.Thickness = 2
    btnStroke.Transparency = 0.3
    btnStroke.Parent = btn

    local btnGrad = Instance.new("UIGradient")
    btnGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Theme.card),
        ColorSequenceKeypoint.new(1, Theme.bgGrad2),
    })
    btnGrad.Rotation = 135
    btnGrad.Parent = btn

    local glow = Instance.new("Frame")
    glow.Size = UDim2.new(1, 16, 1, 16)
    glow.Position = UDim2.new(0, -8, 0, -8)
    glow.BackgroundColor3 = accentColor
    glow.BackgroundTransparency = 1
    glow.BorderSizePixel = 0
    glow.ZIndex = 49
    glow.Parent = btn
    Instance.new("UICorner", glow).CornerRadius = UDim.new(1, 0)

    local innerDot = Instance.new("Frame")
    innerDot.Size = UDim2.new(0, 8, 0, 8)
    innerDot.Position = UDim2.new(0.5, -4, 0, 14)
    innerDot.BackgroundColor3 = accentColor
    innerDot.BorderSizePixel = 0
    innerDot.ZIndex = 52
    innerDot.Parent = btn
    Instance.new("UICorner", innerDot).CornerRadius = UDim.new(1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.Position = UDim2.new(0, 0, 0, 8)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = Theme.text
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 20
    lbl.ZIndex = 52
    lbl.Parent = btn

    local subLbl = Instance.new("TextLabel")
    subLbl.Size = UDim2.new(1, 0, 0, 14)
    subLbl.Position = UDim2.new(0, 0, 1, -22)
    subLbl.BackgroundTransparency = 1
    subLbl.Text = "OFF"
    subLbl.TextColor3 = Theme.textMuted
    subLbl.Font = Enum.Font.GothamBold
    subLbl.TextSize = 9
    subLbl.ZIndex = 52
    subLbl.Parent = btn

    local state = false
    local function setState(s, silent)
        state = s
        if s then
            TweenService:Create(btn, TweenInfo.new(0.2), {
                BackgroundColor3 = accentColor
            }):Play()
            TweenService:Create(btnStroke, TweenInfo.new(0.2), {
                Transparency = 0, Thickness = 3
            }):Play()
            TweenService:Create(glow, TweenInfo.new(0.2), {
                BackgroundTransparency = 0.5
            }):Play()
            subLbl.Text = "ON"
            subLbl.TextColor3 = Theme.text
            lbl.TextColor3 = Color3.fromRGB(16, 24, 18)
        else
            TweenService:Create(btn, TweenInfo.new(0.2), {
                BackgroundColor3 = Theme.card
            }):Play()
            TweenService:Create(btnStroke, TweenInfo.new(0.2), {
                Transparency = 0.3, Thickness = 2
            }):Play()
            TweenService:Create(glow, TweenInfo.new(0.2), {
                BackgroundTransparency = 1
            }):Play()
            subLbl.Text = "OFF"
            subLbl.TextColor3 = Theme.textMuted
            lbl.TextColor3 = Theme.text
        end
        if callback and not silent then callback(s) end
    end

    local dragStart, startPos, isDragging, moved

    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragStart = input.Position
            startPos = btn.Position
            isDragging = true
            moved = false
            showDragBlocker()
            local changedConn, endConn
            changedConn = UserInputService.InputChanged:Connect(function(m)
                if not isDragging then return end
                if m.UserInputType == Enum.UserInputType.MouseMovement
                or m.UserInputType == Enum.UserInputType.Touch then
                    local delta = m.Position - dragStart
                    if math.abs(delta.X) > 4 or math.abs(delta.Y) > 4 then
                        moved = true
                    end
                    if moved then
                        btn.Position = UDim2.new(
                            startPos.X.Scale, startPos.X.Offset + delta.X,
                            startPos.Y.Scale, startPos.Y.Offset + delta.Y
                        )
                    end
                end
            end)
            endConn = UserInputService.InputEnded:Connect(function(e)
                if e.UserInputType == Enum.UserInputType.MouseButton1
                or e.UserInputType == Enum.UserInputType.Touch then
                    isDragging = false
                    changedConn:Disconnect()
                    endConn:Disconnect()
                    hideDragBlocker()
                    if not moved then
                        setState(not state)
                    end
                end
            end)
        end
    end)

    return {
        frame = btn,
        setVisible = function(v) btn.Visible = v end,
        setState = setState,
        get = function() return state end,
    }
end

S.spamButton = createDraggableButton("SpamButton", "SPAM", Theme.accent, function(s)
    S.spamToggle.set(s)
end)
S.triggerButton = createDraggableButton("TriggerButton", "TB", Theme.warn, function(s)
    S.triggerToggle.set(s)
end)

makeToggle(playerTab.inner, "Spam Button", function(s)
    S.spamButton.setVisible(s)
    if not s then S.spamButton.setState(false, true) end
end)
makeToggle(playerTab.inner, "Triggerbot Button", function(s)
    S.triggerButton.setVisible(s)
    if not s then S.triggerButton.setState(false, true) end
end)

closeBtn.MouseEnter:Connect(function()
    tween(closeBtn, { BackgroundColor3 = Theme.danger, TextColor3 = Color3.new(1,1,1) }, 0.12)
    tween(closeStroke, { Color = Theme.danger, Transparency = 0 }, 0.12)
end)
closeBtn.MouseLeave:Connect(function()
    tween(closeBtn, { BackgroundColor3 = Theme.card, TextColor3 = Theme.textDim }, 0.12)
    tween(closeStroke, { Color = Theme.stroke, Transparency = 0 }, 0.12)
end)

local dragStartX, dragStartY, startFramePos, startShadowPos

Sidebar.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local p = input.Position
    local cPos = closeBtn.AbsolutePosition
    local cSize = closeBtn.AbsoluteSize
    if p.X >= cPos.X and p.X <= cPos.X + cSize.X
        and p.Y >= cPos.Y and p.Y <= cPos.Y + cSize.Y then return end
    dragStartX, dragStartY = p.X, p.Y
    startFramePos = MainFrame.Position
    startShadowPos = Shadow.Position
    showDragBlocker()
    activeDrag = {
        onMove = function(x, y)
            local dx, dy = x - dragStartX, y - dragStartY
            MainFrame.Position = UDim2.new(
                startFramePos.X.Scale, startFramePos.X.Offset + dx,
                startFramePos.Y.Scale, startFramePos.Y.Offset + dy
            )
            Shadow.Position = UDim2.new(
                startShadowPos.X.Scale, startShadowPos.X.Offset + dx,
                startShadowPos.Y.Scale, startShadowPos.Y.Offset + dy
            )
        end,
        onEnd = function()
            hideDragBlocker()
        end,
    }
end)

UserInputService.InputBegan:Connect(function(input, gp)
    if S.armingBox then
        if input.UserInputType == Enum.UserInputType.Keyboard then
            if input.KeyCode == Enum.KeyCode.Escape then
                S.armingBox:ReleaseFocus()
                return
            end
            if input.KeyCode == Enum.KeyCode.Backspace then
                S.armingKey.table[S.armingKey.name] = nil
            else
                S.armingKey.table[S.armingKey.name] = input.KeyCode
            end
            S.armingBox:ReleaseFocus()
            return
        end
    end
    if gp then return end
    if input.UserInputType == Enum.UserInputType.Keyboard then
        if S.keybinds.spam and input.KeyCode == S.keybinds.spam then
            S.spamToggle.set(not S.spamToggle.get())
        elseif S.keybinds.trigger and input.KeyCode == S.keybinds.trigger then
            S.triggerToggle.set(not S.triggerToggle.get())
        elseif S.keybinds.orbit and input.KeyCode == S.keybinds.orbit then
            S.orbitToggle.set(not S.orbitToggle.get())
        end
    end
end)

local function checkParry()
    local char = LocalPlayer.Character
    local hrp = char and char.PrimaryPart
    if not hrp then return end
    local t = os.clock()
    if S.ballDebounce or t < S.ballUntilAt then return end
    if not S.remotesHook.tokenFn then return end
    local pos = hrp.Position
    local pingVal = S.pingSmoothed > 0 and S.pingSmoothed or dataPing:GetValue()
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
                S.ballState.AerodynamicTime = t
            end
            if tornado and (t - S.ballState.AerodynamicTime < tornadoTime + 0.314159) then continue end
            if firstTarget == localName and isCurved(firstBall) then continue end
            if target ~= localName then continue end
            if dist > threshold then continue end
            if accuracyMult > 2 then continue end
            if pcall(fireServer) then
                S.ballDebounce = true
                S.ballUntilAt = t + 1
            end
            return
        end
    end
end

RunService.PostSimulation:Connect(function()
    if not AutoParry then return end
    checkParry()
end)

RunService.Heartbeat:Connect(function()
    if not S.orbit.enabled then return end
    local now = os.clock()
    local dt = now - S.orbit.lastTick
    S.orbit.lastTick = now
    if dt > 0.1 then dt = 0.1 end
    updateOrbit(dt)
end)

task.spawn(function()
    while S.alive do
        local maxSpeed = 0
        for _, ball in ipairs(getRealBalls()) do
            local z = ball:FindFirstChild("zoomies")
            if z then
                local s = z.VectorVelocity.Magnitude
                if s > maxSpeed then maxSpeed = s end
            end
        end
        if maxSpeed > 0 then
            local vText = string.format("%.0f", maxSpeed)
            if S.statusVelocity.Text ~= vText then S.statusVelocity.Text = vText end
            S.statusVelocity.TextColor3 = maxSpeed >= 2200 and Theme.warn or Theme.text
        else
            if S.statusVelocity.Text ~= "--" then S.statusVelocity.Text = "--" end
            S.statusVelocity.TextColor3 = Theme.textDim
        end
        local ping = S.pingSmoothed > 0 and S.pingSmoothed or dataPing:GetValue()
        local pText = string.format("%.0fms", ping)
        if S.statusPing.Text ~= pText then S.statusPing.Text = pText end
        S.statusPing.TextColor3 = ping > 200 and Theme.warn or Theme.text
        if S.CONFIG.AccuracyMode == "auto" then
            local eff = getEffectiveAccuracy()
            local aText = string.format("%.0f%%", eff)
            if S.statusAcc.Text ~= aText then S.statusAcc.Text = aText end
            S.accuracySlider.sub.Text = string.format("auto | eff: %.0f%% | j: %.0f", eff, S.pingJitter)
        else
            if S.statusAcc.Text ~= "manual" then S.statusAcc.Text = "manual" end
            S.accuracySlider.sub.Text = "manual"
        end
        if S.spamState.enabled then
            local cutoff = os.clock() - 1
            local rpsCount = 0
            for i = 1, PI.ring_size do
                if PI.ring[i] > cutoff then rpsCount = rpsCount + 1 end
            end
            local rText = tostring(rpsCount)
            if S.statusRPS.Text ~= rText then S.statusRPS.Text = rText end
            S.statusRPS.TextColor3 = Theme.accent
        else
            if S.statusRPS.Text ~= "0" then S.statusRPS.Text = "0" end
            S.statusRPS.TextColor3 = Theme.textDim
        end
        task.wait(0.1)
    end
end)

local MiniButton = Instance.new("TextButton")
MiniButton.Name = "MiniButton"
MiniButton.Size = UDim2.new(0, 112, 0, 36)
MiniButton.Position = UDim2.new(0.5, -56, 0, 14)
MiniButton.BackgroundColor3 = Theme.bg
MiniButton.BorderSizePixel = 0
MiniButton.Text = "   HAHA.dll"
MiniButton.TextColor3 = Theme.accent
MiniButton.Font = Enum.Font.GothamBold
MiniButton.TextSize = 13
MiniButton.TextXAlignment = Enum.TextXAlignment.Center
MiniButton.AutoButtonColor = false
MiniButton.Visible = false
MiniButton.ZIndex = 40
MiniButton.Parent = ScreenGui
Instance.new("UICorner", MiniButton).CornerRadius = UDim.new(1, 0)

local miniStroke = Instance.new("UIStroke")
miniStroke.Color = Theme.stroke
miniStroke.Thickness = 1
miniStroke.Parent = MiniButton

local miniGrad = Instance.new("UIGradient")
miniGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Theme.bgGrad1),
    ColorSequenceKeypoint.new(1, Theme.bgGrad2),
})
miniGrad.Rotation = 90
miniGrad.Parent = MiniButton

local miniDot = Instance.new("Frame")
miniDot.Size = UDim2.new(0, 8, 0, 8)
miniDot.Position = UDim2.new(0, 14, 0.5, -4)
miniDot.BackgroundColor3 = Theme.accent
miniDot.BorderSizePixel = 0
miniDot.ZIndex = 41
miniDot.Parent = MiniButton
Instance.new("UICorner", miniDot).CornerRadius = UDim.new(1, 0)

local miniGlow = Instance.new("Frame")
miniGlow.Size = UDim2.new(0, 16, 0, 16)
miniGlow.Position = UDim2.new(0, 10, 0.5, -8)
miniGlow.BackgroundColor3 = Theme.accent
miniGlow.BackgroundTransparency = 0.85
miniGlow.BorderSizePixel = 0
miniGlow.ZIndex = 39
miniGlow.Parent = MiniButton
Instance.new("UICorner", miniGlow).CornerRadius = UDim.new(1, 0)

local function setMinimized(min)
    MainFrame.Visible = not min
    Shadow.Visible = not min
    MiniButton.Visible = min
end

MiniButton.MouseEnter:Connect(function()
    tween(MiniButton, { BackgroundColor3 = Theme.cardHover }, 0.12)
end)
MiniButton.MouseLeave:Connect(function()
    tween(MiniButton, { BackgroundColor3 = Theme.bg }, 0.12)
end)

MiniButton.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local startX, startY = input.Position.X, input.Position.Y
    local startPos = MiniButton.Position
    local moved = false
    showDragBlocker()
    activeDrag = {
        onMove = function(x, y)
            local dx, dy = x - startX, y - startY
            if math.abs(dx) > 3 or math.abs(dy) > 3 then moved = true end
            MiniButton.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + dx,
                startPos.Y.Scale, startPos.Y.Offset + dy
            )
        end,
        onEnd = function()
            hideDragBlocker()
            if not moved then setMinimized(false) end
        end,
    }
end)

MiniButton.MouseButton2Click:Connect(function()
    S.alive = false
    S.spamState.enabled = false
    S.triggerEnabled = false
    S.orbit.enabled = false
    S.rageOrbit.enabled = false
    if S.refreshLoopConn then S.refreshLoopConn:Disconnect() end
    if S.noRender.enabled then disableNoRender() end
    ScreenGui:Destroy()
end)

closeBtn.MouseButton1Click:Connect(function()
    setMinimized(true)
end)

applyRPS(240)
