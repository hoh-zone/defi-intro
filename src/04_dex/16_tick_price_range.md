# 4.16 Tick 与价格区间

CLMM 的核心是将连续的价格轴离散化为 Tick。每个 Tick 对应一个价格点，LP 的流动性在 Tick 之间分布。理解 Tick 机制是掌握 CLMM 的基础。

## Tick 的定义

连续价格空间无法被计算机精确表示。CLMM 将价格轴离散化为等间距的 Tick：

```
连续价格: $1.997 ─ $1.998 ─ $1.999 ─ $2.000 ─ $2.001 ─ $2.002
          (无穷多价格点)

Tick 离散化:
  tick_-100 ── tick_-50 ── tick_0 ── tick_50 ── tick_100
   $1.990      $1.995     $2.000    $2.005      $2.010

  相邻 Tick 比率恒定 = 1.0001
  Tick 0 → 价格 1.0
```

## 价格与 Tick 的转换公式

```
给定价格 P → Tick:
  tick = floor(log(P) / log(1.0001))
       = floor(ln(P) / ln(1.0001))

给定 Tick → 价格:
  P = 1.0001^tick

数值示例:
  P = 1.0  → tick = 0
  P = 2.0  → tick = floor(0.6931 / 0.0001) = 6931
  P = 0.5  → tick = floor(-0.6931 / 0.0001) = -6932

验证: 1.0001^6931 ≈ 1.99985 ≈ 2.0 ✓
```

### 为什么是 1.0001

```
1 tick = 0.01% 价格变化
100 tick ≈ 1% 价格变化
6931 tick ≈ 2x 价格变化（翻倍）

粒度足够精细 (0.01%)，Tick 数量可控。
```

## Tick Spacing

不是每个 Tick 都可用。Tick Spacing 限制可用位置：

```
Tick Spacing = 10:  可用 ..., -20, -10, 0, 10, 20, ...
Tick Spacing = 50:  可用 ..., -100, -50, 0, 50, 100, ...

作用: 减少活跃 Tick 数量 → 降低存储和 Gas 开销
代价: LP 区间精度降低
```

不同费率对应不同 Tick Spacing：

```
Fee Tier | Tick Spacing | 精度  | 适用场景
─────────|──────────────|───────|──────────────
  0.01%  |    1         | 0.01% | 稳定币对
  0.05%  |   10         | 0.1%  | 紧密相关资产
  0.25%  |   50         | 0.5%  | 主流交易对
  1.00%  |  200         | 2.0%  | 长尾/高波动
```

## Active Tick

Pool 维护一个 Active Tick 表示当前价格位置：

```
价格轴:  $0.5   $0.71  $1.0  $1.41  $2.0  $2.8  $4.0
         │      │      │     │      │     │     │
tick:   -6932  -3465   0   3465   6931 10397 13863
                                ↑
                           Active Tick

Swap 买入 A → 价格下降 → Active Tick 左移
Swap 买入 B → 价格上升 → Active Tick 右移
```

## LP 的 Tick Range

LP 开仓时指定 [tick_lower, tick_upper]：

```
同一 Pool 中多个 LP Position:

LP-A: [tick 6860 ════════════════════ tick 7000]  宽
LP-B:       [tick 6910 ════════ tick 6950]        中
LP-C:              [tick 6925 ═ tick 6935]         窄

每个 Tick 上的流动性叠加:
  tick 6925: LP-A + LP-B + LP-C
  tick 6931: LP-A + LP-B + LP-C (最多)
  tick 6950: LP-A only
```

## Tick 数据结构

```move
public struct TickState has store, copy, drop {
    liquidity_gross: u128,   // 总流动性
    liquidity_net: i128,     // 净变化 (+/-)
    fee_growth_outside_a: u128,
    fee_growth_outside_b: u128,
}
// liquidity_net > 0: 价格上升穿过时添加流动性 (tick_lower)
// liquidity_net < 0: 价格上升穿过时移除流动性 (tick_upper)
```

Sui 中用 dynamic_field 稀疏存储：只存有流动性的 Tick，跳过空 Tick。

## 小结

```
Tick 是 CLMM 基本单位:
  tick = floor(ln(P) / ln(1.0001))
  P = 1.0001^tick
  Tick Spacing 控制精度与 Gas 的平衡
  LP 在 [tick_lower, tick_upper] 提供流动性
```

下一节讨论为什么 CLMM 的 LP Position 必须用 NFT 表示。
