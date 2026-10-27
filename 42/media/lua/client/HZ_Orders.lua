-- HZ_Orders.lua — 订单系统
-- 订单 = HZ._orders[zombie] = { pile=, body=, rec=, t= }
-- 规则：进入订单表后，第一任务就是干饭。
--       能打断的只有两种：1) 尸堆没了  2) 丧尸自己没了/死了
-- 本文件负责：派单、续约、超时回队、释放、幽灵订单清理、热重载善后

local HZ = HardcoreZombies

-- 重载即作废：订单表直接重建，不清理旧对象
HZ._orders = {}

-- 尸体对某只丧尸的冷却（毫秒）：只是优先级，不是禁令——没有别的选择时会突破
local function blockMs()     return tonumber(HZ.opt.BlockMs) or 5000 end

-- 订单状态位掩码（HZ_orderState）：bit0=死, bit1=有eatTarget, bit2=有bodyToEat, bit3=尸体在
local function orderFlags(z, body)
    local st = 0
    if HZ_orderState then
        local ok, v = pcall(HZ_orderState, z, body)
        if ok and type(v) == "number" then st = v end
    end

    local dead      = st % 2 >= 1
    local hasTgt    = math.floor(st / 2) % 2 >= 1 or math.floor(st / 4) % 2 >= 1
    local bodyAlive = math.floor(st / 8) % 2 >= 1
    if bodyAlive and body and HZ.isBone(body) then bodyAlive = false end
    return dead, hasTgt, bodyAlive
end

-- 瞬时动作状态：这些状态里踢 setDefaultState 会打断引擎动作（翻窗卡住、倒地不起、砸窗中断）。
-- 只在“准备干预”时调用（不是每 tick），多几次跨桥可以接受。
local function busyState(z)
    local busy = false
    HZ.try("busyChk", function()
        if z:isClimbing() or z:isFalling() or z:isKnockedDown()
           or z:isGettingUp() or z:isStaggerBack() or z:isAttacking() then
            busy = true
            return
        end
        if z:getThumpTarget() ~= nil then busy = true end   -- 正在砸门/砸窗
    end)
    return busy
end

-- ===================== buff（唯一状态，写在丧尸 modData 上） =====================
-- 只有两个字段，Lua 侧不存任何副本：
--   hz_pile  认领它的堆 pid（0 = 不在任何队列）
--   hz_buff  1=新生 2=开饭 4=饥饿 8=静音 16=受伤
-- 判定一律实时读 modData；写只有 joinQueue / leaveQueue 两个口。

function HZ.pileOf(z)
    if not z then return 0 end
    if HZ_getPile then
        local ok, v = pcall(HZ_getPile, z)
        if ok and type(v) == "number" then return v end
    end
    return 0
end

-- 按当前条件重算并写入。pid 省略时实时读 hz_pile。
-- pid 是否对应一个活着的堆
function HZ.pileExists(pid)
    if not pid or pid == 0 then return false end
    local list = HZ.piles
    if not list then return false end
    for i = 1, #list do
        if list[i].pid == pid then return true end
    end
    return false
end

function HZ.refreshBuffs(z, pid)
    if not z then return end
    -- v2：认领机制已废弃。旧存档里残留的 hz_pile 会让丧尸假"开饭+静音"，这里一律忽略。
    if HZ.v2Active then pid = 0 end
    if pid == nil then pid = HZ.pileOf(z) end

    -- 认领的堆已经不存在（尸体吃光 / 区块卸载 / 重载后未重建）：
    -- 就地作废，否则它会带着 QUEUED|MUTE 永久静音、永远不接单
    if pid ~= 0 and not HZ.pileExists(pid) then
        pid = 0
        if HZ_setPile then pcall(HZ_setPile, z, 0) end
    end

    local s = HZ._zstats and HZ._zstats[z]
    local B = HZ.BUFF
    local bits

    if not s then
        bits = B.NEW
    elseif (HZ._orders and HZ._orders[z]) or pid ~= 0 then
        bits = B.QUEUED + B.MUTE          -- 有订单（v2）或旧认领：开饭 + 静音
    elseif (s.satiety or 0) < 2 then
        bits = B.HUNGRY                   -- 饥饿：没有静音
    else
        bits = B.MUTE                     -- 吃饱且不在队：静音
    end

    if s and s.hurt then bits = bits + B.HURT end

    -- 位没变就不写：setBuff 是 JNI 调用，还有 transmit 成本；派单/维护每 2 秒都会走到这里
    HZ._buffCache = HZ._buffCache or setmetatable({}, { __mode = "k" })
    if HZ._buffCache[z] == bits then return end
    HZ._buffCache[z] = bits
    if HZ_setBuff then pcall(HZ_setBuff, z, bits) end
end

-- 这个堆有多少只（实时扫快照 + hz_pile，不存队列数组）
function HZ.queueCount(pile)
    local snap = HZ._snap
    if not snap or not pile or not pile.pid then return 0 end
    local n = 0
    for i = 1, snap.n do
        local z = snap.obj[i]
        if z and HZ.pileOf(z) == pile.pid then n = n + 1 end
    end
    return n
end

-- 这个堆的下一只（skip 用来避开当前处理中的那只）

-- 进队：写认领，重算 buff

-- 堆消失：把它认领的丧尸全部放回自由。
-- 由删除堆的那段代码调用（HZ_Pile），不是靠每 4 秒轮询兜底。
function HZ.releasePileClaims(pile)
    if not pile or not pile.pid then return end
    local snap = HZ._snap
    if not snap then return end


    for i = 1, snap.n do
        local z = snap.obj[i]
        if z and HZ.pileOf(z) == pile.pid then HZ.leaveQueue(z) end
    end
end

-- 出队：清认领，重算 buff。所有移除路径的唯一出口。
function HZ.leaveQueue(z)
    if not z then return end
    if HZ_setPile then pcall(HZ_setPile, z, 0) end
    HZ.refreshBuffs(z, 0)
end

-- ===================== 释放 =====================
-- 唯一出口：清进食目标/动画、回补餐位、拉黑这具尸体
-- requeue=true ：僵尸仍在干饭队列里，只是换一具尸体 → 保留静音
-- requeue=false：真正结束 → 解除静音，让它能被下一堆吸引
-- 导航诊断计数：每 30 秒一行，用来判断到底是谁在打断走路
local function navBump(k)
    if not HZ.debugEnabled() then return end       -- 诊断代码，Debug 关时零成本
    local st = HZ._navStat
    if not st then
        st = { path = 0, first = 0, body = 0, still = 0, rel = 0 }
        HZ._navStat = st
    end
    st[k] = (st[k] or 0) + 1
    if HZ.due("navStat", 30000) then
        HZ.log(string.format("nav30s: path=%d (first=%d body=%d still=%d) release=%d",
            st.path or 0, st.first or 0, st.body or 0, st.still or 0, st.rel or 0))
        HZ._navStat = { path = 0, first = 0, body = 0, still = 0, rel = 0 }
    end
