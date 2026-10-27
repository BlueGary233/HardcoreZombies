-- HZ_ZDebug.lua — 独立调试快照器
-- 每 10 游戏分钟：扫玩家周围 20 格的丧尸/尸体 + 快照 mod 维护的表和队列
-- 输出：Zomboid/HZ_debug/<时间戳>.txt

local HZ = HardcoreZombies

-- 无论开关状态都安装，运行时再判断 DebugMode ——
-- 这样在设置里随时开关都能生效，不用重载

-- 先解绑旧监听（否则重载后旧监听会越积越多）
if HZ_DBG_EVENT then
    pcall(function() Events.EveryOneMinute.Remove(HZ_DBG_EVENT) end)
    HZ_DBG_EVENT = nil
end

-- 调试扫描半径
local function scanRadius()  return tonumber(HZ.opt.DebugScanRadius) or 20 end
-- 自动快照间隔（游戏分钟）
local function snapMinutes() return tonumber(HZ.opt.DebugSnapMinutes) or 10 end

local acc = 0
local seq = 0

-- 值转字符串，nil 显示为 -
local function s(v)
    if v == nil then return "nil" end
    return tostring(v)
end

-- 布尔转 Y/N
local function bool(v)
    return v and "T" or "F"
end

-- 扫玩家周围，收集丧尸与尸体
local function scanAround(px, py, pz)
    local cell = getCell()
    if not cell then return {}, {} end

    local zs, bs = {}, {}

    for dx = -scanRadius(), scanRadius() do
        for dy = -scanRadius(), scanRadius() do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            if sq then
                local mos = sq:getMovingObjects()
                if mos then
                    for i = 0, mos:size() - 1 do
                        local o = mos:get(i)
                        if o and instanceof(o, "IsoZombie") then
                            -- 失效对象（已移出世界）直接跳过，别对 nil 方法调 pcall
                            local okSq, oSq = HZ.try("dbgSquare", function() return o:getSquare() end)
                            local aliveObj = okSq and oSq ~= nil

                            if aliveObj then
                            local tgt = nil
                            HZ.try("dbgTarget", function()
                                if o.getEatBodyTarget then tgt = o:getEatBodyTarget() end
                            end)

                            local eating = false
                            if tgt then
                                local okE, r = HZ.try("dbgEating", function()
                                    return o:isEatingOther(tgt)
                                end)
                                if okE then eating = (r == true) end
                            end

                            local grp = nil
                            pcall(function()
                                local md = o:getModData()
                                if md then grp = rawget(md, "hz_buff") end
                            end)

                            -- 对照：Java 侧读到的值
                            local grpJ = nil
                            pcall(function()
                                if HZ_getBuff then grpJ = HZ_getBuff(o) end
                            end)

                            local dead = false
                            pcall(function() dead = o:isDead() end)

                            -- 为什么不动？把状态机名字打出来
                            local stName, thump = "?", false
                            HZ.try("dbgState", function() stName = tostring(o:getCurrentStateName()) end)
                            HZ.try("dbgThump", function() thump = (o:getThumpTarget() ~= nil) end)

                            zs[#zs + 1] = string.format(
                                "Z %s pos=(%.2f,%.2f,%.2f) dead=%s state=%s thump=%s tgt=%s eating=%s buffLua=%s buffJava=%s",
                                HZ.uidOf(o), o:getX(), o:getY(), o:getZ(),
                                bool(dead), stName, bool(thump), tgt and HZ.uidOf(tgt) or "nil",
                                bool(eating), s(grp), s(grpJ))
                            end
                        end
                    end
                end

                local bodies = sq:getDeadBodys()
                if bodies then
                    for i = 0, bodies:size() - 1 do
                        local b = bodies:get(i)
                        if b then
                            local bone = false
                            pcall(function() bone = b:isSkeleton() end)

                            local dt = -1
                            pcall(function() dt = b:getDeathTime() end)

                            bs[#bs + 1] = string.format(
                                "B %s pos=(%.2f,%.2f,%.2f) bone=%s dt=%.3f",
                                HZ.uidOf(b), b:getX(), b:getY(), b:getZ(),
                                bool(bone), dt)
                        end
                    end
                end
            end
        end
    end

    return zs, bs
