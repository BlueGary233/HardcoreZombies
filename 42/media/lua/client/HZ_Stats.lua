-- HZ_Stats.lua — 饱食度 / 营养进度 / 五维成长
--
-- 设计（O 定稿 2026-10-23）：
--   五维：health(0.5~4.0, 步进0.5, 7次) / speedType(4->1, 3次：假跑/跑/快走/慢) /
--         strength(1->5, 4次) / sight(3->1, 2次) / hearing(3->1, 2次)  = 18 次
--   营养值 nutrition：吃/饿推动，0~5，唯一状态
--   阶段：stage = clamp(floor((nutrition - 0.25) / 0.25), 0, 18)
--         营养 0.25 以下 = 五维锁最低；4.75 以上 = 锁最高
--   每小时维护顺序：①五维与快照比 → 变了记 flag；②消化/饿推动 nutrition；③跨阈值随机调五维；④flag 为真则 nutrition = f(五维) 校准
--   阶段跨一次：从「还有缺口」的维度随机挑一个 +-1（满的不参与，不超限）
--   饱食度：吃满一具 = +5；满 5 锁定拒食/闻不到味，<2 解锁
--   消化：每 SatDigestHours 小时消化 1 点饱食 -> nutrition += 消化 x NutPerSat
--   饿：每天 nutrition -= NutDecayDay（饱食为 0 时双倍）

local HZ = HardcoreZombies

local MAX_SAT = 5
local MAX_NUT = 5
local MAX_TIER = 4       -- modSpeedType：1 慢尸 / 2 快走尸 / 3 跑尸 / 4 假跑尸
local NUT_STEP = 0.25
local NUT_LO, NUT_HI = 0.25, 4.75
local STAGES = 18

local H_BASE, H_MAX = 0.5, 4.0
local S_MIN,  S_MAX  = 1, 4      -- 速度 4 档：1 假跑尸 / 2 跑尸 / 3 快走 / 4 慢尸（数越小越快）
local T_MIN,  T_MAX  = 1, 5      -- strength：5 最强，1 最弱（Thump 伤害倍率）
local V_MIN,  V_MAX  = 1, 3
local E_MIN,  E_MAX  = 1, 3

-- 消化 1 点饱食需要多少游戏小时
local function optDigestH()  return HZ.opt.SatDigestHours or 4 end
-- 每点饱食折算的营养量
local function optPerSat()   return HZ.opt.NutPerSat or 0.20 end
-- 营养每天的自然衰减
local function optDecayDay() return HZ.opt.NutDecayDay or 0.8 end

-- 世界流逝天数（浮点）
local function worldDays()
    local gt = getGameTime()
    local h = gt and gt:getWorldAgeHours()
    return (tonumber(h) or 0) / 24
end

-- 两段折线：0 天 init → 峰值日 peak → 归零日 min → 之后恒为 min
-- 沙盒值：调试菜单改的是 Java 侧 SandboxOptions，Lua 的 SandboxVars 不会同步
local function sandboxValue(id, def)
    local full = "HardcoreZombies." .. id

    local ok, v = pcall(function()
        local o = getSandboxOptions():getOptionByName(full)
        if o then return o:getValue() end
    end)
    if HZ.debugEnabled and HZ.debugEnabled() then
        HZ.log(string.format("sandbox %s -> ok=%s v=%s", full, tostring(ok), tostring(v)))
    end
    if ok and v ~= nil then return tonumber(v) or v end

    local m = SandboxVars and SandboxVars.HardcoreZombies
    local lv = m and m[id]
    if lv ~= nil then return tonumber(lv) or lv end

    return def
end

