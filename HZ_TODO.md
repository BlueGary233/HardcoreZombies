# HardcoreZombies (Rotwind) — 开发文档

> **版本 0.3.0** · 更新 2026-10-25
> 状态：0.3 的两次大重构已完成并实测通过（200 具尸体 / 4 个刷尸点 / 20 只丧尸，Debug 全开，0 报错，tick ≈ 0.7ms/帧）

---

## 版本线

| 版本 | 内容 |
|---|---|
| 0.1 | 初版：尸体气味 → `WorldSound` 吸引丧尸；尸堆、骨化、血迹 |
| 0.2 | 结构拆分：单文件拆成多文件；引入 Java 桥（`ZombieBuddy` 之上） |
| **0.3** | **两次大重构**：① 状态统一（`hz_buff` + `hz_pile`，Lua 侧零副本）② 调度重构（每类任务独立队列 + `due()`，快照载荷重做） |

---

## 当前结构

| 文件 | 职责 | 行数 |
|---|---|---|
| `HZ_Base.lua` | 常量、`HZ.BUFF` 位定义、选项默认值、`tickList`、`try`/`due`/`log`、`clearEat` | 266 |
| `HZ_Orders.lua` | 接单区、进队/退队、派单队列、导航、订单生命周期 | 1006 |
| `HZ_Stats.lua` | 五维营养、跨阈值校准、受伤判定、饱食驱动、跑尸 | 712 |
| `HZ_Pile.lua` | 尸堆建立、补扫、尸体记录、骨化、堆维护 | 904 |
| `HZ_Sound.lua` | 声源计算（半径/音量/风偏）、`emitPile` | 165 |
| `HZ_Diff.lua` | 4 秒快照、对象主键表、回收 | 130 |
| `HZ_ZDebug.lua` | 调试快照与 overlay（Debug 关时零开销） | 422 |
| `HZ_Loader.lua` | 事件注册器（**改动必须整局重启**） | 237 |

Java 侧（`java/src/com/hardcorezombies/`）：

- `HZBridge.java` — `setBuff/getBuff`、`setPile/getPile`、`clearTarget`、`findBody`、`orderState`、`scanCorpses`、`zombieFrame`、`applyStats`、`applySprint`、`resetDiff`
- `Patch_GetBiggestSoundZomb.java` — 只读静音位：`(hz_buff & 8) != 0` 的丧尸不响应引擎声源

---

## 核心设计

### 状态：只有两个字段

```
modData.hz_buff   位掩码  NEW=1 QUEUED=2 HUNGRY=4 MUTE=8 HURT=16
modData.hz_pile   认领的堆 pid = floor(x)*100000 + floor(y)
```

- **Lua 侧不存副本**，`HZ.pileOf(z)` / `HZ.queueCount(pid)` 都实时读 `modData`。
- **Buff 是纯状态，不是事件**：每轮按条件重算，只有 `bits` 变化才过桥。
- `pid` 用坐标做身份，热重载 / 读档后重建堆会算回同一个数，认领自动对上。

### 调度：每个周期任务一条队列

```
tickList = diffTick, tickStatsStep, tickPiles, tickOneDispatch, tickOneOrder
```

- 每拍只推进**一个**元素，间隔 `due(周期 / 队列长度)`。
- 堆级任务合并进 `tickPiles`；丧尸级（派单/续单/营养）必须全局队列——堆数 < 丧尸数。
- 派单按切比雪夫距离**分环由内向外**（Kahlua 没有 `table.sort`），找到第一具可派的就停。

### 接单区

- 有气味：以声源为圆心、声音半径为半径的圆，随声音一起风偏。
- 无气味（尸体未到腐化时间）：固定为**尸堆方块**。
- 室内堆：扫 `room:getSquares()`。
- 餐位满（每格 `MaxEaters`，允许 1.1 倍）→ 关闭接单，`refill ... SKIP full`。
- 风偏：`level = floor(wind*4.999)`，`off = (radius - 2*pileEdge) * level / 4`。

