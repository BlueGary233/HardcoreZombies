-- HZ_Diff.lua — 引擎实时快照（替代 diff + 队列）
--
-- 拍子：
--   声音 / 续单 / 发单      EmitInterval（默认 2s，每堆轮一次）
--   全量快照                EmitInterval × SnapPerPile（默认 4s，全局一次）
--
-- HZ_zombieFrame 返回：
--   obj[1..n] x[1..n] y[1..n] stats[1..n] n     ← 按 getObjectList 顺序，ArrayList 保序
--   removed[1..m] m                              ← 上一批有、本批无的原实例
--
-- 表是整体替换，不做增量；removed 用来清 _zstats 和释放订单。
-- 顺序每次可能变，但所有消费方都是集合语义 / 每只独立处理，不依赖索引位置。

local HZ = HardcoreZombies

-- 空快照结构：obj/x/y/stats/n
local function emptySnap()
    return { obj = {}, x = {}, y = {}, stats = {}, n = 0 }
end

HZ._snap    = HZ._snap or emptySnap()
HZ._snapGen = HZ._snapGen or 0

-- 快照周期 = 声音周期 × 倍数
function HZ.snapIntervalMs()
    local mult = math.max(1, math.floor(tonumber(HZ.opt.SnapPerPile) or 2))
    return HZ.emitIntervalMs() * mult
end

-- 拉一次全量快照；成功返回 true
function HZ.pullSnapshot()
    if not HZ_zombieFrame then return false end

    local ok, d = pcall(HZ_zombieFrame)
    if not ok or not d then return false end

    local n = tonumber(d.n) or 0
    local new = { obj = {}, x = {}, y = {}, stats = {}, n = n }
    local srcObj, srcX, srcY, srcSt = d.obj, d.x, d.y, d.stats

    for i = 1, n do
        new.obj[i]   = srcObj and srcObj[i] or nil
        new.x[i]     = tonumber(srcX and srcX[i]) or 0
        new.y[i]     = tonumber(srcY and srcY[i]) or 0
        new.stats[i] = srcSt and srcSt[i] or nil
    end

    HZ._snap = new
    HZ._snapGen = (HZ._snapGen or 0) + 1

    -- removed：立刻出表 + 释放订单（对象引用，O(1)）
    local m = tonumber(d.m) or 0
    local dropped = 0
    for i = 1, m do
        local z = d.removed and d.removed[i]
        if z and HZ.statsDropByDiff then
            HZ.statsDropByDiff(z)
            dropped = dropped + 1
        end
    end

    -- 对账：本批快照里没出现的条目一律清掉
    -- removed 是增量信号，可能漏批（热重载后基线复位时恒为空）；
    -- 这条是兜底，防止 _zstats 里的对象引用滞留。
    -- n == 0 时跳过：宁可漏清一次，也不要在空表异常时删光营养数据。
    if n > 0 and HZ._zstats then
        local seen = {}
        for i = 1, n do
            local z = new.obj[i]
            if z then seen[z] = true end
        end

        local orphans = {}
        for z in pairs(HZ._zstats) do
            if not seen[z] then orphans[#orphans + 1] = z end
        end
        for i = 1, #orphans do
            if HZ.statsDropByDiff then HZ.statsDropByDiff(orphans[i]) end
        end
        if #orphans > 0 and HZ.debugEnabled() then
            HZ.log(string.format("snapshot reap: %d orphan entries", #orphans))
        end
    end

    -- 新入场：本批才出现的丧尸建营养条目（用快照里的五维，零额外桥调用）
    if HZ.statsTrackByDiff and HZ._zstats then
        local t = HZ._zstats
        for i = 1, n do
            local z = new.obj[i]
            if z and not t[z] and new.stats[i] then
                HZ.statsTrackByDiff(z, new.stats[i])
            end
        end
    end

    -- 首拉探针：n>0 但 obj[1] 取不到 = 数字键类型不匹配（Double/Integer）
    if not HZ._snapProbed and n > 0 and HZ.debugEnabled() then
        HZ._snapProbed = true
        print(string.format("[HZ] snap probe: n=%d obj1=%s x1=%s",
            n, tostring(new.obj[1] ~= nil),
            tostring(srcX ~= nil and srcX[1] ~= nil)))
    end

    if HZ.debugEnabled() then
        HZ.log(string.format("snapshot: n=%d removed=%d gen=%d", n, dropped, HZ._snapGen))
    end
    return true
end

-- 每帧入口：到点拉快照，然后整表跑一遍营养维护
function HZ.diffTick()
    if not HZ.due("snap", HZ.snapIntervalMs()) then return end

    -- 快照失败（桥缺失 / jar 未更新）也要开轮：
    -- 营养表是 _zstats 自己，不依赖这一拍拿没拿到位置
    HZ.pullSnapshot()

    if HZ.beginStatsPass then HZ.beginStatsPass() end
end

-- 热重载 / 读档：清快照并复位 Java 基线
function HZ.resetDiff()
    HZ._snap       = emptySnap()
    HZ._snapGen    = (HZ._snapGen or 0) + 1
    HZ._snapProbed = nil
    HZ._throttle["snap"] = nil
    if HZ_resetDiff then pcall(HZ_resetDiff) end
end

print("[HZ_Diff] loaded (snapshot mode)")
