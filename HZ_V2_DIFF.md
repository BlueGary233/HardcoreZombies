# v2 与旧版 HZ_Orders 的逻辑差异清单

对比对象：
- 旧版：`bak/2026-10-25_pre-arch2/HZ_Orders.lua`（1058 行）
- 新版：`42/media/lua/client/HZ_Orders.lua`（约 600 行）

## 一、被新结构取代（不需要补）

| 旧逻辑 | 位置 | v2 替代 |
|---|---|---|
| `refillQueue` / `considerZombie` | 旧 763 / 655 | `claimScan` 认领扫描 |
| `dispatchOne` + `cellOrders` 聚合 | 旧 854 | `dispatchCell`（餐位 = 格子属性） |
| `footBodyAt` 脚下扫描 | 旧 264 | 同格尸体可互换，只处理顶层 |
| `otherRecInPile` 堆内换尸体 | 旧 288 | 同上，格子内不再挑 |
| `queueCap`（1.1 倍容量闸） | 旧 769 | 餐位天然限制 |
| `queueNext` 踢人 | 旧 100 | 不再需要 |
| `assignCircle` | 旧 622 | `claimScan` 内联 |
| `recByUid` / `foodSet` 缓存 | 旧 236 / 252 | 不再按尸体挑人 |
| `navBump` 诊断计数 | 旧 144 | 删除 |
| refill / assign 日志 | 旧多处 | `round:` / `cell (...)` 日志 |

## 二、丢了、我认为该补

| # | 机制 | 旧版行为 | v2 现状 | 后果 |
|---|---|---|---|---|
| 1 | 引擎残留 eatBodyTarget | `staleTarget`：目标尸体已删但引擎还挂着 → 清掉 | 无 | 丧尸对着空气保持啃咬动画 |
| 2 | 释放后的尸体冷却 | `rec.blocked[z] = now + BlockMs`（5 秒） | 只有卡住分支给「格子」60 秒冷却，其它释放路径没有 | 同一只丧尸下一轮立刻被派回同一格 |
| 3 | 到达后转向 | `faceLocationF(body)` + `faceNext` | 无 | 视觉上背对尸体吃 |
| 4 | 进食指令重发节流 | 8 秒一次；注释明确写了每拍重设会把状态机推回 idle | 每 2 秒 `setDefaultState` + `setEatBodyTarget` | 可能一顿一顿 |
| 5 | 派单/认领的死亡清理 | `purgeIfGone` 在 refill 和 dispatch 各一次 | 只在 `checkOrder` 里检查 | 队列里可能残留死丧尸到下一轮 |
| 6 | 室内堆按房间格扫描 | `refillFromRoom` 扫 `room:getSquares()` | 用 `pile.x/y` 半径 12 近似 | 大房间边缘的丧尸认领不到 |
| 7 | 派单时 `statsTrack` | `dispatchOne` 里调 | 不调（`getEntry` 懒建） | 我认为多余，不用补 |

## 三、判断为多余（不建议恢复）

- `purgeIfGone` 里清 `_zstats` 的部分：v2 由快照 `removed` 清理
- `queueCap` 的 1.1 倍余量
- `navBump` 计数与 30 秒诊断
- `_orderStateProbed` 探针
- `orderFlags` 的 bit2/bit3 组合：v2 直接读 `getEatBodyTarget()` + 尸体表

## 四、建议

优先补 1、2、4（影响体验/正确性），3 次之，5、6 看实际测试。

## 五、按 O 的决定处理结果

| # | 决定 | 状态 |
|---|---|---|
| 1 | 该补 | ✅ 已补：`clearStaleEatTargets`，每轮清掉指向已消失尸体的 eatBodyTarget |
| 2 | 格子 10 秒 + 尸体冷却 | ✅ 已补：`CELL_BLOCK_MS=10000`；`releaseOrder` 给该尸体加 `BlockMs`，派单时跳过 |
| 3 | 要有 | ✅ 已补：首次到达 `faceLocationF(c.x, c.y)`，只做一次 |
| 4 | 不需要，只要别对在吃的续单 | ✅ 已改：`ord.eating` 为真直接 return，不再重发 |
| 5 | 不需要 | — |
| 6 | 恢复室内尸堆 | ✅ 已补：室内按 `room:getSquares()` 认领（旧 refillFromRoom 行为） |
| 7 | 不需要 | — |

额外修掉：`buildPile` 的第一具尸体原先没写进 `HZ.corpses`，导致每个新堆的第一格永远不派单。
骨化尸体：`feed` 已跳过、`dispatchCell` 增加 `isBone` 检查、骨化时摘除尸体表。