end

function HZ.releaseOrder(z, ord, requeue)
    if not z then return end
    navBump("rel")

    HZ.try("releaseClearTarget", function()
        HZ.clearEat(z)
    end)

    -- 退出吃饭：按时长结算饱食度
    if HZ.statsEatStop then HZ.statsEatStop(z) end

    if ord and ord.rec then
        ord.rec.orders = math.max(0, (ord.rec.orders or 0) - 1)
        ord.rec.blocked = ord.rec.blocked or {}
        -- 冷却而不是永久拉黑：30 秒后这具尸体还能重新派给它
        ord.rec.blocked[z] = getTimestampMs() + blockMs()
    end

    if HZ._orders then HZ._orders[z] = nil end
    if ord and ord.pile and ord.pile.orders then ord.pile.orders[z] = nil end
    -- 格子订单表也要摘：餐位 = MaxEaters - #cell.orders，不清就一直占着
    if ord and ord.cell and ord.cell.orders then ord.cell.orders[z] = nil end

    -- 真正结束才出队；requeue 表示它马上回到队列，保留认领
    if not requeue then HZ.leaveQueue(z) end
end

-- 尸堆消失：释放所有指向它的订单
function HZ.ordersReleasePile(pile)
    if not pile or not pile.orders then return end

    local list = {}
    for z, ord in pairs(pile.orders) do
        list[#list + 1] = { z = z, ord = ord }
    end

    for i = 1, #list do
        HZ.releaseOrder(list[i].z, list[i].ord, false)
    end
    pile.orders = {}
end

-- 尸体骨化/消失：释放所有指向这具尸体的订单
function HZ.ordersReleaseBody(body)
    if not body or not HZ._orders then return end

    -- 按 uid 比较：骨化后的 IsoDeadBody 可能是另一个实例，引用比较会漏
    local okU, uid = HZ.try("getUID", function() return body:getUID() end)
    if not okU or not uid then return end

    local drop = {}
    for z, ord in pairs(HZ._orders) do
        if ord.body then
            local okO, ouid = HZ.try("getUID", function() return ord.body:getUID() end)
            if okO and ouid == uid then
                drop[#drop + 1] = { z = z, ord = ord }
            end
        end
    end

    for i = 1, #drop do
        HZ.releaseOrder(drop[i].z, drop[i].ord, false)
    end
end

-- ===================== 导航续期 =====================
-- ===================== 导航 =====================
-- Lua 接管寻路：直接走向尸体，到达 1 格内才把 bodyToEat 交给原版开吃。
-- 原版对 bodyToEat 每帧 pathToLocationF（每次清路径重算），所以派单时刻意不设它。
-- 导航刷新与声音/派单同频（1 级逻辑间隔，默认 2.1s）；path 本身没有寿命，
-- 只有偏离/卡住时才需要重发，频率跟着 1 级节拍即可。



-- 单个订单：导航 / 进食 / 卡住处理（不遍历，供队列调度逐个调用）
-- 脚下这一格有没有能吃的：在本堆清单里、没骨化
-- 按 uid 在 pile.foods 里找记录。不建索引表：堆里最多一百多具，
-- 线性扫一遍比维护一张镜像表便宜，也不会多一份数据要同步。
local function recByUid(pile, uid)
    if not pile or not uid or not pile.foods then return nil end
    local foods = pile.foods
    for i = 1, #foods do
        if foods[i].uid == uid then return foods[i] end
    end
    return nil
end

-- rec 是否还在这堆的清单里（不建集合表，直接扫）
local function foodSet(pile, rec)
    if not pile or not pile.foods then return false end
    if rec == nil then return nil end
    local foods = pile.foods
    for i = 1, #foods do
        if foods[i] == rec then return true end
    end
    return false
end

local function footBodyAt(z, pile)
    local body, rec = nil, nil
    HZ.try("footBody", function()
        local sq = z:getSquare()
        if not sq then return end
        local list = sq:getDeadBodys()
        if not list then return end
        for i = 0, list:size() - 1 do
            local b = list:get(i)
            if b then
                -- 先取 uid 查索引，命中才去查骨架（少两次跨桥）
                local uid = b:getUID()
                local r = uid and recByUid(pile, uid)
                if r and not HZ.isBone(b) then
                    body, rec = b, r
                    return                      -- 第一具可以吃的就停
                end
            end
        end
    end)
    return body, rec
end

-- 本堆里换一具：跳过骨化、跳过自己刚吃过的冷却

-- 订单主循环：校验目标 → 换目标 → 吃饭 → 导航（每只每次一拍）

-- 每堆兜底：订单指向的尸体没了 / 丧尸没了就释放
function HZ.ordersSweepPile(pile)
    if not pile or not pile.orders then return end

    local nowMs = getTimestampMs()
    local drop = nil

    local inFoods = {}
    for i = 1, #pile.foods do inFoods[pile.foods[i]] = true end

    for z, ord in pairs(pile.orders) do
        local dead = false

        if not z then
            dead = true
        elseif not ord.rec or not inFoods[ord.rec] then
            -- 订单指向的 rec 已经不在本堆（重建/重扫）：旧订单必须释放
            dead = true
        else
            -- 导航和进食交给 tickOneOrder（全局订单队列）；这里只做失效释放
            -- orderFlags 走 Java 桥，失效对象返回 dead=true，不抛
            local isDeadFlag, _, bodyAlive = orderFlags(z, ord.body)

            if isDeadFlag or not bodyAlive then
                -- 丧尸已死/已卸载，或目标尸体没了：释放
                dead = true
            end
            -- 活着什么都不用做：ord.t 是派单时刻，踢人排序要用，别每拍刷新
        end

        if dead then
            drop = drop or {}
            drop[#drop + 1] = { z = z, ord = ord }
        end
    end

    if drop then
        for i = 1, #drop do
            HZ.releaseOrder(drop[i].z, drop[i].ord, false)
        end
    end
end


-- ===================== 队列补充（快照周期，4 秒） =====================
-- 派单区：声源圆（圆心 = 本次发声的声源中心，半径 = 本次声音半径）
-- 风偏已把声源限制在「半径 - 2×尸堆边长」以内，所以这个圆必然覆盖整个尸堆。
-- 没气味（尸体还没腐化）时不发声，派单区退回尸堆本身（方块）。

-- 对象已失效（死亡 / 卸载 / 对象被回收）：清掉所有痕迹并返回 true。
-- HZ_orderState 对失效对象返回 0，桥调用本身 pcall 保护，不会抛。

-- 单只丧尸：续单 / 释放 / 进队。室内和室外共用这一段

-- 室内：边界是墙，扫房间格（室内无风，不用圆）

-- 室外：快照坐标做一次圆判断，命中才碰对象

-- ===================== 派单（全局队列：2s / 排队数） =====================

-- 给一只丧尸派单；成功返回 true

-- ===================== 全局队列：2s / 队列长度 =====================
-- 派单和续单都不绑堆：队列里是所有堆的元素，间隔 = 周期 / 总数。
-- 堆内 while 一次派完会让同堆的多只丧尸同帧起步，这是同步感的来源。

-- 派单队列：所有堆的排队丧尸合成一个全局队列

-- 续单队列：所有订单合成一个全局队列

-- ============================================================================
-- v2 结构层：尸体 → 格子 → 尸堆（旧函数全部保留，只是不再被调用）
--
--   尸堆时间片 2s：按格子数加权（格子多的堆在调度序列里占更多格位）
--      └ 每个格子一圈内必被轮到一次
--          ├ 派单：从本堆可接单队列里取「最近的、够餐位数」的丧尸
--          └ 维护：调用旧的 navOne，行为完全沿用 0.3.0
--
--   可接单队列：纯数据，每 2s 重建；没有订单的丧尸只出现在「离它最近 + 有空位」的堆
--   格子：尸体按入格自然顺序，第一具独享本格全部餐位，吃完/骨化才轮到下一具
-- ============================================================================
-- 每次都建新表。以前写的是 HZ.v2 or {} —— HZ 是跨重载存活的表，
-- 于是重载后 V2.sched 里还留着上一轮的格子对象，格子里的 ord.body / ord.cell
-- 全是失效包装：导航拿到 garbage/0，丧尸就往地图原点跑。
local V2 = {}
HZ.v2 = V2
HZ.v2Active = true

local function v2MaxEaters()
    return math.max(1, math.floor(tonumber(HZ.opt.MaxEaters) or 4))
end

local function v2Key(rec)
    return math.floor(rec.x or 0) .. ":" .. math.floor(rec.y or 0) .. ":" .. math.floor(rec.z or 0)
end


-- 重建某堆的格子表（foods 变了才重建），按「堆中心 → 外围」分环，环内保持入格顺序
local function v2BuildCells(pile)
    local ver = pile._foodsVer or 0
    if pile._v2Ver == ver and pile.cells then return end

    local byKey, cells = {}, {}
    for i = 1, #(pile.foods or {}) do
        local rec = pile.foods[i]
        local k = v2Key(rec)
        local c = byKey[k]
        if not c then
            -- orders 表按格子 key 存在堆上，格子重建时沿用同一张表
            pile.cellOrders = pile.cellOrders or {}
            local o = pile.cellOrders[k]
            if not o then o = {}; pile.cellOrders[k] = o end
            c = { key = k, x = math.floor(rec.x or 0), y = math.floor(rec.y or 0),
                  z = math.floor(rec.z or 0), pile = pile, recs = {}, orders = o }
            byKey[k] = c
            cells[#cells + 1] = c
        end
        c.recs[#c.recs + 1] = rec
        rec._cell = c
    end

    -- 环序：不用 table.sort（Kahlua 没有）
    local rings, maxRing = {}, 0
    for i = 1, #cells do
        local c = cells[i]
        local d = math.max(math.abs(c.x - pile.x), math.abs(c.y - pile.y))
        c.ring = d
        if d > maxRing then maxRing = d end
        rings[d] = rings[d] or {}
        local rr = rings[d]
        rr[#rr + 1] = c
    end

    local ordered = {}
    for r = 0, maxRing do
        local rr = rings[r]
        if rr then
            for i = 1, #rr do ordered[#ordered + 1] = rr[i] end
        end
    end

    pile.cells = ordered
    pile.cellByKey = byKey
    pile._v2Ver = ver

    -- 重建后：格子没了（最后一具尸体被吃空/移除），它上面的订单必须释放。
    -- 否则 cellOrders[key] 变成孤儿表，订单没人维护 → 丧尸挂着单呆立，餐位也不还。
    if pile.cellOrders then
        for key, o in pairs(pile.cellOrders) do
            if not byKey[key] then
                local zs = {}
                for z in pairs(o) do zs[#zs + 1] = z end
                for k = 1, #zs do
                    local z = zs[k]
                    local ord = o[z]
                    if ord and HZ._orders and HZ._orders[z] == ord then
                        HZ.releaseOrder(z, ord, false)
                    else
                        o[z] = nil
                    end
                end
                pile.cellOrders[key] = nil
            end
        end
    end
end

-- 重建调度序列：所有堆的格子首尾相接 → 格子多的堆自然占更多格位（时间片加权）
function HZ.v2Cycle()
    -- 尸体增减是事件驱动的（OnDeadBodySpawn / 骨化 / 移除），格子表本身又按
    -- _foodsVer 缓存，所以这层不需要 2 秒轮询：跟快照同频（4 秒）就够。
    -- 真正要求 2 秒的是：tickPiles（发声/维护）和 v2Tick（派单/导航/进食）。
    local cycleMs = (HZ.snapIntervalMs and HZ.snapIntervalMs()) or 4000
    if not HZ.due("v2cycle", cycleMs) then return end

    local sched = {}
    local piles = HZ.piles or {}
    for i = 1, #piles do
        local pile = piles[i]
        if not pile.dead then
            v2BuildCells(pile)
            HZ.v2PruneCells(pile)
            local cells = pile.cells or {}
            for j = 1, #cells do sched[#sched + 1] = cells[j] end
        end
    end

    V2.sched = sched
    V2.pos = 0
    V2.slot = 0

    -- 可接单队列：输入只有「快照位置 + 堆的餐位」，快照 4 秒才换一次，
    -- 所以没必要时隔 2 秒重建两遍 —— 跟快照同频，省一半扫描。
    local snap = HZ._snap
    for i = 1, #piles do
        local pile = piles[i]
        pile.cand, pile.candSet = {}, {}
        local seats = 0
        local cells = pile.cells or {}
        for j = 1, #cells do
            local c = cells[j]
            -- 自愈：清掉「已经不在 HZ._orders 里」的僵尸订单条目。
            -- 不清理的话这些幽灵占着餐位 → seats=0 → cand 永远为空 → 再也不派单
            for z, o in pairs(c.orders) do
                if not (HZ._orders and HZ._orders[z] == o) then c.orders[z] = nil end
            end
            local n = 0
            for _ in pairs(c.orders) do n = n + 1 end
            seats = seats + math.max(0, v2MaxEaters() - n)
        end
        pile.openSeats = seats

        -- rec.orders 改成「格子订单表的投影」：每轮重算，不再靠增减维护。
        -- 之前 rec 与 cell 各记一份账，任何一条路径漏改一边就会漂（曾出现一格 5 单）。
        for k = 1, #cells do
            local recs = cells[k].recs
            for i = 1, #recs do recs[i].orders = 0 end
        end
        for k = 1, #cells do
            for _, o in pairs(cells[k].orders) do
                local r = o and o.rec
                if r then r.orders = (r.orders or 0) + 1 end
            end
        end

        -- Debug：对账 rec.orders 与格子订单表。两者必须相等，
        -- 不等说明某次派出/释放只更新了一边（名额会漂）。
        if HZ.debugEnabled and HZ.debugEnabled() and HZ.due("seatChk" .. tostring(pile.pid), 10000) then
            local recSum = 0
            for k = 1, #(pile.foods or {}) do recSum = recSum + (pile.foods[k].orders or 0) end
            local cellSum = 0
            for k = 1, #cells do for _ in pairs(cells[k].orders) do cellSum = cellSum + 1 end end
            if recSum ~= cellSum then
                HZ.log(string.format("seat drift pile=(%d,%d) rec=%d cell=%d orders=%d seats=%d",
                    math.floor(pile.x or 0), math.floor(pile.y or 0), recSum, cellSum, #(pile.foods or {}), seats))
            end
        end
    end

    if not snap then return end

    -- 诊断：每 5 秒一行，看订单/可接单/到位/在吃的数量
    if HZ.debugEnabled and HZ.debugEnabled() and HZ.due("v2dbg", 5000) then
        local cells, nOrder, nCand, nNear, nEat = 0, 0, 0, 0, 0
        for i = 1, #piles do
            local pl = piles[i]
            cells = cells + #(pl.cells or {})
            nCand = nCand + #(pl.cand or {})
        end
        local dmin, dmax, nWait, nGoal = 1e9, 0, 0, 0
        for z, ord in pairs(HZ._orders or {}) do
            nOrder = nOrder + 1
            if ord.eating then nEat = nEat + 1 end
            local okD, d = HZ.try("dbgDist2", function() return z:DistTo(ord.body) end)
            if okD and d then
                dmin = math.min(dmin, d)
                dmax = math.max(dmax, d)
                if d <= 1.0 then nNear = nNear + 1 end
                if d <= 2.7 then nWait = nWait + 1 end
            end
            local onTgt = false
            HZ.try("dbgGoal", function()
                local pf = z:getPathFindBehavior2()
                if pf and not pf:isGoalNone() then
                    onTgt = (pf:isTargetLocation(ord.body:getX(), ord.body:getY(), ord.body:getZ()) == true)
                end
            end)
            if onTgt then nGoal = nGoal + 1 end
        end
        local navAtt, navOk = HZ._navAtt or 0, HZ._navOk or 0
        local tickCnt, retCnt = HZ._tickCnt or 0, HZ._retCnt or 0
        local nb, nc, bo, ns = HZ._cNoBody or 0, HZ._cNoCorpse or 0, HZ._cBone or 0, HZ._cNoSq or 0
        HZ._navAtt, HZ._navOk, HZ._tickCnt, HZ._retCnt = 0, 0, 0, 0
        HZ._cNoBody, HZ._cNoCorpse, HZ._cBone, HZ._cNoSq, HZ._cRecGone = 0, 0, 0, 0, 0
        HZ._cNoRec, HZ._cNoCand, HZ._cNoPile, HZ._cOutR, HZ._cOdd = 0, 0, 0, 0, 0
        local sn = (HZ._snap and HZ._snap.n) or 0
        local cz, co, cb = HZ._candZ or 0, HZ._candSkipOrd or 0, HZ._candBest or 0
        local seats = 0
        for i = 1, #piles do seats = seats + (piles[i].openSeats or 0) end
        -- 每堆一行简表：坐标 / 室内 / 空餐位 / 可接单 / 格子数
        local pl = {}
        for i = 1, #piles do
            local p = piles[i]
            local seats = p.openSeats or 0
            pl[#pl + 1] = string.format("%d:%d in=%s seats=%d cand=%d cells=%d R=%s src=(%s,%s)",
                math.floor(p.x or 0), math.floor(p.y or 0),
                tostring(p.indoor == true), seats, #(p.cand or {}), #(p.cells or {}),
                tostring(p.lastRadius), tostring(p.sourceX), tostring(p.sourceY))
        end
        if #pl > 0 then HZ.log("piles " .. table.concat(pl, " | ")) end

        HZ.log(string.format("v2: snap=%d seats=%d candZ=%d skipOrd=%d got=%d piles=%d cells=%d orders=%d cand=%d near=%d wait=%d eating=%d onGoal=%d nav=%d/%d tick=%d ret=%d bad[noBody=%d noCorpse=%d recGone=%d bone=%d noSq=%d noRec=%d noCand=%d noPile=%d outR=%d odd=%d] d=[%.1f..%.1f]",
            sn, seats, cz, co, cb, #piles, cells, nOrder, nCand, nNear, nWait, nEat, nGoal, navAtt, navOk, tickCnt, retCnt, nb, nc, (HZ._cRecGone or 0), bo, ns, (HZ._cNoRec or 0), (HZ._cNoCand or 0), (HZ._cNoPile or 0), (HZ._cOutR or 0), (HZ._cOdd or 0),
            dmin > 1e8 and -1 or dmin, dmax))
    end

    HZ._candZ, HZ._candSkipOrd, HZ._candBest = 0, 0, 0
    for i = 1, snap.n do
        local z = snap.obj[i]
        if z then HZ._candZ = HZ._candZ + 1 end
        if z and (HZ._orders and HZ._orders[z]) then HZ._candSkipOrd = HZ._candSkipOrd + 1 end
        local lureUntil = HZ._lureUntil and HZ._lureUntil[z]
        if lureUntil and lureUntil < getTimestampMs() then
            HZ._lureUntil[z] = nil
            lureUntil = nil
        end
        if z and not lureUntil and not (HZ._orders and HZ._orders[z]) then
            local x, y = snap.x[i], snap.y[i]
            local best, bestD = nil, nil
            for k = 1, #piles do
                local pile = piles[k]
                if (not pile.dead) and (pile.openSeats or 0) > 0 then
                    local mx, my = pile.sourceX or pile.x, pile.sourceY or pile.y
                    -- 还没开始腐烂的堆不发声（hasScent=false），只招身边 8 格内的丧尸
                    local R
                    if not pile.hasScent then      -- 还没开始腐烂（字段为 nil/false）
                        R = 8
                    else
                        R = tonumber(pile.lastRadius) or tonumber(HZ.opt.RadiusMin) or 60
                    end
                    local dx, dy = x - mx, y - my
                    local d = dx * dx + dy * dy
                    if d <= R * R and (not bestD or d < bestD) then best, bestD = pile, d end
                end
            end
            if not best and HZ.debugEnabled and HZ.debugEnabled() then
                -- 诊断分支：会再扫一遍所有堆，只在 DebugMode 下跑
                -- （之前没加门，等于每个没找到堆的丧尸都要多扫一遍，白烧 CPU）
                local anySeat, anyRange = false, false
                for k = 1, #piles do
                    local pp = piles[k]
                    if (not pp.dead) and (pp.openSeats or 0) > 0 then
                        anySeat = true
                        local mx, my = pp.sourceX or pp.x, pp.sourceY or pp.y
                        local R = (not pp.hasScent) and 8
                            or (tonumber(pp.lastRadius) or tonumber(HZ.opt.RadiusMin) or 60)
                        local dx, dy = x - mx, y - my
                        if dx * dx + dy * dy <= R * R then anyRange = true break end
                    end
                end
                if not anySeat then
                    HZ._cNoPile = (HZ._cNoPile or 0) + 1
                elseif not anyRange then
                    HZ._cOutR = (HZ._cOutR or 0) + 1
                else
                    HZ._cOdd = (HZ._cOdd or 0) + 1     -- 有座位也在半径内却没进候选
                end
            end
            if best then
                HZ._candBest = (HZ._candBest or 0) + 1
                best.cand[#best.cand + 1] = { z = z, x = x, y = y }
                best.candSet[z] = true
            end
        end
    end
end

-- 一格的行动：先维护订单，再派单（第一具尸体独享全部餐位）
local function v2CellTurn(cell, now)
    local pile = cell.pile
    if not pile or pile.dead then return end

    -- 骨化 / 移除：rec 已经不在堆的 foods 里 → 摘掉；obj 骨化 → 摘掉
    -- 拿不到对象（未加载）→ 保留，本轮跳过
    for i = #cell.recs, 1, -1 do
        local rec = cell.recs[i]
        local drop = false
        if not foodSet(pile, rec) then
            drop = true
        else
            local b = rec.body
            if not b then
                b = (HZ.findBody and HZ.findBody(rec)) or nil
                rec.body = b
            end
            if b and HZ.isBone and HZ.isBone(b) then drop = true end
        end
        -- 必须 table.remove：直接置 nil 会在数组里留洞，#cell.recs 之后就不可靠了
        if drop then table.remove(cell.recs, i) end
    end

    -- 维护本格订单：沿用旧的 navOne
    local tickFn = HZ.tickOrder
    if tickFn then
        local keys = {}
        for z in pairs(cell.orders) do keys[#keys + 1] = z end
        for i = 1, #keys do
            local z = keys[i]
            local ord = cell.orders[z]
            if z and ord and HZ._orders[z] == ord then
                local ok, err = pcall(tickFn, z, ord, now)
                if not ok then
                    if HZ.debugEnabled and HZ.debugEnabled() and HZ.due("tickErrDbg", 3000) then
                        HZ.log("tickOrder err: " .. tostring(err))
                    end
                    if HZ._orders then HZ._orders[z] = nil end
                end
            end
        end
    end

    -- 派单
    local free = v2MaxEaters()
    for _ in pairs(cell.orders) do free = free - 1 end
    if free <= 0 then return end

    -- 配额：本堆还有几个格子没坐满、还有几个没单的丧尸。
    -- 不配额的话，环序靠前的格子会把附近丧尸一次抢光，后面的格子一具都分不到。
    local pending, freeZ = 0, 0
    do
        local cs = pile.cells or {}
        for i = 1, #cs do
            local c = cs[i]
            local n = 0
            for _ in pairs(c.orders) do n = n + 1 end
            if #c.recs > 0 and n < v2MaxEaters() then pending = pending + 1 end
        end
        local cd = pile.cand or {}
        for i = 1, #cd do
            local e = cd[i]
            if e and e.z and not (HZ._orders and HZ._orders[e.z]) then freeZ = freeZ + 1 end
        end
        if pending > 1 and freeZ > 0 then
            local quota = math.ceil(freeZ / pending)
            if quota < 1 then quota = 1 end
            if free > quota then free = quota end
        end
    end

    -- 自然顺序：第一具吃完/骨化才轮到下一具；未加载的跳过本轮
    local rec, body
    for i = 1, #cell.recs do
        local r = cell.recs[i]
        if r and r.body then rec, body = r, r.body; break end
    end
    if not rec then
        HZ._cNoRec = (HZ._cNoRec or 0) + 1      -- 格子里有 rec，但没有一个能解析出 body
        return
    end

    local cand = pile.cand
    if not cand or #cand == 0 then
        HZ._cNoCand = (HZ._cNoCand or 0) + 1    -- 有餐位、有尸体，但本堆没有可接单丧尸
        return
    end

    local cx, cy = body:getX(), body:getY()

    -- 一次扫描挑出最近的 free 只（free 最多 MaxEaters，通常 4）。
    -- 旧写法是「每挑一只 → 全表扫一遍 → table.remove 移位」，候选表几百只时
    -- 等于 4×N 次比较 + 4 次 O(N) 移位，这就是接单时那点可感知的 CPU。
    local picks, pickN = {}, 0
    for i = 1, #cand do
        local e = cand[i]
        if e and e.z and not (HZ._orders and HZ._orders[e.z]) then
            local dx, dy = e.x - cx, e.y - cy
            local d = dx * dx + dy * dy
            local pos = pickN + 1
            for k = 1, pickN do
                if d < picks[k].d then pos = k break end
            end
            if pos <= free then
                table.insert(picks, pos, { e = e, d = d })
                if #picks > free then table.remove(picks) end
                pickN = #picks
            end
        end
    end
    if pickN == 0 then return end

    -- 挑中的从候选表里摘掉：一次压缩，不再逐只 table.remove
    local used = {}
    for k = 1, pickN do used[picks[k].e] = true end
    local kept = {}
    for i = 1, #cand do
        local e = cand[i]
        if e and not used[e] then kept[#kept + 1] = e end
    end
    cand = kept
    pile.cand = kept
    for k = 1, pickN do
        local e = picks[k].e
        if pile.candSet then pile.candSet[e.z] = nil end
    end

    for k = 1, pickN do
        local e = picks[k].e
        local z = e.z
        if free <= 0 then break end

        -- 正在翻窗/翻栅栏的先不派，免得派单时的 setDefaultState 打断它
        local busy = busyState(z)
        if busy then
            -- 放回候选表末尾，下一轮再考虑
            cand[#cand + 1] = { z = z, x = e.x, y = e.y }
            if pile.candSet then pile.candSet[z] = true end
        else
        local ord = {
            pile = pile, rec = rec, body = body, uid = rec.uid, cell = cell,
        }
        HZ._orders = HZ._orders or {}
        HZ._orders[z] = ord
        pile.orders = pile.orders or {}
        pile.orders[z] = ord
        cell.orders[z] = ord
        rec.orders = (rec.orders or 0) + 1

        -- 引擎可能已经自己挂上了别的尸体（原版 AI 会自动找脚边尸体吃）。
        -- 不清掉的话，我们的订单指向 A，它却在 B 那里吃 / 往 B 走，距离越走越大。
        if HZ.clearEat then HZ.try("v2clearEat", function() HZ.clearEat(z) end) end
        ord.faceNext = true                 -- 到位后朝尸体转一次身
        -- clearEat 内部已经 setDefaultState 过一次，这里不再重复调用（每次都是 JNI）
        if HZ_clearTarget then pcall(HZ_clearTarget, z) end
        HZ.refreshBuffs(z)

        free = free - 1
        pile.openSeats = math.max(0, (pile.openSeats or 0) - 1)
        end
    end
end

-- 2 秒内轮完一圈：每 250ms 处理 ceil(总数/8) 个格子
function HZ.v2Tick()
    local sched = V2.sched
    local n = sched and #sched or 0
    if n == 0 then return end

    -- 2 秒一圈；格子少于 8 个时减少槽位，否则同一格一圈会被轮到多次
    local SLOTS = math.min(8, n)
    if not HZ.due("v2cell", 2000 / SLOTS) then return end

    V2.slot = ((V2.slot or 0) % SLOTS) + 1
    local chunk = math.ceil(n / SLOTS)
    local now = getTimestampMs()
    local start = V2.pos or 0

    for k = 0, chunk - 1 do
        local i = (start + k) % n + 1
        local cell = sched[i]
        if cell and cell.pile then v2CellTurn(cell, now) end
    end
    V2.pos = (start + chunk) % n
end


-- 换格：在本堆里找另一个还有空位、且首尸可用的格子
function HZ.v2PickOther(pile, curCell, z)
    local cells = pile and pile.cells
    if not cells then return nil end
    for i = 1, #cells do
        local c = cells[i]
        if c ~= curCell then
            local n = 0
            for _ in pairs(c.orders) do n = n + 1 end
            if n < v2MaxEaters() then
                for j = 1, #c.recs do
                    local rec = c.recs[j]
                    local b = rec and (rec.body or (HZ.findBody and HZ.findBody(rec)) or nil)
                    rec.body = b
                    if rec and b and not (HZ.isBone and HZ.isBone(b)) then
                        rec.body = b
                        return b, rec, c
                    end
                end
            end
        end
    end
    return nil
end


-- ============================================================================
-- 续单：单一状态机（替代 navOne 的 17 条路径）
--   行军 / 等位 / 到位 三段；一个 stillMs 计时器替代 osc / stuckNow / targetMiss / waitAt
-- ============================================================================
local EAT_R      = 1.0     -- 到位
local WAIT_R     = 2.7     -- 等位区
local MOVE_EPS   = 0.3     -- 位移小于它 = 没动
local NAV_RETRY  = 2000    -- 没动 2s → 重下导航
local GIVEUP_MS  = 4000    -- 没动 4s → 换目标 / 释放

-- 到位：确认 → 重发 → 置位
local function eatTick(z, ord, now)
    if HZ.statsSatiated and HZ.statsSatiated(z) then
        HZ.releaseOrder(z, ord, false)
        return
    end

    -- === 与 0.3.0 完全一致的进食判定，不要自创 ===
    local et = nil
    HZ.try("tickEatTgt", function() et = z:getEatBodyTarget() end)
    local onTarget = (et ~= nil and et == ord.body)

    if not onTarget then
        -- 没挂上/挂到别的尸体：每秒重发一次，直到引擎接受。
        if busyState(z) then return end        -- 翻窗/倒地时不发进食指令
        if (now - (ord.lastEatCmd or 0)) > 1000 then
            HZ.try("tickEat", function()
                z:setDefaultState()
                z:setEatBodyTarget(ord.body, true)   -- force：绕 3 人上限
                z:setForceEatingAnimation(true)
            end)
            ord.lastEatCmd = now
        end

        if ord.eating then
            ord.eating = false
            if HZ.statsEatStop then HZ.statsEatStop(z) end
        end

        -- 引擎就是不接这个进食目标：记下来，连续失败 → 换尸体/换格。
        -- 没有这一段的话，eatTick 会一秒一次永远重发，丧尸站在尸体上不吃也不换。
        ord.eatFails = (ord.eatFails or 0) + 1
        if ord.eatFails == 1 then
            local back = nil
            HZ.try("eatBack", function() back = z:getEatBodyTarget() end)
            if back == nil and HZ.debugEnabled and HZ.debugEnabled() then
                local px, py, bx, by = -1, -1, -1, -1
                HZ.try("eatPos", function() px, py = z:getX(), z:getY(); bx, by = ord.body:getX(), ord.body:getY() end)
                HZ.log(string.format("eat reject uid=%s z=(%.1f,%.1f) body=(%.1f,%.1f) fails=%d",
                    tostring(ord.uid), px, py, bx, by, ord.eatFails))
            end
        end
        if ord.eatFails >= 6 then
            ord.eatFails = 0
            retargetOrRelease(z, ord, now)
            return
        end
        return
    end

    if not ord.eating then
        ord.eating = true
        if HZ.statsEatStart then HZ.statsEatStart(z) end
    end
end

-- 换目标：脚下 → 本格 → 本堆其他格 → 释放
local function retargetOrRelease(z, ord, now)
    HZ._retCnt = (HZ._retCnt or 0) + 1
    local pile, cell = ord.pile, ord.cell
    local nb, nrec, ncell

    if footBodyAt then nb = footBodyAt(z, pile) end

    if not nb and cell then
        for i = 1, #cell.recs do
            local rec = cell.recs[i]
            if rec and rec ~= ord.rec then
                local b = rec.body or (HZ.findBody and HZ.findBody(rec)) or nil
                rec.body = b
                if b and not (HZ.isBone and HZ.isBone(b)) then nb, nrec, ncell = b, rec, cell; break end
            end
        end
    end

    if not nb and HZ.v2PickOther and cell then
        nb, nrec, ncell = HZ.v2PickOther(pile, cell, z)
    end

    if not nb then
        HZ.releaseOrder(z, ord, false)
        return
    end

    -- 餐位迁移（成对）
    if ncell and ncell ~= cell then
        if cell and cell.orders then cell.orders[z] = nil end
        ncell.orders[z] = ord
        ord.cell = ncell
    end
    if ord.rec and nrec and ord.rec ~= nrec then
        ord.rec.orders = math.max(0, (ord.rec.orders or 0) - 1)
        nrec.orders = (nrec.orders or 0) + 1
    end

    if ord.eating then
        ord.eating = false
        if HZ.statsEatStop then HZ.statsEatStop(z) end
    end

    ord.body, ord.rec = nb, nrec
    ord.faceNext = true                     -- 换目标后同样转一次
    ord.navX, ord.navY, ord.navBody = nil, nil, nil
    ord.stillMs, ord.t = 0, now
    ord.lastEatCmd = 0
    HZ.try("retargetClear2", function() HZ.clearEat(z) end)
end

-- ===================== 续单主函数 =====================
function HZ.tickOrder(z, ord, now)
    HZ._tickCnt = (HZ._tickCnt or 0) + 1
    if not z or not ord then return end

    -- ① 校验：死了 / 堆没了 / 目标尸体不可用
    -- 一次跨桥同时拿到三件事：丧尸已死 / 挂着进食目标 / 尸体还在。
    -- 旧写法在上面调一次 HZ_orderState、下面 orderFlags 里又调一次，等于每拍两次 JNI。
    local dead, hasTgt, bodyAlive = orderFlags(z, ord.body)
    if dead or not ord.pile or ord.pile.dead then
        -- 和 releaseOrder 的数据语义一致（0.3.0 也是走 releaseOrder）：
        -- 尸体名额 -1、三张表摘干净。区别是不对可能已销毁的对象调引擎方法。
        if ord.rec then ord.rec.orders = math.max(0, (ord.rec.orders or 0) - 1) end
        if HZ._orders then HZ._orders[z] = nil end
        if ord.pile and ord.pile.orders then ord.pile.orders[z] = nil end
        if ord.cell and ord.cell.orders then ord.cell.orders[z] = nil end
        HZ.try("tickClearBuff", function() HZ.refreshBuffs(z) end)
        return
    end

    -- 尸体是否还在：用桥的 orderFlags（bit3 = body 存在且没骨化），和 0.3.0 的 navOne 一致。
    -- 不要拿 HZ.corpses 当判据 —— 那张表在 0.3.0 里根本没有维护者，永远是空表。
    -- 尸体是否还能吃：桥的 bodyAlive（有 square、没骨化）**并且**这条记录还在堆的清单里。
    -- 只判 bodyAlive 会漏掉"已经被吃完/骨化替换、但对象还在"的情况 ——
    -- 那样丧尸会对着幻影继续吃，同一格里的下一具永远轮不到（不续单）。
    local bodyOk = false
    if not ord.body then
        HZ._cNoBody = (HZ._cNoBody or 0) + 1
    else
        local recOk = true
        if ord.rec and recByUid and ord.pile then
            recOk = (recByUid(ord.pile, ord.rec.uid) ~= nil)
        end
        if bodyAlive and recOk then
            bodyOk = true
        elseif not recOk then
            HZ._cRecGone = (HZ._cRecGone or 0) + 1
        else
            HZ._cNoCorpse = (HZ._cNoCorpse or 0) + 1
        end
    end
    if not bodyOk then
        retargetOrRelease(z, ord, now)      -- 目标没了
        return
    end

    -- 翻窗/翻栅栏过程中一个字都别碰：setDefaultState 会打断 Climb 状态，
    -- 有概率把丧尸卡在窗上（引擎的 climbing 标记没复位）。
    local climbing = false
    HZ.try("isClimbing", function() climbing = (z:isClimbing() == true) end)
    if climbing then
        -- 正常翻越 1~2 拍就结束；连续 3 拍还在翻 = 卡住了（引擎的 climbing 标记没复位）
        ord.climbMs = (ord.climbMs or 0) + 1
        if ord.climbMs >= 3 then
            ord.climbMs = 0
            HZ._cClimbStuck = (HZ._cClimbStuck or 0) + 1
            HZ.try("climbReset", function() z:setDefaultState() end)
        end
        return
    end
    ord.climbMs = nil

    -- 转向：0.3.0 在这里消费（只要有目标就转一次），不是等到开吃
    if ord.faceNext then
        ord.faceNext = false
        HZ.try("faceOnce", function() z:faceLocationF(ord.body:getX(), ord.body:getY()) end)
    end

    -- ② 距离
    local okD, d = HZ.try("tickDist", function() return z:DistTo(ord.body) end)
    if not okD or not d then d = 1e9 end

    -- 远单观测：d 特别大的订单，10 秒一条，确认是在接近还是在远离
    if HZ.debugEnabled and HZ.debugEnabled() and d and d > 15 and HZ.due("farOrd" .. tostring(HZ.uidOf and HZ.uidOf(z) or z), 10000) then
        local px, py, bx, by, bz = -1, -1, -1, -1, -1
        local tx, ty, tz, goalNone = -1, -1, -1, "?"
        HZ.try("farPos", function()
            px, py = z:getX(), z:getY()
            bx, by, bz = ord.body:getX(), ord.body:getY(), ord.body:getZ()
        end)
        HZ.try("farGoal", function()
            local pf = z:getPathFindBehavior2()
            goalNone = tostring(pf:isGoalNone())
            tx, ty, tz = pf:getTargetX(), pf:getTargetY(), pf:getTargetZ()
        end)
        HZ.log(string.format("far order uid=%s d=%.1f z=(%.1f,%.1f) body=(%.1f,%.1f,%.3f) engTgt=(%.1f,%.1f,%.3f) none=%s",
            tostring(ord.uid), d, px, py, bx, by, bz, tx, ty, tz, goalNone))
    end

    -- ③ 位移
    local x, y
    local okP = HZ.try("tickPos", function() x, y = z:getX(), z:getY() end)
    local moved = false
    if okP and x then
        if ord.lastX then
            moved = (math.abs(x - ord.lastX) + math.abs(y - ord.lastY)) >= MOVE_EPS
        end
        ord.lastX, ord.lastY = x, y
    end
    local dt = now - (ord.t or now)
    if dt < 0 or dt > 5000 then dt = 0 end
    ord.t = now
    if moved then ord.stillMs = 0 else ord.stillMs = (ord.stillMs or 0) + dt end

    -- 站桩观测：没在吃、站着超过 5 秒的订单，10 秒打一条（含引擎进食目标）
    if HZ.debugEnabled and HZ.debugEnabled()
        and (not ord.eating) and (ord.stillMs or 0) > 5000
        and HZ.due("stuck" .. tostring(HZ.uidOf and HZ.uidOf(z) or z), 10000) then
        local et, px, py, bx, by = nil, -1, -1, -1, -1
        local gx, gy, gnone = -1, -1, "?"
        HZ.try("stuckInfo", function()
            et = z:getEatBodyTarget()
            px, py = z:getX(), z:getY()
            bx, by = ord.body:getX(), ord.body:getY()
            local pf = z:getPathFindBehavior2()
            gnone = tostring(pf:isGoalNone())
            gx, gy = pf:getTargetX(), pf:getTargetY()
        end)
        HZ.log(string.format("stuck uid=%s d=%.1f still=%dms fails=%d et=%s z=(%.1f,%.1f) body=(%.1f,%.1f) goal=(%.1f,%.1f) none=%s",
            tostring(ord.uid), d, math.floor(ord.stillMs or 0), ord.eatFails or 0,
            tostring(et), px, py, bx, by, gx, gy, gnone))
    end

    -- ④ 距离 > 1.0：要么在赶路，要么在桌边等位 —— 两种情况都要保证导航活着。
    -- 旧代码就是这么做的（near 为假就走导航分支），我之前把 1.0~2.7 单独劈成
    -- “等位区”且不发导航，结果丧尸卡在 1.5~2.2 格原地不动。
    if d > EAT_R then
        if ord.eating then
            if d <= EAT_R + 0.2 then
                eatTick(z, ord, now)      -- 1.0~1.2 继续吃（keepD）
                return
            end
            -- 真的离桌：结算 + 清进食状态
            ord.eating = false
            if HZ.statsEatStop then HZ.statsEatStop(z) end
            if not busyState(z) then
                HZ.try("leaveFar", function() HZ.clearEat(z) end)
            end
        end

        -- 引擎当前目标是不是我们给的那具尸体
        -- 用 0.75 格容差和引擎目标比。isTargetLocation 是浮点全等（fcmpl），
        -- 只要引擎内部对 target 做过任何取整/修正就会判 false，进而每拍重下发。
        -- 容差比较不改变“目标一致”的语义，只去掉这种脆弱的全等依赖。
        local onTarget = false
        local bx, by, bz = ord.body:getX(), ord.body:getY(), ord.body:getZ()
        local tx, ty = nil, nil
        HZ.try("tickGoal", function()
            local pf = z:getPathFindBehavior2()
            if pf and not pf:isGoalNone() then
                tx, ty = pf:getTargetX(), pf:getTargetY()
            end
        end)
        -- 判"目标有没有用"，而不是"目标是不是正好等于尸体坐标"。
        -- 引擎会把 target 改写成路径最后一个节点（绕路/部分路径时并不在尸体上），
        -- 用严格相等会导致每 2 秒判一次"目标不对"→ 踢状态 → 肉眼看到每 4 秒卡一下。
        -- 只要目标比它现在离尸体更近，就认为它在正常赶路，别碰它。
        if tx and ty then
            local gdx, gdy = tx - bx, ty - by
            local goalToBody = math.sqrt(gdx * gdx + gdy * gdy)
            local selfToBody = d or 1e9
            onTarget = (goalToBody < 1.0) or (goalToBody < selfToBody - 1.0)
        end

        -- 被玩家/声音拉走：寻路目标不是尸体，而且距离还在变大。
        -- 这种状态下怎么重下发都没用（引擎会重新追目标），订单必须放掉，
        -- 否则餐位被一个正在追玩家的丧尸永久占着。
        local goalIsBody = onTarget
        if (not goalIsBody) and ord.lastD and d > ord.lastD then
            ord.lureN = (ord.lureN or 0) + 1
        else
            ord.lureN = 0
        end
        if (ord.lureN or 0) >= 4 then          -- 连续 4 拍（约 8 秒）都在变远
            HZ._cLured = (HZ._cLured or 0) + 1
            HZ.releaseOrder(z, ord, false)
            -- 它还在堆的半径内，不放冷却的话下一轮立刻又被派回来（追人→释放→再派），
            -- 白白占着餐位还每 12 秒重复一遍。给 30 秒冷静期。
            HZ._lureUntil = HZ._lureUntil or {}
            HZ._lureUntil[z] = getTimestampMs() + 30000
            return
        end

        -- 目标对、但距离在变大：被追击目标接管了，抢回控制
        if onTarget and ord.lastD and d > ord.lastD + 1.0 then
            onTarget = false
            HZ._cFarAway = (HZ._cFarAway or 0) + 1
        end
        ord.lastD = d

        -- 引擎把目标设成了自己脚下（寻路不可达时会这样）→ 记一次失败
        local selfGoal = false
        if tx and ty and x and y then
            selfGoal = (math.abs(tx - x) < 0.75 and math.abs(ty - y) < 0.75)
        end
        if selfGoal and d > WAIT_R then
            local psz = -1
            HZ.try("pathSize", function()
                local pth = z:getPath2()
                if pth then psz = pth:size() end
            end)
            if (ord.navFail or 0) == 0 and HZ.debugEnabled and HZ.debugEnabled() then
                HZ.log(string.format("selfGoal uid=%s d=%.1f pathSize=%d",
                    tostring(ord.uid), d, psz))
            end
            ord.navFail = (ord.navFail or 0) + 1
            if ord.navFail >= 3 then
                ord.navFail = 0
                HZ._cNoPath = (HZ._cNoPath or 0) + 1
                retargetOrRelease(z, ord, now)     -- 这条路走不通，换尸体
                return
            end
        else
            ord.navFail = 0
        end

        if not onTarget then
            if busyState(z) then return end     -- 翻窗/倒地/砸门中：不要踢状态
            -- 频率天然就是 2 秒一次（每个格子每圈轮到一次，订单跟着格子走），
            -- 不需要再叠一层节流。
            -- IsoZombie.pathToLocationF 的字节码：
            --   if (allowRepathDelay > 0 && (当前是 PathFindState/WalkTowardState/WalkTowardNetworkState)) return;
            -- 也就是说：正在走的时候再下发会被【直接丢弃】。
            -- 想纠正目标，必须先把状态踢出这三个，再下发，否则永远改不掉。
            HZ.try("navKick", function() z:setDefaultState() end)
            ord.navX, ord.navY, ord.navZ = bx, by, bz
            ord.navBody = ord.body
            ord.navAt = now
            HZ._navAtt = (HZ._navAtt or 0) + 1
            HZ.try("tickNav", function() z:pathToLocationF(bx, by, bz) end)

            local accepted = false
            HZ.try("tickNavChk", function()
                local pf = z:getPathFindBehavior2()
                if pf and not pf:isGoalNone() then
                    local atx, aty = pf:getTargetX(), pf:getTargetY()
                    accepted = (atx ~= nil and math.abs(atx - bx) < 0.75 and math.abs(aty - by) < 0.75)
                end
            end)
            if accepted then HZ._navOk = (HZ._navOk or 0) + 1 end
        end

        -- 放弃换目标：桌边等位给足 12 秒（挤不进去才换），路程上 4 秒不动就换
        local limit = (d <= WAIT_R) and 12000 or GIVEUP_MS
        if (ord.stillMs or 0) >= limit then
            retargetOrRelease(z, ord, now)
        end
        return
    end

    -- ⑥ 到位
    eatTick(z, ord, now)
end

-- 堆回收空格子（骨化后没有尸体了）
function HZ.v2PruneCells(pile)
    local cells = pile and pile.cells
    if not cells then return end
    for i = #cells, 1, -1 do
        local c = cells[i]
        if #c.recs == 0 then
            -- 格子没尸体了：它上面的订单必须先释放，否则格子从 pile.cells 消失后
            -- 这些订单再也没人维护 —— 丧尸挂着订单呆立、也不吃东西
            local zs = {}
            for z in pairs(c.orders) do zs[#zs + 1] = z end
            for k = 1, #zs do
                local z = zs[k]
                local o = c.orders[z]
                if o and HZ._orders and HZ._orders[z] == o then
                    HZ.releaseOrder(z, o, false)
                else
                    c.orders[z] = nil
                end
            end
        end

        if #c.recs == 0 and next(c.orders) == nil then
            table.remove(cells, i)
            if pile.cellByKey then pile.cellByKey[c.key] = nil end
            -- 订单表的 key 表也一起回收，否则重建时会一直累积空表
            if pile.cellOrders and next(pile.cellOrders[c.key] or {}) == nil then
                pile.cellOrders[c.key] = nil
            end
        end
    end
end
