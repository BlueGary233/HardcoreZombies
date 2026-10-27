# 腐风 · 硬核丧尸（HardcoreZombies）

Project Zomboid **Build 42** 的丧尸行为强化模组：尸体会散发气味，循味而来的丧尸按餐位排队进食；吃饱后营养值上升，营养满的丧尸会开始奔跑。

> 必须搭配 **[ZombieBuddy](https://steamcommunity.com/sharedfiles/filedetails/?id=3610065891)** 使用（Java 桥依赖）。

## 这个 mod 做了什么

- **尸体气味**：新鲜尸体气味弱，腐烂后扩散到最远，随后衰减。气味随风向偏移，上风口的丧尸先闻到。
- **排队进食**：每个尸堆有固定餐位，多出来的丧尸在旁边等，不会一拥而上互相卡住。
- **营养成长**：进食累积营养，营养随时间消化；营养满的丧尸会变成超级跑尸，长期饥饿的会逐级掉回去。
- **尸体骨化**：被吃空的尸体变成骨架，装备落地并损坏。
- **室内尸堆**：房间里的尸堆不发声、只影响房间内的丧尸（门窗关着，外面的丧尸闻不到也进不来）。

## 架构

三层队列，各自独立：

| 层 | 周期 | 职责 |
|---|---|---|
| 尸体 | 4 秒 | 按位置算出所属格子 / 堆，只做归属 |
| 格子 | 2 秒内轮完一圈 | 派单 + 订单维护（导航 / 进食 / 续单） |
| 尸堆 | 2 秒 | 格子重排、发声、重建可接单队列 |

派单方向是「尸体（格子）挑丧尸」：每格按餐位数派给最近的空闲丧尸，订单一旦派出即锁定餐位。

## 行为判据（都对着引擎字节码核过）

- **到达** `DistTo(body) ≤ 1.0`；`1.0 ~ 1.2` 保持进食（keepD 迟滞）；`> 1.2` 离桌。
- **吃饭模式** 3 格内登记 `setBodyToEat`。引擎 `updateEatBodyTarget()` 在 `IdleState && DistToSquared ≤ 1.0` 时自动挂 `setEatBodyTarget`，到位即开吃。
- **纠正导航** 先 `setDefaultState()` 再 `pathToLocationF()`：`IsoZombie` 覆写的版本在 `allowRepathDelay > 0` 且处于 `PathFind / WalkToward / WalkTowardNetwork` 状态时会直接丢弃命令。
- **空转** 状态是 `ZombieIdleState / IdleState / GenericDefaultState` 时立刻重下发导航（引擎把路径走完就停在 Idle，不推它不会自己动）。
- **卡住** 连续 3 拍没位移就 `setStaggerBack(true)` 推一把；推两次还不动才换目标。
- **被拉走** 引擎寻路目标不是我们的尸体（在追玩家/声音）→ 2 拍（约 4 秒）释放订单，30 秒冷却。
- **不可达** 引擎目标 = 自己脚下 → 2 拍换尸体。

## 已知问题

1. 暂不支持联机，仅本地游戏生效。
2. 跑尸的营养值回落不会使其回到普通丧尸。
3. 爬尸无法进食。
4. 没有持久化保存，读档会重新积攒营养值。
5. 调试模式（DebugMode）会持续写日志和快照，正常游玩请关闭。
6. 旧存档里的丧尸可能带着上一局的尸堆认领，进游戏后会自动作废重来。

## 目录

```
42/media/lua/client/   行为逻辑（HZ_Orders / HZ_Pile / HZ_Diff / HZ_Stats …）
42/media/lua/shared/   翻译
java/                  Java 桥源码（编译产物在 42/media/java/HardcoreZombies.jar）
docs/                  创意工坊描述（中/英）
CHANGELOG.md           更新日志
```

## 致谢

- **ZombieBuddy**：提供 Java 桥。
- **Realism Zombies**（Amostradinho）：尸体骨化的技术思路参考，也是本 mod 的灵感来源。追求更细致完整的丧尸行为且不在意性能的话，更推荐它。

## 授权

源码可自由查看、修改。转载/二次分发请注明出处。
