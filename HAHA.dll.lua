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

local CONFIG = {
    FireArg = 0.5,
    Accuracy = 85,
    AccuracyMode = "auto",
}

local keybinds = {
    spam = Enum.KeyCode.X,
    trigger = Enum.KeyCode.C,
    orbit = Enum.KeyCode.O,
}

local function keyName(k)
    if not k then return "None" end
    return (tostring(k):gsub("Enum.KeyCode.", ""))
end

local armingBox = nil
local armingKey = nil

local unlimitedKbps = false
local infiniteMode = false
local INFINITE_BURST = 40
local INFINITE_BURST_KB = 50
local payloadRefreshThreshold = 0.016
local screenRefreshThreshold = 0.016
local lastScreenRefresh = 0

local aliveFolderCache = nil
local aliveFolderCacheAt = 0
local function getAliveFolder()
    local now = os.clock()
    if now - aliveFolderCacheAt > 2 then
        aliveFolderCache = ws:FindFirstChild("Alive")
        aliveFolderCacheAt = now
    end
    return aliveFolderCache
end

local pingSmoothed = 0
local pingJitter = 0
local lastPingSample = 0
local lastPingSampleTime = 0
local cachedEffectiveAccuracy = 85
local lastAccuracyCalc = 0

local function updateAccuracyEstimate()
    local now = os.clock()
    if now - lastPingSampleTime >= 0.2 then
        lastPingSampleTime = now
        local raw = dataPing:GetValue()
        if pingSmoothed == 0 then
            pingSmoothed = raw
            lastPingSample = raw
        else
            local delta = math.abs(raw - lastPingSample)
            lastPingSample = raw
            pingJitter = pingJitter * 0.8 + delta * 0.2
            pingSmoothed = pingSmoothed * 0.7 + raw * 0.3
        end
    end
    if now - lastAccuracyCalc >= 0.5 then
        lastAccuracyCalc = now
        if CONFIG.AccuracyMode ~= "auto" then
            cachedEffectiveAccuracy = CONFIG.Accuracy
        else
            local p = pingSmoothed
            local pingFactor
            if p <= 80 then pingFactor = 1
            elseif p >= 2000 then pingFactor = 0.35
            else pingFactor = 1 - ((p - 80) / 1920) * 0.65 end
            local jitterFactor = math.clamp(1 - (pingJitter / 300), 0.6, 1)
            cachedEffectiveAccuracy = CONFIG.Accuracy * pingFactor * jitterFactor
        end
    end
end

local function getEffectiveAccuracy()
    updateAccuracyEstimate()
    return cachedEffectiveAccuracy
end

local function getAccuracyMultiplier()
    updateAccuracyEstimate()
    return 100 / cachedEffectiveAccuracy
end

local orbit = {
    enabled = false,
    angle = 0,
    radius = 12,
    speed = 6,
    lastTick = os.clock(),
}

local function getOrbitHRP()
    local char = LocalPlayer.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local orbitBallsCache = nil
local orbitBallsCacheAt = 0
local function getOrbitBall()
    local now = os.clock()
    if not orbitBallsCache or now - orbitBallsCacheAt > 0.1 then
        orbitBallsCacheAt = now
        orbitBallsCache = ws:FindFirstChild("Balls")
    end
    local folder = orbitBallsCache
    if not folder then return nil end
    local hrp = getOrbitHRP()
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
    if not orbit.enabled then return end
    local hrp = getOrbitHRP()
    if not hrp then return end
    local ball = getOrbitBall()
    if not ball then return end
    orbit.angle = orbit.angle + orbit.speed * dt
    if orbit.angle > math.pi * 2 then
        orbit.angle = orbit.angle - math.pi * 2
    end
    local center = ball.Position
    local offset = Vector3.new(
        math.cos(orbit.angle) * orbit.radius,
        math.sin(orbit.angle * 2) * 2,
        math.sin(orbit.angle) * orbit.radius
    )
    hrp.CFrame = CFrame.new(center + offset)
end

local remotesHook = {
    mt = {},
    orig = {},
    captured = {},
    tokenFn = nil,
    firstSignal = nil,
    done = false,
    descConn = nil,
}

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
                    remotesHook.tokenFn = up
                    break
                end
            end
            if remotesHook.tokenFn then break end
        end
    end
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
    if remotesHook.descConn then
        remotesHook.descConn:Disconnect()
        remotesHook.descConn = nil
    end
    remotesHook.done = true
end

