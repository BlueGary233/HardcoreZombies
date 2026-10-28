# 更新日志

## 0.6.0

- 完成存档持久化
- 营养系统优化
- 增加伪装跑尸
- 增加"饿死"假死丧尸

## 0.4.1（行为修正：卡住 / 续单 / 拉走）

**目标只有一个：没有丧尸再"站在尸体旁边发呆"。**

### 卡住 = 只看有没有动

- 连续 **3 拍位置没变**就 `setStaggerBack(true)` 推一把，推两次还不动才换目标。
- 不再按状态机分级判断"该不该推"：翻窗、倒地、砸门都会卡，状态名只用来决定"别乱踢它的状态"。
- 新增诊断日志 `NUDGE-BEFORE` / `NUDGE-AFTER`（状态 / 寻路目标 / 进食目标 / 坐标 / 是否移动），一次推送两行对比。
- 计数器：`HZ._cNudge`、`HZ._cIdle`、`HZ._cIdleEat`、`HZ._cLured`、`HZ._cNoPath`。

### 续单

- **空转（`ZombieIdleState` / `IdleState` / `GenericDefaultState`）立即重下发导航**，不再等卡住超时。原因是引擎把路径走完后就停在 Idle，`setDefaultState + pathToLocationF` 是唯一能把它推回 `PathFind` 的手段。
- 空转且已在 **1.2 格**内 → 直接 `eatTick` 挂进食目标。
- **3 格内 = 吃饭模式**：`setBodyToEat(body)` 登记目标。引擎 `updateEatBodyTarget()` 在 `IdleState && DistToSquared <= 1.0` 时自动挂 `setEatBodyTarget`，到位即开吃；3 格外只导航，不碰进食。

### 被拉走 / 不可达

- **被拉走**（引擎寻路目标不是我们的尸体，也不在它自己脚下）= 在追玩家或声音：**连续 2 拍（约 4 秒）就出队释放餐位**，30 秒内不再派回。原来要 4 拍，且会先徒劳地重下发导航，和引擎抢目标。
- **不可达**（引擎目标 = 自己脚下）：`navFail` 连续 2 拍（约 4 秒）就换尸体/换格/释放，原来 3 拍。

### 修掉的坑

- `isClimbing()` 只反映绳索类状态：翻窗 / 翻栅栏 / 翻墙写的是 `NetworkZombieAI.isClimbing`。据此判断翻窗永远是 false，导致翻窗中的丧尸被我们 `setDefaultState` 打断、卡在窗上。改用 `getCurrentStateName()`（= 状态类的 simpleName）。
- 派单不再跳过 busy 丧尸：busy 只是"不导航、不踢状态"，不是"不给单"——不给单它们就永远不进维护流程。
- `getPath2():size()` 会抛 `attempted index: size of non-table`（`zombie.pathfind.Path` 未暴露给 Kahlua），调试模式还会连带弹出 Lua 调试器 UI，已删除。
- 去掉 `GIVEUP_MS` / 桌边 12 秒 / busy 计数等中间层，卡住处理只剩"3 拍不动 → 推"。


## 0.4.0（架构重构，已完成）

**派单方向反转：从「丧尸找尸体」改成「尸体（格子）挑丧尸」。三层队列。**

### 结构

- **尸体队列（4 秒）**：尸体按位置算出所属格子 / 堆。只做归属，不碰对象行为。
- **格子队列（2 秒内轮完一圈）**：派单 + 订单维护（导航 / 进食 / 续单）。格子多的堆占更多时间片。
- **尸堆（2 秒）**：格子重排（仅在格子集合增减时）、发声、重建可接单队列。餐位满 → 不发声、不接单。
- 堆内格子按「从堆中心外扩」排序，内圈优先填满再外扩。
- 订单 = `{ pile, cell, rec, body, uid }`，餐位 = 每格 `MaxEaters`，`rec.orders` 与格子订单表成对增减。
- 没有认领机制：订单一旦派出即锁定，只有目标失效 / 卡住超时 / 堆消失才变。

### 判据（全部对过 0.3.0 原文或引擎字节码）

- **尸体存活**：Java 桥 `orderFlags` bit3（body 有 square、未骨化）**且**该 rec 仍在堆的 `foods` 里。
- **到达**：`DistTo(body) ≤ 1.0`；`1.0~1.2` 继续吃（keepD 迟滞）；`> 1.2` 才离桌。
- **进食**：`getEatBodyTarget() == body`。吃上之后不再干预；引擎一轮进食 30~60 秒后自己清空目标，由 2 秒维护重发。
- **纠正导航**：先 `setDefaultState()` 再 `pathToLocationF()`。`IsoZombie` 覆写的 `pathToLocationF` 在 `allowRepathDelay > 0` 且处于 `PathFind/WalkToward/WalkTowardNetwork` 状态时会直接丢弃命令。
- **目标判定**：`|engineTarget - body| < 0.75`。引擎把 `targetX/Y` 写成「路径末节点」，不能做浮点全等比较。

### 派单

- 每格按「餐位 − 已派」派给最近的空闲丧尸；候选只收「在堆半径内且有餐位」的堆。
- 配额：每格每轮最多 `ceil(空闲丧尸数 / 待填格数)`，避免先轮到的格子把附近丧尸抢光。
- 卡住：路上 4 秒不动 / 桌边 12 秒不动 → 换本格下一具 → 换格 → 释放。
- 顶层尸体吃完骨化 → 同格自动续下一具；格子无尸体 → 释放其订单并回收。

