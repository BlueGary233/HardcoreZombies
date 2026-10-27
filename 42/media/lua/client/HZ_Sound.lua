-- HZ_Sound.lua — 发声
-- 只负责：把一个尸堆变成一次 WorldSound（半径/音量/风偏移）
-- 调度不在这里：tickPiles 按 2s/堆数 轮转，每拍一个堆，调用 HZ.emitPile

local HZ = HardcoreZombies

-- 本文件日志（走 HZ.debug）
local function log(msg)
    if HZ.log then HZ.log(msg) else print("[HZ-smell] " .. tostring(msg)) end
end

-- 读配置项的快捷方式
local function opt(id, default)
    local v = HZ.opt[id]
    if v == nil then return default end
    return v
end

-- ===================== 堆消失 =====================
HZ.onPileGone = function(pile)
    if not pile then return end
    pile.dead = true

    -- 堆消失：订单由订单系统统一释放（“尸堆没了”）
    if HZ.ordersReleasePile then HZ.ordersReleasePile(pile) end
    -- 认领也要清：每个堆自己负责放掉它认领的丧尸
    if HZ.releasePileClaims then HZ.releasePileClaims(pile) end

end

-- ===================== 配置/风缓存 =====================
-- 配置滑杆 60 秒读一次；风是全局状态，1 秒读一次，避免每次 emit 都跨 JNI
local function soundOpts()
    if HZ._soundOpts then return HZ._soundOpts end

    local wRA = opt("WeightRadiusAge", 0.90)
    local wVC = opt("WeightVolumeCount", 0.85)

    HZ._soundOpts = {
        stinkFull = opt("StinkFullHours", 9),
        countFull = opt("CountFull", 25),
        rMin      = opt("RadiusMin", 40),
        rMax      = opt("RadiusMax", 120),
        vMin      = opt("VolumeMin", 30),
        vMax      = opt("VolumeMax", 300),
        wRA       = wRA,
        wRC       = 1 - wRA,
        wVC       = wVC,
        wVA       = 1 - wVC,
    }
    return HZ._soundOpts
end

-- 风力/风向（1 秒缓存，只有室外发声用）
local function windInfo()
    local now = getTimestampMs()
    local w = HZ._wind
    if (not w) or (now - w.at > 1000) then
        local weather = getWorld() and getWorld():getClimateManager()
        w = { at = now, wind = 0, angle = 0 }
        if weather then
            w.wind  = weather:getWindIntensity()
            w.angle = weather:getWindAngleRadians()
        end
        HZ._wind = w
    end
    return w
end

-- ===================== 发声 =====================
HZ.emitPile = function(pile, now)
    -- 室内堆：不发声（声音会穿墙，等于把整条街的丧尸都叫来砸门），
    -- 只保留接单半径 10 格——墙外 10 格内的丧尸会接到单，走过来撞门/翻窗（原版行为）。
    if pile.indoor then
        pile.sourceX, pile.sourceY = pile.x, pile.y
        pile.lastRadius, pile.lastVolume = 10, 0
        pile.lastOff = 0
        return
    end

    local c = soundOpts()
    local stinkFull, countFull = c.stinkFull, c.countFull
    local rMin, rMax           = c.rMin, c.rMax
    local vMin, vMax           = c.vMin, c.vMax
    local wRA, wRC, wVC, wVA   = c.wRA, c.wRC, c.wVC, c.wVA

    local avgAge = now - (pile.avgRotStart or now)
    if avgAge < 0 then avgAge = 0 end

    local count = pile.count or 0

    local ageK   = math.min(avgAge / stinkFull, 1)
    local countK = math.min(count / countFull, 1)

    -- 权重之和可能不等于 1，clamp 防止超出范围
    local rw = math.min(wRA * ageK + wRC * countK, 1)
    local radius = rMin + (rMax - rMin) * rw

    local vw = math.min(wVC * countK + wVA * ageK, 1)
    local volume = vMin + (vMax - vMin) * vw

    -- 风偏移：0 级 = 堆中心，4 级 = 半径边缘（风缓存 1 秒）
    local wi = windInfo()
    local wind, angle = wi.wind, wi.angle

    local level = math.floor(wind * 4.999)

    -- 风偏：0 级 = 堆中心，4 级 = 半径 - 2×尸堆边长
    -- 保证声源圆始终把整个尸堆包住（派单区 = 声源圆）
    local pileR    = math.floor(tonumber(HZ.opt.PileSize) or 2)
    local pileEdge = 2 * pileR + 1
    local maxOff   = math.max(0, radius - 2 * pileEdge)
    local off      = maxOff * (level / 4)

    -- 防风吹进室内：只查声源落点一格
    -- （原来扫 5x5 × 最多 64 轮 = 1600 次 getGridSquare，是全链路最贵的一段）
    if off > 0 then
        local cell = getCell()
        if cell then
            local tx = math.floor(pile.x + math.sin(angle) * off)
            local ty = math.floor(pile.y - math.cos(angle) * off)
            local sq = cell:getGridSquare(tx, ty, pile.z)
            if sq and not sq:isOutside() then off = 0 end
        end
    end

    pile.lastOff = off

    local soundR = radius
    local soundV = volume

    -- 落在设置的最大/最小范围内
    soundR = math.max(opt("RadiusMin", 40), math.min(opt("RadiusMax", 120), soundR))
    soundV = math.max(opt("VolumeMin", 30), math.min(opt("VolumeMax", 300), soundV))

    local sx = pile.x + math.sin(angle) * off
    local sy = pile.y - math.cos(angle) * off
    local rx, ry = math.floor(sx), math.floor(sy)

    -- 派单中心 = 这一级声音的源点（跟着声音走）
    pile.sourceX = rx
    pile.sourceY = ry

    WorldSoundManager.instance:addSound(pile.group, rx, ry, pile.z,
        math.floor(soundR), math.floor(soundV), true)

    -- 派单不在这里：tickOneDispatch 按 2s/排队数 全局轮转


    -- 接单圆 = 实际声音圆：存夹紧后的值，两边用同一个数，不重复计算
    pile.lastRadius = soundR
    pile.lastVolume = soundV

    if HZ.debugEnabled() then
        log(string.format("emit (%d,%d) src=(%d,%d) n=%d age=%.2f r=%d v=%d lastAssign=%d",
            pile.x, pile.y, rx, ry, count, avgAge,
            math.floor(soundR), math.floor(soundV), pile.lastAssign or 0))
    end
end

print("[HZ_Sound] loaded")
