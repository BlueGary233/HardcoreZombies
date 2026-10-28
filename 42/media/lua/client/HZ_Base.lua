-- HZ_Base.lua — 公共基础设施 + 节拍
-- 这里只放所有模块都要用的东西：受控调用、日志、选项、骷髅判定、随机、时间节流

HardcoreZombies = HardcoreZombies or {}

local HZ = HardcoreZombies

HZ.VERSION = "0.4.0"

-- 重载后重新读取调试开关

-- 受控调用：失败不崩，但按方法名累计，快照可见
HZ._tryFail = HZ._tryFail or {}

-- pcall 包装：失败不抛，只在首次记录日志（避免每帧刷屏）
function HZ.try(name, fn, ...)
    local ok, r = pcall(fn, ...)
    if not ok then
        local key = tostring(name or "?")
        HZ._tryFail[key] = (HZ._tryFail[key] or 0) + 1
        return false, nil
    end
    return true, r
end

-- ===================== 工具 =====================
-- 调试开关：直接读设置（PZAPI 的值是实时的，菜单一改立刻生效）
function HZ.debugEnabled()
    local v = HZ.opt.DebugMode
    return v == true or v == "true"
end

-- 调试日志，受 debugEnabled 控制
function HZ.log(msg)
    if HZ.debugEnabled() then print("[HZ] " .. tostring(msg)) end
end

-- ===================== ModOptions 取值 =====================
local MODOPT_ID = "HardcoreZombies"
HZ.MODOPT_ID = MODOPT_ID

-- 统一判断：骷髅（引擎状态或我们打的 modData 标记）
HZ._boneUids = {}      -- 重载即作废（尸体对象的标记由引擎 isSkeleton 兜底）

-- 尸体是否已完全骨化（引擎 isSkeleton）
function HZ.isBone(body)
    if not body then return true end

    local okU, uid = HZ.try("getUID", function() return body:getUID() end)
    if okU and uid and HZ._boneUids[uid] then
        return true
    end

    local ok, sk = HZ.try("isSkeleton", function() return body:isSkeleton() end)
    -- 读不到属性（对象半失效 / 正在被替换）时按骨头处理：
    -- 宁可不吃，也不能把骷髅当成尸体派出去
    if not ok then return true end
    return sk == true
end

-- 读沙盒/面板选项，缺省时返回 default
function HZ.getOpt(id, default)
    local mo = PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.Dict[MODOPT_ID]
    local o = mo and mo.dict and mo.dict[id]
    if o and o.getValue then
        local v = o:getValue()
        if v ~= nil then return v end
    end
    return default
end


-- [0,1) 随机数
local function rand01()
    if Rand and Rand.Next then
        return Rand.Next(1000) / 1000
    end
    return 0.5
end

-- [a,b) 随机浮点
local function randFloat(a, b)
    return a + (b - a) * rand01()
end

HZ.rand01  = rand01
HZ.randFloat = randFloat

HZ._throttle = {}

-- 频率常量（毫秒）：优先用每分钟刷新的缓存，避免每帧查 ModOptions
-- 统一清理"吃"状态（三连调用收口）
-- 只清进食目标/动画，不动状态机（出队时用：setDefaultState 会打断动作）
function HZ.clearEatTarget(z)
    if not z then return end
    pcall(function() z:setEatBodyTarget(nil, true) end)
    pcall(function() z:setBodyToEat(nil) end)
    pcall(function() z:setForceEatingAnimation(false) end)
end

function HZ.clearEat(z)
    if not z then return end
    pcall(function() z:setEatBodyTarget(nil, true) end)
    pcall(function() z:setBodyToEat(nil) end)
    pcall(function() z:setForceEatingAnimation(false) end)
    -- 最后必须回一次 idle：只清目标不切状态机，它会保持进食状态站着
    pcall(function() z:setDefaultState() end)
end

-- 统一 uid 字符串（对象失效返回 nil）
function HZ.uidOf(o)
    if not o then return nil end
    local ok, v = pcall(function() return o:getUID() end)
    if not ok or v == nil then return nil end
    return tostring(v)
