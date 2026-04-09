# 4.3 集中流动性与资金效率

## 问题

传统 AMM 的流动性均匀分布在 (0, ∞) 的价格区间内。但实际上，大多数交易发生在很窄的价格范围内。例如 SUI/USDC 可能在 1.8-2.2 之间波动 95% 的时间，但 AMM 把流动性浪费在 0.001 和 10000 这种极端价格上。

集中流动性允许 LP 选择一个价格区间 [p_lower, p_upper]，只在这个区间内提供流动性。

## Tick 机制

价格空间被离散化为 tick。每个 tick 对应一个价格：

$$p(i) = 1.0001^i$$

- tick 0 → 价格 1.0
- tick 10000 → 价格 e ≈ 2.718
- tick -10000 → 价格 1/e ≈ 0.368

LP 选择 [tick_lower, tick_upper] 作为自己的价格区间。

## Move 对象设计

```move
struct CLPool<phantom A, phantom B> has key {
    id: UID,
    current_tick: u64,
    fee_bps: u64,
    tick_spacing: u64,
    sqrt_price: u128,
    liquidity: u128,
    fee_growth_global_a: u128,
    fee_growth_global_b: u128,
}

struct CLPosition<phantom A, phantom B> has key, store {
    id: UID,
    pool_id: ID,
    tick_lower: u64,
    tick_upper: u64,
    liquidity: u128,
    fee_growth_inside_a: u128,
    fee_growth_inside_b: u128,
    tokens_owed_a: u64,
    tokens_owed_b: u64,
}

struct TickState has store {
    liquidity_gross: u128,
    fee_growth_outside_a: u128,
    fee_growth_outside_b: u128,
    initialized: bool,
}
```

关键点：
- `CLPosition` 比 AMM 的 LP 多了 `tick_lower` 和 `tick_upper`
- `tokens_owed_a/b` 记录该仓位累积但未领取的手续费
- `TickState` 跟踪每个 tick 的流动性增量

## 仓位激活与失活

当价格（current_tick）在 [tick_lower, tick_upper] 范围内时，仓位是**活跃的**——它在赚取手续费，它的流动性正在被交易消耗。

当价格移出区间时，仓位变为**不活跃的**——它不再赚取手续费，流动性全部转换为其中一种代币。

```move
public fun is_position_active(
    pool: &CLPool,
    position: &CLPosition,
): bool {
    pool.current_tick >= position.tick_lower
        && pool.current_tick < position.tick_upper
}
```

这意味着集中流动性的 LP 需要**主动管理**：当价格移出区间时，需要调整区间或重新提供流动性。如果不管，你的资金就变成了单边持仓，承担方向性风险而不赚手续费。

## 资金效率对比

假设 SUI/USDC 在 1.8-2.2 区间内交易：

| 指标 | 传统 AMM | 集中流动性（4%区间） |
|------|----------|---------------------|
| 1000 USDC 资金效率 | 1x | ~25x |
| 手续费收益 | 基准 | ~25x（区间内） |
| 需要主动管理 | 否 | 是 |
| 价格移出区间风险 | 无 | 单边持仓风险 |

效率提升不是免费的——你用管理成本和区间风险换取了更高的资金效率。
