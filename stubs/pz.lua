---@meta
-- PZ 全局接口 stub（只给 IDE 看，PZ 不加载这个目录）
-- 覆盖 HardcoreZombies 实际用到的全局函数、全局表与常用类方法

-- ===== 全局函数 =====
---@return number 现实时间戳（毫秒）
function getTimestampMs() end

---@return IsoCell
function getCell() end

---@param obj any
---@param class string
---@return boolean
function instanceof(obj, class) end

---@return Core
function getCore() end

---@param playerIndex integer
---@param x number
---@param y number
---@param z number
---@return number
function isoToScreenX(playerIndex, x, y, z) end

---@param playerIndex integer
---@param x number
---@param y number
---@param z number
---@return number
function isoToScreenY(playerIndex, x, y, z) end

---@return World
function getWorld() end

---@param index? integer
---@return IsoPlayer
function getPlayer(index) end

---@param name string
---@return FileWriter
function getFileWriter(name, ...) end
function getFileReader(name, ...) end

---@return TextManager
function getTextManager() end

---@return GameTime
function getGameTime() end

---@param file string
---@return boolean
function reloadLuaFile(file) end

-- ===== Java bridge（HZ 自己的 Java 方法） =====
---@param zombie IsoZombie
---@param value integer
function HZ_setGroup(zombie, value) end

---@param zombie IsoZombie
---@return integer
function HZ_getGroup(zombie) end

---@param zombie IsoZombie
function HZ_clearGroup(zombie) end

-- ===== 全局表 =====
---@type table
PZAPI = {}

---@type table
Events = {}

---@type table
Rand = {}

---@type table
Keyboard = {}

---@type table
UIFont = {}

---@type table
BloodBodyPartType = {}

---@type table
WorldSoundManager = {}

-- ============================================================
-- KahluaTable
-- ============================================================
---@class KahluaTable
function KahluaTable:get(k) end
function KahluaTable:put(k, v) end
function KahluaTable:rawget(k) end
function KahluaTable:rawset(k, v) end

-- ============================================================
-- IsoObject / IsoMovingObject / IsoGameCharacter
-- ============================================================
---@class IsoObject
function IsoObject:getX() end
function IsoObject:getY() end
function IsoObject:getZ() end
function IsoObject:getSquare() end
function IsoObject:getModData() end
function IsoObject:getUID() end
function IsoObject:getContainer() end
function IsoObject:getItem() end
function IsoObject:getObjectName() end
function IsoObject:transmitModData() end

---@class IsoMovingObject : IsoObject
function IsoMovingObject:DistTo(other) end
function IsoMovingObject:getMovingObjects() end

---@class IsoGameCharacter : IsoMovingObject
function IsoGameCharacter:isDead() end
function IsoGameCharacter:getDir() end
function IsoGameCharacter:setDir(dir) end
function IsoGameCharacter:setForwardIsoDirection(dir) end
function IsoGameCharacter:isFemale() end
function IsoGameCharacter:setFemale(v) end
function IsoGameCharacter:getHumanVisual() end

-- ============================================================
-- IsoZombie
-- ============================================================
---@class IsoZombie : IsoGameCharacter
function IsoZombie:isEatingOther(body) end
function IsoZombie:setEatBodyTarget(body, force) end
function IsoZombie:getEatBodyTarget() end
function IsoZombie:setBodyToEat(body) end
function IsoZombie:getEatingZombies() end
function IsoZombie:setForceEatingAnimation(v) end
function IsoZombie:pathToLocationF(x, y, z) end
function IsoZombie:faceLocationF(x, y) end
function IsoZombie:getTarget() end

-- ============================================================
-- IsoDeadBody
-- ============================================================
---@class IsoDeadBody : IsoMovingObject
function IsoDeadBody:getDeathTime() end
function IsoDeadBody:isSkeleton() end
function IsoDeadBody:setSkeleton(v) end
function IsoDeadBody:setCurrent(square) end
function IsoDeadBody:copyFrom(other) end
function IsoDeadBody:getHumanVisual() end
function IsoDeadBody:getBlood(part) end
function IsoDeadBody:setBlood(part, v) end
function IsoDeadBody:getDirt(part) end
function IsoDeadBody:setDirt(part, v) end
function IsoDeadBody:invalidateCorpse() end
function IsoDeadBody:getEatingZombies() end
function IsoDeadBody:setSkinTextureIndex(i) end
function IsoDeadBody:setSkinTextureName(name) end
function IsoDeadBody:removeFromWorld() end

