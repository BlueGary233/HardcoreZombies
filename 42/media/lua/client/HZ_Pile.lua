-- HZ_Pile.lua — 尸堆（主单位）
-- 食物按 PileSize 网格归堆（默认 2 → 5×5）：进堆只存位置，死亡时间/腐化时间从尸体对象现算
-- tickPiles 每拍只处理一个堆：维护 → 骨化 → 发声（有气味）
-- 派单和续单不在这里：tickOneDispatch / tickOneOrder 各自用全局队列

HardcoreZombies = HardcoreZombies or {}

local HZ = HardcoreZombies

-- ===================== 参数 =====================
local ROT_MIN        = 0.0        -- 腐烂延迟（小时），测试用 0
local ROT_MAX        = 0.0

-- 尸体实体化重试：先等 120 tick（60fps ≈ 2s）再试，给 10 秒总窗口
local function pendingRetryMs()  return tonumber(HZ.opt.PendingRetryMs) or 2000 end
-- 待处理尸体多久拿不到格子就放弃
local function pendingGiveupMs() return tonumber(HZ.opt.PendingGiveupMs) or 10000 end

-- ===================== 状态 =====================
-- 开档 / 热重载后补扫一次已加载范围
local initialScanned = false

-- 加载半径：chunkGridWidth 个 chunk × 每个 chunk 的格数，取一半
-- 读不到游戏常量时退回 80
local function loadedRadius()
    local r
    HZ.try("loadedRadius", function()
        -- 静态字段读出来是 Java 包装对象，先转 number
        local grid = tonumber(IsoChunkMap.chunkGridWidth)
        local per  = tonumber(IsoChunkMap.CHUNK_SIZE_IN_SQUARES)
        if grid and per then
            r = math.floor(grid * per / 2)
        end
    end)
    return r or 80
end

-- 尸堆列表
-- pile = { x, y, z（5×5 网格中心）, foods[], count, avgRotStart, rotDelay, hasScent }
local piles   = {}
local pileMap = {}             -- "cx,cy,z" -> pile

HZ.piles   = piles
HZ._pendingFeed = {}      -- 重载即作废
HZ._pileCursor  = 0
HZ._groupSeq    = 0

-- 尸堆半径（可配置）：实际边长 = R*2+1
-- 腐烂延迟：RotRandom 关掉时固定用 RotMin
local function rotDelayValue()
    local lo = tonumber(HZ.opt.RotMin) or ROT_MIN
    local hi = tonumber(HZ.opt.RotMax) or ROT_MAX
    local r  = HZ.opt.RotRandom
    if r == false or r == "false" then return lo end
    if hi < lo then hi = lo end
    return HZ.randFloat(lo, hi)
end

-- 尸堆半径（格）
local function pileRadius()
    -- 下拉索引即半径：1=3×3, 2=5×5, 3=7×7 ...
    return math.floor(tonumber(HZ.opt.PileSize) or 2)
end
-- 尸堆不设上限；上限只作用于声音精灵

-- ===================== 进堆 =====================
local function gridCenter(x, y)
    local R = pileRadius()
    local S = R * 2 + 1
    return math.floor(x / S) * S + R,
           math.floor(y / S) * S + R
end

-- 堆的缓存键（中心格 + 层）
local function pileKey(cx, cy, z)
    return cx .. "," .. cy .. "," .. z
end

-- 位置检测：该坐标所在网格是否已有尸堆
local function findPile(x, y, z)
    local cx, cy = gridCenter(x, y)
    return pileMap[pileKey(cx, cy, z)]
end

-- 尸体加入尸堆，累加平均开始腐烂时间
-- 格子数缓存：foods 变化时置 dirty，平时直接读
function HZ.pileCellCount(pile)
    if pile._cellDirty or not pile._cellCount then
        local set = {}
        for i = 1, #pile.foods do
            local f = pile.foods[i]
            set[(f.x or 0) .. ":" .. (f.y or 0)] = true
        end
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        pile._cellCount = math.max(1, n)
        pile._cellDirty = false
    end
    return pile._cellCount
end

