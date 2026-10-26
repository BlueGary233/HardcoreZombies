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
function HZ.queueNext(pile, skip)
    local snap = HZ._snap
    if not snap or not pile or not pile.pid then return nil end
    for i = 1, snap.n do
        local z = snap.obj[i]
        if z and z ~= skip and HZ.pileOf(z) == pile.pid
           and not (HZ._orders and HZ._orders[z]) then
            return z
        end
    end
    return nil
end

-- 进队：写认领，重算 buff
function HZ.joinQueue(z, pile)
    -- v2：可接单队列改为纯数据视图，不再写认领/状态。
    -- 保留函数体为空，旧调用点（navOne 释放后回队等）自然失效。
    return
end

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

local function longBlockMs() return tonumber(HZ.opt.LongBlockMs) or 60000 end   -- 失败的那只多久内不再派给同一具尸体


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
local function otherRecInPile(pile, z, curRec)
    local nowMs = getTimestampMs()
    for i = 1, #pile.foods do
        local rec = pile.foods[i]
        if rec ~= curRec then
            local untilMs = rec.blocked and rec.blocked[z]
            if ((not untilMs) or nowMs >= untilMs)
               and (rec.orders or 0) < (HZ.opt.MaxEaters or 4) then
                local b = HZ.findBody and HZ.findBody(rec) or nil
                if b and not HZ.isBone(b) then return b, rec end
            end
        end
    end
    return nil, nil
end

