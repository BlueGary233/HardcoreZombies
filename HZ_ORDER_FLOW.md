# 丧尸：进队 → 找尸体 全链路

> 对应代码：`42/media/lua/client/HZ_Orders.lua`（行号以当前版本为准）
> 三个周期任务：`tickPiles`（堆维护+发声+拉人）、`tickOneDispatch`（派单）、`tickOneOrder`（导航/进食）

## 0. 状态与字段

| 状态 | 判定 | 占餐位 | 听自定义声音 |
|---|---|---|---|
| 自由 | `hz_pile == 0` | 否 | 是 |
| 排队 | `hz_pile == pid` 且 `HZ._orders[z] == nil` | 否 | 否（静音位） |
| 有单 | `HZ._orders[z]` + `pile.orders[z]` | 是（`rec.orders`） | 否 |

- 队列不是数组：`queueCount/queueNext` 实时扫 4 秒快照，按 `hz_pile` 分桶推导。
- `pid = floor(x)*100000 + floor(y)`，认领的唯一身份。

---

## 1. 进队：`tickPiles` → `refillQueue(pile)`（周期 2s / 堆数）

**前置闸门**（`HZ_Orders.lua:763`）

1. 餐位满：`Σ rec.orders >= MaxEaters × 格数` → 直接 return，不拉人（`:778`）
2. 队列超容：`queueCount > ceil(cap×1.1)` → 用 `queueNext` 反复踢人到自由（`:791`）
3. 室内堆 → `refillFromRoom`，扫 `room:getSquares()` 的移动对象（`:800`）
4. 无气味（尸体未腐化）→ 只扫尸堆方块 ±`PileSize`（`:809`）
5. 有气味 → 圆心 `(sourceX,sourceY)`、半径 `lastRadius`（`:824`）

**逐只 `considerZombie`（`:655`）分支，按顺序命中即返回：**

| # | 条件 | 动作 | 返回 |
|---|---|---|---|
| 1 | `purgeIfGone`：对象死亡/卸载 | `leaveQueue` + 清 `_zstats` | gone |
| 2 | 无订单但引擎 `eatBodyTarget` 挂着已删尸体 | 有订单 `releaseOrder(false)`；无订单只 `clearEat` | — |
| 3 | `statsFull`（饱食 ≥ 5） | 有订单 `releaseOrder(false)`；否则 `clearEat` | full |
| 4 | 已有订单 | 死了 → `releaseOrder(false)`；尸体没了 → `releaseOrder(true)` + 回队 | ord |
| 5 | `pid ≠ 0` 且堆不存在 | `leaveQueue`（作废旧认领） | — |
| 6 | `pid ≠ 0` 且 ≠ 本堆 | 跳过（属于别的堆） | owner |
| 7 | `pid == 0` 且队列未满 | `joinQueue`（写 pid + 静音） | ok |
| 8 | 其它 | 容量不足 | cap |

---

## 2. 派单：`tickOneDispatch`（周期 `2s / 队列长度`，索引每 2 秒重建）

- 索引来源：4 秒快照里 `hz_pile ≠ 0` 且**没有订单**的丧尸，按 pid 分桶（`:985`）
- 每拍只处理 `keys[cursor]` 一个元素 → `dispatchOne(pile, mo)`（`:1029`）

**`dispatchOne`（`:854`）分支：**

| # | 条件 | 动作 |
|---|---|---|
| 1 | `purgeIfGone` | `leaveQueue` |
| 2 | 已有订单（被抢/重复） | 把 `hz_pile` 校正成订单的堆，`refreshBuffs` |
| 3 | `statsFull` | `clearEat` + `leaveQueue` |
| 4 | 统计每格订单数 `cellOrders` | — |
| 5 | 由内向外按切比雪夫环找第一具：格子未满 + 该丧尸对该 rec 无冷却 + `findBody` 成功 + 非骨架 | 命中即停 |
| 6 | 找不到 | 留在队里（`no-pick`） |
| 7 | 找到 | 清该 rec 对该丧尸的冷却 → `setDefaultState` → `clearTarget` → `refreshBuffs`（仍静音）→ 写 `_orders`/`pile.orders` → `rec.orders += 1` |