-- 四段生命曲线：初始值 → 峰值 → 线性衰减 → 归零
local function curve(d, init, peak, minV, peakDay, zeroDay)
    if peakDay < 1 then peakDay = 1 end
    if zeroDay <= peakDay then zeroDay = peakDay + 1 end

    -- 沙盒选项优先（CurveExp 不在 ModOptions 里）
    local e = tonumber(sandboxValue("CurveExp", HZ.opt.CurveExp or 2.0)) or 2.0

    if d <= 0 then return init end

    -- 上升段：t^e → 前段平，末尾陡升到峰值
    if d < peakDay then
        local t = d / peakDay
        return init + (peak - init) * (t ^ e)
    end

    if d >= zeroDay then return minV end

    -- 下降段：t^e → 峰值附近保持，末尾陡降
    local t = (d - peakDay) / (zeroDay - peakDay)
    return peak + (minV - peak) * (t ^ e)
end

-- 首次进表时算一次，之后不再变（"每只丧尸只衰减一次"）
--   饱食度：绝对值 0~5
--   营养值：百分比 0~100，乘到 f(五维) 上
-- 10 秒缓存：首拉 116 只丧尸时，不缓存会打 1160 次 sandbox 查询
-- 缓存很短，调试菜单改值 10 秒内生效
local function initValues()
    local nowMs = getTimestampMs()
    local c = HZ._initVals
    if c and (nowMs - c.at) < 10000 then return c.sat, c.nutK end

    local d = worldDays()

    -- 沙盒优先（含调试菜单的运行时修改），没有则回退 ModOptions 默认
    local function n(id, def)
        local v = sandboxValue(id, HZ.opt[id])
        return tonumber(v) or def
    end

    local sat = curve(d,
        n("SatInit", 3.0), n("SatPeak", 3.0), n("SatMin", 0.0),
        n("SatPeakDay", 90), n("SatZeroDay", 180))

    local nutPct = curve(d,
        n("NutInit", 100), n("NutPeak", 100), n("NutMin", 0),
        n("NutPeakDay", 90), n("NutZeroDay", 360))

    HZ._initVals = { at = nowMs, sat = sat, nutK = nutPct / 100 }
    return sat, nutPct / 100
end

-- 当前世界时间（小时，浮点）
local function nowHours()
    local gt = getGameTime()
    local v = gt and gt:getWorldAgeHours()
    return tonumber(v) or 0
end

-- ===================== 五维读写（走 bridge） =====================
-- 桥返回值统一夹到合法区间（桥异常/-1/浮点误差都不许漏进来）
local function clampv(v, lo, hi, fallback)
    v = tonumber(v)
    if not v or v ~= v then return fallback end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- 读血量（营养的基准）
local function getHealth(z)
    local ok, v = pcall(function() return z:getHealth() end)
    return clampv(ok and v, H_BASE, H_MAX, H_BASE)
end
-- 写血量，越界夹取
local function setHealth(z, v)
    pcall(function() z:setHealth(clampv(v, H_BASE, H_MAX, H_BASE)) end)
end

-- ===================== modSpeedType（4 档） =====================
-- 引擎没有"假跑尸"标志位，但 (speedType, walkVariant) 能唯一反推：
--   1 + ZombieWalk1 = 4 假跑尸     1 + ZombieWalk2 = 3 跑尸
--   2 + ZombieWalk2 = 2 快走尸     3 + ZombieWalk1 = 1 慢尸
local function readTier(z)
    local st, wv
    HZ.try("readTier", function() st = z:getSpeedType(); wv = z.walkVariant end)
    st = tonumber(st)
    if st == 1 then return (wv == "ZombieWalk1") and 4 or 3 end
    if st == 2 then return 2 end
    return 1
end

-- 读速度维：档位反过来当数据值（1 假跑尸 = 最快，4 慢尸 = 最慢）
local function getSpeed(z)
    return clampv(5 - readTier(z), S_MIN, S_MAX, S_MAX)
end
-- 读力量：5 最强，1 最弱
local function getStrength(z)
    if HZ_getStrength then
        local ok, v = pcall(HZ_getStrength, z)
        if ok then return clampv(v, T_MIN, T_MAX, T_MAX) end
    end
    return T_MAX
