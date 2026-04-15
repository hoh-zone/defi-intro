# 11.1 做市收益的来源与拆解

## 做市的三个收入来源

```
总收入 = 手续费收入 + 激励代币收入 + 价格增值（或贬值）
```

### 1. 手续费收入

每当有人通过你提供流动性的池子交易，你按份额获得手续费。

```
AMM 手续费：
  用户交易 1000 USDC → SUI，手续费 0.3%
  手续费 = 3 USDC
  如果你的份额占池子 10%，你获得 0.3 USDC

订单簿手续费：
  Maker 手续费通常为 -0.01% 到 0.1%（挂单者可能获得返佣）
  Taker 手续费通常为 0.05% 到 0.25%
```

### 2. 激励代币收入

协议用原生代币补贴流动性提供者（第 8 章详细讲过）。这部分收入的实际价值取决于代币价格。

### 3. 价格增值 / 无常损失

你存入的资产价值会随价格变化。这里有一个关键的不对称性：

```
价格不变：资产价值不变
价格上涨：资产价值增加，但少于"单纯持有"
价格下跌：资产价值减少，且多于"单纯持有"
```

这就是**无常损失（Impermanent Loss, IL）**——无论价格往哪个方向变动，AMM LP 的资产价值都低于单纯持有。

## 无常损失的数学

### Uniswap V2 风格（全区间）

```
设初始价格 P₀ = 1，投入等值资产（500 USDC + 500 SUI = $1000）

价格变为 P：

AMM LP 价值 = 2 × √(P/P₀) / (1 + P/P₀) × 初始价值
单纯持有价值 = (1 + P/P₀) / 2 × 初始价值

无常损失 = 1 - AMM价值 / 单纯持有价值
```

| 价格变化 | 无常损失 |
| -------- | -------- |
| 1.25x    | 0.6%     |
| 1.5x     | 2.0%     |
| 2.0x     | 5.7%     |
| 3.0x     | 13.4%    |
| 5.0x     | 25.5%    |
| 0.5x     | 5.7%     |
| 0.25x    | 20.0%    |

### CLMM 风格（集中区间）

集中流动性放大了无常损失——因为资金集中在更窄的价格区间内。

```
区间 [Pₐ, P_b]，集中度系数 = 1 / (价格区间覆盖比例)

集中区间越窄：
  手续费收入越高（资金效率高）
  无常损失风险越大
  价格穿出区间的概率越大
```

## 净收益公式

```
净收益 = 手续费收入 + 激励收入 - 无常损失 - 机会成本

年化净收益率：
  Net APY = Fee APR + Incentive APR - IL Rate - Risk Premium

判断标准：
  Net APY > 0：做市有价值
  Net APY > 单纯持有收益：做市优于持有
  Net APY < 0：不如不做
```

### 用 Move 计算无常损失

```move
module yield_strategy::il_calculator;

const PRECISION: u64 = 1_000_000_000;

public fun impermanent_loss(price_ratio_scaled: u64): u64 {
    let sqrt_r = sqrt_scaled(price_ratio_scaled);
    let amm_value = 2 * sqrt_r;
    let hold_value = PRECISION + price_ratio_scaled;
    if (amm_value * 2 >= hold_value) {
        0
    } else {
        (hold_value - amm_value * 2) * PRECISION / hold_value
    }
}

public fun net_yield(fee_apr_bps: u64, incentive_apr_bps: u64, il_bps: u64): u64 {
    let total = fee_apr_bps + incentive_apr_bps;
    if (total > il_bps) { total - il_bps } else { 0 }
}

fun sqrt_scaled(n: u64): u64 {
    if (n == 0) { return 0 };
    let mut x = n;
    let mut y = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    };
    x
}

public fun clmm_concentration_factor(
    tick_lower: u32,
    tick_upper: u32,
    current_tick: u32,
): u64 {
    let range = (tick_upper - tick_lower) as u64;
    if (range == 0) { return PRECISION };
    let dist_lower = if (current_tick > tick_lower) { (current_tick - tick_lower) as u64 } else {
        0
    };
    let dist_upper = if (tick_upper > current_tick) { (tick_upper - current_tick) as u64 } else {
        0
    };
    let in_range = if (dist_lower > 0 && dist_upper > 0) {
        if (dist_lower < dist_upper) { dist_lower * 2 } else { dist_upper * 2 }
    } else {
        0
    };
    PRECISION * in_range / range
}
```

## 收益归因分析

理解做市收益的关键是做归因分析——收入到底从哪来？

```
示例：SUI/USDC CLMM LP，30 天

投入：$10,000
期末资产价值：$10,800
单纯持有价值：$10,300

收益归因：
  手续费收入：+$600（年化 ~73%）
  激励收入：+$400（年化 ~49%，CETUS 代币）
  无常损失：-$200（SUI 价格上涨 30% 导致）
  总收益：+$800（年化 ~98%）
  Alpha（相对持有）：+$500（年化 ~61%）
```

**警惕**：如果激励收入占总收益的 80% 以上，说明收益严重依赖代币补贴，而非真实的交易需求。补贴一停，收益断崖。

## 风险分析

| 风险           | 描述                                                            |
| -------------- | --------------------------------------------------------------- |
| 无常损失被低估 | 很多 LP 只看手续费 APR，忽视 IL 可能吃掉全部收益                |
| 激励代币贬值   | 激励收入以协议代币发放，代币价格下跌时实际收益远低于名义值      |
| 区间穿出       | CLMM 集中区间被价格穿出后，手续费收入归零，资金全部转为单边资产 |
| 尾部风险       | 极端行情下 IL 可能超过 50%，远超手续费收入                      |