### 本轮修复

- 用不存在的 `HZ.corpses` 当判据导致全量误判 → 改回 `orderFlags`。
- 重写时丢掉 `keepD` 迟滞 / `faceNext` 转向 / `maintainCell` 维护入口 → 已补回。
- `1.0~2.7` 区不发导航导致站桩 → 合并回导航分支。
- 纠正导航被引擎丢弃 → 下发前先退状态。
- 事件注册写在 `reloadMod()` 内导致监听器累积、按一次键触发 N 次重载卡死 → 移到文件作用域（靠顶部 `return` 保证只注册一次）。
- `HZ.v2` 跨热重载复用，`sched` 里残留失效格子 → 每次加载新建。
- 删除死代码：`tickOneDispatch` / `tickOneOrder` / `navOne` / `dispatchOne` / `refillQueue` / `refillFromRoom` / `considerZombie` / `assignCircle` / `purgeIfGone` / `v2Cells` / `joinQueue` / `queueNext` / `longBlockMs` / `otherRecInPile`。

### 实机验证

50 只丧尸 + 200 具尸体：`orders=50` 满单、`eating=33~36`、`near=39`、零异常；格子尸体被逐具吃掉。

---

## 未发布（0.3.1）

### 修复

- **被拉走不释放餐位**：丧尸被玩家/声音吸引走时，引擎目标会偏离导航给的目的地，但订单一直占着餐位。现在连续两拍检测到 `getPathFindBehavior2():getTargetX/Y` 不是我们发 path 时的目的地，就交还餐位（`releaseOrder(..., true)`），`hz_pile` 保留 —— 跟丢玩家后回到队列，自动重新接单。
- **卡住判定**：旧判据（6 拍 + 距离改善）换成「先判目标偏离，再判位置振荡」：目标连续两拍不是导航目的地 → 判定为被拉走，交还餐位；目标没偏离时，用位置窗口判定真卡住（至少 4 拍约 8 秒、总跨度 < 0.8 格）。**判卡住后立刻换尸体**：先扫脚下那一格，没有就在堆内另找一具当场换过去（餐位随之转移，旧尸给自己 60 秒冷却）；整堆都没得换才回队，不站在原地等。已到达 / 进食中 / 在餐位等位的丧尸不参与判定。
- **到达后只发一次进食指令**：`near` 分支里 `ord.eating = true` 是无条件写的，`setEatBodyTarget` 只尝试一次（失败要等 8 秒），而且从不校验引擎的进食目标是不是那具尸体。现在每拍检查 `z:getEatBodyTarget() == body`，不是就每秒重发一次，直到引擎接受；没挂上期间不结算进食，`statsEatStart` 只在真正吃上时调用一次。
- **物品消失**：白骨化时即使 `AddWorldInventoryItem` 失败也会把物品从尸体容器里删掉。改为只有落地成功才删。
- **派单每拍报错**：`rec.blocked` 为 nil 时 `dispatchOne` 抛 `attempted index of non-table`，第一次派单就炸。改为先判空。
- **旧认领残留**：上一局的 `hz_pile` 指向已不存在的堆时，所有新堆都会认为它「已被别人认领」而拒绝（日志表现为 `refill ... owner=N q=0`），丧尸永远接不到单。现在认领的堆不存在就地作废。
- **清掉的死代码**：`ord.stuckAt`、`ord.bestD` 两套旧判据，以及卡住分支里多余的 `HZ.joinQueue`。

### 优化

- **脚下扫描**：`footBodyAt` 从「格子尸体数 × 堆尸体数」的嵌套扫，改成 uid 索引 O(1)，命中第一具就停；`isBone` 只在确认属于本堆时调用。
- **派单**：按切比雪夫距离分环由内向外，找到第一具可派的尸体就停（不再为堆里每具尸体都调一次 `findBody`）。
- **白骨化**：失败重试上限 2 次，避免每 2 秒重建一次 `IsoZombie`/`IsoDeadBody`。

### 其他

- 移除按 `0` 热重载的快捷键，只保留设置面板里的 **ReloadMod** 按钮。
- 修正过期注释：Java 两处「声音组」说明、`HZ_Diff` 的拍子说明、`HZ_Pile` 文件头（派单已移出）。
- 封面 `poster.png` / `preview.png`（256×256）。
- 文档 `HZ_TODO.md` 重写：0.3 结构、实测数据、0.4 方向。

---

## 0.3.0

- 初始发布版本。
- 状态统一：只保留 `modData.hz_buff`（位掩码）与 `modData.hz_pile`（认领的堆 pid），Lua 侧零副本。
- 调度重构：每类周期任务一条独立队列，间隔 `due(周期 / 队列长度)`，每拍只推进一个。
- 接单区与声音同圆心同半径，支持风偏；无气味时固定为尸堆方块。
- 到达判定收紧到 1 格。
- 新增营养系统：饱食 → 营养 → 五维 → 跑尸。
- 快照改为对象作主键，载荷只有 `obj/stats/removed/n/m`。

## 0.2

- 拆分为多文件结构，引入 Java 桥。

## 0.1

- 尸体气味吸引丧尸，尸堆与骨化。