local function hookRemote(inst)
    if remotesHook.done then return end
    local ok, mt = pcall(getrawmetatable, inst)
    if not ok or remotesHook.mt[mt] then return end
    remotesHook.mt[mt] = true
    setreadonly(mt, false)
    local origIdx = mt.__index
    remotesHook.orig[mt] = origIdx
    mt.__index = function(self, key)
        if not remotesHook.done and (key == "FireServer" or key == "InvokeServer") then
            local realFn = origIdx(self, key)
            if realFn then
                return function(self2, ...)
                    if not remotesHook.done then
                        local cls = self2.ClassName
                        if (key == "FireServer" and cls == "RemoteEvent")
                        or (key == "InvokeServer" and cls == "RemoteFunction") then
                            local args = {...}
                            if validArgs(args) then
                                remotesHook.captured[self2] = args
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
    remotesHook.descConn = ReplicatedStorage.DescendantAdded:Connect(function(d)
        if remotesHook.done then return end
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

local hotRemote, hotArgs1, hotArgs2, hotIsEvent
local fireMethod
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
        if hotIsEvent then
            fireMethod = remote.FireServer
        else
            fireMethod = remote.InvokeServer
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
    local sig = hotSigBytes
    local sigLen = hotSigLen
    for i = 1, n do
        tokenBuf[i] = string.char(bit32.bxor((string.byte(stamp, i) + i) % 256, sig[(i - 1) % sigLen + 1]))
    end
    return table.concat(tokenBuf, "", 1, n)
end

local lastTokenGenTime = 0
local tokenRegenInterval = 0.05
local cachedToken = ""
local cachedTokenStamp = -1

local function refreshCachedToken()
    if not hotSigLen or not hotSigBytes then return end
    local now = os.clock()
    if now - lastTokenGenTime < tokenRegenInterval then return end
    lastTokenGenTime = now
    local stampNum = math.floor(GetServerTimeNow(ws) * 100)
    if stampNum == cachedTokenStamp then return end
    cachedTokenStamp = stampNum
    local stamp = tostring(stampNum)
    local n = #stamp
    local sig = hotSigBytes
    local sigLen = hotSigLen
    for i = 1, n do
        tokenBuf[i] = string.char(bit32.bxor((string.byte(stamp, i) + i) % 256, sig[(i - 1) % sigLen + 1]))
    end
    cachedToken = table.concat(tokenBuf, "", 1, n)
end

local cachedScreen = {}
local cachedAim = {0, 0}
local cachedCframe
local cachedScale = 0.5
local lastPayloadRefresh = 0
local cachedTargetPos = nil
local lastTargetRefresh = 0
local targetRefreshInterval = 0.1

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
    if now - lastTargetRefresh < targetRefreshInterval then return end
    lastTargetRefresh = now
    cachedTargetPos = getTarget()
end

local function refreshPayload()
    local now = os.clock()
    if now - lastPayloadRefresh < payloadRefreshThreshold then return end
    lastPayloadRefresh = now
    refreshTarget()
    cachedScale = CONFIG.FireArg
    local camCFrame = Camera.CFrame
    if cachedTargetPos then
        cachedCframe = CFrame.new(camCFrame.Position, cachedTargetPos)
    else
        cachedCframe = camCFrame
    end
    if now - lastScreenRefresh >= screenRefreshThreshold then
        lastScreenRefresh = now
        table.clear(cachedScreen)
        local aliveFolder = getAliveFolder()
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
end

local function fireServer()
    if not remotesHook.tokenFn then return false end
    if not hotRemote or not fireMethod then refreshHot() end
    if not hotRemote or not fireMethod then
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
    fireMethod(hotRemote, hotArgs1, hotArgs2, tok, cachedScale, cachedCframe, cachedScreen, cachedAim, false)
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
    if not hotRemote or not fireMethod then
        if next(remotesHook.captured) ~= nil then refreshHot() end
        if not hotRemote or not fireMethod then
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
    fireMethod(hotRemote, hotArgs1, hotArgs2, tok, cachedScale, cf, cachedScreen, cachedAim, false)
end

local function isCurved(ball)
    local zoomies = ball:FindFirstChild("zoomies")
    if not zoomies then return false end
    local char = LocalPlayer.Character
    if not char or not char.PrimaryPart then return false end
    local t = os.clock()
    local ping = pingSmoothed > 0 and pingSmoothed or dataPing:GetValue()
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

local noRender = {
    enabled = false,
    saved = setmetatable({}, {__mode = "k"}),
    enabledHooks = setmetatable({}, {__mode = "k"}),
    count = 0,
    sweepConn = nil,
}

local function saveProp(inst, prop)
    local s = noRender.saved[inst]
    if not s then
        s = {}
        noRender.saved[inst] = s
    end
    if s[prop] == nil then
        local ok, v = pcall(function() return inst[prop] end)
        if ok then
            s[prop] = v
            noRender.count = noRender.count + 1
        end
    end
end

local function killProp(inst, prop, killer)
    local ok, cur = pcall(function() return inst[prop] end)
    if not ok then return end
    if cur == killer then return end
    saveProp(inst, prop)
    pcall(function() inst[prop] = killer end)
end

local function killEnabled(inst)
    killProp(inst, "Enabled", false)
    if not noRender.enabledHooks[inst] then
        local conn = inst:GetPropertyChangedSignal("Enabled"):Connect(function()
            if noRender.enabled then
                pcall(function()
                    if inst.Enabled then
                        saveProp(inst, "Enabled")
                        inst.Enabled = false
                    end
                end)
            end
        end)
        noRender.enabledHooks[inst] = conn
    end
end

local function killTransparency(inst)
    killProp(inst, "Transparency", 1)
end

local function killVisible(inst)
    killProp(inst, "Visible", false)
end

local function killShadow(inst)
    killProp(inst, "CastShadow", false)
end

local function killImage(inst)
    killProp(inst, "Image", "")
    killProp(inst, "ImageTransparency", 1)
end

local function killMeshTexture(inst)
    killProp(inst, "Texture", "")
end

local function killSound(inst)
    killProp(inst, "Volume", 0)
    pcall(function() inst:Stop() end)
    if not noRender.enabledHooks[inst] then
        local conn = inst.Played:Connect(function()
            if noRender.enabled then
                pcall(function() inst:Stop() end)
            end
        end)
        noRender.enabledHooks[inst] = conn
    end
end

local function killPostFX(inst)
    killProp(inst, "Enabled", false)
end

local function killAtmosphere(inst)
    killProp(inst, "Density", 0)
    killProp(inst, "Haze", 0)
    killProp(inst, "Glare", 0)
end

local function killClouds(inst)
    killProp(inst, "Cover", 0)
    killProp(inst, "Density", 0)
end

local function killSky(inst)
    for _, p in ipairs({
        "SkyboxBk","SkyboxDn","SkyboxFt","SkyboxLf","SkyboxRt","SkyboxUp",
        "SunTextureId","MoonTextureId"
    }) do
        killProp(inst, p, "")
    end
    killProp(inst, "StarCount", 0)
end

local function killTerrain(terrain)
    killProp(terrain, "WaterWaveSize", 0)
    killProp(terrain, "WaterWaveSpeed", 0)
    killProp(terrain, "WaterReflectance", 0)
end

local function killEffect(inst)
    local cls = inst.ClassName
    if cls == "ParticleEmitter" or cls == "Trail" or cls == "Beam"
        or cls == "Smoke" or cls == "Fire" or cls == "Sparkles"
        or cls == "Explosion" or cls == "Highlight" then
        killEnabled(inst)
        if cls == "ParticleEmitter" or cls == "Fire" or cls == "Smoke" then
            killProp(inst, "Rate", 0)
            killProp(inst, "Brightness", 0)
        end
        if cls == "Trail" or cls == "Beam" then
            killProp(inst, "Transparency", NumberSequence.new(1))
            killProp(inst, "LightEmission", 0)
        end
        if cls == "Highlight" then
            killProp(inst, "FillTransparency", 1)
            killProp(inst, "OutlineTransparency", 1)
        end
    elseif cls == "PointLight" or cls == "SpotLight" or cls == "SurfaceLight" then
        killEnabled(inst)
        killProp(inst, "Brightness", 0)
        killProp(inst, "Range", 0)
    elseif cls == "Decal" or cls == "Texture" then
        killTransparency(inst)
        if cls == "Texture" then
            killMeshTexture(inst)
        end
    elseif cls == "SurfaceGui" or cls == "BillboardGui" then
        killEnabled(inst)
    elseif cls == "ViewportFrame" then
        killVisible(inst)
    elseif cls == "Sound" or cls == "SoundGroup" then
        killSound(inst)
    end
end

local function killEnv(inst)
    if inst:IsA("PostEffect") then
        killPostFX(inst)
    elseif inst:IsA("Atmosphere") then
        killAtmosphere(inst)
    elseif inst:IsA("Clouds") then
        killClouds(inst)
    elseif inst:IsA("Sky") then
        killSky(inst)
    end
end

local function killAllInRoot(root, skipPlayerGui)
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("BasePart") then
            killShadow(d)
            if d:FindFirstAncestorWhichIsA("Accessory") then
                killTransparency(d)
            end
        end
        if skipPlayerGui and d:IsDescendantOf(PlayerGui) then
            continue
        end
        local cls = d.ClassName
        if cls == "ParticleEmitter" or cls == "Trail" or cls == "Beam"
            or cls == "Smoke" or cls == "Fire" or cls == "Sparkles"
            or cls == "Explosion" or cls == "Highlight"
            or cls == "PointLight" or cls == "SpotLight" or cls == "SurfaceLight"
            or cls == "Decal" or cls == "Texture"
            or cls == "SurfaceGui" or cls == "BillboardGui" or cls == "ViewportFrame"
            or cls == "Sound" or cls == "SoundGroup" then
            killEffect(d)
        elseif cls == "ImageLabel" or cls == "ImageButton" then
            killImage(d)
        end
    end
end

local function applyNoRender()
    noRender.count = 0
    local s = noRender.saved[Lighting]
    if not s then s = {}; noRender.saved[Lighting] = s end
    s.Ambient = Lighting.Ambient
    s.OutdoorAmbient = Lighting.OutdoorAmbient
    s.Brightness = Lighting.Brightness
    s.GlobalShadows = Lighting.GlobalShadows
    pcall(function() s.EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale end)
    pcall(function() s.EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale end)
    pcall(function() s.ShadowSoftness = Lighting.ShadowSoftness end)
    s.FogEnd = Lighting.FogEnd
    s.FogStart = Lighting.FogStart
    s.ClockTime = Lighting.ClockTime

    Lighting.Ambient = Color3.fromRGB(180, 180, 180)
    Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
    Lighting.Brightness = 2
    Lighting.GlobalShadows = false
    pcall(function() Lighting.EnvironmentDiffuseScale = 0.5 end)
    pcall(function() Lighting.EnvironmentSpecularScale = 0.5 end)
    pcall(function() Lighting.ShadowSoftness = 0 end)
    Lighting.FogEnd = 1e10
    Lighting.FogStart = 0
    Lighting.ClockTime = 12

    for _, c in ipairs(Lighting:GetChildren()) do
        killEnv(c)
    end

    local terrain = ws:FindFirstChildOfClass("Terrain")
    if terrain then
        killTerrain(terrain)
    end

    killAllInRoot(ws, true)
end

local function restoreNoRender()
    for inst, s in next, noRender.saved do
        if inst == Lighting then
            pcall(function()
                if s.Ambient then Lighting.Ambient = s.Ambient end
                if s.OutdoorAmbient then Lighting.OutdoorAmbient = s.OutdoorAmbient end
                if s.Brightness then Lighting.Brightness = s.Brightness end
                if s.GlobalShadows ~= nil then Lighting.GlobalShadows = s.GlobalShadows end
                if s.EnvironmentDiffuseScale then Lighting.EnvironmentDiffuseScale = s.EnvironmentDiffuseScale end
                if s.EnvironmentSpecularScale then Lighting.EnvironmentSpecularScale = s.EnvironmentSpecularScale end
                if s.ShadowSoftness then Lighting.ShadowSoftness = s.ShadowSoftness end
                if s.FogEnd then Lighting.FogEnd = s.FogEnd end
                if s.FogStart then Lighting.FogStart = s.FogStart end
                if s.ClockTime then Lighting.ClockTime = s.ClockTime end
            end)
        else
            for prop, v in next, s do
                pcall(function() inst[prop] = v end)
            end
        end
    end
    for inst, conn in next, noRender.enabledHooks do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(noRender.enabledHooks)
    table.clear(noRender.saved)
    noRender.count = 0
end

local function enableNoRender()
    if noRender.enabled then return end
    noRender.enabled = true
    applyNoRender()

    local sweeping = false
    local function resweep()
        if sweeping or not noRender.enabled then return end
        sweeping = true
        task.spawn(function()
            while noRender.enabled do
                task.wait(0.5)
                if not noRender.enabled then break end
                killAllInRoot(ws, true)
            end
            sweeping = false
        end)
    end

    local descConn = ws.DescendantAdded:Connect(function(d)
        if not noRender.enabled then return end
        if d:IsDescendantOf(PlayerGui) then return end
        task.defer(function()
            if not noRender.enabled or not d.Parent then return end
            if d:IsA("BasePart") then
                killShadow(d)
                if d:FindFirstAncestorWhichIsA("Accessory") then
                    killTransparency(d)
                end
            end
            killEffect(d)
            if d:IsA("ImageLabel") or d:IsA("ImageButton") then
                killImage(d)
            end
        end)
    end)

    local lightingConn = Lighting.ChildAdded:Connect(function(c)
        if not noRender.enabled then return end
        task.defer(function()
            if not noRender.enabled or not c.Parent then return end
            killEnv(c)
        end)
    end)

    noRender.sweepConn = {
        descConn = descConn,
        lightingConn = lightingConn,
    }

    resweep()
end

local function disableNoRender()
    if not noRender.enabled then return end
    noRender.enabled = false
    if noRender.sweepConn then
        if noRender.sweepConn.descConn then noRender.sweepConn.descConn:Disconnect() end
        if noRender.sweepConn.lightingConn then noRender.sweepConn.lightingConn:Disconnect() end
        noRender.sweepConn = nil
    end
    restoreNoRender()
end

local spamState = {
    enabled = false,
    rate = 100,
    accumulator = 0,
    lastFrame = os.clock(),
    maxDt = 0.05,
    maxGuard = 20,
}

local function refreshGuard()
    local base = unlimitedKbps and 0.15 or 0.05
    spamState.maxDt = base
    spamState.maxGuard = math.max(20, math.floor(spamState.rate * base * 2))
end

local arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8

local function refreshSpamArgs()
    arg1 = hotArgs1
    arg2 = hotArgs2
    arg3 = cachedToken
    arg4 = cachedScale
    arg5 = cachedCframe
    arg6 = cachedScreen
    arg7 = cachedAim
    arg8 = false
end

local function fireBurst(remote, fn, count)
    local a1, a2, a3, a4, a5, a6, a7, a8 = arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8
    local i = 0
    while i + 8 <= count do
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        i = i + 8
    end
    while i + 4 <= count do
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        i = i + 4
    end
    while i < count do
        fn(remote, a1, a2, a3, a4, a5, a6, a7, a8)
        i = i + 1
    end
end

local function doSpamTick()
    if not spamState.enabled then return end
    if not hotRemote or not fireMethod then
        if next(remotesHook.captured) ~= nil then refreshHot() end
        if not hotRemote or not fireMethod then return end
    end

    local remote = hotRemote
    local method = fireMethod

    if infiniteMode then
        refreshPayload()
        refreshCachedToken()
        refreshSpamArgs()
        local burst = unlimitedKbps and INFINITE_BURST_KB or INFINITE_BURST
        fireBurst(remote, method, burst)
        return
    end

    local now = os.clock()
    local dt = now - spamState.lastFrame
    spamState.lastFrame = now
    local maxDt = spamState.maxDt
    if dt > maxDt then dt = maxDt end

    local rate = spamState.rate
    local acc = spamState.accumulator + dt * rate
    if acc < 1 then
        spamState.accumulator = acc
        return
    end
    local guard = spamState.maxGuard
    if acc > guard then acc = guard end
    local count = math.floor(acc)
    spamState.accumulator = acc - count

    refreshPayload()
    refreshCachedToken()
    refreshSpamArgs()
    fireBurst(remote, method, count)
end

local refreshLoopConn = nil
local function ensureHot()
    if hotRemote and fireMethod then
        if refreshLoopConn then
            refreshLoopConn:Disconnect()
            refreshLoopConn = nil
        end
        return
    end
    if next(remotesHook.captured) ~= nil then
        refreshHot()
    end
    if hotRemote and fireMethod and refreshLoopConn then
        refreshLoopConn:Disconnect()
        refreshLoopConn = nil
    end
end

refreshLoopConn = RunService.Heartbeat:Connect(ensureHot)
RunService.PreSimulation:Connect(doSpamTick)
RunService.Heartbeat:Connect(doSpamTick)

local renderTickConn = nil
local function setUnlimitedKbps(enabled)
    unlimitedKbps = enabled
    screenRefreshThreshold = enabled and 1.0 or 0.016
    payloadRefreshThreshold = 0.016
    refreshGuard()
    spamState.accumulator = 0
    spamState.lastFrame = os.clock()
    if enabled and not renderTickConn then
        renderTickConn = RunService.RenderStepped:Connect(doSpamTick)
    elseif not enabled and renderTickConn then
        renderTickConn:Disconnect()
        renderTickConn = nil
    end
end

local C = {
    bg = Color3.fromRGB(22, 22, 26),
    sidebar = Color3.fromRGB(18, 18, 22),
    bg2 = Color3.fromRGB(28, 28, 33),
    card = Color3.fromRGB(36, 36, 42),
    cardHover = Color3.fromRGB(44, 44, 52),
    stroke = Color3.fromRGB(52, 52, 60),
    text = Color3.fromRGB(240, 240, 245),
    textDim = Color3.fromRGB(148, 148, 158),
    textMuted = Color3.fromRGB(100, 100, 110),
    accent = Color3.fromRGB(95, 200, 130),
    toggleOff = Color3.fromRGB(52, 52, 60),
    knob = Color3.fromRGB(220, 220, 228),
    danger = Color3.fromRGB(225, 95, 95),
    warn = Color3.fromRGB(230, 180, 90),
    keybg = Color3.fromRGB(18, 18, 22),
}

local function tween(obj, props, dur)
    TweenService:Create(obj, TweenInfo.new(dur or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

local activeDrag = nil

UserInputService.InputChanged:Connect(function(input)
    local d = activeDrag
    if not d then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
        d.onMove(input.Position.X, input.Position.Y)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    local d = activeDrag
    if not d then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
        activeDrag = nil
        if d.onEnd then d.onEnd() end
    end
end)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "HAHA_dll"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 999
ScreenGui.Parent = PlayerGui

local PANEL_W = 460
local PANEL_H = 340
local SIDEBAR_W = 128

local Shadow = Instance.new("Frame")
Shadow.Size = UDim2.new(0, PANEL_W + 4, 0, PANEL_H + 4)
Shadow.Position = UDim2.new(0.5, -(PANEL_W + 4) / 2, 0.5, -(PANEL_H + 4) / 2)
Shadow.BackgroundColor3 = Color3.new(0, 0, 0)
Shadow.BackgroundTransparency = 0.55
Shadow.BorderSizePixel = 0
Shadow.Parent = ScreenGui
Instance.new("UICorner", Shadow).CornerRadius = UDim.new(0, 16)

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, PANEL_W, 0, PANEL_H)
MainFrame.Position = UDim2.new(0.5, -PANEL_W / 2, 0.5, -PANEL_H / 2)
MainFrame.BackgroundColor3 = C.bg
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Parent = ScreenGui
Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 14)

local frameStroke = Instance.new("UIStroke")
frameStroke.Color = C.stroke
frameStroke.Thickness = 1
frameStroke.Parent = MainFrame

local Sidebar = Instance.new("Frame")
Sidebar.Name = "Sidebar"
Sidebar.Size = UDim2.new(0, SIDEBAR_W, 1, 0)
Sidebar.BackgroundColor3 = C.sidebar
Sidebar.BorderSizePixel = 0
Sidebar.Parent = MainFrame

local sidebarCorner = Instance.new("UICorner")
sidebarCorner.CornerRadius = UDim.new(0, 14)
sidebarCorner.Parent = Sidebar

local sidebarCover = Instance.new("Frame")
sidebarCover.Size = UDim2.new(0, 14, 1, 0)
sidebarCover.Position = UDim2.new(1, -14, 0, 0)
sidebarCover.BackgroundColor3 = C.sidebar
sidebarCover.BorderSizePixel = 0
sidebarCover.Parent = Sidebar

local sidebarDivider = Instance.new("Frame")
sidebarDivider.Size = UDim2.new(0, 1, 1, -24)
sidebarDivider.Position = UDim2.new(1, -1, 0, 12)
sidebarDivider.BackgroundColor3 = C.stroke
sidebarDivider.BackgroundTransparency = 0.4
sidebarDivider.BorderSizePixel = 0
sidebarDivider.Parent = Sidebar

local titleDot = Instance.new("Frame")
titleDot.Size = UDim2.new(0, 7, 0, 7)
titleDot.Position = UDim2.new(0, 16, 0, 26)
titleDot.BackgroundColor3 = C.accent
titleDot.BorderSizePixel = 0
titleDot.Parent = Sidebar
Instance.new("UICorner", titleDot).CornerRadius = UDim.new(1, 0)

local titleGlow = Instance.new("Frame")
titleGlow.Size = UDim2.new(0, 14, 0, 14)
titleGlow.Position = UDim2.new(0, 12.5, 0, 22.5)
titleGlow.BackgroundColor3 = C.accent
titleGlow.BackgroundTransparency = 0.85
titleGlow.BorderSizePixel = 0
titleGlow.Parent = Sidebar
Instance.new("UICorner", titleGlow).CornerRadius = UDim.new(1, 0)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -34, 0, 14)
title.Position = UDim2.new(0, 30, 0, 22)
title.BackgroundTransparency = 1
title.Text = "HAHA.dll"
title.TextColor3 = C.text
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = Sidebar