-- ============================================================
-- IsoGridSquare / IsoCell
-- ============================================================
---@class IsoGridSquare
function IsoGridSquare:getX() end
function IsoGridSquare:getY() end
function IsoGridSquare:getZ() end
function IsoGridSquare:getDeadBodys() end
function IsoGridSquare:getDeadBody() end
function IsoGridSquare:getMovingObjects() end
function IsoGridSquare:getWorldObjects() end
function IsoGridSquare:addCorpse(body, b) end
function IsoGridSquare:removeCorpse(body, b) end

---@class IsoCell
function IsoCell:getGridSquare(x, y, z) end
function IsoCell:getZombieList() end

-- ============================================================
-- 玩家 / 物品
-- ============================================================
---@class IsoPlayer : IsoGameCharacter
function IsoPlayer:getInventory() end

---@class ItemContainer
function ItemContainer:getItems() end
function ItemContainer:AddWorldInventoryItem(item) end

---@class InventoryItem
function InventoryItem:getFullType() end
function InventoryItem:getName() end
function InventoryItem:setName(v) end
function InventoryItem:setCondition(v) end
function InventoryItem:setBroken(v) end
function InventoryItem:setHole(v) end
function InventoryItem:setInvalidateNextRender(v) end

-- ============================================================
-- 引擎服务
-- ============================================================
---@class GameTime
function GameTime:getWorldAgeHours() end

---@class Core
function Core:getZoom(i) end
function Core:getScreenWidth() end
function Core:getScreenHeight() end
function Core:getTileScale() end

---@class World
function World:getClimateManager() end

---@class ClimateManager
function ClimateManager:getWindIntensity() end
function ClimateManager:getWindAngleRadians() end

---@class TextManager
function TextManager:DrawString(font, x, y, text, r, g, b, a) end

---@class FileWriter
function FileWriter:write(s) end
function FileWriter:close() end

---@class WorldSoundManager
---@field instance WorldSoundManager
function WorldSoundManager:addSound(source, x, y, z, radius, volume, attract) end

-- ============================================================
-- ModOptions (PZAPI)
-- ============================================================
---@class ModOptions
function ModOptions:create(id, name) end
function ModOptions:load() end
function ModOptions:addTitle(id) end
function ModOptions:addSlider(id, name, min, max, step, default) end
function ModOptions:addTickBox(id, name, default) end
function ModOptions:addButton(id, name, tooltip, fn) end
function ModOptions:addComboBox(id, name, tooltip) end

---@class ModOptionsItem
function ModOptionsItem:getValue() end
function ModOptionsItem:addItem(label, selected) end

-- 补充：移动/状态/集合（IDE 用）
function IsoMovingObject:setX(v) end
function IsoMovingObject:setY(v) end
function IsoMovingObject:setZ(v) end
function IsoGameCharacter:setDefaultState() end
function IsoGameCharacter:faceLocationF(x, y) end
function IsoGameCharacter:getEatBodyTarget() end
function IsoGameCharacter:setEatBodyTarget(body, force) end
function IsoGameCharacter:setBodyToEat(body) end
function IsoGameCharacter:setForceEatingAnimation(v) end
function IsoGameCharacter:setCrawler(v) end
function IsoGameCharacter:setCanWalk(v) end
function IsoGameCharacter:knockDown(behind) end
function IsoGameCharacter:PlayAnimUnlooped(name) end
function IsoGameCharacter:setStateMachineLocked(v) end

---@class ArrayList
local ArrayList = {}
function ArrayList:size() end
function ArrayList:get(i) end

Events = Events or {}
function Events.Remove() end

-- 事件表（IDE 用）
local ev = { Add = function() end, Remove = function() end }
Events.OnTick = ev
Events.OnPlayerUpdate = ev
Events.OnGameStart = ev
Events.OnPostUIDraw = ev
Events.OnKeyStartPressed = ev
Events.OnDeadBodySpawn = ev
Events.LoadGridsquare = ev
Events.EveryOneMinute = ev
Events.EveryTenMinutes = ev
