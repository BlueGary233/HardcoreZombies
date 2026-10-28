-- HZ_Persist.lua — 丧尸营养状态的跨存档持久化
--
-- 思路（O 定稿）：
--   存：OnSave（单机=退出游戏时）现拉一次全量快照，和这次存档同一瞬间，
--       把每只有数据的丧尸记成 { x, y, nut, sat, 五维 }，写进 world modData。
--   取：读档后第一次拿到快照时，逐条找最近的丧尸（≤ MATCH_R 格），一对一消费。
--       同格错位无所谓——营养本来就是邻级，换谁都看不出。
--
-- 不做的事：
--   · 不存 uid：IsoMovingObject 的 uid 是 final 字段，不进存档，跨档无意义。
--   · 不存 tier：档位由五维里的 sp 反推，避免两份真相。
--   · 不自己写文件：modData 跟世界存档一起落盘（Saves/<模式>/<存档>/global_mod_data.bin）。
--     删掉 mod 后这个键没人读，不影响游戏；重装回来还能读。

local HZ = HardcoreZombies

local KEY      = "HZ_saved"     -- modData 键名，带前缀避免撞车
local VER      = 1              -- 格式版本；读到不认识的就整块丢弃
local MATCH_R  = 3.0            -- 匹配半径（格）
local MAX_LIST = 4000           -- 上限，防止异常数据把存档撑爆

-- 全局 modData（存档里的 global_mod_data.bin）。
-- IsoWorld 没有 getModData()，正确入口是 Lua 全局 ModData.getOrCreate(name)。
local GLOBAL_KEY = "HardcoreZombies"

local function worldModData()
    if not ModData or not ModData.getOrCreate then
        if not HZ._persistNoModData then
            HZ._persistNoModData = true
            HZ.log("persist: ModData 不可用，持久化关闭")
        end
        return nil
    end
    local ok, md = pcall(function() return ModData.getOrCreate(GLOBAL_KEY) end)
    if not ok or not md then return nil end
    return md
end

-- 存：OnSave 时调用。现拉快照，保证坐标和这次存档同一瞬间。
-- 快照失败重试次数：写不进去就别把旧数据留在档里
local WRITE_TRIES = 5

function HZ.persistWrite()
    local md = worldModData()
    if not md then return end

    -- 全量快照（一次 JNI，存档期间可忽略）。失败就重试，避免存进去的是过期坐标。
    local snap
    for attempt = 1, WRITE_TRIES do
        HZ.pullSnapshot()
        local s0 = HZ._snap
        if s0 and (s0.n or 0) > 0 then snap = s0 break end
        HZ.log(string.format("persist: snapshot attempt %d/%d failed", attempt, WRITE_TRIES))
    end

    if not snap then
        md[KEY] = nil
        HZ.log("persist: no snapshot after " .. WRITE_TRIES .. " tries, cleared saved data")
        return
    end

    local list = {}
    local stats = HZ._zstats or {}
    for i = 1, snap.n do
        local z = snap.obj[i]
        local s = z and stats[z]
        if s and s.five then
            list[#list + 1] = {
                x = snap.x[i], y = snap.y[i],
                nut = s.nutrition, sat = s.satiety,
                h = s.five.h, sp = s.five.sp, st = s.five.st,
                si = s.five.si, he = s.five.he,
            }
            if #list >= MAX_LIST then break end
        end
    end

    md[KEY] = { v = VER, list = list }
    HZ.log(string.format("persist: saved %d zombies", #list))
end

-- 取：读档后第一次快照就绪时调用；跑一次就再也不碰。
function HZ.persistRestore()
    if HZ._restored then return end

    local md = worldModData()
    if not md then return end
    local saved = md[KEY]
    if type(saved) ~= "table" then HZ._restored = true return end
    if tonumber(saved.v) ~= VER or type(saved.list) ~= "table" then
        -- 版本不认识或结构坏了：丢弃，不污染逻辑
        HZ.log("persist: saved data has unknown version, ignored")
        HZ._restored = true
        return
    end

    -- 时机固定：等第一次扫全图（尸体扫描）完成后再恢复，避免和初始扫描抢对象
    if HZ.initialScanDone and not HZ.initialScanDone() then return end

    local snap = HZ._snap
    if not snap or (snap.n or 0) == 0 then return end   -- 快照还没来，下一拍再试

    HZ._restored = true                                  -- 只跑一次
    if not HZ.statsRestore then return end

    local r2 = MATCH_R * MATCH_R
    local used = {}
    local matched, missed = 0, 0

    for _, rec in ipairs(saved.list) do
        if type(rec) == "table" and tonumber(rec.x) and tonumber(rec.y) then
            local best, bestD = nil, nil
            for i = 1, snap.n do
                local z = snap.obj[i]
                if z and not used[z] then
                    local dx = (snap.x[i] or 0) - rec.x
                    local dy = (snap.y[i] or 0) - rec.y
                    local d = dx * dx + dy * dy
                    if d <= r2 and (not bestD or d < bestD) then best, bestD = i, d end
                end
            end

            if best then
                local z = snap.obj[best]
                used[z] = true
                if HZ.statsRestore(z, rec, snap.stats[best]) then
                    matched = matched + 1
                else
                    missed = missed + 1
                end
            else
                missed = missed + 1
            end
        end
    end

    HZ.log(string.format("persist: restored %d / %d (miss %d, r=%.1f)",
        matched, #saved.list, missed, MATCH_R))

    -- 副本保留：热重载（Lua 重跑）后 _restored 清空，会再恢复一次，
    -- 正好可以验证"热重载时状态是否留存"。下次 OnSave 会覆盖它。
end

-- 退出游戏存档时写入（单机唯一的存档时机）
-- 热重载会重新执行本文件，用标志防止重复挂钩
if not HZ._persistHooked then
    HZ._persistHooked = true
    Events.OnSave.Add(function()
        local ok, err = pcall(HZ.persistWrite)
        if not ok then HZ.log("persist: write failed: " .. tostring(err)) end
    end)
end

print("[HZ_Persist] loaded")