local titleSub = Instance.new("TextLabel")
titleSub.Size = UDim2.new(1, -34, 0, 10)
titleSub.Position = UDim2.new(0, 30, 0, 36)
titleSub.BackgroundTransparency = 1
titleSub.Text = "by HAHA"
titleSub.TextColor3 = C.textMuted
titleSub.Font = Enum.Font.Gotham
titleSub.TextSize = 8
titleSub.TextXAlignment = Enum.TextXAlignment.Left
titleSub.Parent = Sidebar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 22, 0, 22)
closeBtn.Position = UDim2.new(1, -30, 0, 22)
closeBtn.BackgroundColor3 = C.card
closeBtn.BorderSizePixel = 0
closeBtn.Text = "×"
closeBtn.TextColor3 = C.textDim
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 16
closeBtn.AutoButtonColor = false
closeBtn.Parent = Sidebar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

local TabList = Instance.new("Frame")
TabList.Size = UDim2.new(1, -16, 1, -90)
TabList.Position = UDim2.new(0, 8, 0, 62)
TabList.BackgroundTransparency = 1
TabList.Parent = Sidebar
local tabListLayout = Instance.new("UIListLayout")
tabListLayout.Padding = UDim.new(0, 3)
tabListLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabListLayout.Parent = TabList

local Content = Instance.new("Frame")
Content.Name = "Content"
Content.Size = UDim2.new(1, -SIDEBAR_W, 1, 0)
Content.Position = UDim2.new(0, SIDEBAR_W, 0, 0)
Content.BackgroundTransparency = 1
Content.Parent = MainFrame

