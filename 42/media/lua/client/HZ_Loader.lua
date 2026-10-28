-- HZ_Loader.lua
-- 事件只在这里注册一次。热重载只替换 HZ._onXxx 的函数引用，
-- 事件系统里始终只有这一套转发器，不会残留旧闭包。

HardcoreZombies = HardcoreZombies or {}

local HZ = HardcoreZombies

if HZ._loaderInstalled then
    return
end
HZ._loaderInstalled = true

-- 事件回调统一 pcall：出错只记录，不中断其它 mod 的 OnTick
local function safe(name, ...)
    local fn = HZ[name]
    if not fn then return end

    local ok, err = pcall(fn, ...)
    if not ok then
        print("[HZ] event error in " .. name .. ": " .. tostring(err))
    end
end

-- 事件边界：直接调模块函数，不再经过 _onXxx 转发层
-- 每 3 帧检查一次（20fps），2.1s 节拍精度足够，Lua 开销降到 1/3
Events.OnTick.Add(function()
    -- tick 顺序由 HZ.tickList 决定（HZ_Base 定义，可热重载）
    local list = HZ.tickList
    if not list then return end

    -- 平时：零测量开销，直接跑
    if not (HZ.debugEnabled and HZ.debugEnabled()) then
        for i = 1, #list do safe(list[i]) end
        return
    end

    -- Debug 打开时：累计每个 tick 的耗时，每 5 秒打一行平均值。
    -- 这一行（safe 调用）在性能面板里显示的是「所有 tick 的总和」，
    -- 想知道具体是谁贵，看这行日志。
    local acc = HZ._tickMs
    if not acc then acc = {}; HZ._tickMs = acc; acc.n = 0 end
    for i = 1, #list do
        local name = list[i]
        local t0 = getTimestampMs()
        safe(name)
        acc[name] = (acc[name] or 0) + (getTimestampMs() - t0)
    end
    acc.n = acc.n + 1

    if HZ.due("tickProf", 5000) then
        local out = {}
        for i = 1, #list do
            local name = list[i]
            out[#out + 1] = string.format("%s=%.2f", name, (acc[name] or 0) / math.max(1, acc.n))
        end
        HZ.log("tick ms(avg/frame): " .. table.concat(out, " "))
        HZ._tickMs = { n = 0 }
    end
end)

Events.OnZombieDead.Add(function(z)
    safe("statsDrop", z)
end)

-- 尸体：生成 / chunk 加载 / 开档扫描（旧版路径，diff 只负责丧尸）
Events.OnDeadBodySpawn.Add(function(body)
    safe("onBodySpawn", body)
end)

Events.LoadGridsquare.Add(function(sq)
    safe("onLoadGridsquare", sq)
end)

Events.OnPlayerUpdate.Add(function(player)
    safe("initialScan", player)
end)

Events.OnPostUIDraw.Add(function()
    safe("_onUIDraw")          -- Debug.lua 定义；DebugMode 关闭时不存在
end)

Events.OnGameStart.Add(function()
    safe("resetTables")
    if HZ.resetDiff then pcall(HZ.resetDiff) end
    safe("buildOptions")
end)




-- ===================== 热重载 =====================
function HZ.reloadMod()
    local now = getTimestampMs()
    if HZ._reloadGuard and (now - HZ._reloadGuard) < 1000 then
        return
    end
    HZ._reloadGuard = now

    -- 重载前先结算所有正在吃的条目，否则 eatingSince 记到重载之后（跨整个间隔）
    if HZ.statsFlushAll then pcall(HZ.statsFlushAll) end

    -- 清尸体上的模组数据（进食进度）。必须在这里做：
    -- dofile HZ_Pile 会重建 piles，之后旧堆连同 foods 一起丢了，找不到尸体。
    if HZ.purgeBodies then pcall(HZ.purgeBodies) end

    -- reloadLuaFile 的基准目录是 Zomboid/mods/，必须带完整相对路径
    local base = "HardcoreZombies/42/media/lua/client/"
    local files = { "HZ_Base.lua", "HZ_Pile.lua", "HZ_Orders.lua", "HZ_Stats.lua", "HZ_Sound.lua", "HZ_Diff.lua", "HZ_Persist.lua", "HZ_ZDebug.lua" }

    for i = 1, #files do
        local ok, err = pcall(reloadLuaFile, base .. files[i])
        if not ok then
            print("[HZ] reload fail " .. files[i] .. ": " .. tostring(err))
        end
    end

    -- 重新读 ini，让面板值和 option.value 同步
    if PZAPI and PZAPI.ModOptions then
        HZ.try("load", function() PZAPI.ModOptions:load() end)
    end

    -- 关键：等 ini 读完、所有文件重载完，再同步到 HZ.opt
    if HZ.reloadCfg then HZ.reloadCfg() end
    if HZ.invalidateOptCache then HZ.invalidateOptCache() end

    -- 重载后重新对齐：所有运行时状态（表 / Java 桥数据 / 节拍）一次清干净
    HZ.clearRuntimeState()
    HZ.invalidateOptCache()

    
print("[HZ] reloaded")
end

-- ===================== ModOptions 注册 =====================
local MODOPT_ID = HZ.MODOPT_ID or "HardcoreZombies"

-- 注册 ModOptions 面板项
local function buildOptions()
    if not (PZAPI and PZAPI.ModOptions) then return end

    -- 面板值变化：写回 HZ.opt 并让数值缓存失效
    local function onOptionChanged(self, value)
        local id = self and self.id
        if id and HZ.opt[id] ~= nil then
            HZ.opt[id] = value
        end
        HZ.invalidateOptCache()
    end

    local opts = PZAPI.ModOptions.Dict[MODOPT_ID]
    if opts then
        -- 已注册过：热重载不重建面板，但回调要重挂（指向新的 HZ.opt）
        opts.onChangeApply = onOptionChanged
        return
    end

    opts = PZAPI.ModOptions:create(MODOPT_ID, "HardcoreZombies")

    -- 设置变更：直接把新值写进缓存（self 是 option，带 id）
    -- 派生缓存（依赖多个设置）仍然清掉，下次用到时重建
    -- 设置变更：直接写回 HZ.opt，同时让派生缓存失效
    opts.onChangeApply = onOptionChanged

    -- 清掉多次重载累积的重复注册
    local list = PZAPI.ModOptions.Data
    for i = #list, 1, -1 do
        local it = list[i]
        if it and it.modOptionsID == MODOPT_ID and it ~= opts then
            table.remove(list, i)
        end
    end

    -- ============ 性能 ============
    opts:addTitle("UI_HZ_SectionPerf")
    opts:addSlider("EmitInterval", "UI_HZ_EmitInterval", 0.5, 5.0, 0.1, 2.0, getText("UI_HZ_EmitInterval_tip"))
    opts:addSlider("SnapPerPile", "UI_HZ_SnapPerPile", 2, 8, 1, 2, getText("UI_HZ_SnapPerPile_tip"))

    -- ============ 尸堆与进食 ============
    opts:addSeparator()
    opts:addTitle("UI_HZ_SectionPile")
    local pileCombo = opts:addComboBox("PileSize", "UI_HZ_PileSize", "UI_HZ_PileSize_tip")
    pileCombo:addItem("3x3")
    pileCombo:addItem("5x5", true)
    pileCombo:addItem("7x7")
    pileCombo:addItem("9x9")
    pileCombo:addItem("11x11")
    opts:addSlider("RotMin", "UI_HZ_RotMin", 0, 12, 0.5, 0.0, getText("UI_HZ_RotMin_tip"))
    opts:addSlider("RotMax", "UI_HZ_RotMax", 0, 12, 0.5, 2.0, getText("UI_HZ_RotMax_tip"))
    opts:addTickBox("RotRandom", "UI_HZ_RotRandom", true, getText("UI_HZ_RotRandom_tip"))
    opts:addSlider("MaxEaters", "UI_HZ_MaxEaters", 1, 10, 1, 4, getText("UI_HZ_MaxEaters_tip"))
    opts:addSlider("EatMinutes", "UI_HZ_EatMinutes", 20, 120, 1, 60, getText("UI_HZ_EatMinutes_tip"))
    opts:addSlider("BoneHours", "UI_HZ_BoneHours", 4, 24, 1, 6, getText("UI_HZ_BoneHours_tip"))

    -- ============ 气味 ============
    opts:addSeparator()
    opts:addTitle("UI_HZ_SectionSmell")
    opts:addSlider("RadiusMin", "UI_HZ_RadiusMin", 10, 100, 1, 20, getText("UI_HZ_RadiusMin_tip"))
    opts:addSlider("RadiusMax", "UI_HZ_RadiusMax", 40, 200, 1, 120, getText("UI_HZ_RadiusMax_tip"))
    opts:addSlider("VolumeMin", "UI_HZ_VolumeMin", 10, 100, 5, 10, getText("UI_HZ_VolumeMin_tip"))
    opts:addSlider("VolumeMax", "UI_HZ_VolumeMax", 10, 100, 5, 100, getText("UI_HZ_VolumeMax_tip"))
    opts:addSlider("StinkFullHours", "UI_HZ_StinkFullHours", 1, 24, 1, 9, getText("UI_HZ_StinkFullHours_tip"))
    opts:addSlider("CountFull", "UI_HZ_CountFull", 1, 100, 1, 25, getText("UI_HZ_CountFull_tip"))
    opts:addSlider("WeightRadiusAge", "UI_HZ_WeightRadiusAge", 0, 1, 0.05, 0.80, getText("UI_HZ_WeightRadiusAge_tip"))
    opts:addSlider("WeightVolumeCount", "UI_HZ_WeightVolumeCount", 0, 1, 0.05, 0.80, getText("UI_HZ_WeightVolumeCount_tip"))

    -- ============ 营养系统 ============
    opts:addSeparator()
    opts:addTitle("UI_HZ_SectionNut")
    opts:addSlider("SatDigestHours", "UI_HZ_SatDigestHours", 1, 24, 1, 4, getText("UI_HZ_SatDigestHours_tip"))
    opts:addSlider("NutPerSat", "UI_HZ_NutPerSat", 0.05, 0.5, 0.05, 0.20, getText("UI_HZ_NutPerSat_tip"))
    opts:addSlider("NutDecayDay", "UI_HZ_NutDecayDay", 0, 5, 0.1, 0.8, getText("UI_HZ_NutDecayDay_tip"))

    -- ============ 开发 ============
    opts:addSeparator()
    opts:addTitle("UI_HZ_SectionDev")
    opts:addTickBox("DebugMode", "UI_HZ_DebugMode", false, getText("UI_HZ_DebugMode_tip"))
    opts:addTickBox("Snap", "UI_HZ_Snap", false, getText("UI_HZ_Snap_tip"))
    opts:addSlider("DebugSnapMinutes", "UI_HZ_DebugSnapMinutes", 1, 60, 1, 10, getText("UI_HZ_DebugSnapMinutes_tip"))
    opts:addSlider("DebugScanRadius", "UI_HZ_DebugScanRadius", 5, 60, 1, 20, getText("UI_HZ_DebugScanRadius_tip"))
    opts:addSlider("EatDistance", "UI_HZ_EatDistance", 0.5, 3.0, 0.1, 1.0, getText("UI_HZ_EatDistance_tip"))
    opts:addSlider("BlockMs", "UI_HZ_BlockMs", 500, 30000, 500, 5000, getText("UI_HZ_BlockMs_tip"))
    opts:addSlider("LongBlockMs", "UI_HZ_LongBlockMs", 5000, 300000, 5000, 60000, getText("UI_HZ_LongBlockMs_tip"))
    opts:addSlider("PendingRetryMs", "UI_HZ_PendingRetryMs", 500, 10000, 500, 2000, getText("UI_HZ_PendingRetryMs_tip"))
    opts:addSlider("PendingGiveupMs", "UI_HZ_PendingGiveupMs", 1000, 60000, 1000, 10000, getText("UI_HZ_PendingGiveupMs_tip"))
    opts:addTickBox("FakeDeadFood", "UI_HZ_FakeDeadFood", false, getText("UI_HZ_FakeDeadFood_tip"))
    opts:addButton("ReloadMod", "UI_HZ_ReloadMod", "UI_HZ_ReloadMod_tip", HZ.reloadMod)

    HZ.try("load", function() PZAPI.ModOptions:load() end)
end

HZ.buildOptions = buildOptions
buildOptions()

-- 启动时把设置读进 HZ.opt
HZ.reloadCfg()

print("[HZ_Loader] installed")

-- ===================== 调试入口 =====================
-- 0.3.0 的做法：注册写在文件作用域（reloadMod 外面）。文件顶部有
-- `if HZ._loaderInstalled then return end`，重载/重复加载时整个文件直接 return，
-- 所以这里的注册天然只发生一次 —— 不需要第二个标志。
Events.OnKeyStartPressed.Add(function(key)
    HZ.try("keyPressed", function() HZ.onKeyPressed(key) end)
end)

-- 文件看门狗：改 Lua/HZ_reload.txt 的内容即触发重载
Events.OnTick.Add(function()
    local now = getTimestampMs()
    if now < (HZ._flagNextMs or 0) then return end
    HZ._flagNextMs = now + 1000

    local v
    for _, path in ipairs({ "Lua/HZ_reload.txt", "HZ_reload.txt" }) do
        local ok, r = pcall(getFileReader, path, false)
        if ok and r then
            pcall(function() v = r:readLine() end)
            pcall(function() r:close() end)
            if v ~= nil then break end
        end
    end
    if v == nil then return end
    if HZ._flagLast == nil then
        HZ._flagLast = v
        print("[HZ] watcher ready, flag=" .. tostring(v))
        return
    end
    if v ~= HZ._flagLast then
        HZ._flagLast = v
        print("[HZ] flag changed -> reload")
        if HZ.reloadMod then pcall(HZ.reloadMod) end
    end
end)

function HZ.onKeyPressed(key)
    if key == Keyboard.KEY_0 then
        HZ.reloadMod()
    end
end

print("[HZ] hotkey installed (key0)")