### 到达与进食

- 到达判定 **1 格**（`eatD = min(1, EatDistance)`，`keepD = eatD + 0.2`）。
- 目标骨化 → 先扫脚下 1 格（`footBodyAt`，uid 索引 O(1)，命中即停）→ 没有就换堆内其他尸体。
- 饱食满（`>= MAX_SAT = 5`）才出队，不是 `> 2`。

### 营养

- 五维 `hp/sp/st/si/he` 通过 `HZ_applyStats` 写回引擎；营养值由进食累积。
- 营养 ≥ `RUN_NUT = 4.5` → `HZ_applySprint`（写 `speedMod`，`makeInactive` 不会重置它）。
- 外部改过五维 → `HURT` 位；跨阈值校准后清除。

### 快照

- 4 秒一批，**对象作主键**，载荷只有 `added / stats 打包串 / removed / n / m`。
- 无 `changed`、无 `x/y/z`、无 `uid → 子表`；坐标实时 `z:getX()/getY()`。

---

## 0.3 实测结果

条件：Debug 全开，4 个刷尸点共 200 具尸体 + 20 只丧尸。

| 指标 | 结果 |
|---|---|
| 报错 | 0（`event error` / `Lua fail`） |
| 空订单 | 0（`order dead` / `no-target` / `retarget` 全 0） |
| 接单覆盖 | `ord + owner = in`，没有空闲没人管的丧尸 |
| `no-pick` | 只有容量拒绝（每格餐位满），不是找不到尸体 |
| 性能 | 总计 **0.66–0.7 ms/帧**；最大 `tickPiles` 0.45ms，无尖峰 |
| 白骨化 | 32 具全部完成，无卡在重试 |

---

## TODO（0.4 方向）

### 1. 更多气味源

先把 `HZ_Sound` 改成统一的 **source registry**，每个源带：
`位置 / 半径 / 音量 / 衰减曲线 / 生命期 / 是否随时间变化`

- [ ] **生肉**（地面物品、玩家背包/容器里的肉）
- [ ] **腐肉**（腐坏度越高气味越强）
- [ ] **玩家气味**（移动/停留累积，洗澡或换衣清除）
- [ ] **玩家血迹**（复用 `applyBlood` 的血量数据）

注意：
- `WorldSound` 同一时刻只有一个源在被争抢，多源要按距离/强度排序，别让丧尸来回跑（ping-pong）。
- 声源之间要合并/取最强，而不是各自发一条。

### 2. 扩展营养系统

现状：五维 + 营养值 → buff → 跑尸。

- [ ] 营养分层（饥饿 / 正常 / 饱食 / 超标），不同档位影响移动与感知
- [ ] 跨餐累积：连续进食有加成，长期饥饿有惩罚
- [ ] 持久化：僵尸不存档 → 只能用**区域池**（按 chunk/区域累积），不能挂丧尸身上

### 3. 特感丧尸

- [ ] 设计分化条件（营养阈值 / 病毒浓度 / 区域池等级）
- [ ] 先定种类与行为差异（跑尸 / 高血量大块头 / 会召唤的尖叫者……）
- [ ] 依赖：营养扩展 + 区域池先落地

---

## 开发注意

1. **`HZ_Loader.lua` 改动必须整局重启**（不在热重载列表，开头有 `_loaderInstalled` 早退）。
2. **Java jar 改动必须整局重启**，纯 Lua 可以热重载。
3. 热重载走 **设置面板的 ReloadMod 按钮**（按 0 的快捷键已移除）。
4. Kahlua 没有 `next/select/unpack/loadstring/setmetatable/table.sort`，离线 Lua 5.1 测试会掩盖这些差异。
5. `HZ_orderState` 的 bit0 是「已死」，普通丧尸返回 0 = 活着。
6. 状态字段不许直接写：先检查条件，条件满足才触发，且只有 `bits` 变化才过桥。