local contentHeader = Instance.new("Frame")
contentHeader.Size = UDim2.new(1, -32, 0, 52)
contentHeader.Position = UDim2.new(0, 16, 0, 0)
contentHeader.BackgroundTransparency = 1
contentHeader.Parent = Content

local pageTitle = Instance.new("TextLabel")
pageTitle.Size = UDim2.new(1, 0, 0, 20)
pageTitle.Position = UDim2.new(0, 0, 0, 14)
pageTitle.BackgroundTransparency = 1
pageTitle.Text = "Combat"
pageTitle.TextColor3 = C.text
pageTitle.Font = Enum.Font.GothamBold
pageTitle.TextSize = 17
pageTitle.TextXAlignment = Enum.TextXAlignment.Left
pageTitle.Parent = contentHeader

local pageSub = Instance.new("TextLabel")
pageSub.Size = UDim2.new(1, 0, 0, 12)
pageSub.Position = UDim2.new(0, 0, 0, 34)
pageSub.BackgroundTransparency = 1
pageSub.Text = "Toggles and automation"
pageSub.TextColor3 = C.textMuted
pageSub.Font = Enum.Font.Gotham
pageSub.TextSize = 10
pageSub.TextXAlignment = Enum.TextXAlignment.Left
pageSub.Parent = contentHeader

