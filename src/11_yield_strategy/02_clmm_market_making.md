# 11.2 AMM 集中流动性做市

## CLMM 做市的核心决策

CLMM（Concentrated Liquidity Market Maker）做市只有一个核心决策：**选择价格区间**。

```
全区间（V2 风格）：[0, ∞)
  - 永远在区间内，永远赚手续费
  - 资金效率最低，APR 最低

窄区间（V3/Cetus 风格）：[P - 5%, P + 5%]
  - 资金效率高，APR 高
  - 价格穿出区间后手续费归零
  - 需要频繁再平衡

超窄区间：[P - 1%, P + 1%]
  - 资金效率极高
  - 几乎一定会穿出区间
  - 本质上是在赌价格不会大幅波动
```

## 区间选择策略

### 策略 1：波动率锚定

```
区间宽度 = k × 历史波动率 × √时间窗口

示例：
  SUI 30 日历史波动率 = 5%/天
  k = 2（2 倍标准差覆盖 ~95% 的价格变动）
  时间窗口 = 7 天
  区间宽度 = 2 × 5% × √7 ≈ 26%

  区间 = [当前价 × 0.87, 当前价 × 1.13]
```

### 策略 2：支撑阻力锚定

```
区间上限 = 近期阻力位
区间下限 = 近期支撑位

示例：
  SUI 在 $1.00-$1.40 之间震荡
  支撑位 $1.00，阻力位 $1.40
  区间 = [$1.00, $1.40]
```

### 策略 3：对称锚定

```
区间 = [当前价 × (1-δ), 当前价 × (1+δ)]

示例：
  当前价 $1.20
  δ = 10%
  区间 = [$1.08, $1.32]
```

## 自动再平衡策略

当价格穿出区间时，需要将仓位移到新区间。自动再平衡的 Move 实现：

```move
module yield_strategy::auto_rebalance;

use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::object::{Self, UID};
use sui::tx_context::TxContext;

#[error]
const ENotOwner: vector<u8> = b"Not Owner";
#[error]
const EOutOfRange: vector<u8> = b"Out Of Range";
#[error]
const EAlreadyInRange: vector<u8> = b"Already In Range";
const PRECISION: u64 = 1_000_000_000;

public struct RebalanceParams has store {
    tick_range_bps: u64,
    min_liquidity: u64,
    max_gas_budget: u64,
}

public struct AutoRebalanceVault has key {
    id: UID,
    position_id: UID,
    current_tick_lower: int32,
    current_tick_upper: int32,
    params: RebalanceParams,
    rebalance_count: u64,
    last_rebalance_ms: u64,
    total_fees_collected: u64,
    owner: address,
}

public fun create_vault(position_id: UID, tick_range_bps: u64, ctx: &mut TxContext) {
    let vault = AutoRebalanceVault {
        id: object::new(ctx),
        position_id,
        current_tick_lower: 0,
        current_tick_upper: 0,
        params: RebalanceParams {
            tick_range_bps,
            min_liquidity: 100_000_000,
            max_gas_budget: 50_000_000,
        },
        rebalance_count: 0,
        last_rebalance_ms: 0,
        total_fees_collected: 0,
        owner: ctx.sender(),
    };
    transfer::transfer(vault, ctx.sender());
}

public fun should_rebalance(vault: &AutoRebalanceVault, current_tick: int32): bool {
    let in_range =
        current_tick >= vault.current_tick_lower
            && current_tick <= vault.current_tick_upper;
    if (in_range) { return false };
    let range = (vault.current_tick_upper - vault.current_tick_lower) as u64;
    let margin = range * vault.params.tick_range_bps / 10000;
    let distance = if (current_tick < vault.current_tick_lower) {
        (vault.current_tick_lower - current_tick) as u64
    } else {
        (current_tick - vault.current_tick_upper) as u64
    };
    distance > margin
}

public fun compute_new_range(vault: &AutoRebalanceVault, current_tick: int32): (int32, int32) {
    let half_range = ((vault.current_tick_upper - vault.current_tick_lower) / 2);
    let tick_spacing = 10;
    let aligned_tick = (current_tick / tick_spacing) * tick_spacing;
    let lower = aligned_tick - half_range;
    let upper = aligned_tick + half_range;
    (lower, upper)
}

public fun update_params(
    vault: &mut AutoRebalanceVault,
    tick_range_bps: u64,
    min_liquidity: u64,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == vault.owner, ENotOwner);
    vault.params.tick_range_bps = tick_range_bps;
    vault.params.min_liquidity = min_liquidity;
}
```

## 区间宽度的权衡

```
区间越窄：
  ✓ 手续费 APR 越高（资金集中）
  ✗ 穿出概率越大
  ✗ 再平衡越频繁（gas 成本）
  ✗ 每次再平衡的滑点损失

区间越宽：
  ✓ 穿出概率低
  ✓ 管理成本低
  ✗ 资金效率低
  ✗ 手续费 APR 低

最优区间 = 让手续费收入最大化 - 再平衡成本 - IL
```

## Cetus 上的做市实践

Cetus 使用 CLMM，tick spacing 决定最小区间粒度：

```
费率档位    tick spacing    适用场景
0.01%       1               稳定币对
0.05%       10              主要交易对
0.25%       50              中等波动
1%          200             高波动代币
```

做市时选择合适的费率档位：

- 稳定币对：选 0.01%，窄区间，赚小价差
- 主流代币对：选 0.05%，中等区间，平衡收益和风险
- meme 币对：选 1%，宽区间，主要靠激励而非手续费

## 风险分析

| 风险           | 描述                                               |
| -------------- | -------------------------------------------------- |
| 再平衡频率过高 | 震荡行情中频繁穿出区间，每次再平衡都产生滑点和 gas |
| 单边持仓       | 价格单向突破后，仓位 100% 转为弱势资产             |
| 自动化失败     | 自动再平衡合约如果出现 bug，可能在错误的区间开仓   |
| 资金效率幻觉   | 看似高 APR，但 IL 可能吃掉大部分收益               |
