# 4.18 CLMM Swap 算法

CLMM 的 Swap 比 CPMM 复杂得多。交易不仅计算单个 Tick 内的兑换量，还要处理跨 Tick 边界时的流动性变化。

## Swap 流程概览

```
CPMM: 输入 → 一步计算 → 输出
CLMM: 输入 → 当前 Tick 内兑换 → 不够？跨 Tick → 更新流动性 → 继续
```

### ASCII 流程图

```
              ┌──────────────┐
              │  开始 Swap   │
              │ amount_in,   │
              │ direction    │
              └──────┬───────┘
                     ▼
              ┌─────────────┐
        ┌────▶│当前Tick有   │
        │     │足够流动性？ │
        │     └──┬──────┬───┘
        │     Yes│      │No
        │        ▼      ▼
        │  ┌────────┐ ┌─────────────┐
        │  │在当前  │ │计算到下个   │
        │  │Tick内  │ │活跃Tick的量 │
        │  │兑换    │ └──────┬──────┘
        │  └───┬────┘        ▼
        │      │      ┌─────────────┐
        │      │      │剩余量能跨过？│
        │      │      └─┬───────┬───┘
        │      │     Yes│      │No
        │      │        ▼      ▼
        │      │  ┌──────────┐ ┌────────┐
        │      │  │跨过Tick  │ │部分兑换│
        │      │  │更新流动性│ │在边界  │
        │      │  └────┬─────┘ │停止    │
        │      │       │       └───┬────┘
        │      │       ▼           │
        │      │  ┌──────────┐     │
        │      │  │移到下一个│     │
        │      │  │活跃Tick  │     │
        │      │  └────┬─────┘     │
        │      ▼      ▼           ▼
        │  ┌──────────────────────────┐
        └──│还有剩余 amount_in？      │
           └────┬─────────────────────┘
              No│
                ▼
         ┌──────────────┐
         │返回amount_out│
         └──────────────┘
```

## 单 Tick 内的兑换

每个 Tick 区间内流动性 L 恒定，用虚拟储备表示：

```
x_virtual = L / √P_current
y_virtual = L × √P_current

买入 B (卖 A):
  Δy = (Δx × y_virtual) / (x_virtual + Δx)

买入 A (卖 B):
  Δx = (Δy × x_virtual) / (y_virtual + Δy)
```

### 数值示例

```
Tick [6930, 6940], P = $2.00, L = 10000
  x_virtual = 7071.1,  y_virtual = 14142.1

Swap 100 A 买 B:
  Δy = (100 × 14142.1) / (7071.1 + 100) = 197.2 B
```

## 跨 Tick 边界

```
Step 1: 计算当前 Tick 到下一个 Tick 的量
  当前 tick=6931, 下一个活跃 tick=6940
  P_current = 1.99985, P_next = 2.00166
  Δx = L × (1/√P_cur - 1/√P_next) = 3.6

Step 2: 消耗 3.6 A, 得到 7.0 B

Step 3: 更新流动性
  新 L = 旧 L + tick_6940.liquidity_net
  假设 +5000 → 新 L = 15000

Step 4: 用剩余量继续兑换
```

### 流动性激活/停用

```
价格上升穿过 tick_lower → liquidity_net > 0 → L 增加
价格上升穿过 tick_upper → liquidity_net < 0 → L 减少

LP 的区间 [6930, 6950]:
  穿过 6930: L += 5000 (进入区间)
  穿过 6950: L -= 5000 (离开区间)
```

## 手续费累积

```
三层追踪:
  全局: fee_growth_global (Pool 级)
  Tick: fee_growth_outside (Tick 级)
  Position: fee_growth_inside_last (快照)

Position 待领手续费:
  fee = liquidity × (全局 - tick_lower.outside
        - tick_upper.outside - 快照) / PRECISION

核心: 全局累计 - 区间外 = 区间内
```

## Swap 伪代码

```
function clmm_swap(pool, amount_in, direction):
    remaining = amount_in, out = 0
    tick = pool.active_tick, L = pool.active_liquidity

    while remaining > 0:
        next = find_next_active_tick(tick, direction)
        max = calc_max_in_tick(L, tick, next)

        if remaining <= max:
            out += swap_within_tick(L, remaining)
            remaining = 0
        else:
            out += swap_to_boundary(L, tick, next)
            remaining -= max
            tick = next
            L += next.liquidity_net  // 跨 Tick 更新

    pool.active_tick = tick
    pool.active_liquidity = L
    return out
```

## 小结

CLMM Swap 核心：在 Tick 内用虚拟储备计算 → 流动性不够时跨 Tick → 更新活跃流动性 → 重复。手续费通过全局/Tick/Position 三层追踪。下一节将构建完整的 Sui CLMM 实现。