local headerDivider = Instance.new("Frame")
headerDivider.Size = UDim2.new(1, -32, 0, 1)
headerDivider.Position = UDim2.new(0, 16, 0, 52)
headerDivider.BackgroundColor3 = C.stroke
headerDivider.BackgroundTransparency = 0.5
headerDivider.BorderSizePixel = 0
headerDivider.Parent = Content

local PageContainer = Instance.new("Frame")
PageContainer.Size = UDim2.new(1, -24, 1, -66)
PageContainer.Position = UDim2.new(0, 12, 0, 62)
PageContainer.BackgroundTransparency = 1
PageContainer.ClipsDescendants = true
PageContainer.Parent = Content

local PageScroll = Instance.new("ScrollingFrame")
PageScroll.Size = UDim2.new(1, 0, 1, 0)
PageScroll.BackgroundTransparency = 1
PageScroll.BorderSizePixel = 0
PageScroll.ScrollBarThickness = 3
PageScroll.ScrollBarImageColor3 = C.stroke
PageScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
PageScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
PageScroll.Parent = PageContainer

local pageLayout = Instance.new("UIListLayout")
pageLayout.Padding = UDim.new(0, 8)
pageLayout.SortOrder = Enum.SortOrder.LayoutOrder
pageLayout.Parent = PageScroll

local pagePadding = Instance.new("UIPadding")
pagePadding.PaddingTop = UDim.new(0, 4)
pagePadding.PaddingBottom = UDim.new(0, 12)
pagePadding.Parent = PageScroll

local pages = {}
local currentTab = nil

