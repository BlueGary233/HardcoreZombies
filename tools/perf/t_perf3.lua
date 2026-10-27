-- 性能基准：500 具尸体 + 200 只丧尸，模拟 600 秒游戏时间
-- 用与 t_sim 相同的引擎桩，但走真实入口 HZ.onBodySpawn / HZ._snap / HZ.tickList

CNT = { orderState=0, idle=0, eatTgt=0, bodyToEat=0, forceAnim=0, setBuff=0, clearTgt=0 }
local NOW = 0
function getTimestampMs() return NOW end
local function mksq(x, y, z)
  local sq = { x=x, y=y, z=z, __sq=true,
           isOutside = function() return true end,
           getRoom = function() return nil end,
           getRoomID = function() return -1 end,
           getX = function(self) return self.x end,
           getY = function(self) return self.y end,
           getZ = function(self) return self.z end,
           getDeadBodys = function(self)
             local list = {}
             for i = 1, #BODIES do
               local b = BODIES[i]
               if not b.boned and math.floor(b.x) == self.x and math.floor(b.y) == self.y then
                 list[#list+1] = b
               end
             end
             return { size = function() return #list end,
                      get = function(_, i) return list[i+1] end }
           end }
  return sq
end
local CELL = { getGridSquare = function(self, x, y, z) return mksq(x, y, z) end }
function getCell() return CELL end
function getWorld() return { getClimateManager = function() return {
  getWindIntensity = function() return 0.5 end,
  getWindAngleRadians = function() return 0 end } end } end
WorldSoundManager = { instance = { addSound = function() end } }
function instanceof(o, c) return c == "IsoDeadBody" and o.__body == true end
function getGameTime() return { getWorldAgeHours = function() return NOW / 3600000 end } end
function getSandboxOptions() return { getOptionByName=function() return nil end, getDayLengthMinutes=function() return 60 end } end
getText = function(s) return s end
Keyboard = { KEY_0 = 48 }
Events = setmetatable({}, { __index = function() return { Add=function() end, Remove=function() end } end })
Rand = { Next = function(n) return math.floor(os.time()) % n end }
SandboxVars = {}
PZAPI = nil

ZOMBIES, BODIES = {}, {}
local function uid_seq() local n = 0; return function(p) n = n + 1; return p .. n end end
local nextZUid, nextBUid = uid_seq(), uid_seq()

local function makeZombie(x, y)
  local z = { __zombie = true, uid = nextZUid("z"), x = x, y = y,
              target = nil, eatBody = nil, forceAnim = false, dead = false }
  function z:getX() return self.x end
  function z:getY() return self.y end
  function z:getZ() return 0 end
  function z:getUID() return self.uid end
  function z:isDead() return self.dead end
  function z:getSquare() if self.dead then return nil end return mksq(math.floor(self.x), math.floor(self.y), 0) end
  function z:DistTo(o) local dx,dy = self.x-o.x, self.y-o.y; return math.sqrt(dx*dx+dy*dy) end
  function z:setDefaultState() CNT.idle = CNT.idle + 1 end
  function z:pathToLocationF(tx, ty) self.target = { x = tx, y = ty } end
  function z:getPathFindBehavior2()
    return { isGoalNone = function() return self.target == nil end,
             getTargetX = function() return self.target and self.target.x or 0 end,
             getTargetY = function() return self.target and self.target.y or 0 end,
             getTargetZ = function() return 0 end }
  end
  function z:setEatBodyTarget(b) CNT.eatTgt = CNT.eatTgt + 1; self.eatBody = b end
  function z:setBodyToEat(b) CNT.bodyToEat = CNT.bodyToEat + 1; self.eatBody = b end
  function z:getEatBodyTarget() return self.eatBody end
  function z:setForceEatingAnimation(v) CNT.forceAnim = CNT.forceAnim + 1; self.forceAnim = v end
  ZOMBIES[#ZOMBIES+1] = z
  return z
end

local function makeBody(x, y, z)
  local b = { __body = true, uid = nextBUid("b"), x = x, y = y, z = z or 0,
              eatProgress = 0, boned = false, deathTime = 0 }
  function b:getUID() return self.uid end
  function b:getX() return self.x end
  function b:getY() return self.y end
  function b:getZ() return self.z end
  function b:getSquare() if self.boned then return mksq(math.floor(self.x), math.floor(self.y), 0) end return mksq(math.floor(self.x), math.floor(self.y), 0) end
  function b:isSkeleton() return self.boned end
  function b:isFakeDead() return false end
  function b:getDeathTime() return self.deathTime end
  function b:getContainer() return nil end
  function b:getHumanVisual() return nil end
  BODIES[#BODIES+1] = b
  return b
end

local PILE_MD = {}
function HZ_setPile(z, p) PILE_MD[z] = p end
function HZ_getPile(z) return PILE_MD[z] or 0 end
function HZ_setBuff() CNT.setBuff = CNT.setBuff + 1 end
function HZ_getBuff() return 0 end
function HZ_clearTarget(z) CNT.clearTgt = CNT.clearTgt + 1; z.target = nil end
function HZ_orderState(z, body) CNT.orderState = (CNT.orderState or 0) + 1
  if not z then return 1 end
  local s = 0
  if z.dead then s = s + 1 end
  if z.eatBody then s = s + 2 end
  if body and not body.boned then s = s + 8 end
  return s
end
function HZ_findBody(x, y, z, uid)
  for i = 1, #BODIES do local b = BODIES[i]; if b.uid == uid and not b.boned then return b end end
  return nil
end
function HZ_applyStats() return true end
function HZ_getStats() return "" end
function HZ_resetDiff() end
-- 让 diffTick 真的跑起来：模拟 Java 每 4 秒给的丧尸帧
function HZ_zombieFrame()
  local o, xs, ys = {}, {}, {}
  for i = 1, #ZOMBIES do
    local z = ZOMBIES[i]
    o[i], xs[i], ys[i] = z, z.x, z.y
  end
  return { obj = o, x = xs, y = ys, n = #ZOMBIES, m = 0, removed = {} }
end
function HZ_applySprint() end

HardcoreZombies = { opt = {}, _throttle = {}, _tryFail = {}, _zstats = {}, _byUid = {},
  _orders = {}, _boneUids = {}, _snapGen = 0, piles = {}, corpses = {},
  BUFF = {NEW=1,QUEUED=2,HUNGRY=4,MUTE=8,HURT=16} }
local HZ = HardcoreZombies
-- 脚本放在 tools/perf/ 下，按自身位置推导 mod 的 lua 目录
local scriptDir = (arg and arg[0] and arg[0]:match("^(.*)[/\]")) or "."
local base = scriptDir .. "/../../42/media/lua/client/"
for _, f in ipairs{"HZ_Base","HZ_Orders","HZ_Sound","HZ_Stats","HZ_Pile","HZ_Diff"} do
  dofile(base .. f .. ".lua")
end
HZ.opt = {
  MaxEaters = 4, EatDistance = 1.0, EatMinutes = 60, EmitInterval = 2,
  PileSize = 3, RadiusMin = 80, RadiusMax = 120, BoneHours = 999,
  SatDigestHours = 1, NutPerSat = 0.5, NutDecayDay = 0.8, BlockMs = 5000,
  LongBlockMs = 60000, DebugMode = false, CountFull = 25, StinkFullHours = 9,
  RotMin = 0, RotMax = 0, VolumeMin = 10, VolumeMax = 100,
}
HZ.statsEatStart = function() end
HZ.statsEatStop = function() end
HZ.statsTrack = function() end

-- ===================== 场景：200 具尸体 × 2.5 堆/格区，200 只丧尸 =====================
-- 25 个尸堆，每堆 20 具（5×4 的密集堆），丧尸 200 只撒在周围
local PILES = 500
local BODIES_PER_PILE = 1
local cx0, cy0 = 1000, 1000
local made = 0
for p = 0, PILES - 1 do
  local px = cx0 + (p % 25) * 6
  local py = cy0 + math.floor(p / 25) * 6
  local b = makeBody(px + 0.5, py + 0.5, 0)
  HZ.onBodySpawn(b)
  made = made + 1
end
print("尸体:", made, "堆:", #HZ.piles)

for i = 1, 400 do
  local a = i * 0.37
  makeZombie(cx0 + 30 + math.cos(a) * 26, cy0 + 30 + math.sin(a) * 26)
end

-- ===================== 驱动 =====================
local FRAME = 1000 / 60          -- 60fps
local SECONDS = 600
local frames = SECONDS * 60
local perSec, maxCall = {}, 0
local tickSum, tickMax, tickCnt = {}, {}, {}
local clock = os.clock

local t0 = clock()
local secStart = clock()
local sec = 0

for f = 1, frames do
  NOW = NOW + FRAME

  -- Loader 是每 3 帧跑一次 tickList
  if f % 3 == 0 then
    local c0 = clock()
    for i = 1, #HZ.tickList do
      local fn = HZ.tickList[i]
      local t1 = clock()
      local ok, err = xpcall(HZ[fn], debug.traceback)
      local d1 = clock() - t1
      tickSum[fn] = (tickSum[fn] or 0) + d1
      tickCnt[fn] = (tickCnt[fn] or 0) + 1
      if d1 > (tickMax[fn] or 0) then tickMax[fn] = d1 end
      if not ok and not _G._firstErr then
        _G._firstErr = true
        print("ERR " .. fn .. ": " .. tostring(err))
      end
    end
    local dt = clock() - c0
    if dt > maxCall then maxCall = dt end
  end

  -- 丧尸朝它的目标慢慢走（模拟引擎移动），吃的时候不动
  for i = 1, #ZOMBIES do
    local z = ZOMBIES[i]
    if z.target and not z.eatBody then
      local dx, dy = z.target.x - z.x, z.target.y - z.y
      local d = math.sqrt(dx*dx + dy*dy)
      if d > 0.05 then
        local sp = math.min(d, 0.02)
        z.x, z.y = z.x + dx / d * sp, z.y + dy / d * sp
      end
    end
  end

  if f % 60 == 0 then
    sec = sec + 1
    perSec[sec] = clock() - secStart
    secStart = clock()
  end
end
local total = clock() - t0

-- 统计
local sum, mx, mxSec = 0, 0, 0
for i = 1, #perSec do
  sum = sum + perSec[i]
  if perSec[i] > mx then mx, mxSec = perSec[i], i end
end
local avg = sum / math.max(1, #perSec)
local orders, eat, withTgt = 0, 0, 0
for _ in pairs(HZ._orders or {}) do orders = orders + 1 end
for i = 1, #ZOMBIES do
  local z = ZOMBIES[i]
  if z.eatBody then eat = eat + 1 end
  if z.target then withTgt = withTgt + 1 end
end
local bones = 0
for i = 1, #BODIES do if BODIES[i].boned then bones = bones + 1 end end

-- 稳态统计：跳过前 5 秒的建堆/首派单
local st, stn, stmax = 0, 0, 0
for i = 6, #perSec do
  st = st + perSec[i]; stn = stn + 1
  if perSec[i] > stmax then stmax = perSec[i] end
end
local sorted = {}
for i = 6, #perSec do sorted[#sorted+1] = perSec[i] end
table.sort(sorted)
local p95 = sorted[math.max(1, math.floor(#sorted * 0.95))] or 0

print(string.format("模拟 %d 秒 | 实际耗时 %.2fs", SECONDS, total))
print(string.format("稳态(跳过前5s): 均值 %.2f ms/s | p95 %.2f ms | 峰值 %.2f ms",
  (st / math.max(1, stn)) * 1000, p95 * 1000, stmax * 1000))
print(string.format("Lua 每秒均值 %.2f ms | 最差一秒 %.2f ms（第 %d 秒）| 单次 tickList 峰值 %.2f ms",
  avg * 1000, mx * 1000, mxSec, maxCall * 1000))
print(string.format("订单=%d 在吃=%d 有目标=%d 骨化=%d 堆=%d", orders, eat, withTgt, bones, #HZ.piles))
local jni = CNT.eatTgt + CNT.bodyToEat + CNT.forceAnim + CNT.idle + CNT.clearTgt + CNT.setBuff
print("orderFlags(=orderState) 调用:", CNT.orderState)
print(string.format("引擎调用次数: eatTgt=%d bodyToEat=%d forceAnim=%d idle=%d clearTarget=%d setBuff=%d  合计=%d",
  CNT.eatTgt, CNT.bodyToEat, CNT.forceAnim, CNT.idle, CNT.clearTgt, CNT.setBuff, jni))
print("各 tick 占用（总计 ms / 单次峰值 ms / 次数）：")
for _, fn in ipairs(HZ.tickList) do
  print(string.format("  %-14s %8.2f  %6.2f  %5d",
    fn, (tickSum[fn] or 0) * 1000, (tickMax[fn] or 0) * 1000, tickCnt[fn] or 0))
end