end
-- 读视力：1 最好，3 最差
local function getSight(z)
    if HZ_getSight then
        local ok, v = pcall(HZ_getSight, z)
        if ok then return clampv(v, V_MIN, V_MAX, V_MAX) end
    end
    return V_MAX
end
-- 读听力：1 最好，3 最差
local function getHearing(z)
    if HZ_getHearing then
        local ok, v = pcall(HZ_getHearing, z)
        if ok then return clampv(v, E_MIN, E_MAX, E_MAX) end
    end
    return E_MAX
end
-- ===================== 营养 <-> 五维 =====================
-- 五维一共 18 档：health 7 / speed 3 / strength 4 / sight 2 / hearing 2
-- 每档 = 0.25 营养，所以 f(五维) = 0.25 + 0.25 × 已完成的档数（0.25 ~ 4.75）
local function doneSteps(z)
    local n = 0

    -- health：0.5 起步，每 0.5 一档（四舍五入，初始小数不算半档）
    n = n + math.floor((getHealth(z) - H_BASE) / 0.5 + 0.5)

    -- 其余四维：整档，好的一端分别是 1 / 5 / 1 / 1
    local sp = getSpeed(z)
    if sp < S_MAX then n = n + (S_MAX - sp) end

    local st = getStrength(z)
    if st > T_MIN then n = n + (st - T_MIN) end

    local si = getSight(z)
    if si < V_MAX then n = n + (V_MAX - si) end

    local he = getHearing(z)
    if he < E_MAX then n = n + (E_MAX - he) end

    return n
end

-- 实际营养 = f(五维)：0.5 + 0.25 × 档数
local function actualNutrition(z)
    return clampv(NUT_LO + NUT_STEP * doneSteps(z), 0, MAX_NUT, NUT_LO)
end

-- 营养值 → 阶段（0 濒死 … 4 巅峰）
local function stageOf(target)
    local s = math.floor((target - NUT_LO) / NUT_STEP)
    if s < 0 then return 0 end
    if s > STAGES then return STAGES end
    return s
end

-- 校准用：向下对齐到 0.25 网格，避免血量浮点让营养卡在阈值边界抖动
local function snap(f)
    return NUT_LO + stageOf(f) * NUT_STEP
end

-- 五维数据 -> 营养（与 doneSteps 等价，只是不碰对象）
local function nutritionFromFive(hp, sp, st, si, he)
    local n = 0
    n = n + math.floor((hp - H_BASE) / 0.5 + 0.5)
    if sp < S_MAX then n = n + (S_MAX - sp) end
    if st > T_MIN then n = n + (st - T_MIN) end
    if si < V_MAX then n = n + (V_MAX - si) end
    if he < E_MAX then n = n + (E_MAX - he) end
    return clampv(NUT_LO + NUT_STEP * n, 0, MAX_NUT, NUT_LO)
end