local function makeToggle(parent, label, onChanged, keybindTarget)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, -8, 0, 42)
    row.BackgroundColor3 = C.card
    row.BorderSizePixel = 0
    row.Text = ""
    row.AutoButtonColor = false
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 9)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, keybindTarget and -132 or -80, 1, 0)
    lbl.Position = UDim2.new(0, 14, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.text
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    if keybindTarget then
        local box = Instance.new("TextBox")
        box.Size = UDim2.new(0, 54, 0, 22)
        box.Position = UDim2.new(0, 96, 0.5, -11)
        box.BackgroundColor3 = C.keybg
        box.BorderSizePixel = 0
        box.Text = keyName(keybindTarget.table[keybindTarget.name])
        box.TextColor3 = C.accent
        box.Font = Enum.Font.GothamBold
        box.TextSize = 11
        box.TextXAlignment = Enum.TextXAlignment.Center
        box.ClearTextOnFocus = false
        box.Parent = row
        pcall(function() box.TextEditable = false end)
        Instance.new("UICorner", box).CornerRadius = UDim.new(0, 5)
        local stroke = Instance.new("UIStroke")
        stroke.Color = C.stroke
        stroke.Thickness = 1
        stroke.Parent = box
        box.Focused:Connect(function()
            armingBox = box
            armingKey = keybindTarget
            box.Text = "..."
            stroke.Color = C.accent
            stroke.Thickness = 2
        end)
        box.FocusLost:Connect(function()
            if armingBox == box then
                armingBox = nil
                armingKey = nil
            end
            box.Text = keyName(keybindTarget.table[keybindTarget.name])
            stroke.Color = C.stroke
            stroke.Thickness = 1
        end)
    end

    local bg = Instance.new("Frame")
    bg.Size = UDim2.new(0, 38, 0, 20)
    bg.Position = UDim2.new(1, -52, 0.5, -10)
    bg.BackgroundColor3 = C.toggleOff
    bg.BorderSizePixel = 0
    bg.Parent = row
    Instance.new("UICorner", bg).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = UDim2.new(0, 3, 0.5, -7)
    knob.BackgroundColor3 = C.knob
    knob.BorderSizePixel = 0
    knob.Parent = bg
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

    local state = false
    local function setState(s)
        state = s
        tween(knob, {
            Position = s and UDim2.new(0, 21, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
        }, 0.18)
        TweenService:Create(bg, TweenInfo.new(0.18), {
            BackgroundColor3 = s and C.accent or C.toggleOff
        }):Play()
        if onChanged then onChanged(s) end
    end

    row.MouseButton1Click:Connect(function()
        if armingBox then return end
        setState(not state)
    end)
    row.MouseEnter:Connect(function()
        if not state then tween(row, { BackgroundColor3 = C.cardHover }) end
    end)
    row.MouseLeave:Connect(function()
        if not state then tween(row, { BackgroundColor3 = C.card }) end
    end)

    return { set = setState, get = function() return state end }
end

local function makeSlider(parent, label, min, max, initial, onChanged)
    local container = Instance.new("Frame")
    container.Size = UDim2.new(1, -8, 0, 58)
    container.BackgroundColor3 = C.card
    container.BorderSizePixel = 0
    container.Parent = parent
    Instance.new("UICorner", container).CornerRadius = UDim.new(0, 9)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.6, 0, 0, 16)
    lbl.Position = UDim2.new(0, 14, 0, 5)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.text
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = container

    local valLabel = Instance.new("TextLabel")
    valLabel.Size = UDim2.new(0.35, 0, 0, 16)
    valLabel.Position = UDim2.new(0.65, 0, 0, 5)
    valLabel.BackgroundTransparency = 1
    valLabel.Text = tostring(initial)
    valLabel.TextColor3 = C.accent
    valLabel.Font = Enum.Font.GothamBold
    valLabel.TextSize = 13
    valLabel.TextXAlignment = Enum.TextXAlignment.Right
    valLabel.Parent = container

    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1, -28, 0, 12)
    sub.Position = UDim2.new(0, 14, 0, 22)
    sub.BackgroundTransparency = 1
    sub.Text = ""
    sub.TextColor3 = C.textMuted
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 10
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.Parent = container

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -28, 0, 6)
    track.Position = UDim2.new(0, 14, 1, -14)
    track.BackgroundColor3 = C.toggleOff
    track.BorderSizePixel = 0
    track.Parent = container
    Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

    local initialPct = (initial - min) / (max - min)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(initialPct, 0, 1, 0)
    fill.BackgroundColor3 = C.accent
    fill.BorderSizePixel = 0
    fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = UDim2.new(initialPct, 0, 0.5, -7)
    knob.AnchorPoint = Vector2.new(0.5, 0)
    knob.BackgroundColor3 = C.knob
    knob.BorderSizePixel = 0
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
            activeDrag = { onMove = function(x) trackToValue(x) end }
            trackToValue(input.Position.X)
        end
    end)

    return { set = setValue, get = function() return value end, sub = sub }
end

local function makeTab(name, subtitle, order)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 34)
    btn.BackgroundColor3 = C.card
    btn.BackgroundTransparency = 1
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.LayoutOrder = order
    btn.Parent = TabList
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 7)

    local accentBar = Instance.new("Frame")
    accentBar.Size = UDim2.new(0, 3, 0, 18)
    accentBar.Position = UDim2.new(0, 0, 0.5, -9)
    accentBar.BackgroundColor3 = C.accent
    accentBar.BorderSizePixel = 0
    accentBar.BackgroundTransparency = 1
    accentBar.Parent = btn
    Instance.new("UICorner", accentBar).CornerRadius = UDim.new(1, 0)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, -24, 1, 0)
    lbl.Position = UDim2.new(0, 16, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = name
    lbl.TextColor3 = C.textDim
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = btn

    local page = Instance.new("Frame")
    page.Name = name .. "Page"
    page.Size = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency = 1
    page.Visible = false
    page.Parent = PageScroll

    local inner = Instance.new("Frame")
    inner.Size = UDim2.new(1, 0, 0, 0)
    inner.BackgroundTransparency = 1
    inner.AutomaticSize = Enum.AutomaticSize.Y
    inner.Parent = page
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 8)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = inner

    pages[name] = { page = page, inner = inner, subtitle = subtitle, button = btn, accent = accentBar, label = lbl }

    btn.MouseEnter:Connect(function()
        if currentTab ~= name then
            tween(btn, { BackgroundColor3 = C.card, BackgroundTransparency = 0.5 })
        end
    end)
    btn.MouseLeave:Connect(function()
        if currentTab ~= name then
            tween(btn, { BackgroundTransparency = 1 })
        end
    end)
    btn.MouseButton1Click:Connect(function()
        for tabName, tab in pairs(pages) do
            tab.page.Visible = false
            tab.accent.BackgroundTransparency = 1
            tab.label.TextColor3 = C.textDim
            tab.button.BackgroundTransparency = 1
        end
        pages[name].page.Visible = true
        pages[name].accent.BackgroundTransparency = 0
        pages[name].label.TextColor3 = C.text
        pages[name].button.BackgroundColor3 = C.card
        pages[name].button.BackgroundTransparency = 0
        pageTitle.Text = name
        pageSub.Text = subtitle
        currentTab = name
    end)

    return pages[name]