end

-- 设置默认值（与 addSlider/addTickBox 的 default 保持一致）
local OPT_DEFAULTS = {
    RotMin = 0.0, RotMax = 2.0, RotRandom = true,
    EmitInterval = 2.0,
    StinkFullHours = 9, CountFull = 25,
    RadiusMin = 20, RadiusMax = 120,
    VolumeMin = 10, VolumeMax = 100,
    WeightRadiusAge = 0.80, WeightVolumeCount = 0.80,
    MaxEaters = 4, EatMinutes = 60, BoneHours = 6, PileSize = 2,
    SatDigestHours = 4, NutPerSat = 0.20, NutDecayDay = 0.8,
    EatDistance = 1.0, BlockMs = 5000, LongBlockMs = 60000,
    PendingRetryMs = 2000, PendingGiveupMs = 10000,
    DebugScanRadius = 20, DebugSnapMinutes = 10,
    FakeDeadFood = false, DebugMode = false, Snap = false,
    SnapPerPile = 2,
}

-- 设置直接给 Lua 变量：启动/热重载时读一次，之后靠回调更新
-- 重载时保留旧表，避免 Base 先于 reloadCfg 执行导致设置全空
HZ.opt = HZ.opt or {}
-- 把面板(ini)的值同步进 HZ.opt，重载后必须调
function HZ.reloadCfg()
    local c = {}
    for id, def in pairs(OPT_DEFAULTS) do
        local v = nil
        if HZ.getOpt then v = HZ.getOpt(id, def) end
        if v == nil then v = def end
        c[id] = v
    end
    HZ.opt = c

    -- 调试模式下把读到的设置全打一遍，方便对照 ini 排查
    if HZ.debugEnabled and HZ.debugEnabled() then
        local keys = {}
        for id in pairs(OPT_DEFAULTS) do keys[#keys + 1] = id end
        table.sort(keys)
        print("[HZ] ---- settings loaded ----")
        for _, id in ipairs(keys) do
            print(string.format("[HZ] opt %-18s = %s", id, tostring(c[id])))
        end
        print("[HZ] -------------------------")
    end
end

-- ===================== buff 位掩码 =====================
-- 唯一写入口是 HZ.refreshBuffs（HZ_Orders）。其它模块只读，不许直接写 modData。
-- 存在丧尸 modData.hz_buff 上，Java patch 只读静音位（8）。
HZ.BUFF = {
    NEW    = 1,    -- 还没有营养/饱食条目 → 需要初始化 + 校准五维
    QUEUED = 2,    -- 在某个堆的队列里（开饭）；与 HUNGRY 互斥
    HUNGRY = 4,    -- 不在队列 且 饱食 < 2
    MUTE   = 8,    -- 静音：自定义尸堆声音全部听不到（Java patch 读这一位）
    HURT   = 16,   -- 五维被营养系统之外的来源改动
}

-- ===================== 每帧 tick 顺序 =====================
-- Loader 只负责遍历这张表。放在 Base 里：以后增删 tick 只需热重载，
-- 不用重启游戏（Loader 自己不在 reloadMod 列表里）。
HZ.tickList = {
    "diffTick",        -- 4s：全量快照 + 开一轮营养
    "tickStatsStep",   -- 4s / 条目数：营养衰减
    "tickPiles",       -- 2s / 堆数：维护 + 订单兜底 + 容量 + 发声 + 补队
    "v2Cycle",         -- 2s：重建格子表 / 调度序列 / 可接单队列
    "v2Tick",          -- 2s 内轮完一圈：格子派单 + 订单维护
}

-- ===================== 运行时状态清理 =====================
-- 热重载 / 读档时调用。原则：凡是「临时表 / Java 桥拿来的数据 / 节拍时间戳」
-- 一律丢弃。旧对象引用残留会导致「已有订单」「查不到条目」这类死锁。
function HZ.clearRuntimeState()
    -- 诊断：重载前到底有没有订单、modData 清了几只
    local nOrd, nFrame, nCleared = 0, 0, 0
    for _ in pairs(HZ._orders or {}) do nOrd = nOrd + 1 end
    if HZ_zombieFrame then
        local ok, d = pcall(HZ_zombieFrame)
        if ok and d then nFrame = tonumber(d.n) or 0 end
    end
    print(string.format("[HZ] clearRuntimeState: ordersBefore=%d zombFrame=%d", nOrd, nFrame))

    HZ._zstats         = {}
    HZ._byUid          = {}
    HZ._orders         = {}

    -- 三个全局队列的 key 列表与游标
    HZ._statPass       = nil
    HZ._ordKeys        = nil
    HZ._ordKeysAt      = nil
    HZ._ordCursor      = nil
    HZ._dispKeys       = nil
    HZ._dispKeysAt     = nil
    HZ._dispCursor     = nil

    -- Java 桥快照（整表都是对象引用）
    HZ._snap           = nil
    HZ._snapGen        = (HZ._snapGen or 0) + 1
    HZ._snapProbed     = nil
    HZ._navStat        = nil
    HZ._tickMs         = nil
    HZ._orderStateProbed = nil

    -- 派生缓存 / 沙盒曲线 / 风
    HZ._initVals       = nil
    HZ._soundOpts      = nil
    HZ._emitIntervalMs = nil
    HZ._wind           = nil

    -- 杂项
    HZ._boneUids       = {}
    HZ._pendingFeed    = {}
    HZ._tryFail        = {}
    HZ._hudZ           = nil
    HZ._hudAt          = nil
    HZ._pileCursor     = 0
    HZ._groupSeq       = 0
    HZ._throttle       = {}       -- 所有 due 时间戳，重载后重新起拍
    HZ._statDirty      = true

    -- Java 侧帧快照的上一批引用 + Lua 侧的 _snap/_restored
    -- 注意：HZ.resetDiff（Lua）内部会再调 HZ_resetDiff（Java），所以优先走 Lua 版
    if HZ.resetDiff then
        pcall(HZ.resetDiff)
    elseif HZ_resetDiff then
        pcall(HZ_resetDiff)
    end

    -- 重载 = 模组重新开始：把丧尸身上的状态清空，一切从零重建。
    -- 不清的话，Lua 表已经重置、modData 还留着 QUEUED|MUTE，
    -- 就会出现"表里没有它、它自己以为在吃饭"的悬空状态。
    if HZ_zombieFrame and HZ_setBuff and HZ_setPile then
        local ok, d = pcall(HZ_zombieFrame)
        if ok and d then
            for i = 1, tonumber(d.n) or 0 do
                local z = d.obj and d.obj[i]
                if z then
                    pcall(HZ_setBuff, z, 0)
                    pcall(HZ_setPile, z, 0)
                end
            end
        end
    end
end

-- 派生缓存（依赖多个设置、构建成本较高）
function HZ.invalidateOptCache()
    HZ._soundOpts      = nil
    HZ._emitIntervalMs = nil
end

-- 声音/派单/续单共用的基础节拍，返回毫秒
function HZ.emitIntervalMs()
    if HZ._emitIntervalMs == nil then
        -- 下限 0.1 秒：设成 0 会让 due() 每帧都放行
        local sec = tonumber(HZ.opt.EmitInterval) or 2.0
        if sec < 0.1 then sec = 0.1 end
        HZ._emitIntervalMs = sec * 1000
    end
    return HZ._emitIntervalMs
end

-- 独立节流：每个 key 单独计时。返回 true 时已刷新该 key 的时间戳。
function HZ.due(key, intervalMs)
    local now = getTimestampMs()
    local last = HZ._throttle[key]

    if last and (now - last) < intervalMs then
        return false
    end

    HZ._throttle[key] = now
    return true
end

print("[HZ] v" .. HZ.VERSION .. " core loaded")