end

-- 快照 mod 内部结构
local function snapshotTables(out)
    out[#out + 1] = ""
    out[#out + 1] = "===== PILES (" .. #(HZ.piles or {}) .. ") ====="

    for i, p in ipairs(HZ.piles or {}) do
        out[#out + 1] = string.format(
            "PILE #%d (%d,%d,%d) pid=%s count=%d foods=%d queue=%d avgRot=%.3f rotDelay=%.2f hasScent=%s group=%s",
            i, p.x, p.y, p.z, s(p.pid), p.count or 0, #(p.foods or {}),
            (HZ.queueCount and HZ.queueCount(p)) or 0,
            p.avgRotStart or 0, p.rotDelay or 0,
            bool(p.hasScent), s(p.group))

        for j, b in ipairs(p.foods or {}) do
            out[#out + 1] = string.format(
                "  food[%d] uid=%s pos=(%d,%d,%d) orders=%d progress=%.3f boned=%s",
                j, s(b.uid), b.x, b.y, b.z,
                b.orders or 0, b.eatProgress or 0, bool(b.boned))
        end

        if p.queue and #p.queue > 0 then
            local ids = {}
            for k = 1, math.min(#p.queue, 30) do
                ids[#ids + 1] = HZ.uidOf(p.queue[k])
            end
            out[#out + 1] = "  queue: " .. table.concat(ids, ", ")
        end
    end

    out[#out + 1] = ""
    out[#out + 1] = "===== ORDERS ====="

    local n = 0
    for z, ord in pairs(HZ._orders or {}) do
        n = n + 1
        -- 诊断：距尸体 / 吃目标 / 卡住时长
        local dist, eatTgt = -1, "?"
        pcall(function()
            if ord.body then dist = z:DistTo(ord.body) end
            eatTgt = (z:getEatBodyTarget() ~= nil) and "T" or "F"
        end)
        local stN = "?"
        pcall(function() stN = tostring(z:getCurrentStateName()) end)
        out[#out + 1] = string.format(
            "ORDER z=%s pile=(%d,%d) body=%s rec=(%d,%d) ageMs=%d d=%.2f state=%s eatTgt=%s stillN=%d pushN=%d",
            HZ.uidOf(z), ord.pile and ord.pile.x or -1, ord.pile and ord.pile.y or -1,
            HZ.uidOf(ord.body),
            ord.rec and ord.rec.x or -1, ord.rec and ord.rec.y or -1,
            getTimestampMs() - (ord.t or 0), dist, stN, eatTgt,
            ord.stillN or 0, ord.nudgeN or 0)
    end
    out[#out + 1] = "orders total=" .. n

    out[#out + 1] = ""
    out[#out + 1] = "===== ZSTATS (sat/nut/三维) ====="

    local zn = 0

    -- 总表 key 是对象，直接打
    for z, st in pairs(HZ._zstats or {}) do
        zn = zn + 1

        local f = st.five or {}
        local idOnly = string.match(tostring(z), "IsoZombie%-(%d+)%-")

        -- 位置实时取（表里的 s.x/s.y 只在小时校准后更新，不能拿来做调试依据）
        local px, py = -1, -1
        HZ.try("dbgPos", function() px, py = z:getX(), z:getY() end)

        out[#out + 1] = string.format(
            "ZSTAT uid=%s pos=(%d,%d) nut=%.2f stage=%d sat=%.2f eating=%s banned=%s h=%.2f sp=%s str=%s si=%s he=%s",
            idOnly and ("ID:" .. idOnly) or tostring(st.uid),
            math.floor(px), math.floor(py),
            st.nutrition or 0, st.stage or 0, st.satiety or 0,
            bool(st.eatingSince), bool((tonumber(st.satiety) or 0) > 2),
            f.h or -1, tostring(f.sp or -1), tostring(f.st or -1),
            tostring(f.si or -1), tostring(f.he or -1))
    end

    out[#out + 1] = "zstats total=" .. zn

    -- 位置快照 + 负载均衡状态
    local snap  = HZ._snap
    local piles = #(HZ.piles or {})
    local emitMs = HZ.emitIntervalMs and HZ.emitIntervalMs() or 0
    out[#out + 1] = string.format(
        "SNAP n=%d gen=%d iv=%.0fms | piles=%d pileIv=%.0fms cursor=%d",
        snap and snap.n or 0, HZ._snapGen or 0,
        HZ.snapIntervalMs and HZ.snapIntervalMs() or 0,
        piles, piles > 0 and (emitMs / piles) or 0, HZ._pileCursor or 0)

    out[#out + 1] = ""
    out[#out + 1] = "===== TRY FAILURES ====="

    local anyFail = false
    for name, n in pairs(HZ._tryFail or {}) do
        out[#out + 1] = string.format("%s: %d", tostring(name), n)
        anyFail = true
    end
    if not anyFail then
        out[#out + 1] = "(none)"
    end

end

-- 是否启用定时快照
local function snapEnabled()
    local v = HZ.opt.Snap
    return v == true or v == "true"
end

-- 生成快照文本并落盘
local function writeSnapshot()
    if not (HZ.debugEnabled and HZ.debugEnabled()) then return end
    if not snapEnabled() then return end
    local player = getPlayer()
    if not player then return end

    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())

    seq = seq + 1

    local out = {}
    out[#out + 1] = string.format("HZ DEBUG SNAPSHOT #%d  ts=%d", seq, getTimestampMs())
    out[#out + 1] = string.format("player pos=(%d,%d,%d) radius=%d", px, py, pz, scanRadius())

    local zs, bs = scanAround(px, py, pz)

    out[#out + 1] = ""
    out[#out + 1] = "===== ZOMBIES IN RADIUS (" .. #zs .. ") ====="
    for i = 1, #zs do out[#out + 1] = zs[i] end

    out[#out + 1] = ""
    out[#out + 1] = "===== BODIES IN RADIUS (" .. #bs .. ") ====="
    for i = 1, #bs do out[#out + 1] = bs[i] end

    snapshotTables(out)

    local name = string.format("HZ_debug/snap_%02d_%d.txt", seq, getTimestampMs())

    local ok = pcall(function()
        local w = getFileWriter(name, true, false)
        if not w then return end
        w:write(table.concat(out, "\n"))
        w:close()
    end)

    print(string.format("[HZ_DBG] snapshot #%d -> %s (ok=%s) z=%d b=%d",
        seq, name, tostring(ok), #zs, #bs))
end

-- 每分钟检查一次是否写快照
local function onMinute()
    if not (HZ.debugEnabled and HZ.debugEnabled()) then return end

    acc = acc + 1
    if acc >= snapMinutes() then
        acc = 0
        local ok, err = pcall(writeSnapshot)
        if not ok then
            print("[HZ_ZDBG] snapshot error: " .. tostring(err))
        end
    end
end

HZ_DBG_EVENT = onMinute
Events.EveryOneMinute.Add(HZ_DBG_EVENT)

-- 控制台手动触发：HZ.debugSnapshot()
function HZ.debugSnapshot()
    pcall(writeSnapshot)
end

print("[HZ_ZDBG] installed (idle until DebugMode is on)")

-- 热重载/首次加载立即拍一张，不用等 10 分钟
pcall(writeSnapshot)

-- ===== 调试 overlay：尸堆/声源在地图上的屏幕位置 =====
HZ._onUIDraw = function()
    -- 用 Base 里的 5 秒缓存版本：开关关掉后最多 5 秒就停
    if not (HZ.debugEnabled and HZ.debugEnabled()) then return end

    local tm = getTextManager()
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local pn = 0

    -- 尸堆：只显示尸体数量
    for i = 1, #(HZ.piles or {}) do
        local p = HZ.piles[i]
        local sx = isoToScreenX(pn, p.x, p.y, p.z)
        local sy = isoToScreenY(pn, p.x, p.y, p.z)
        if sx > -200 and sx < sw + 200 and sy > -200 and sy < sh + 200 then
            tm:DrawString(UIFont.Small, sx - 24, sy - 30,
                string.format("[PILE] n=%d", p.count or 0),
                0.2, 1, 0.2, 1)
        end

        -- 声源：半径 + 响度
        if p.sourceX then
            local ex = isoToScreenX(pn, p.sourceX, p.sourceY, p.z)
            local ey = isoToScreenY(pn, p.sourceX, p.sourceY, p.z)
            if ex > -200 and ex < sw + 200 and ey > -200 and ey < sh + 200 then
                tm:DrawString(UIFont.Small, ex - 24, ey - 14,
                    string.format("[SRC] r=%d v=%d",
                        math.floor(p.lastRadius or 0), math.floor(p.lastVolume or 0)),
                    1, 0.8, 0.2, 1)
            end
        end
    end

    -- 丧尸：只画光标 10×10 格内、最多 10 条
    local now = getTimestampMs()
    if (not HZ._hudZ) or (now - (HZ._hudAt or 0)) > 500 then
        HZ._hudAt = now
        HZ._hudZ = {}

        -- 引擎渲染列表（视野内的活对象）-> uid 映射
        local byUid = {}
        local list = HZ_allZombies and HZ_allZombies() or nil
        if list then
            for k = 0, list:size() - 1 do
                local zb = list:get(k)
                if zb then
                    local okU, u = pcall(function() return zb:getUID() end)
                    if okU and u then byUid[tostring(u)] = zb end
                end
            end
        end

        -- 光标世界坐标（拿不到就退回玩家位置）
        local p = getSpecificPlayer(0)
        local cx = p and p:getX() or 0
        local cy = p and p:getY() or 0
        local pz = p and p:getZ() or 0

        local mx, my = nil, nil
        pcall(function() mx = getMouseX() end)
        pcall(function() my = getMouseY() end)
        if mx and my and screenToIsoX and screenToIsoY then
            local wx, wy
            pcall(function()
                wx = screenToIsoX(0, mx, my, pz)
                wy = screenToIsoY(0, mx, my, pz)
            end)
            if wx and wy then cx, cy = wx, wy end
        end

        -- 遍历总表，用引擎列表里对应的活对象
        local cand = {}

        for z, st in pairs(HZ._zstats or {}) do
            -- Java 桥判死活：失效对象传进去是 null，安全
            local alive = false
            if z and HZ_orderState then
                local ok, state = pcall(HZ_orderState, z, nil)
                alive = ok and ((tonumber(state) or 1) % 2 < 1)
            end
            if alive then
                local zx, zy
                local okP = pcall(function() zx, zy = z:getX(), z:getY() end)
                if okP and zx then
                    local dx, dy = zx - cx, zy - cy
                    cand[#cand + 1] = {
                        uid = st.uid, st = st, z = z,
                        d = dx * dx + dy * dy,
                    }
                end
            end
        end

        table.sort(cand, function(a, b) return a.d < b.d end)

        for i = 1, math.min(3, #cand) do
            HZ._hudZ[i] = cand[i]
        end
    end

    for i = 1, #(HZ._hudZ or {}) do
        local e = HZ._hudZ[i]
        local st = e.st
        local z = e.z
        -- 实时取坐标；对象已失效（缓存 500ms 内死掉/卸载）就跳过，不画错位
        local sx, sy
        local okP = pcall(function()
            local zx, zy, zz = z:getX(), z:getY(), z:getZ()
            sx = isoToScreenX(pn, zx, zy, zz)
            sy = isoToScreenY(pn, zx, zy, zz)
        end)

        -- 屏幕外不画（严格边界）
        if okP and sx and sy and sx >= 0 and sx <= sw and sy >= 0 and sy <= sh then
            local sat = (HZ.statsCurrentSat and e.z and HZ.statsCurrentSat(e.z)) or (st.satiety or 0)
            tm:DrawString(UIFont.Small, sx - 40, sy - 22,
                string.format("sat=%.1f nut=%.2f stg=%d h=%.1f sp=%d str=%d si=%d he=%d",
                    sat, st.nutrition or 0, st.stage or 0,
                    (st.five and st.five.h) or -1,
                    (st.five and st.five.sp) or -1,
                    (st.five and st.five.st) or -1,
                    (st.five and st.five.si) or -1,
                    (st.five and st.five.he) or -1),
                0.8, 0.8, 1, 1)
        end
    end
end