end

local combatTab = makeTab("Combat", "Toggles and automation", 1)
local movementTab = makeTab("Movement", "Ball orbit", 2)
local perfTab = makeTab("Performance", "Lag reduction & burst control", 3)
local tuningTab = makeTab("Tuning", "Precision control", 4)
local statsTab = makeTab("Stats", "Live telemetry", 5)

local AutoParry = false
local spamToggle, triggerToggle, orbitToggle, infiniteToggle

makeToggle(combatTab.inner, "Auto parry", function(s) AutoParry = s end)
spamToggle = makeToggle(combatTab.inner, "Manual spam", function(s)
    spamState.enabled = s
    spamState.accumulator = 0
    spamState.lastFrame = os.clock()
    if s then
        if next(remotesHook.captured) ~= nil then refreshHot() end
        if not refreshLoopConn then
            refreshLoopConn = RunService.Heartbeat:Connect(ensureHot)
        end
    end
end, { table = keybinds, name = "spam" })
triggerToggle = makeToggle(combatTab.inner, "Triggerbot", function(s)
    triggerEnabled = s
    if s then
        for _, ball in ipairs(getRealBalls()) do
            triggerFire(ball)
        end
    end
end, { table = keybinds, name = "trigger" })

orbitToggle = makeToggle(movementTab.inner, "Ball Orbit", function(s)
    orbit.enabled = s
    orbit.angle = 0
    orbit.lastTick = os.clock()
end, { table = keybinds, name = "orbit" })

makeToggle(perfTab.inner, "Unlimited KBPS", function(s) setUnlimitedKbps(s) end)
makeToggle(perfTab.inner, "No Render", function(s)
    if s then enableNoRender() else disableNoRender() end
end)
infiniteToggle = makeToggle(perfTab.inner, "Infinite spam", function(s)
    infiniteMode = s
    if s then
        if next(remotesHook.captured) ~= nil then refreshHot() end
        if not refreshLoopConn then
            refreshLoopConn = RunService.Heartbeat:Connect(ensureHot)
        end
    end
end)

makeSlider(tuningTab.inner, "Spam rate (/s)", 100, 1000, spamState.rate, function(v)
    spamState.rate = v
    refreshGuard()
end)
local accuracySlider = makeSlider(tuningTab.inner, "Accuracy", 40, 100, CONFIG.Accuracy, function(v) CONFIG.Accuracy = v end)
makeToggle(tuningTab.inner, "Auto accuracy", function(s)
    CONFIG.AccuracyMode = s and "auto" or "manual"
    lastAccuracyCalc = 0
end)

local StatsCard = Instance.new("Frame")
StatsCard.Size = UDim2.new(1, -8, 0, 100)
StatsCard.BackgroundColor3 = C.card
StatsCard.BorderSizePixel = 0
StatsCard.Parent = statsTab.inner
Instance.new("UICorner", StatsCard).CornerRadius = UDim.new(0, 9)

local statsGrad = Instance.new("UIGradient")
statsGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, C.card),
    ColorSequenceKeypoint.new(1, C.cardHover)
})
statsGrad.Rotation = 90
statsGrad.Parent = StatsCard

local VelocityLabel = Instance.new("TextLabel")
VelocityLabel.Size = UDim2.new(0.5, 0, 0, 22)
VelocityLabel.Position = UDim2.new(0, 16, 0, 12)
VelocityLabel.BackgroundTransparency = 1
VelocityLabel.Text = "Ball velocity"
VelocityLabel.TextColor3 = C.textDim
VelocityLabel.Font = Enum.Font.Gotham
VelocityLabel.TextSize = 11
VelocityLabel.TextXAlignment = Enum.TextXAlignment.Left
VelocityLabel.Parent = StatsCard

local VelocityValue = Instance.new("TextLabel")
VelocityValue.Size = UDim2.new(0.5, 0, 0, 22)
VelocityValue.Position = UDim2.new(0.5, -16, 0, 12)
VelocityValue.BackgroundTransparency = 1
VelocityValue.Text = "--"
VelocityValue.TextColor3 = C.text
VelocityValue.Font = Enum.Font.GothamBold
VelocityValue.TextSize = 14
VelocityValue.TextXAlignment = Enum.TextXAlignment.Right
VelocityValue.Parent = StatsCard

local PingLabel = Instance.new("TextLabel")
PingLabel.Size = UDim2.new(0.5, 0, 0, 22)
PingLabel.Position = UDim2.new(0, 16, 0, 40)
PingLabel.BackgroundTransparency = 1
PingLabel.Text = "Ping"
PingLabel.TextColor3 = C.textDim
PingLabel.Font = Enum.Font.Gotham
PingLabel.TextSize = 11
PingLabel.TextXAlignment = Enum.TextXAlignment.Left
PingLabel.Parent = StatsCard

local PingValue = Instance.new("TextLabel")
PingValue.Size = UDim2.new(0.5, 0, 0, 22)
PingValue.Position = UDim2.new(0.5, -16, 0, 40)
PingValue.BackgroundTransparency = 1
PingValue.Text = "--"
PingValue.TextColor3 = C.text
PingValue.Font = Enum.Font.GothamBold
PingValue.TextSize = 14
PingValue.TextXAlignment = Enum.TextXAlignment.Right
PingValue.Parent = StatsCard

local AccLabel = Instance.new("TextLabel")
AccLabel.Size = UDim2.new(0.5, 0, 0, 22)
AccLabel.Position = UDim2.new(0, 16, 0, 68)
AccLabel.BackgroundTransparency = 1
AccLabel.Text = "Effective accuracy"
AccLabel.TextColor3 = C.textDim
AccLabel.Font = Enum.Font.Gotham
AccLabel.TextSize = 11
AccLabel.TextXAlignment = Enum.TextXAlignment.Left
AccLabel.Parent = StatsCard