-- 订单主循环：校验目标 → 换目标 → 吃饭 → 导航（每只每次一拍）
function HZ.navOne(z, ord, now)
    local pile = ord.pile
    if not pile then
        -- 脏订单（堆已被丢弃）：直接摘掉，别让它在 tickOneOrder 里反复报错
        if z and HZ._orders then HZ._orders[z] = nil end
        return
    end
    local body = ord.body
    local zDead, hasTgt, bodyAlive = false, false, false

    if (not z) or pile.dead then
        zDead = true
    else
        -- 一次 bridge 拿：丧尸死了 / hasEatTarget / bodyToEat / body.getSquare()
        zDead, hasTgt, bodyAlive = orderFlags(z, body)
        -- isBone 已在 orderFlags 内检查
    end

    -- 目标没了（nil / 骨化 / 被删）和丧尸自己死了是两件事：
    -- 前者换目标继续吃，后者才释放
    local bodyGone = (not zDead) and ((not body) or (not bodyAlive))

    if body and (not zDead) and (not bodyGone) and ord.faceNext then
        -- 设目标的下一次维护里转一次，之后不再改（避免每拍覆盖它自己的朝向）
        HZ.try("faceOnce", function() z:faceLocationF(body:getX(), body:getY()) end)
        ord.faceNext = false
    end

    if bodyGone and z then
        -- ① 先扫脚下这一格
        local nb, nrec = footBodyAt(z, pile)
        -- ② 脚下没有就换本堆的其他尸体
        if not nb then nb, nrec = otherRecInPile(pile, z, ord.rec) end

        if nb and nrec then
            if ord.rec then ord.rec.orders = math.max(0, (ord.rec.orders or 0) - 1) end
            nrec.orders = (nrec.orders or 0) + 1

            -- 换目标前结算已经吃的时长
            if ord.eating and HZ.statsEatStop then HZ.statsEatStop(z) end

            ord.body, ord.rec = nb, nrec
            ord.lastX, ord.lastY = nil, nil
            ord.navBody, ord.eating = nil, false

            HZ.try("retargetClear", function() HZ.clearEat(z) end)
            if HZ.debugEnabled() then
                HZ.log(string.format("retarget uid=%s -> rec=(%s,%s)",
                    tostring(ord.uid), tostring(nrec.x), tostring(nrec.y)))
            end
            return
        end
        -- ③ 本堆没得吃了：释放回队列（有尸体才回队，没尸体就放自由）
        if HZ.debugEnabled() then
            HZ.log(string.format("no-target uid=%s pile=(%d,%d) foods=%d",
                tostring(ord.uid), pile.x, pile.y, #pile.foods))
        end
        local p = ord.pile
        HZ.releaseOrder(z, ord, false)
        if p and not p.dead and #p.foods > 0
           and not HZ._orders[z] and HZ.pileOf(z) == 0 then
            HZ.joinQueue(z, p)
        end
        return
    end

    if zDead then
        -- 不碰 z（可能已销毁）：只用 uid 和尸体坐标
        if HZ.debugEnabled() then
            HZ.log(string.format("order dead uid=%s rec=(%s,%s) bodyAlive=%s pileDead=%s",
                tostring(ord.uid),
                tostring(ord.rec and ord.rec.x), tostring(ord.rec and ord.rec.y),
                tostring(bodyAlive), tostring(pile.dead)))
        end
        local p = ord.pile
        HZ.releaseOrder(z, ord, false)

        if p and not p.dead and not HZ._orders[z] and HZ.pileOf(z) == 0 then
            HZ.joinQueue(z, p)
        end
    else
        local okD, d = HZ.try("bodyDist", function() return z:DistTo(body) end)

        -- 到达判定写死 1 格；滑杆只允许调小，不能超过 1
        local eatD  = math.min(1.0, tonumber(HZ.opt.EatDistance) or 1.0)
        local keepD = eatD + 0.2          -- 只留 0.2 格迟滞，防止边界抖动
        local near  = okD and d and (ord.eating and d <= keepD or d <= eatD)

        -- 爬行不站起：爬到 1 格内直接趴着吃，订单释放时才恢复站立
        if near then
            -- 吃满 5 点：主动离开（不然会一直吃到尸体骨化）
            if HZ.statsSatiated and HZ.statsSatiated(z) then
                HZ.releaseOrder(z, ord, false)
                return
            end

            -- 引擎当前的进食目标是不是我们要的那具尸体
            local et = nil
            HZ.try("eatTarget", function() et = z:getEatBodyTarget() end)
            local onTarget = (et ~= nil and et == body)

            if not onTarget then
                -- 没挂上/挂到别的尸体：每秒重发一次，直到引擎真的接受。
                -- 不能只发一次：目标不是尸体时引擎会静默丢弃，之后永远不吃。
                if (now - (ord.arriveAt or 0)) > 1000 then
                    HZ.try("arrive", function()
                        z:setDefaultState()
                        z:setEatBodyTarget(body, true)   -- force：绕 3 人上限
                        z:setForceEatingAnimation(true)
                    end)
                    ord.arriveAt = now
                    ord.faceNext = true                  -- 下一次维护再转一次，之后不再改
                end

                -- 没挂上就不算在吃，避免饱食度按"到点时长"虚增
                if ord.eating then
                    if HZ.statsEatStop then HZ.statsEatStop(z) end
                    ord.eating = false
                end
                ord.osc, ord.targetMiss = nil, 0
                return
            end

            if not ord.eating then
                ord.eating = true
                if HZ.statsEatStart then HZ.statsEatStart(z) end   -- 真正吃上才开始计时
            end
            ord.osc, ord.targetMiss = nil, 0     -- 已经到餐桌：振荡窗口/偏离计数作废
        else
            if ord.eating then
                HZ.try("leaveTable", function()
                    HZ.clearEat(z)
                end)
                -- 退出吃饭：按时长结算饱食度
                if HZ.statsEatStop then HZ.statsEatStop(z) end
                ord.eating = false
            end

            -- 卡住判定必须排除「已到达」的三种情况：
            --   正在吃 / 离尸体 keepD+1.5 内（在等餐位）/ 引擎已给进食目标且就在附近
            local atTable = ord.eating
                or (d and d <= keepD + 1.5)
                or (hasTgt and d and d <= keepD + 4)

            if ord.stuckNow and not atTable then
                -- 卡住了：立刻换尸体，不要站在原地等派单
                -- ① 脚下有尸体就改吃它（目标就在嘴边，最快）
                local nb, nrec = footBodyAt(z, pile)
                -- ② 脚下没有就在本堆里另找一具能吃的，当场换过去
                if not nb then nb, nrec = otherRecInPile(pile, z, ord.rec) end

                if nb and nrec then
                    -- 餐位从旧尸体转移到新尸体
                    if ord.rec and ord.rec ~= nrec then
                        ord.rec.orders = math.max(0, (ord.rec.orders or 0) - 1)
                        -- 卡住的那具给自己一段长冷却，别下一拍又派回来
                        ord.rec.blocked = ord.rec.blocked or {}
                        ord.rec.blocked[z] = now + longBlockMs()
                    end
                    nrec.orders = (nrec.orders or 0) + 1

                    -- 换目标前先结算已吃的时长，否则走路时间被算成进食
                    if ord.eating and HZ.statsEatStop then HZ.statsEatStop(z) end

                    ord.body  = nb
                    ord.rec   = nrec
                    ord.lastX, ord.lastY = nil, nil   -- 强制下一次维护发新 path
                    ord.navBody, ord.osc, ord.stuckNow = nil, nil, false
                    ord.targetMiss, ord.eating = 0, false

                    HZ.try("retarget", function()
                        HZ.clearEat(z)
                    end)
                else
                    -- 整堆都没有能换的尸体：才回队等空位
                    HZ.releaseOrder(z, ord, true)   -- 餐位 -1，认领保留，回队列
                    if ord.rec then
                        ord.rec.blocked = ord.rec.blocked or {}
                        ord.rec.blocked[z] = now + longBlockMs()
                    end
                end
            else
                -- 导航 + 两拍判定：位移不足 0.3 = 卡住；目标不是我们给的目的地 = 被拉走
                local x, y = nil, nil
                HZ.try("getX", function() x, y = z:getX(), z:getY() end)

                local firstNav    = (ord.lastX == nil)
                local bodyChanged = (ord.navBody ~= body)
                if bodyChanged then ord.navBody = body end

                -- 已经在餐位边上等位，不算卡住
                local waiting = (d and d <= keepD + 1.5)

                -- 挤不进去：贴到餐桌 5 秒还没挂上进食目标（被别的丧尸堵住），
                -- 换到本堆另一格有空位的地方；换不到就释放，让它去别的堆
                -- 只对「真的贴在餐桌前（1.7 格内）」的算挤住；还在路上走的不算
                if waiting and not ord.eating and d and d <= (keepD + 0.5) then
                    ord.waitAt = ord.waitAt or now
                    if (now - ord.waitAt) > 5000 then
                        ord.waitAt = nil
                        local moved = false
                        if HZ.v2PickOther and ord.cell then
                            local nb, nrec, ncell = HZ.v2PickOther(pile, ord.cell, z)
                            if nb then
                                if ord.cell.orders then ord.cell.orders[z] = nil end
                                if ord.rec then ord.rec.orders = math.max(0, (ord.rec.orders or 0) - 1) end
                                nrec.orders = (nrec.orders or 0) + 1
                                ncell.orders[z] = ord
                                ord.body, ord.rec, ord.cell = nb, nrec, ncell
                                ord.navBody, ord.navX, ord.navY = nil, nil, nil
                                ord.eating = false
                                HZ.try("blockedRetarget", function() HZ.clearEat(z) end)
                                moved = true
                            end
                        end
                        if not moved then HZ.releaseOrder(z, ord, false) end
                        return
                    end
                else
                    ord.waitAt = nil
                end


                -- ② 目标：引擎当前的目标不是我们导航给的目的地 → 被玩家/声音拉走了
                --    连续两拍不一致 → 交还餐位，保留认领，跟丢后回来再派单
                local tx, ty = nil, nil
                HZ.try("pfTarget", function()
                    local pf = z:getPathFindBehavior2()
                    if pf then tx, ty = pf:getTargetX(), pf:getTargetY() end
                end)
                if not waiting and tx and ty and ord.navX then
                    if math.abs(tx - ord.navX) < 0.6 and math.abs(ty - ord.navY) < 0.6 then
                        ord.targetMiss = 0
                    else
                        ord.targetMiss = (ord.targetMiss or 0) + 1
                    end
                else
                    ord.targetMiss = 0
                end

                -- 目标偏离两拍：先重下导航（路径节点噪声会让 getTargetX 不等于终点，
                -- 直接释放会造成"派单→释放→再派单"的抖动，丧尸原地打转）
                -- 只有连续 8 拍（约 16 秒）都不对，才认定真被拉走、交还餐位
                if (ord.targetMiss or 0) >= 2 then
                    if HZ.debugEnabled() then
                        HZ.log(string.format("nav drift uid=%s n=%d nav=(%.1f,%.1f) target=(%.1f,%.1f) d=%.1f",
                            tostring(ord.uid), ord.targetMiss or 0, ord.navX or -1, ord.navY or -1,
                            tx or -1, ty or -1, d or -1))
                    end

                    -- 只要它还在往前走（位移 ≥ 0.3），这点偏差就是路径节点噪声，什么都不用做
                    local progressed = (x and ord.lastX
                        and (math.abs(x - ord.lastX) + math.abs(y - ord.lastY)) >= 0.3)

                    if progressed then
                        ord.targetMiss = 0
                        ord.lastX, ord.lastY = x, y
                        return
                    elseif (ord.targetMiss or 0) >= 8 then
                        HZ.releaseOrder(z, ord, true)
                        return
                    end

                    if ord.targetMiss == 0 then return end

                    ord.navX, ord.navY = body:getX(), body:getY()
                    HZ.try("renav", function()
                        z:pathToLocationF(ord.navX, ord.navY, body:getZ())
                    end)
                    ord.navAt = now
                    ord.targetMiss = 0
                end

                -- ③ 真卡住：目标没偏离（走到这里说明目标一致），但位置只在一个小范围里来回波动
                --    地形 / 被别的丧尸挤住才会这样。位置每拍采一次，至少 4 拍（约 8 秒）才判定；
                --    只要它真的在往外走，窗口就会被撑开，永远不会误判。
                if x and not waiting then
                    local win = ord.osc
                    if not win then
                        win = { n = 0, minX = x, maxX = x, minY = y, maxY = y }
                        ord.osc = win
                    end
                    win.n = win.n + 1
                    if x < win.minX then win.minX = x end
                    if x > win.maxX then win.maxX = x end
                    if y < win.minY then win.minY = y end
                    if y > win.maxY then win.maxY = y end

                    -- 走出 2 格说明它确实在赶路：窗口重开，从当前位置重新算
                    if (win.maxX - win.minX) + (win.maxY - win.minY) > 2.0 then
                        win.n, win.minX, win.maxX, win.minY, win.maxY = 1, x, x, y, y
                    end

                    if win.n >= 4 and (win.maxX - win.minX) + (win.maxY - win.minY) < 0.8 then
                        ord.stuckNow = true
                    end
                else
                    ord.osc, ord.stuckNow = nil, false
                end

                -- 目标丢失（引擎里 target=nil）也算需要重下：否则站着不动、有订单、没目标，永远不动
                local lostTarget = (tx == nil and ty == nil)
                local needNav = firstNav or bodyChanged or lostTarget

                if needNav and (now - (ord.navAt or 0)) > HZ.emitIntervalMs() then
                    navBump("path")
                    navBump(firstNav and "first" or "body")

                    ord.navX, ord.navY = body:getX(), body:getY()
                    HZ.try("nav", function()
                        z:pathToLocationF(body:getX(), body:getY(), body:getZ())
                    end)
                    ord.navAt = now
                end

                if x then
                    ord.lastX, ord.lastY = x, y
                end
            end
        end
    end
end

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
local function assignCircle(pile)
    local sx = pile.sourceX or pile.x
    local sy = pile.sourceY or pile.y
    local R  = tonumber(pile.lastRadius) or tonumber(HZ.opt.RadiusMin) or 20
    return sx, sy, R
end

-- 对象已失效（死亡 / 卸载 / 对象被回收）：清掉所有痕迹并返回 true。
-- HZ_orderState 对失效对象返回 0，桥调用本身 pcall 保护，不会抛。
local function purgeIfGone(z)
    if not z then return true end
    if not HZ_orderState then return false end

    -- 用 orderFlags 而不是裸调 HZ_orderState：
    -- 它内部 pcall，桥调用失败时 st 保持 0 → 当成"活着"，不会误杀。
    -- 注意 bit0 是「已死」，正常游荡丧尸返回 0（活）。
    local dead = orderFlags(z, nil)

    if not HZ._orderStateProbed and HZ.debugEnabled() then
        HZ._orderStateProbed = true
        local ok, v = pcall(HZ_orderState, z, nil)
        HZ.log(string.format("orderState probe: ok=%s v=%s type=%s",
            tostring(ok), tostring(v), type(v)))
    end

    if not dead then return false end

    if HZ.leaveQueue then HZ.leaveQueue(z) end
    if HZ._zstats then HZ._zstats[z] = nil end
    return true
end

-- 单只丧尸：续单 / 释放 / 进队。室内和室外共用这一段
local function considerZombie(pile, mo, nowMs, queueCap, cnt)
    if purgeIfGone(mo) then return "gone" end

    local full = (HZ.statsFull and HZ.statsFull(mo)) or false
    local ord0 = HZ._orders[mo]

    -- 目标尸体被删除后引擎不清 eatBodyTarget
    local stale = false
    if not ord0 then
        HZ.try("staleTarget", function()
            local tgt = mo:getEatBodyTarget()
            if tgt and instanceof(tgt, "IsoDeadBody") then
                if not tgt:getSquare() then stale = true end
            end
        end)
    end

    if stale then
        local so = HZ._orders[mo]
        if so then
            HZ.releaseOrder(mo, so, false)
        else
            -- 只清引擎里的残留 eatBodyTarget，不动静音：
            -- 它可能正躺在某个堆的队列里，清掉静音位会让它重新听见
            -- 所有堆的声音，被另一堆拉走 —— 这就是"反复拉动"的来源。
            HZ.try("clearStaleEat", function() HZ.clearEat(mo) end)
        end
    end

    local ord = HZ._orders[mo]

    -- 吃饱了：释放、不入队、不接单
    if full then
        if ord then
            HZ.releaseOrder(mo, ord, false)      -- 会 clearEat
        else
            -- 没有订单但引擎里还挂着进食目标（被别人先踢出队的情况）：
            -- 不清的话它会一直保持啃咬动画和状态，看着像"5.0 还在吃"
            HZ.try("fullClearEat", function() HZ.clearEat(mo) end)
        end
        HZ.refreshBuffs(mo)
        return "full"
    end

    -- 已有订单：只检查目标，导航交给 tickOneOrder
    if ord then
        local isDeadFlag, _, bodyAlive = orderFlags(mo, ord.body)
        if isDeadFlag then
            HZ.releaseOrder(mo, ord, false)
        elseif not bodyAlive then
            HZ.releaseOrder(mo, ord, true)   -- requeue：保留静音
            if HZ.pileOf(mo) == 0 and cnt.n < queueCap then
                HZ.joinQueue(mo, pile)
                cnt.n = cnt.n + 1
            end
        end
        return "ord"
    end

    -- 空闲：进队（限容量）。
    -- 已被别的堆认领（开饭 + 静音 buff）就不入本堆 ——
    -- 这是"一只丧尸只跟一个堆走、不被两个堆反复拉动"的硬条件。
    local pid = HZ.pileOf(mo)

    -- 认领的堆不存在（旧存档 / 重载残留 / 尸体已吃完）：作废重来。
    -- 不校验的话，丧尸会顶着上一局的 pid 被所有新堆拒绝，
    -- 永远进不了队、永远接不到单（refill 里会看到 owner=N、q=0）
    if pid ~= 0 and not HZ.pileExists(pid) then
        HZ.leaveQueue(mo)
        pid = 0
    end

    if pid ~= 0 and pid ~= pile.pid then return "owner" end

    if pid == 0 and cnt.n < queueCap then
        HZ.joinQueue(mo, pile)
        cnt.n = cnt.n + 1
        return "ok"
    end
    return "cap"
end

-- 室内：边界是墙，扫房间格（室内无风，不用圆）
local function refillFromRoom(pile, nowMs, queueCap, cnt)
    local cell = getCell()
    if not cell or not pile.room then return end

    local list = pile.room:getSquares()
    if not list then return end

    for i = 0, list:size() - 1 do
        local sq = list:get(i)
        local mos = sq and sq:getMovingObjects()
        if mos then
            for j = 0, mos:size() - 1 do
                local mo = mos:get(j)
                if mo and instanceof(mo, "IsoZombie") then
                    local okD, dead = HZ.try("roomIsDead", function() return mo:isDead() end)
                    if okD and not dead then
                        considerZombie(pile, mo, nowMs, queueCap, cnt)
                    end
                end
            end
        end
    end
end

-- 室外：快照坐标做一次圆判断，命中才碰对象
function HZ.refillQueue(pile)
    if not pile then return 0 end

    local maxEaters = math.floor(HZ.opt.MaxEaters or 4)
    local cellCount = (HZ.pileCellCount and HZ.pileCellCount(pile)) or 1
    local pileCap   = maxEaters * math.max(1, cellCount)
    local queueCap  = math.ceil(pileCap * 1.1)

    -- 餐位满：这个堆不再拉人（发声那边也已经有同样的闸）。
    -- 否则会把丧尸认领到一张坐满的桌子前，静音站着，而别的还有空位的堆
    -- 又发声音拉它 —— 来回跑的根源。
    local pileOrders = 0
    for i = 1, #pile.foods do
        pileOrders = pileOrders + (pile.foods[i].orders or 0)
    end
    if pileOrders >= pileCap then
        if HZ.debugEnabled() then
            HZ.log(string.format("refill (%.0f,%.0f) SKIP full orders=%d/%d",
                pile.x, pile.y, pileOrders, pileCap))
        end
        return 0
    end

    HZ._orders = HZ._orders or {}

    -- 容量下降（尸体骨化）：超出上限的排队者踢回自由
    -- 队列长度只算一次，后面进队时在 cnt 上累加，避免每只丧尸扫全快照
    local cnt = { n = HZ.queueCount(pile) }
    while cnt.n > queueCap do
        local zz = HZ.queueNext(pile)
        if not zz then break end
        HZ.leaveQueue(zz)
        cnt.n = cnt.n - 1
    end

    local nowMs = getTimestampMs()

    if pile.indoor then
        refillFromRoom(pile, nowMs, queueCap, cnt)
        return cnt.n
    end

    local snap = HZ._snap
    if not snap or (snap.n or 0) <= 0 then return 0 end

    -- 没气味（尸体还没到腐化时间）：只收尸堆本身，不扩散
    if not pile.hasScent then
        local pileR = math.floor(tonumber(HZ.opt.PileSize) or 2)
        for i = 1, snap.n do
            local mo = snap.obj[i]
            if mo then
                local dx, dy = snap.x[i] - pile.x, snap.y[i] - pile.y
                if math.abs(dx) <= pileR and math.abs(dy) <= pileR then
                    considerZombie(pile, mo, nowMs, queueCap, cnt)
                end
            end
        end
        return cnt.n
    end

    -- 有气味：声源圆（风偏已保证覆盖整个尸堆）
    local mx, my, R = assignCircle(pile)
    local R2 = R * R

    local seen, inCircle = 0, 0
    local why = {}
    for i = 1, snap.n do
        local mo = snap.obj[i]
        if mo then
            seen = seen + 1
            local dx, dy = snap.x[i] - mx, snap.y[i] - my
            if dx * dx + dy * dy <= R2 then
                inCircle = inCircle + 1
                local r = considerZombie(pile, mo, nowMs, queueCap, cnt) or "?"
                why[r] = (why[r] or 0) + 1
            end
        end
    end

    if HZ.debugEnabled() then
        HZ.log(string.format("refill (%.0f,%.0f) src=(%.0f,%.0f) R=%d in=%d q=%d | ok=%d owner=%d ord=%d full=%d gone=%d cap=%d",
            pile.x, pile.y, mx, my, R, inCircle, cnt.n,
            why.ok or 0, why.owner or 0, why.ord or 0, why.full or 0, why.gone or 0, why.cap or 0))
    end

    return cnt.n
end

-- ===================== 派单（全局队列：2s / 排队数） =====================

-- 给一只丧尸派单；成功返回 true
function HZ.dispatchOne(pile, mo, nowMs, passLimit)
    if not pile or not mo then return false end

    HZ._orders = HZ._orders or {}

    -- 对象已死/卸载：出队
    if purgeIfGone(mo) then
        HZ.leaveQueue(mo)
        return false
    end

    -- 已经被别的堆抢了：认领跟着订单走（静音不能断）
    if HZ._orders[mo] then
        local ord = HZ._orders[mo]
        if ord.pile and ord.pile.pid then
            if HZ_setPile then pcall(HZ_setPile, mo, ord.pile.pid) end
        end
        HZ.refreshBuffs(mo)
        return false
    end

    if HZ.statsTrack then pcall(HZ.statsTrack, mo) end

    if HZ.statsFull and HZ.statsFull(mo) then
        if HZ.debugEnabled() and HZ.due("dbgFull", 3000) then
            HZ.log(string.format("disp-skip full pile=(%d,%d) uid=%s", pile.x, pile.y, HZ.uidOf(mo) or "?"))
        end
        -- 出队的同时清引擎进食目标，否则它带着啃咬动画站在尸体上
        HZ.try("dispFullClearEat", function() HZ.clearEat(mo) end)
        HZ.leaveQueue(mo)
        return false
    end

    local maxEaters = math.floor(HZ.opt.MaxEaters or 4)
    local limit = passLimit or maxEaters

    -- 每格已有订单数：只遍历订单，不碰尸体（成员集合按版本缓存）
    local cellOrders = {}
    for _, ord in pairs(pile.orders or {}) do
        local r = ord.rec
        if r and inFoods[r] then
            local c = (r.x or 0) .. ":" .. (r.y or 0)
            cellOrders[c] = (cellOrders[c] or 0) + 1
        end
    end

    -- 由内向外找：命中第一具能派的尸体就停。
    -- 原来会为每具尸体都调一次 findBody（扫格子），一具一具扫完才挑；
    -- 现在只有「格子没满、没在冷却」的候选才会去扫它的格子。
    local pick, pickCk = nil, nil
    local maxRing = (math.floor(tonumber(HZ.opt.PileSize) or 2)) + 3

    for ring = 0, maxRing do
        for i = 1, #pile.foods do
            local rec = pile.foods[i]
            local dx = math.abs((rec.x or 0) - pile.x)
            local dy = math.abs((rec.y or 0) - pile.y)
            if math.max(dx, dy) == ring then
                local c = (rec.x or 0) .. ":" .. (rec.y or 0)
                if (cellOrders[c] or 0) < limit then
                    local untilMs = rec.blocked and rec.blocked[mo]
                    if (not untilMs) or nowMs >= untilMs then
                        local b = HZ.findBody and HZ.findBody(rec) or nil
                        if b and not HZ.isBone(b) then
                            pick, pickCk = { rec = rec, body = b }, c
                            break
                        end
                    end
                end
            end
        end
        if pick then break end
    end

    if not pick then
        if HZ.debugEnabled() and HZ.due("dbgNoPick", 3000) then
            local ordN = 0
            for _ in pairs(pile.orders or {}) do ordN = ordN + 1 end
            HZ.log(string.format("disp-skip no-pick pile=(%d,%d) foods=%d pileOrders=%d limit=%d",
                pile.x, pile.y, #pile.foods, ordN, limit))
        end
        return false                          -- 没尸体 / 满格 / 冷却：留在队里
    end

    local rec, body = pick.rec, pick.body
    local ck = pickCk

    if rec.blocked then rec.blocked[mo] = nil end

    HZ.try("forceIdle", function() mo:setDefaultState() end)
    if HZ_clearTarget then pcall(HZ_clearTarget, mo) end
    -- 注意：不 unmark。派单后它仍在"认领"状态（只是从排队数组挪到订单），
    -- 否则去吃饭的路上会重新听见别的堆的声音，被拉走。
    HZ.refreshBuffs(mo)

    local ord = {
        pile = pile,
        body = body,
        rec  = rec,
        t    = nowMs,
        uid  = HZ.uidOf(mo) or "?",   -- 失效对象返回 nil
    }
    HZ._orders[mo] = ord
    pile.orders = pile.orders or {}
    pile.orders[mo] = ord

    rec.orders = (rec.orders or 0) + 1
    cellOrders[ck] = (cellOrders[ck] or 0) + 1
    pile.lastAssign = (pile.lastAssign or 0) + 1

    if HZ.debugEnabled() then
        HZ.log(string.format("assign uid=%s -> rec=(%d,%d) cell=%d/%d",
            ord.uid, rec.x, rec.y, cellOrders[ck], limit))
    end
    return true
end

-- ===================== 全局队列：2s / 队列长度 =====================
-- 派单和续单都不绑堆：队列里是所有堆的元素，间隔 = 周期 / 总数。
-- 堆内 while 一次派完会让同堆的多只丧尸同帧起步，这是同步感的来源。

-- 派单队列：所有堆的排队丧尸合成一个全局队列
function HZ.tickOneDispatch()
    local piles = HZ.piles
    if not piles or #piles == 0 then return end

    local now = getTimestampMs()
    local emitMs = HZ.emitIntervalMs()

    -- 每 2 秒重建一次索引。队列 = 扫快照 + hz_pile 分桶（p.queue 已删除）
    if not HZ._dispKeys or (now - (HZ._dispKeysAt or 0)) > emitMs then
        local keys = {}
        local snap = HZ._snap
        if snap then
            local byPid = {}
            for k = 1, snap.n do
                local z = snap.obj[k]
                -- 已有订单的不进派单队列（它们在 tickOneOrder 里续单）
                if z and not (HZ._orders and HZ._orders[z]) then
                    local pid = HZ.pileOf(z)
                    if pid ~= 0 then
                        local b = byPid[pid]
                        if not b then b = {}; byPid[pid] = b end
                        b[#b + 1] = z
                    end
                end
            end
            for i = 1, #piles do
                local p = piles[i]
                local b = p.pid and byPid[p.pid]
                if b then
                    for j = 1, #b do keys[#keys + 1] = { pile = p, mo = b[j] } end
                end
            end
        end
        HZ._dispKeys = keys
        HZ._dispKeysAt = now
    end

    local keys = HZ._dispKeys
    local n = #keys

    if HZ.debugEnabled() and HZ.due("dbgDispTick", 5000) then
        HZ.log(string.format("disp tick: piles=%d keys=%d cursor=%d due=%.1fms",
            #piles, n, HZ._dispCursor or 0, n > 0 and (emitMs / n) or 0))
    end

    if n == 0 then return end

    if not HZ.due("disp", emitMs / n) then return end

    HZ._dispCursor = ((HZ._dispCursor or 0) % n) + 1
    local e = keys[HZ._dispCursor]
    if e and e.pile and e.mo then
        HZ.dispatchOne(e.pile, e.mo, now, nil)
    end
end

-- 续单队列：所有订单合成一个全局队列
function HZ.tickOneOrder()
    local t = HZ._orders
    if not t then return end

    local now = getTimestampMs()
    local emitMs = HZ.emitIntervalMs()

    if not HZ._ordKeys or (now - (HZ._ordKeysAt or 0)) > emitMs then
        local keys = {}
        for z in pairs(t) do keys[#keys + 1] = z end
        HZ._ordKeys = keys
        HZ._ordKeysAt = now
    end

    local keys = HZ._ordKeys
    local n = #keys
    if n == 0 then return end

    if not HZ.due("ord", emitMs / n) then return end

    HZ._ordCursor = ((HZ._ordCursor or 0) % n) + 1
    local z = keys[HZ._ordCursor]
    local ord = z and t[z]
    if ord then HZ.navOne(z, ord, now) end
end

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

local function v2Cells(pile)
    return pile and pile.cells or {}
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
end

-- 重建调度序列：所有堆的格子首尾相接 → 格子多的堆自然占更多格位（时间片加权）
function HZ.v2Cycle()
    if not HZ.due("v2cycle", 2000) then return end

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

    -- 可接单队列：纯数据，每 2s 重建一次
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
        local sn = (HZ._snap and HZ._snap.n) or 0
        local cz, co, cb = HZ._candZ or 0, HZ._candSkipOrd or 0, HZ._candBest or 0
        local seats = 0
        for i = 1, #piles do seats = seats + (piles[i].openSeats or 0) end
        HZ.log(string.format("v2: snap=%d seats=%d candZ=%d skipOrd=%d got=%d piles=%d cells=%d orders=%d cand=%d near=%d wait=%d eating=%d onGoal=%d nav=%d/%d tick=%d ret=%d bad[noBody=%d noCorpse=%d recGone=%d bone=%d noSq=%d] d=[%.1f..%.1f]",
            sn, seats, cz, co, cb, #piles, cells, nOrder, nCand, nNear, nWait, nEat, nGoal, navAtt, navOk, tickCnt, retCnt, nb, nc, (HZ._cRecGone or 0), bo, ns,
            dmin > 1e8 and -1 or dmin, dmax))
    end

    -- 室内堆：按房间格拉人（墙挡气味，不能用半径，否则会把墙外的丧尸叫进来）
    local taken = {}
    for i = 1, #piles do
        local pile = piles[i]
        if pile.indoor and pile.room then
            local list = pile.room:getSquares()
            if list then
                for k = 0, list:size() - 1 do
                    local sq = list:get(k)
                    local mos = sq and sq:getMovingObjects()
                    if mos then
                        for m = 0, mos:size() - 1 do
                            local z = mos:get(m)
                            if z and instanceof(z, "IsoZombie")
                               and not (HZ._orders and HZ._orders[z])
                               and not taken[z] then
                                local dead = false
                                HZ.try("roomDead", function() dead = z:isDead() end)
                                if not dead then
                                    local zx, zy = z:getX(), z:getY()
                                    pile.cand[#pile.cand + 1] = { z = z, x = zx, y = zy }
                                    pile.candSet[z] = true
                                    taken[z] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    HZ._candZ, HZ._candSkipOrd, HZ._candBest = 0, 0, 0
    for i = 1, snap.n do
        local z = snap.obj[i]
        if z then HZ._candZ = HZ._candZ + 1 end
        if z and (HZ._orders and HZ._orders[z]) then HZ._candSkipOrd = HZ._candSkipOrd + 1 end
        if z and not taken[z] and not (HZ._orders and HZ._orders[z]) then
            local x, y = snap.x[i], snap.y[i]
            local best, bestD = nil, nil
            for k = 1, #piles do
                local pile = piles[k]
                if (not pile.dead) and (not pile.indoor) and (pile.openSeats or 0) > 0 then
                    local mx, my = pile.sourceX or pile.x, pile.sourceY or pile.y
                    local R = tonumber(pile.lastRadius) or tonumber(HZ.opt.RadiusMin) or 60
                    local dx, dy = x - mx, y - my
                    local d = dx * dx + dy * dy
                    if d <= R * R and (not bestD or d < bestD) then best, bestD = pile, d end
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
    local tickFn = HZ.tickOrder or HZ.navOne
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
    if not rec then return end

    local cand = pile.cand
    if not cand or #cand == 0 then return end

    local cx, cy = body:getX(), body:getY()
    while free > 0 and #cand > 0 do
        local bi, bd
        for i = 1, #cand do
            local e = cand[i]
            if e and e.z and not (HZ._orders and HZ._orders[e.z]) then
                local dx, dy = e.x - cx, e.y - cy
                local d = dx * dx + dy * dy
                if (not bd) or d < bd then bi, bd = i, d end
            end
        end
        if not bi then break end

        local e = table.remove(cand, bi)
        local z = e.z

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
        HZ.try("v2forceIdle", function() z:setDefaultState() end)
        if HZ_clearTarget then pcall(HZ_clearTarget, z) end
        HZ.refreshBuffs(z)

        free = free - 1
        pile.openSeats = math.max(0, (pile.openSeats or 0) - 1)
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
            if back == nil then
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
    local dead = false
    if HZ_orderState then
        local ok, st = pcall(HZ_orderState, z, nil)
        dead = ok and (tonumber(st) or 1) % 2 >= 1
    end
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
        local _, _, bodyAlive = orderFlags(z, ord.body)
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

    -- 转向：0.3.0 在这里消费（只要有目标就转一次），不是等到开吃
    if ord.faceNext then
        ord.faceNext = false
        HZ.try("faceOnce", function() z:faceLocationF(ord.body:getX(), ord.body:getY()) end)
    end

    -- ② 距离
    local okD, d = HZ.try("tickDist", function() return z:DistTo(ord.body) end)
    if not okD or not d then d = 1e9 end

    -- 远单观测：d 特别大的订单，10 秒一条，确认是在接近还是在远离
    if d and d > 15 and HZ.due("farOrd" .. tostring(HZ.uidOf and HZ.uidOf(z) or z), 10000) then
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
    if (not ord.eating) and (ord.stillMs or 0) > 5000
        and HZ.due("stuck" .. tostring(HZ.uidOf and HZ.uidOf(z) or z), 10000) then
        local et, px, py, bx, by = nil, -1, -1, -1, -1
        HZ.try("stuckInfo", function()
            et = z:getEatBodyTarget()
            px, py = z:getX(), z:getY()
            bx, by = ord.body:getX(), ord.body:getY()
        end)
        HZ.log(string.format("stuck uid=%s d=%.1f still=%dms fails=%d et=%s z=(%.1f,%.1f) body=(%.1f,%.1f)",
            tostring(ord.uid), d, math.floor(ord.stillMs or 0), ord.eatFails or 0,
            tostring(et), px, py, bx, by))
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
            HZ.try("leaveFar", function() HZ.clearEat(z) end)
        end

        -- 引擎当前目标是不是我们给的那具尸体
        -- 不能用 isTargetLocation：它内部是 targetX == x 的浮点全等比较，
        -- 而 pathToLocationF 会把目标吸附到格子中心，尸体坐标是物体中心（如 2134.7），
        -- 两者永远不相等 → onTarget 恒 false → 每 2 秒重下发一次 setDefaultState+path，
        -- 丧尸被反复打断，看起来就在原地游荡。
        local onTarget = false
        local bx, by, bz = ord.body:getX(), ord.body:getY(), ord.body:getZ()
        local tx, ty = nil, nil
        HZ.try("tickGoal", function()
            local pf = z:getPathFindBehavior2()
            if pf and not pf:isGoalNone() then
                tx, ty = pf:getTargetX(), pf:getTargetY()
            end
        end)
        if tx and ty then
            onTarget = (math.abs(tx - bx) < 0.75 and math.abs(ty - by) < 0.75)
        end

        -- 目标对、但距离在变大：被追击目标接管了，抢回控制
        if onTarget and ord.lastD and d > ord.lastD + 1.0 then
            onTarget = false
            HZ._cFarAway = (HZ._cFarAway or 0) + 1
        end
        ord.lastD = d

        if not onTarget then
            -- 先打断当前状态（声音目标），再重新下令
            HZ.try("tickIdle", function() z:setDefaultState() end)
            if HZ_clearTarget then pcall(HZ_clearTarget, z) end
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