-- 往已存在的堆里追加一具尸体（合并同格尸体）
local function addToPile(pile, x, y, z, uid, eat)
    -- 同一具尸体只登记一次（spawn / 补扫 / 重试都会打到同一具）
    if uid then
        for i = 1, #pile.foods do
            if pile.foods[i].uid == uid then
                return
            end
        end
    end

    -- 只存位置和 uid；死亡时间/腐化时间不存，tickPile 时从尸体对象现算
    pile.foods[#pile.foods + 1] = {
        x = x, y = y, z = z, uid = uid,
        eatProgress = eat or 0,
    }
    pile.count = pile.count + 1
    pile._cellDirty = true
    pile._foodsVer = (pile._foodsVer or 0) + 1
end


-- ===================== 血迹 =====================
local BLOOD_PARTS = {
    {1, "Torso_Upper", 0.35}, {1, "Torso_Lower", 0.30},
    {1, "UpperArm_L",  0.25}, {1, "UpperArm_R",  0.25},

    {2, "Back",        0.55}, {2, "Groin",       0.50},
    {2, "UpperLeg_L",  0.45}, {2, "UpperLeg_R",  0.45},
    {2, "Neck",        0.45}, {2, "Head",        0.40},

    {3, "ForeArm_L",   0.65}, {3, "ForeArm_R",   0.65},
    {3, "LowerLeg_L",  0.55}, {3, "LowerLeg_R",  0.55},
    {3, "Hand_L",      0.60}, {3, "Hand_R",      0.60},

    {4, "Torso_Upper", 0.90}, {4, "Back",        0.85},
    {4, "Groin",       0.80}, {4, "Head",        0.75},
    {4, "UpperLeg_L",  0.75}, {4, "UpperLeg_R",  0.75},

    {5, "Torso_Lower", 1.00}, {5, "Torso_Upper", 1.00},
    {5, "Back",        0.95}, {5, "Head",        0.90},
    {5, "Groin",       0.95},
}

local bloodPartCache = {}

-- 血污贴图的部件名
local function bloodPart(name)
    local cached = bloodPartCache[name]
    if cached ~= nil then
        return cached or nil
    end

    local part = nil
    if BloodBodyPartType then
        local ok, p = HZ.try("call", function() return BloodBodyPartType[name] end)
        if ok and p then
            part = p
        elseif BloodBodyPartType.FromString then
            local ok2, p2 = pcall(BloodBodyPartType.FromString, name)
            if ok2 then part = p2 end
        end
    end

    bloodPartCache[name] = part or false
    return part
end

-- 进度 -> 血迹阶段（0..5）
local function bloodStage(progress)
    if progress >= 0.55 then return 5 end
    if progress >= 0.40 then return 4 end
    if progress >= 0.25 then return 3 end
    if progress >= 0.12 then return 2 end
    if progress >= 0.05 then return 1 end
    return 0
end

-- 按阶段叠血迹，只增不减
local function applyBlood(body, stage)
    if stage <= 0 then return end

    local visual = nil
    local okV, v = HZ.try("getHumanVisual", function() return body:getHumanVisual() end)
    if okV then visual = v end
    if not visual then return end

    local changed = false

    for i = 1, #BLOOD_PARTS do
        local row = BLOOD_PARTS[i]
        if row[1] <= stage then
            local part = bloodPart(row[2])
            if part then
                local okB = HZ.try("onumber", function()
                    local cur = tonumber(visual:getBlood(part)) or 0
                    if cur < row[3] then
                        visual:setBlood(part, row[3])
                        changed = true
                    end

                    local dirt = math.min(row[3] * 0.85, 1.0)
                    local curD = tonumber(visual:getDirt(part)) or 0
                    if curD < dirt then
                        visual:setDirt(part, dirt)
                        changed = true
                    end

                    if stage >= 3 and (row[2] == "Torso_Upper"
                        or row[2] == "Torso_Lower"
                        or row[2] == "Back"
                        or row[2] == "Groin") then
                        visual:setHole(part)
                    end
                end)

                if not okB then
                    HZ.log("blood error part=" .. tostring(row[2]))
                end
            end
        end
    end

    if changed then
        body:invalidateCorpse()
        body:setInvalidateNextRender(true)
    end
end