---

## 3. 导航与进食：`tickOneOrder`（周期 `2s / 订单数`）→ `navOne`

**入口判定（`:305`）**

1. 订单没有堆 → 摘掉脏订单
2. `orderFlags(z, body)`：
   - 丧尸死 → `releaseOrder(false)`，堆还在则回队
   - 尸体没了/骨化 → ①脚下 1 格 → ②堆内其他尸体（餐位转移）→ ③都没有：`releaseOrder(false)` + 回队
3. 距离 `d ≤ eatD(1.0)`（吃中时 `≤ keepD=1.2`）→ **到达分支**
4. 否则 → **导航分支**

**到达分支**

| 条件 | 动作 |
|---|---|
| 饱食满 | `releaseOrder(false)` |
| `getEatBodyTarget() ≠ body` | 每秒重发 `setEatBodyTarget(body,true)` + 强制动画；`eating=false`，不结算 |
| 目标正确 | 首次 `eating=true` + `statsEatStart`（只一次），清振荡/偏离计数 |

**导航分支**

| 顺序 | 检查 | 结果 |
|---|---|---|
| a | 若之前在吃 | `clearEat` + `statsEatStop` |
| b | `atTable`：eating / `d ≤ keepD+1.5` / (`hasTgt` 且 `d ≤ keepD+4`) | 不判卡住 |
| c | `stuckNow` | 立刻换尸体：脚下 → 堆内其他 → 都没有就 `releaseOrder(true)` 回队；旧尸加 60s 冷却 |
| d | 目标偏离：`pf:getTargetX/Y` 与 `navX/navY` 差 > 0.6，连续 2 拍 | `releaseOrder(true)` 交还餐位 |
| e | 振荡窗口：≥4 拍、总跨度 < 0.8 格（走出 2 格则窗口重开） | 置 `stuckNow`（下一拍走 c） |
| f | `needNav`：首拍 / 换尸体 | `pathToLocationF(body)`，记录 `navX/navY` |

---

## 4. 所有退出路径（`releaseOrder` 是唯一出口，`:159`）

| 触发 | requeue | 认领 |
|---|---|---|
| 饱食满 5 | false | 解除 |
| 丧尸死亡/卸载 | false | 解除 |
| 堆消失 | false | 解除 |
| 目标尸体消失且无替代 | false（然后按需回队） | 先解除再写 |
| 被拉走（目标偏离） | true | 保留 |
| 真卡住且堆内无替代 | true | 保留 |
| 容量踢人（`leaveQueue`） | — | 解除 |
| 堆被删（空堆） | `HZ.onPileGone` | 依赖 pid 失效自愈 |

---

## 5. 周期与采样

| 任务 | 周期 | 数据源 |
|---|---|---|
| 堆维护/发声/拉人 | `EmitInterval / 堆数`（默认 2s/N） | 实时 |
| 派单 | `EmitInterval / 队列长度` | 4s 快照（索引 2s 重建） |
| 导航/进食 | `EmitInterval / 订单数` | 实时位置 + 引擎目标 |
| 快照 | `EmitInterval × SnapPerPile`（默认 4s） | 引擎对象表 |

---

## 6. 我自己标出的可疑点（待审）

1. `releasePileClaims` 有定义但**没有任何调用点**：堆被删后，认领靠 `considerZombie` 里 `pileExists` 自愈，最坏慢一个 refill 周期。
2. `otherRecInPile` 只用 `rec.orders < MaxEaters`，不按“每格”统计；`dispatchOne` 用的是 `cellOrders`（每格）。两处容量口径不一致。
3. 卡住换尸体时直接 `nrec.orders += 1`，没有检查该格是否已满。
4. 回队后不会立刻派单：要等 `tickOneDispatch` 的索引重建（2s）+ 游标轮到它。
5. 被拉走的丧尸保留认领，会一直占 `queueCap` 名额；如果很多只都在外面追玩家，真正在附近的反而进不来。
6. `queueNext` 踢人时按快照顺序取，没有距离/状态优先级。
7. `atTable` 用 `hasTgt` 放宽到 `keepD+4`：卡在 4 格内的丧尸永远不会被判卡住。
