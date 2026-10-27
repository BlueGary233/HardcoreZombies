# 性能基准（离线）

用与游戏无关的纯 Lua 桩跑 `HZ.tickList`，测“每模拟秒消耗多少毫秒 Lua 时间”，
以及每个 tick 的占比和单次峰值。**它不是真机数字**：引擎调用在桩里是免费的，
真机的 JNI 成本看不到，只有相对占比和回归对比有意义。

## 运行

```
lua tools/perf/t_perf.lua     # A 密集：56 堆 / 500 尸 / 200 丧尸
lua tools/perf/t_perf2.lua    # B 摊开：396 堆 / 500 尸 / 200 丧尸
lua tools/perf/t_perf3.lua    # C 加压：396 堆 / 500 尸 / 400 丧尸
```

Windows 下用 `"C:/Program Files (x86)/Lua/5.1/lua.exe" tools/perf/t_perf3.lua`。

## 看什么

- `稳态(跳过前5s)` 的均值：回归基线，改完不该变差
- `各 tick 占用`：谁变贵了一目了然（`tickPiles` / `v2Tick` / `v2Cycle`）
- `orderFlags(=orderState) 调用` 次数：跨桥调用的回归指标（现在是每单每周期 1 次）

## 注意

- 桩里的 `findBody` 是线性扫全部尸体，`tickPiles` 的绝对值会偏高
- 桩里 `HZ_orderState` / `setBuff` 等都有计数器，改签名时记得同步
- 真机数字看游戏内 Debug 模式那行：`tick ms(avg/frame): ...`