-- 按记录找到实际的 IsoDeadBody
local function findBody(b)
    if not b or not HZ_findBody then return nil end
    local ok, body = pcall(HZ_findBody, b.x, b.y, b.z, b.uid)
    if ok then return body end
    return nil
end

HZ.findBody = findBody

-- 用骷髅变体替换整具尸体（RZ 的做法）
local function replaceWithSkeleton(body)
    if not body then return false end

    local sq = body:getSquare()
    local cell = getCell()
    if not sq or not cell then return false end

    -- 原尸体身上的物品：掉到地上并打坏
    HZ.try("getContainer", function()
        local cont = body:getContainer()
        if not cont then return end

        local items = cont:getItems()
        if not items then return end

        for i = items:size() - 1, 0, -1 do
            local it = items:get(i)
            if it then
                HZ.try("setCondition", function() it:setCondition(0) end)
                HZ.try("setBroken", function() it:setBroken(true) end)
                -- 只有真的落地成功才从容器里删；插入失败就留着，
                -- 否则物品会凭空消失
                local okAdd = HZ.try("AddWorldInventoryItem",
                    function() sq:AddWorldInventoryItem(it, 0, 0, 0) end)
                if okAdd then
                    HZ.try("Remove", function() cont:Remove(it) end)
                end
            end
        end
    end)

    local shell = nil
    local ok = HZ.try("new", function() shell = IsoZombie.new(cell) end)
    if not ok or not shell then return false end

    HZ.try("setFemale", function()
        shell:setFemale(body:isFemale())
        shell:setCurrent(sq)
        shell:setX(body:getX())
        shell:setY(body:getY())
        shell:setZ(body:getZ())
        shell:setDir(body:getDir())
        shell:setForwardIsoDirection(body:getDir())

        local sv = shell:getHumanVisual()
        local ov = body:getHumanVisual()
        if sv and ov then sv:copyFrom(ov) end

        shell:setSkeleton(true)
        if shell:isSkeleton() ~= true then
            error("shell did not enter skeleton state")
        end

        if sv then
            sv:setSkinTextureName(nil)
            sv:setSkinTextureIndex(1)
        end
    end)

    local replacement = nil
    local ok2 = HZ.try("new", function() replacement = IsoDeadBody.new(shell, false, false) end)
    if not ok2 or not replacement then return false end

    if not replacement:getSquare() then
        HZ.try("removeFromWorld", function() replacement:removeFromWorld() end)
        return false
    end

    HZ.try("setName", function() replacement:setName("骷髅") end)

    if HZ.debugEnabled() then
        HZ.log("skeleton replace: isSkeleton=" .. tostring(replacement:isSkeleton())
            .. " shell=" .. tostring(shell:isSkeleton()))
    end

    local added = HZ.try("addCorpse", function() sq:addCorpse(replacement, false) end)
    if not added then return false end

    HZ.try("removeCorpse", function() sq:removeCorpse(body, false) end)
    return true
end

-- 把尸体变成骷髅
local function boneBody(b, stage, progress)
    local cell = getCell()
    if not cell then return end

    local sq = cell:getGridSquare(b.x, b.y, b.z)
    if not sq then return end

    local bodies = sq:getDeadBodys()
    if not bodies then return end

    for i = 0, bodies:size() - 1 do
        local body = bodies:get(i)
        if body and body:getUID() == b.uid then
            if (progress or 1) >= 0.9 then
                local okCall, okBone = pcall(replaceWithSkeleton, body)
                local success = okCall and okBone == true

                if success then
                    -- 记 uid：替换后的旧对象 isSkeleton 不会变，靠标记兜底
                    HZ._boneUids = HZ._boneUids or {}
                    HZ._boneUids[b.uid] = true

                    -- 释放所有订单，餐位清零（订单系统统一出口）
                    if HZ.ordersReleaseBody then HZ.ordersReleaseBody(body) end
                    b.orders = 0
                end
                -- 清食客...
                if body.getEatingZombies then
                    local ez = body:getEatingZombies()
                    if ez then
                        for j = ez:size() - 1, 0, -1 do
                            local z = ez:get(j)
                            if z then
                                if HZ.statsEatStop then pcall(HZ.statsEatStop, z) end
                                HZ.try("setEatBodyTarget", function()
                                    HZ.clearEat(z)
                                end)
                            end
                        end
                    end
                end
                return success
            end

            return false
        end
    end

    return false