-- 还能涨 / 还能跌的维度（操作 s.five 数据）
local function gapsUp(f)
    local g = {}
    if f.h  < H_MAX - 0.001 then g[#g + 1] = "h" end
    if f.sp > S_MIN then g[#g + 1] = "sp" end
    if f.st < T_MAX then g[#g + 1] = "st" end
    if f.si > V_MIN then g[#g + 1] = "si" end
    if f.he > E_MIN then g[#g + 1] = "he" end
    return g
end

-- 还能继续下降的维度列表
local function gapsDown(f)
    local g = {}
    if f.h  > H_BASE + 0.001 then g[#g + 1] = "h" end
    if f.sp < S_MAX then g[#g + 1] = "sp" end
    if f.st > T_MIN then g[#g + 1] = "st" end
    if f.si < V_MAX then g[#g + 1] = "si" end
    if f.he < E_MAX then g[#g + 1] = "he" end
    return g
end

-- 改数据 + 写回引擎
local function applyFive(z, f)
    if HZ_applyStats and z then pcall(HZ_applyStats, z, f.h, f.st, f.si, f.he) end
end

-- 单维上升一格并写回引擎
local function stepUp(z, f, dim)
    if dim == "h" then
        f.h = math.min(H_MAX, f.h + 0.5)
    elseif dim == "sp" then
        f.sp = math.max(S_MIN, f.sp - 1)
    elseif dim == "st" then
        f.st = math.min(T_MAX, f.st + 1)
    elseif dim == "si" then
        f.si = math.max(V_MIN, f.si - 1)
    elseif dim == "he" then
        f.he = math.max(E_MIN, f.he - 1)
    end
    applyFive(z, f)
end

-- 单维下降一格并写回引擎
local function stepDown(z, f, dim)
    if dim == "h" then
        f.h = math.max(H_BASE, f.h - 0.5)
    elseif dim == "sp" then
        f.sp = math.min(S_MAX, f.sp + 1)
    elseif dim == "st" then
        f.st = math.max(T_MIN, f.st - 1)
    elseif dim == "si" then
        f.si = math.min(V_MAX, f.si + 1)
    elseif dim == "he" then
        f.he = math.min(E_MAX, f.he + 1)
    end
    applyFive(z, f)
end

-- PZ 的 Kahlua 没有 math.random，用引擎的 Rand
local function randInt(n)
    if n <= 1 then return 1 end
    if Rand and Rand.Next then
        local v = Rand.Next(n)
        if type(v) == "number" then return v + 1 end
    end
    return 1
end

-- 阶段跨一次：随机挑一个有缺口的维度 +-1；全满返回 false
local function adjustStats(s, dir)
    local g = (dir > 0) and gapsUp(s.five) or gapsDown(s.five)
    if #g == 0 then return false end
    local dim = g[randInt(#g)]
    if not dim then return false end

    local z = s.obj
    if not z then return false end
    if dir > 0 then stepUp(z, s.five, dim) else stepDown(z, s.five, dim) end

    -- 记下"营养系统期望的五维"，下次校准用它区分外部改动
    s.expectedFive = { h = s.five.h, sp = s.five.sp, st = s.five.st,
                       si = s.five.si, he = s.five.he }
    return true
end

-- 五维快照（用于校准检测）
local function snapshot(z)
    return {
        h  = getHealth(z),
        sp = getSpeed(z),
        st = getStrength(z),
        si = getSight(z),
        he = getHearing(z),
    }
end

-- 两组五维是否有任何一项不同
-- 校准只比这四维：速度维 sp 由 modSpeedType 派生，读回来是循环引用
local function changedNoSpeed(a, b)
    if not a or not b then return true end
    return math.abs((a.h or 0)  - (b.h or 0))  > 0.01
        or math.abs((a.st or 0) - (b.st or 0)) > 0.01
        or math.abs((a.si or 0) - (b.si or 0)) > 0.01
        or math.abs((a.he or 0) - (b.he or 0)) > 0.01
end

-- 档位和目标不符才调一次桥（桥内部会连带 speedMod / walkVariant / walkType / turnDelta）
function HZ.setModTier(z, tier)
    tier = tonumber(tier)
    if not tier or tier < 1 or tier > MAX_TIER then return false end
    if readTier(z) == tier then return true end
    local ok = false
    if HZ_applyTier then ok = HZ.try("applyTier", function() return HZ_applyTier(z, tier) end) or false end
    if HZ.debugEnabled and HZ.debugEnabled() and HZ.due("tierLog", 3000) then
        HZ.log(string.format("modSpeedType -> %d uid=%s ok=%s", tier, tostring(HZ.uidOf and HZ.uidOf(z)), tostring(ok)))
    end
    return ok
end

-- 持久化恢复：把存档里的记录写进这只丧尸的条目（读档首帧匹配时调用一次）
function HZ.statsRestore(z, rec, packed)
    if not z or not rec then return false end
    local s = HZ._zstats and HZ._zstats[z]
    if not s and HZ.statsTrackByDiff and packed then s = HZ.statsTrackByDiff(z, packed) end
    if not s then return false end

    s.nutrition = clampv(rec.nut, 0, MAX_NUT, s.nutrition)
    s.satiety   = clampv(rec.sat, 0, MAX_SAT, s.satiety)
    s.five.h    = clampv(rec.h,  H_BASE, H_MAX, s.five.h)
    s.five.sp   = clampv(rec.sp, S_MIN,  S_MAX, s.five.sp)
    s.five.st   = clampv(rec.st, T_MIN,  T_MAX, s.five.st)
    s.five.si   = clampv(rec.si, V_MIN,  V_MAX, s.five.si)
    s.five.he   = clampv(rec.he, E_MIN,  E_MAX, s.five.he)
    s.stage     = stageOf(s.nutrition)
    -- 记成"我方写入"，避免下一小时校准把它当外部改动
    s.expectedFive = { h = s.five.h, sp = s.five.sp, st = s.five.st,
                       si = s.five.si, he = s.five.he }

    if HZ_applyStats then
        pcall(HZ_applyStats, z, s.five.h, s.five.st, s.five.si, s.five.he)
    end
    -- 只恢复五维和双值；档位/装死/订单等一概不碰，交给正常维护下一拍自己收敛
    return true
end

-- ===================== 条目（僵尸对象作 key） =====================
-- 对象就是指针，拿它当 key；对象失效（getUID 拿不到）即出表。



-- 取条目：有就返回，没有就建（建条目不碰队列）
local function getEntry(z)
    if not z then return nil end

    local s = HZ._zstats and HZ._zstats[z]
    if s then return s end

    local uid = HZ.uidOf(z)
    if not uid then return nil end

    s = HZ._byUid and HZ._byUid[uid]
    if s then
        HZ._zstats[z] = s              -- 顺手登记对象 key，下次免 uid
        s.obj = z
        return s
    end

    HZ._zstats = HZ._zstats or {}
    HZ._byUid  = HZ._byUid  or {}

    local sat0, nutK = initValues()
    local base = snap(actualNutrition(z) * nutK)   -- 实际营养 × 衰减系数 = 显示营养
    s = {
        uid         = uid,
        nutrition   = base,
        satiety     = sat0,
        stage       = stageOf(base),    -- 仅供 HUD 显示
        lastHours   = nil,
        five        = snapshot(z),
        x           = (function() local ok,v = pcall(function() return z:getX() end); return ok and v or 0 end)(),
        y           = (function() local ok,v = pcall(function() return z:getY() end); return ok and v or 0 end)(),
        eatingSince = nil,
    }
    HZ._zstats[z] = s
    HZ._byUid[uid] = s
    HZ._statDirty = true

    -- 听力状态由 HZ.refreshBuffs 统一维护（这里不写，避免递归）
    return s
end-- 公开入口：把僵尸写进总表（初始化 nutrition = f(五维) 现算 + 对齐）
-- 给一只丧尸建营养条目：从桥上读五维作为基准
function HZ.statsTrack(z)
    if not z then return nil end
    local ok, dead = pcall(function() return z:isDead() end)
    if not ok or dead then return nil end
    return getEntry(z)
end

-- ===================== 吃饭 =====================
-- 开饭结算：表里没有这只僵尸就顺手建（初始值按世界天数打折）
function HZ.statsEatStart(z)
    if not z then return end
    local s = getEntry(z)
    if s and not s.eatingSince then s.eatingSince = nowHours() end
end

-- 结束进食：按实际啃食时长结算饱食度
function HZ.statsEatStop(z)
    if not z then return nil end
    local s = getEntry(z)
    if not s or not s.eatingSince then return s end

    local nowH    = nowHours()
    local elapsed = nowH - s.eatingSince
    s.eatingSince = nil
    if elapsed <= 0 then return s end

    local eatMinutes = HZ.opt.EatMinutes or 60
    local perHour    = MAX_SAT * 60 / math.max(1, eatMinutes)
    s.satiety = math.min(MAX_SAT, s.satiety + elapsed * perHour)

    return s
end

-- 实时饱食度：吃饭中按已吃时长累加（结算时同一公式）
function HZ.statsCurrentSat(z)
    if not z then return 0 end
    local s = getEntry(z)
    if not s then return 0 end
    if not s.eatingSince then return s.satiety end

    local eatMinutes = HZ.opt.EatMinutes or 60
    local perHour = MAX_SAT * 60 / math.max(1, eatMinutes)
    local v = s.satiety + (nowHours() - s.eatingSince) * perHour
    if v > MAX_SAT then v = MAX_SAT end
    if v < 0 then v = 0 end        -- 时钟回拨 / 重载后 eatingSince 在"未来"
    return v
end

-- 吃满 5：主动离开餐桌，不等尸体骨化
function HZ.statsSatiated(z)
    return HZ.statsCurrentSat(z) >= MAX_SAT
end

-- 吃饱 = 饱食满（5）。没满就继续接单、继续吃。
-- 用 statsCurrentSat 而不是 s.satiety：正在吃的进度要算进去，否则会晚一拍。
-- ===================== 营养维护（每个快照周期把 N 只各过一遍，单只约 4 秒一次） =====================
-- 处理单只：消化 / 饿 / 校准 / 静音 / 跨阈值
local function processEntry(z, s, nowH, dh)


    local digest = math.min(s.satiety, dh / optDigestH())
    if digest > 0 and HZ.debugEnabled() then
        HZ.log(string.format("digest uid=%s dh=%.3f eat=%d sat %.2f -> %.2f",
            tostring(s.uid), dh, digest, s.satiety, math.max(0, s.satiety - digest)))
    end
    s.satiety = math.max(0, s.satiety - digest)
    s.nutrition = s.nutrition + digest * optPerSat()

    local rate = optDecayDay() * ((s.satiety <= 0) and 2 or 1)
    s.nutrition = s.nutrition - rate * (dh / 24)
    s.nutrition = math.max(0, math.min(MAX_NUT, s.nutrition))

    -- 五维校准：每只自己攒满 1 游戏小时才过桥，不跟快照频率走
    if (nowH - (s.lastCalib or -1e9)) >= 1 and HZ_getStats then
        s.lastCalib = nowH
        local okS, str = pcall(HZ_getStats, z)
        if okS and str and str ~= "" then
            local hp, sp, st, si, he, x, y =
                string.match(str, "^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
            if hp then
                local nf = {
                    h  = tonumber(hp), sp = tonumber(sp), st = tonumber(st),
                    si = tonumber(si), he = tonumber(he),
                }
                s.x = tonumber(x) or s.x
                s.y = tonumber(y) or s.y

                if nf.h and nf.sp and nf.st and nf.si and nf.he then
                    -- 速度维不参与校准：引擎的 speedType 现在由 modSpeedType 派生，读回来是循环引用
                    if changedNoSpeed(s.five, nf) then
                        if s.expectedFive and not changedNoSpeed(s.expectedFive, nf) then
                            -- 五维变化 = 营养系统自己跨阈值改的：不算受伤
                            s.expectedFive = nil
                            s.hurt = nil
                        else
                            -- 外部来源（玩家打伤 / 脚本 / 引擎）：受伤 buff + 校准营养
                            s.hurt = true
                            s.nutrition = snap(nutritionFromFive(nf.h, s.five.sp or nf.sp, nf.st, nf.si, nf.he))
                            s.stage = stageOf(s.nutrition)
                        end
                        s.five.h, s.five.st, s.five.si, s.five.he = nf.h, nf.st, nf.si, nf.he
                    else
                        s.hurt = nil        -- 一整个校准周期没变化：受伤状态解除
                    end
                end
            end
        end
    end

    -- 听力：统一入口。状态 = 在队列(认领中) 或 饱食 > 2，条件不变就不写桥
    if HZ.refreshBuffs then HZ.refreshBuffs(z) end

    -- 显示营养（吃/饿推动，0.25 网格）vs 实际营养（f 五维）：不相等就随机增减一维，
    -- 每拍最多 4 格（每格 = 一次 applyStats，内部要线性扫 uid）。
    local shown = snap(s.nutrition)
    local adj = 0
    while adj < 4 do
        local actual = nutritionFromFive(s.five.h, s.five.sp, s.five.st, s.five.si, s.five.he)
        if actual < shown - 0.001 then
            if not adjustStats(s, 1) then break end
        elseif actual > shown + 0.001 then
            if not adjustStats(s, -1) then break end
        else
            break
        end
        adj = adj + 1
    end
    s.stage = stageOf(s.nutrition)      -- 仅供 HUD 显示

    -- 饿死：营养见底只设一次装死（走引擎生成器那套：低血 + 躺姿 + fakeDead），之后全交给引擎
    if HZ_fakeDead and s.nutrition <= 0.01 and not s.fakeDead then
        s.fakeDead = true
        HZ.try("fakeDeadOn", function() HZ_fakeDead(z) end)
    end

    -- 档位 = 速度维反推（sp 1→4 假跑尸 / 2→3 跑尸 / 3→2 快走 / 4→1 慢尸）
    local wantTier = 5 - (s.five and s.five.sp or S_MAX)
    if wantTier < 1 then wantTier = 1 elseif wantTier > MAX_TIER then wantTier = MAX_TIER end
    if readTier(z) ~= wantTier then HZ.setModTier(z, wantTier) end
end

-- 一轮维护 = 一个快照周期内把 N 只各过一遍
-- 间隔 = 快照周期 / N（和声音、派单用同一个"周期/队列长度"规则）
function HZ.beginStatsPass()
    local t = HZ._zstats
    if not t then return end

    local keys = {}
    for z in pairs(t) do keys[#keys + 1] = z end
    HZ._statPass = { keys = keys, pos = 0, n = #keys }
end

-- 每帧最多推进一只；轮完清空，等下一次 beginStatsPass
function HZ.tickStatsStep()
    local t = HZ._zstats
    local pass = HZ._statPass
    if not t or not pass then return end

    local n = pass.n
    if n <= 0 then HZ._statPass = nil; return end

    -- 4 秒周期 / N 只：N=116 → 34ms 一只；N=1000 → 4ms 一只
    if not HZ.due("stats", HZ.snapIntervalMs() / n) then return end

    pass.pos = pass.pos + 1
    local z = pass.keys[pass.pos]
    local s = z and t[z]

    if s then
        local nowH = nowHours()
        if s.lastHours == nil then
            s.lastHours = nowH
            s.lastCalib = s.lastCalib or nowH
        else
            local dh = nowH - s.lastHours
            s.lastHours = nowH
            if dh < 0 then dh = 0 end
            processEntry(z, s, nowH, dh)
        end
    end

    if pass.pos >= n then HZ._statPass = nil end
end

-- 热重载/退场前统一结算所有正在吃的条目
function HZ.statsFlushAll()
    local t = HZ._zstats
    if not t then return end
    local nowH = nowHours()
    for uid, s in pairs(t) do
        if s and s.eatingSince then
            local eatMinutes = HZ.opt.EatMinutes or 60
            local perHour = MAX_SAT * 60 / math.max(1, eatMinutes)
            s.satiety = math.min(MAX_SAT, s.satiety + (nowH - s.eatingSince) * perHour)
            s.eatingSince = nil
        end
    end
end

-- ===================== diff 接口（对象 + 打包串） =====================
-- packed = "uid|hp|sp|st|si|he"
-- 对象作主键；uid 只进 _byUid 做 O(1) 兜底（包装换了 / 将来持久化）
function HZ.statsTrackByDiff(z, packed)
    if not z or not packed then return nil end

    HZ._zstats = HZ._zstats or {}
    HZ._byUid  = HZ._byUid  or {}

    -- 同一对象已在表里：不动
    local s = HZ._zstats[z]
    if s then return s end

    local uid, hp, sp, st, si, he =
        string.match(packed, "^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if not uid then return nil end

    -- 同一 uid 的旧条目（Lua 包装换过）：迁到新对象 key
    s = HZ._byUid[uid]
    if s then
        HZ._zstats[z] = s
        s.obj = z
        return s
    end

    -- 判活：失效对象传进桥是 null，桥返回 bit0=1，不抛错
    if HZ_orderState then
        local okS, state = pcall(HZ_orderState, z, nil)
        if okS and ((tonumber(state) or 1) % 2 >= 1) then return nil end
    end

    local hN  = clampv(tonumber(hp), H_BASE, H_MAX, H_BASE)
    local spN = clampv(5 - readTier(z), S_MIN, S_MAX, S_MAX)   -- 速度维 = 档位反推（原版假跑尸 = 1）
    local stN = clampv(tonumber(st), T_MIN,  T_MAX, T_MIN)
    local siN = clampv(tonumber(si), V_MIN,  V_MAX, V_MAX)
    local heN = clampv(tonumber(he), E_MIN,  E_MAX, E_MAX)

    local sat0, nutK = initValues()
    local base = snap(nutritionFromFive(hN, spN, stN, siN, heN) * nutK)

    s = {
        uid         = uid,
        obj         = z,
        nutrition   = base,
        satiety     = sat0,
        stage       = stageOf(base),    -- 仅供 HUD 显示
        lastHours   = nil,          -- 第一次轮到只校准、不打分
        five        = { h = hN, sp = spN, st = stN, si = siN, he = heN },
        x           = 0,            -- 坐标不随 diff 传；小时校准/调试时现取
        y           = 0,
        eatingSince = nil,
    }
    HZ._zstats[z] = s
    HZ._byUid[uid] = s
    s.lastCalib = nowHours()      -- 刚用快照五维建过，一小时后才需要校准
    HZ._statDirty = true

    -- 建好条目立刻按当前条件写一次 buff（把重载/读档留下的旧值纠正过来）
    if HZ.refreshBuffs then HZ.refreshBuffs(z) end
    return s
end


-- 出表：对象主键 O(1)；包装失效时用 uid 兜底，防条目泄漏
function HZ.statsDropByDiff(z)
    if not z then return end

    local s = HZ._zstats and HZ._zstats[z]

    if not s then
        local uid = HZ.uidOf(z)
        if uid and HZ._byUid then s = HZ._byUid[uid] end
    end

    if s then
        if s.obj and HZ._zstats then HZ._zstats[s.obj] = nil end
        if HZ._zstats then HZ._zstats[z] = nil end
        if s.uid and HZ._byUid then HZ._byUid[s.uid] = nil end
        HZ._statDirty = true
    end

    -- 状态只在 modData 上，没有 Lua 副本要清

    -- 派单表：对象 key O(1)；miss 时才按 uid 扫一次（罕见路径）
    local target, o = z, (HZ._orders and HZ._orders[z])
    if not o and s and s.uid and HZ._orders then
        for zz, oo in pairs(HZ._orders) do
            if oo.uid == s.uid then target, o = zz, oo; break end
        end
    end
    if o then
        if HZ.releaseOrder then pcall(HZ.releaseOrder, target, o, false)
        else HZ._orders[target] = nil end
    end
end

-- OnZombieDead：当场出表，不等下一次 diff
function HZ.statsDrop(z)
    if HZ.statsDropByDiff then HZ.statsDropByDiff(z) end
end

print("[HZ_Stats] loaded")