local AccValue = Instance.new("TextLabel")
AccValue.Size = UDim2.new(0.5, 0, 0, 22)
AccValue.Position = UDim2.new(0.5, -16, 0, 68)
AccValue.BackgroundTransparency = 1
AccValue.Text = "--"
AccValue.TextColor3 = C.text
AccValue.Font = Enum.Font.GothamBold
AccValue.TextSize = 14
AccValue.TextXAlignment = Enum.TextXAlignment.Right
AccValue.Parent = StatsCard

currentTab = "Combat"
pages["Combat"].page.Visible = true
pages["Combat"].accent.BackgroundTransparency = 0
pages["Combat"].label.TextColor3 = C.text
pages["Combat"].button.BackgroundColor3 = C.card
pages["Combat"].button.BackgroundTransparency = 0

closeBtn.MouseEnter:Connect(function()
    tween(closeBtn, { BackgroundColor3 = C.danger, TextColor3 = Color3.fromRGB(255, 255, 255) }, 0.12)
end)
closeBtn.MouseLeave:Connect(function()
    tween(closeBtn, { BackgroundColor3 = C.card, TextColor3 = C.textDim }, 0.12)
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
    }
end)

UserInputService.InputBegan:Connect(function(input, gp)
    if armingBox then
        if input.UserInputType == Enum.UserInputType.Keyboard then
            if input.KeyCode == Enum.KeyCode.Escape then
                armingBox:ReleaseFocus()
                return
            end
            if input.KeyCode == Enum.KeyCode.Backspace then
                armingKey.table[armingKey.name] = nil
            else
                armingKey.table[armingKey.name] = input.KeyCode
            end
            armingBox:ReleaseFocus()
            return
        end
    end
    if gp then return end
    if input.UserInputType == Enum.UserInputType.Keyboard then
        if keybinds.spam and input.KeyCode == keybinds.spam then
            spamToggle.set(not spamToggle.get())
        elseif keybinds.trigger and input.KeyCode == keybinds.trigger then
            triggerToggle.set(not triggerToggle.get())
        elseif keybinds.orbit and input.KeyCode == keybinds.orbit then
            orbitToggle.set(not orbitToggle.get())
        end
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
    local pingVal = pingSmoothed > 0 and pingSmoothed or dataPing:GetValue()
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

RunService.Heartbeat:Connect(function()
    if not orbit.enabled then return end
    local now = os.clock()
    local dt = now - orbit.lastTick
    orbit.lastTick = now
    if dt > 0.1 then dt = 0.1 end
    updateOrbit(dt)
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
            local vText = string.format("%.0f", maxSpeed)
            if VelocityValue.Text ~= vText then VelocityValue.Text = vText end
            VelocityValue.TextColor3 = maxSpeed >= 2200 and C.warn or C.text
        else
            if VelocityValue.Text ~= "--" then VelocityValue.Text = "--" end
            VelocityValue.TextColor3 = C.textDim
        end
        local ping = pingSmoothed > 0 and pingSmoothed or dataPing:GetValue()
        local pText = string.format("%.0fms", ping)
        if PingValue.Text ~= pText then PingValue.Text = pText end
        PingValue.TextColor3 = ping > 200 and C.warn or C.text
        if CONFIG.AccuracyMode == "auto" then
            local eff = getEffectiveAccuracy()
            local aText = string.format("%.0f%%", eff)
            if AccValue.Text ~= aText then AccValue.Text = aText end
            accuracySlider.sub.Text = string.format("auto | eff: %.0f%% | j: %.0f", eff, pingJitter)
        else
            if AccValue.Text ~= "manual" then AccValue.Text = "manual" end
            accuracySlider.sub.Text = "manual"
        end
        task.wait(0.05)
    end
end)

local MiniButton = Instance.new("TextButton")
MiniButton.Name = "MiniButton"
MiniButton.Size = UDim2.new(0, 108, 0, 34)
MiniButton.Position = UDim2.new(0.5, -54, 0, 12)
MiniButton.BackgroundColor3 = C.bg
MiniButton.BorderSizePixel = 0
MiniButton.Text = "HAHA.dll"
MiniButton.TextColor3 = C.accent
MiniButton.Font = Enum.Font.GothamBold
MiniButton.TextSize = 13
MiniButton.TextXAlignment = Enum.TextXAlignment.Center
MiniButton.AutoButtonColor = false
MiniButton.Visible = false
MiniButton.Parent = ScreenGui
Instance.new("UICorner", MiniButton).CornerRadius = UDim.new(1, 0)

local miniStroke = Instance.new("UIStroke")
miniStroke.Color = C.stroke
miniStroke.Thickness = 1
miniStroke.Parent = MiniButton

local miniDot = Instance.new("Frame")
miniDot.Size = UDim2.new(0, 7, 0, 7)
miniDot.Position = UDim2.new(0, 14, 0.5, -3.5)
miniDot.BackgroundColor3 = C.accent
miniDot.BorderSizePixel = 0
miniDot.Parent = MiniButton
Instance.new("UICorner", miniDot).CornerRadius = UDim.new(1, 0)

local function setMinimized(min)
    MainFrame.Visible = not min
    Shadow.Visible = not min
    MiniButton.Visible = min
end

MiniButton.MouseEnter:Connect(function()
    tween(MiniButton, { BackgroundColor3 = C.cardHover }, 0.12)
end)
MiniButton.MouseLeave:Connect(function()
    tween(MiniButton, { BackgroundColor3 = C.bg }, 0.12)
end)

MiniButton.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local startX, startY = input.Position.X, input.Position.Y
    local startPos = MiniButton.Position
    local moved = false
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
            if not moved then setMinimized(false) end
        end,
    }
end)

MiniButton.MouseButton2Click:Connect(function()
    alive = false
    spamState.enabled = false
    triggerEnabled = false
    orbit.enabled = false
    infiniteMode = false
    if renderTickConn then renderTickConn:Disconnect() end
    if refreshLoopConn then refreshLoopConn:Disconnect() end
    if noRender.enabled then disableNoRender() end
    ScreenGui:Destroy()
end)

closeBtn.MouseButton1Click:Connect(function()
    setMinimized(true)
end)