end

-- 处理进食进度与白骨化
-- 进食进度存尸体 modData：chunk 卸载后堆会被删，靠它恢复
local function readBodyEat(body)
    local eat = 0
    HZ.try("readEat", function()
        local md = body:getModData()
        local v = rawget(md, "HZ_eatProgress")
        if type(v) == "number" then eat = v end
    end)
    return eat
end

-- 把进食进度写回尸体 modData —— chunk 卸载后靠它恢复
local function writeBodyEat(body, eat)
    HZ.try("writeEat", function()
        local md = body:getModData()
        rawset(md, "HZ_eatProgress", eat)
    end)
end

-- 新建尸堆：pid = 坐标身份，跨重载不变
local function buildPile(rec)
    -- 尸体在 feed 时已经分配好：建堆只需要把触发它的这一具放进去，
    -- 不再扫描周围收集（附近尸体各自 feed 时会 addToPile）
    local cx, cy = gridCenter(rec.x, rec.y)
    local key = pileKey(cx, cy, rec.z)

    if pileMap[key] then
        return pileMap[key]
    end

    HZ._groupSeq = (HZ._groupSeq or 0) + 1

    local pile = {
        x = cx, y = cy, z = rec.z,
        -- 认领标识：写进丧尸 modData.hz_pile。
        -- 15+15 位（各取模 32768）：最大 1073741823，Java int 不会溢出；
        -- 同图内相距 32768 格的两个堆不可能同时加载，所以不会碰撞。
        pid = (math.floor(cx) % 32768) * 32768 + (math.floor(cy) % 32768),
        group = HZ._groupSeq,
        -- 同一个堆共用一次随机腐化延迟；个体 rotStart = deathTime + rotDelay
        rotDelay = rotDelayValue(),
        foods = {
            { uid = rec.uid, x = rec.x, y = rec.y, z = rec.z, eatProgress = rec.eat or 0 },
        },
        count = 1,
        orders = {},            -- 该堆自己的订单（z -> ord）
        avgRotStart = 0,        -- tickPile 第一次维护时重算
    }

    piles[#piles + 1] = pile
    pileMap[key] = pile

    if HZ.debugEnabled() then
        HZ.log(string.format("pile built (%d,%d,%d) uid=%s rotDelay=%.2f",
            cx, cy, rec.z, tostring(rec.uid), pile.rotDelay))
    end

    -- 不发声：等 tickPile 里 avgRotStart 过了 now 才建声源

    return pile
end

-- 统一入口：死亡 / 加载（骨骼在这里滤掉，不进入尸堆）
-- 室内尸体：不进室外堆，按房间建一个室内堆（key = r:<roomID>）
local function feedIndoor(body, sq)
    local room = sq:getRoom()
    local roomID = sq:getRoomID()
    if not room or not roomID then return false end

    local key = "r:" .. tostring(roomID)
    local pile = pileMap[key]

    if not pile then
        HZ._groupSeq = (HZ._groupSeq or 0) + 1
        pile = {
            key      = key,
            indoor   = true,
            room     = room,
            roomID   = roomID,
            -- 室内堆没有坐标身份，用负的序号当 pid（室外都是正数）。
            -- 没有 pid 的话 queueCount/queueNext 直接返回 0，室内永远不会派单。
            pid      = -HZ._groupSeq,
            x = sq:getX(), y = sq:getY(), z = sq:getZ(),
            group    = HZ._groupSeq,
            rotDelay = 0,
            foods    = {},
            count    = 0,
            orders   = {},
            avgRotStart = 0,
            hasScent = true,          -- 室内直接发小半径声源
            lastTick = 0,
        }
        pileMap[key] = pile
        piles[#piles + 1] = pile
        if HZ.debugEnabled() then
            HZ.log("indoor pile room=" .. tostring(roomID) .. " at (" .. sq:getX() .. "," .. sq:getY() .. ")")
        end
    end

    local uid = body:getUID()
    if not uid then return false end

    addToPile(pile, sq:getX(), sq:getY(), sq:getZ(), uid, readBodyEat(body))
    return true
end

-- 尸体入堆入口：取格子 → 室内/室外分支
local function feed(body)
    if not body or HZ.isBone(body) then return false end

    -- 假死尸体（IsoDeadBody + fakeDead）：复活前不当食物，
    -- 否则被吃进度推进会让它没法 reanimate 起身
    local okFd, fd = HZ.try("isFakeDead", function() return body:isFakeDead() end)
    if okFd and fd and not HZ.opt.FakeDeadFood then return false end

    local sq = body:getSquare()
    if not sq then return false end

    -- 室内尸体：走室内堆（不建室外堆、不吃风偏）
    if not sq:isOutside() then
        return feedIndoor(body, sq)
    end

    local uid = body:getUID()
    if not uid then return false end

    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    local eat = readBodyEat(body)
    local pile = findPile(x, y, z)

    if pile then
        addToPile(pile, x, y, z, uid, eat)
        if HZ.debugEnabled() then
            HZ.log(string.format("body -> pile (%d,%d) count=%d avgRot=%.2f",
                x, y, pile.count, pile.avgRotStart))
        end
        return true
    end

    -- 不排队：直接按 5×5 网格建堆
    buildPile({ x = x, y = y, z = z, uid = uid, eat = eat })
    return true
end

-- 重试列表：OnDeadBodySpawn 触发时 square 可能还没就绪。
-- 先等 pendingRetryMs() 再试，按 FIFO；超过 pendingGiveupMs() 才放弃
local function flushPendingFeed()
    local q = HZ._pendingFeed
    if not q or #q == 0 then return end

    local nowMs = getTimestampMs()

    local i = 1
    while i <= #q do
        local e = q[i]

        if nowMs - (e.born or nowMs) > pendingGiveupMs() then
            table.remove(q, i)
            HZ.log("pending feed: give up uid=" .. tostring(e.body and e.body:getUID()))
        elseif nowMs >= (e.nextTry or 0) then
            if feed(e.body) then
                table.remove(q, i)
            else
                e.nextTry = nowMs + pendingRetryMs()
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

-- 单个尸堆的一次完整计算（由 tickPiles 按 2s/堆数 轮转，一次一个堆）
function HZ.tickPile(p, now)
    local maxEaters = HZ.opt.MaxEaters
    -- 一只丧尸吃完一具尸体需要的游戏分钟 → 每游戏小时的进度
    local eatMinutes = HZ.opt.EatMinutes or 60
    local eatSpeed   = 60 / math.max(1, eatMinutes)
    local boneHours = HZ.opt.BoneHours or 12
    local rotDelay  = p.rotDelay or 0

    -- 这个堆上次计算到现在过了多久（游戏小时）；长时间没算也别一次跳太多
    local dt = now - (p.lastTick or now)
    if dt < 0 then dt = 0 end
    if dt > 0.05 then dt = 0.05 end
    p.lastTick = now

    local sum, n = 0, 0
    local cell = getCell()

    for i = #p.foods, 1, -1 do
        local b = p.foods[i]

        -- 先用格子判卸载（O(1) 哈希，比 findBody 遍历便宜）：
        -- 格子没了 = chunk 卸载 = 尸体不在了，直接移除
        local sq = cell and cell:getGridSquare(b.x, b.y, b.z)
        local body = nil
        if sq then body = findBody(b) end

        -- 防御：复活成其他对象 / 假死状态的尸体 -> 移出堆（让它能正常起身）
        if body and not instanceof(body, "IsoDeadBody") then
            body = nil
        end

        -- 骷髅不能留在食物列表里：旧存档残留或替换竞争都可能留下这种 rec，
        -- 留着会让它一直占 count（堆永不消失、持续发声），但没人能吃
        if body and HZ.isBone(body) then body = nil end
        if body then
            local okFd, fd = HZ.try("isFakeDead", function() return body:isFakeDead() end)
            if okFd and fd and not HZ.opt.FakeDeadFood then body = nil end
        end

        if not body then
            -- 实体不在了：从堆里移除（进度已在 modData 里）
            table.remove(p.foods, i)
            p._cellDirty = true
            p._foodsVer = (p._foodsVer or 0) + 1
        else

        -- 死亡时间从引擎读；堆里不存副本
        local deathTime = now
        HZ.try("getDeathTime", function()
            local d = body:getDeathTime()
            if d and d >= 0 then deathTime = d end
        end)

        local rotStart = deathTime + rotDelay
        sum = sum + rotStart
        n = n + 1

        -- 每具尸体单独被吃；由尸堆每 2.1 秒维护一次
        local eaters = math.min(b.orders or 0, maxEaters)
        if eaters > 0 then
            b.eatProgress = (b.eatProgress or 0) + eaters * eatSpeed * dt
            writeBodyEat(body, b.eatProgress)   -- 进食时写，2.1 秒一次足够
        end

        local aged = now - rotStart
        -- BoneHours = 0 → 禁用自然白骨化，只看被吃进度
        local natural = 0
        if boneHours > 0 then natural = aged / boneHours end
        local progress = math.max(b.eatProgress or 0, natural)

        local stage = bloodStage(progress)
        if stage ~= b.bloodStage then
            applyBlood(body, stage)
            b.bloodStage = stage
        end

        if progress >= 0.9 and not b.boned then
            local tries = (b.boneTries or 0) + 1
            b.boneTries = tries
            local okBone = boneBody(b, 5, progress)
            -- 成功，或连续失败 2 次：都不再重试。
            -- 不设上限的话，失败路径每 2 秒会重建一次 IsoZombie/IsoDeadBody
            if okBone or tries >= 2 then b.boned = true end
            if HZ.debugEnabled() then
                HZ.log(string.format("bone p=%.3f eaters=%d speed=%.2f uid=%s",
                    progress, eaters or 0, eatSpeed, tostring(b.uid)))
            end
        end

        if b.boned then
            table.remove(p.foods, i)
            p._cellDirty = true
            p._foodsVer = (p._foodsVer or 0) + 1
            sum = sum - rotStart
            n = n - 1
            if HZ.debugEnabled() then
                HZ.log(string.format("bone done (%d,%d) uid=%s", b.x, b.y, tostring(b.uid)))
            end
        end

        end   -- body 存在
    end

    p.count = #p.foods
    p.avgRotStart = n > 0 and (sum / n) or (p.avgRotStart or now)

    -- 平均“开始腐化时间”已过 → 开始发气味（只触发一次）
    if not p.hasScent and p.count > 0 and p.avgRotStart <= now then
        p.hasScent = true
        if HZ.debugEnabled() then
            HZ.log(string.format("scent on (%d,%d) avgRot=%.2f now=%.2f", p.x, p.y, p.avgRotStart, now))
        end
        -- 声源由 tickPiles 在同一拍里紧接着发射
    end
end

-- 每帧只算一个堆（负载均衡）
-- ===================== 尸堆节拍：2s / 堆数，一次一个堆 =====================
-- 堆级任务（维护 / 订单兜底 / 容量 / 发声 / 补队）一起做：
-- 它们共用同一个队列（堆），周期也相同，拆成多个 due 只会让同一帧做两件同一堆的事。
-- 丧尸级任务不在这里 —— 派单、续单、营养各有自己的全局队列（堆数 < 丧尸数，
-- 绑定到堆轮转会让一轮走完还有丧尸没派单）。

function HZ.tickPiles()
    -- 补投：spawn / 扫格时拿不到 square 的尸体在这里重试（原来这个函数定义了却没人调）
    if HZ.due("pending", HZ.emitIntervalMs()) then flushPendingFeed() end

    local n = #piles
    if n == 0 then return end

    if not HZ.due("pile", HZ.emitIntervalMs() / n) then return end

    HZ._pileCursor = (HZ._pileCursor or 0) % n + 1
    local p = piles[HZ._pileCursor]
    if not p then return end

    local now = getGameTime():getWorldAgeHours()

    -- ① 维护：进食 / 血迹 / 骨化 / 腐化
    local okTick, tickErr = pcall(HZ.tickPile, p, now)
    if not okTick then
        HZ.try("logTickErr", function() HZ.log("tickPile error: " .. tostring(tickErr)) end)
    end

    -- 空堆立即删：否则它会继续发声，把僵尸吸到一个没有尸体的地方
    if (p.count or 0) <= 0 then
        pileMap[p.key or pileKey(p.x, p.y, p.z)] = nil
        table.remove(piles, HZ._pileCursor)
        HZ._pileCursor = HZ._pileCursor - 1
        if HZ._pileCursor < 1 then HZ._pileCursor = 0 end
        if HZ.debugEnabled() then
            HZ.log(string.format("pile gone (empty) (%d,%d,%d)", p.x, p.y, p.z))
        end
        if HZ.onPileGone then HZ.onPileGone(p) end
        return
    end

    -- ② 订单兜底：丧尸死了 / 目标尸体没了
    -- 每个订单在 v2Tick → tickOrder 里已经每 2 秒校验过一次（HZ_orderState +
    -- orderFlags + recByUid），这里只是"格子不在调度里"时的安全网。
    -- 所以按 8 秒扫一次堆就够，省掉重复的跨桥调用。
    local sweepNow = getTimestampMs()
    if HZ.ordersSweepPile and (sweepNow - (p._sweptAt or 0)) > 8000 then
        p._sweptAt = sweepNow
        HZ.ordersSweepPile(p)
    end

    -- ③ 容量（按格算）
    local maxEaters  = HZ.opt.MaxEaters
    local cellCount  = HZ.pileCellCount(p)

    local pileOrders = 0
    for i = 1, #p.foods do
        pileOrders = pileOrders + (p.foods[i].orders or 0)
    end

    local pileCap  = maxEaters * math.max(1, cellCount)
    local queueCap = math.ceil(pileCap * 1.1)

    -- 容量下降（骨化）时踢出最晚派的
    if pileOrders > pileCap and HZ._orders then
        local list = {}
        for z, ord in pairs(HZ._orders) do
            if ord.pile == p then list[#list + 1] = { z = z, ord = ord } end
        end
        table.sort(list, function(a, b)
            return (a.ord.t or 0) > (b.ord.t or 0)
        end)
        local kick = math.min(pileOrders - pileCap, #list)
        for i = 1, kick do
            if HZ.releaseOrder then HZ.releaseOrder(list[i].z, list[i].ord, false) end
        end
        pileOrders = pileOrders - kick
    end

    -- ④ 发声：满员 / 排队满都不再喊人
    local queueLen = #(p.queue or {})
    p.lastEmitMs = getTimestampMs()

    if p.count > 0 and p.hasScent and pileOrders < pileCap
       and queueLen < queueCap and HZ.emitPile then
        HZ.emitPile(p, now)
    end

    -- ⑤ 补队：快照代数变了才跑（4 秒一次/堆）
    if p.snapGen ~= HZ._snapGen then
        p.snapGen = HZ._snapGen
    end
end

-- ===================== 表入口（事件层调用） =====================
-- 开档 / 热重载后扫一遍已加载范围：读档时 LoadGridsquare 不一定触发
-- 载入/重载后的全图补扫：分帧做，每帧固定预算，避免一帧扫上万格
local scanState = nil
local SCAN_BUDGET = 256          -- 每帧最多处理多少格

function HZ.initialScan(player)
    if initialScanned then return end
    if not player then return end

    local cell = getCell()
    if not cell then return end

    if not scanState then
        local R = loadedRadius()
        scanState = {
            px = math.floor(player:getX()),
            py = math.floor(player:getY()),
            pz = math.floor(player:getZ()),
            R  = R, dx = -R, dy = -R, n = 0,
        }
    end

    local st = scanState
    local budget = SCAN_BUDGET

    while budget > 0 do
        local sq = cell:getGridSquare(st.px + st.dx, st.py + st.dy, st.pz)
        if sq then
            local bodies = sq:getDeadBodys()
            if bodies and bodies:size() > 0 then
                for i = 0, bodies:size() - 1 do
                    if feed(bodies:get(i)) then st.n = st.n + 1 end
                end
            end

            local mos = sq:getMovingObjects()
            if mos and mos:size() > 0 then
                for i = 0, mos:size() - 1 do
                    local mo = mos:get(i)
                    if mo and instanceof(mo, "IsoZombie") then
                        if HZ.refreshBuffs then
                            HZ.try("scanHearing", function() HZ.refreshBuffs(mo) end)
                        end
                        if HZ.statsTrack then pcall(HZ.statsTrack, mo) end
                    end
                end
            end
        end

        st.dx = st.dx + 1
        if st.dx > st.R then st.dx = -st.R; st.dy = st.dy + 1 end
        budget = budget - 1

        if st.dy > st.R then
            initialScanned = true
            scanState = nil
            if HZ.debugEnabled() then HZ.log("initial scan bodies=" .. st.n) end
            break
        end
    end
end

-- chunk 加载时逐格触发：读档 / 走路 / 传送都靠这条重建尸堆
function HZ.onLoadGridsquare(sq)
    if not sq then return end

    -- 丧尸：chunk 加载时进总表（和尸体一样）
    local mos = sq:getMovingObjects()
    if mos and mos:size() > 0 and HZ.statsTrack then
        for i = 0, mos:size() - 1 do
            local mo = mos:get(i)
            if mo and instanceof(mo, "IsoZombie") then
                pcall(HZ.statsTrack, mo)
            end
        end
    end

    local bodies = sq:getDeadBodys()
    if not bodies or bodies:size() == 0 then return end

    for i = 0, bodies:size() - 1 do
        feed(bodies:get(i))
    end
end

-- 尸体生成事件：入堆
function HZ.onBodySpawn(body)
    if not body then return end

    local sq = body:getSquare()
    if sq then
        if HZ.debugEnabled() then
            HZ.log(string.format("body spawned (%d,%d,%d) uid=%s",
                sq:getX(), sq:getY(), sq:getZ(), tostring(body:getUID())))
        end
    end

    -- 构造器触发时可能还没入格（getSquare == nil）：留到下一帧再试
    if not feed(body) then
        HZ._pendingFeed = HZ._pendingFeed or {}
        local nowMs = getTimestampMs()
        HZ._pendingFeed[#HZ._pendingFeed + 1] = {
            body = body,
            born = nowMs,
            nextTry = nowMs + pendingRetryMs(),
        }
    end
end

-- 热重载前清尸体上的模组数据：进食进度写在尸体 modData 里（chunk 卸载靠它恢复），
-- 重载 = 重新开始，旧进度不能留。必须在 dofile 之前调用 —— 之后旧的 piles 就没了。
function HZ.purgeBodies()
    for i = 1, #piles do
        local foods = piles[i].foods or {}
        for j = 1, #foods do
            local b = HZ.findBody and HZ.findBody(foods[j]) or nil
            if b then
                HZ.try("purgeBody", function()
                    rawset(b:getModData(), "HZ_eatProgress", nil)
                end)
            end
        end
    end
end

-- 每帧补喂上一帧没拿到 square 的尸体
function HZ.resetTables()
    -- 所有临时表 / Java 桥数据 / 节拍统一清（含 _zstats、_orders、_snap、_throttle）
    if HZ.clearRuntimeState then HZ.clearRuntimeState() end

    -- 本文件的 local 表：重载时已由文件重新执行重建，这里兜底。
    -- 注意必须重新暴露给 HZ.piles —— local 换成新表后，旧引用会让
    -- tickOneDispatch 继续遍历已经废弃的堆。
    piles = {}
    pileMap = {}
    HZ.piles = piles
    initialScanned = false
    scanState = nil
end


-- ===================== 对外接口 =====================
-- 只留订单系统需要的入口（HZ.findBody 定义在上方）；其余 local function 仅供本文件内部使用


print("[HZ] Java bridge: applySprint=" .. tostring(HZ_applySprint)
    .. " setBuff=" .. tostring(HZ_setBuff)
    .. " getBuff=" .. tostring(HZ_getBuff)
    .. " clearTarget=" .. tostring(HZ_clearTarget)
    .. " orderState=" .. tostring(HZ_orderState)
    .. " findBody=" .. tostring(HZ_findBody)
    .. " scanCorpses=" .. tostring(HZ_scanCorpses))

print("[HZ_Pile] loaded ok")
