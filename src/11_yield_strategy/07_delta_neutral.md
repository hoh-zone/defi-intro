# 11.7 Delta 中性策略

## 什么是 Delta 中性

Delta 衡量仓位价值对基础资产价格变化的敏感度：

```
Delta = 0：仓位价值不随价格变化（完全对冲）
Delta > 0：仓位在价格上涨时盈利
Delta < 0：仓位在价格下跌时盈利

Delta 中性策略 = 构建一个 Delta ≈ 0 的组合
  → 不赌方向，只赚利差、手续费、资金费率
```

### Delta 中性的直觉

```
普通 LP：
  持有 50% SUI + 50% USDC
  Delta > 0（SUI 上涨时盈利，但少于纯持有）

Delta 中性 LP：
  持有 50% SUI + 50% USDC（LP 仓位）
  + 做空等量 SUI（通过永续合约或借款）
  Delta ≈ 0
```

## Delta 中性策略的三种实现

### 策略 1：LP + 永续合约对冲

```
步骤：
1. 提供 SUI/USDC 流动性（做多 SUI）
2. 在永续合约上做空等量 SUI
3. 净 Delta ≈ 0

收益 = LP 手续费 + 激励 - 资金费率（做空支付）
风险 = LP 的无常损失 + 资金费率成本
```

### 策略 2：借款做 LP

```
步骤：
1. 存入 USDC 作为抵押品
2. 借出 SUI
3. 将借出的 SUI + 自有 USDC 做 LP
4. LP 赚手续费和激励

Delta 分析：
  做多 SUI（LP 中的 SUI 部分）+ 做空 SUI（借款欠 SUI）
  净 Delta ≈ 0

收益 = LP 手续费 + 激励 - 借款利息
风险 = LP 被穿出区间 + 借款利率波动
```

### 策略 3：资金费率套利

```
步骤：
1. 买入现货 SUI
2. 在永续合约上做空等量 SUI
3. Delta = 0，不承担价格风险
4. 赚取资金费率差

收益 = 资金费率（永续合约多头支付给空头时）
风险 = 资金费率可能为负（空头支付多头）
```

## Delta 中性做市的 Move 实现

```move
module yield_strategy::delta_neutral;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID};
use sui::tx_context::TxContext;

#[error]
const ENotOwner: vector<u8> = b"Not Owner";
#[error]
const EZeroAmount: vector<u8> = b"Zero Amount";
#[error]
const EDeltaExceeded: vector<u8> = b"Delta Exceeded";
#[error]
const EInsufficientBalance: vector<u8> = b"Insufficient Balance";
const PRECISION: u64 = 1_000_000_000;

public struct DeltaNeutralPosition has key {
    id: UID,
    owner: address,
    long_balance: Balance<BaseCoin>,
    short_amount: u64,
    lp_shares: u64,
    target_delta_bps: u64,
    max_delta_bps: u64,
    entry_price: u64,
    total_fees_earned: u64,
    total_funding_paid: u64,
}

public struct Rebalanced has copy, drop {
    position: address,
    old_short: u64,
    new_short: u64,
    delta_before: u64,
    delta_after: u64,
}

public fun open<BaseCoin>(
    initial_long: Coin<BaseCoin>,
    short_amount: u64,
    entry_price: u64,
    target_delta_bps: u64,
    ctx: &mut TxContext,
) {
    assert!(initial_long.value() > 0, EZeroAmount);
    assert!(target_delta_bps <= 1000, EDeltaExceeded);
    let long_value = initial_long.value() * entry_price / PRECISION;
    let position = DeltaNeutralPosition {
        id: object::new(ctx),
        owner: ctx.sender(),
        long_balance: coin::into_balance(initial_long),
        short_amount,
        lp_shares: 0,
        target_delta_bps,
        max_delta_bps: target_delta_bps * 3,
        entry_price,
        total_fees_earned: 0,
        total_funding_paid: 0,
    };
    transfer::transfer(position, ctx.sender());
}

public fun current_delta(position: &DeltaNeutralPosition, current_price: u64): u64 {
    let long_value = position.long_balance.value() * current_price / PRECISION;
    let short_value = position.short_amount * current_price / PRECISION;
    if (long_value + short_value == 0) { return 0 };
    if (long_value > short_value) {
        (long_value - short_value) * 10000 / (long_value + short_value)
    } else {
        (short_value - long_value) * 10000 / (long_value + short_value)
    }
}

public fun needs_rebalance(position: &DeltaNeutralPosition, current_price: u64): bool {
    current_delta(position, current_price) > position.max_delta_bps
}

public fun compute_rebalance_amount(position: &DeltaNeutralPosition, current_price: u64): u64 {
    let long_value = position.long_balance.value() * current_price / PRECISION;
    let target_short = long_value * (10000 - position.target_delta_bps) / 10000;
    let current_short_value = position.short_amount * current_price / PRECISION;
    if (target_short > current_short_value) {
        (target_short - current_short_value) * PRECISION / current_price
    } else {
        0
    }
}

public fun rebalance<BaseCoin>(
    position: &mut DeltaNeutralPosition<BaseCoin>,
    current_price: u64,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == position.owner, ENotOwner);
    let delta_before = current_delta(position, current_price);
    assert!(delta_before > position.max_delta_bps, EDeltaExceeded);
    let long_value = position.long_balance.value() * current_price / PRECISION;
    let target_short = long_value * (10000 - position.target_delta_bps) / 10000;
    let new_short_amount = target_short * PRECISION / current_price;
    let old_short = position.short_amount;
    position.short_amount = new_short_amount;
    let delta_after = current_delta(position, current_price);
    event::emit(Rebalanced {
        position: object::uid_to_address(&position.id),
        old_short,
        new_short: new_short_amount,
        delta_before,
        delta_after,
    });
}

public fun record_funding<BaseCoin>(
    position: &mut DeltaNeutralPosition<BaseCoin>,
    funding_amount: u64,
) {
    position.total_funding_paid = position.total_funding_paid + funding_amount;
}

public fun record_fees<BaseCoin>(position: &mut DeltaNeutralPosition<BaseCoin>, fee_amount: u64) {
    position.total_fees_earned = position.total_fees_earned + fee_amount;
}

public fun net_pnl(position: &DeltaNeutralPosition, current_price: u64): u64 {
    let long_value = position.long_balance.value() * current_price / PRECISION;
    let short_cost = position.short_amount * current_price / PRECISION;
    let unrealized = if (long_value > short_cost) { long_value - short_cost } else { 0 };
    position.total_fees_earned + unrealized - position.total_funding_paid
}

public fun close<BaseCoin>(
    position: DeltaNeutralPosition<BaseCoin>,
    ctx: &mut TxContext,
): Coin<BaseCoin> {
    assert!(ctx.sender() == position.owner, ENotOwner);
    let base = coin::from_balance(position.long_balance, ctx);
    let DeltaNeutralPosition {
        id,
        owner: _,
        long_balance: _,
        short_amount: _,
        lp_shares: _,
        target_delta_bps: _,
        max_delta_bps: _,
        entry_price: _,
        total_fees_earned: _,
        total_funding_paid: _,
    } = position;
    id.delete();
    base
}
```

## Delta 中性的实际成本

```
Delta 中性不是免费的。维持 Delta ≈ 0 需要：

1. 再平衡成本
   - 每次再平衡都有交易滑点和 gas
   - 波动越大，再平衡越频繁

2. 做空成本
   - 永续合约做空需要支付资金费率
   - 借款做空需要支付借款利息

3. 机会成本
   - 做空占用的资金无法用于其他收益策略

净收益 = LP 手续费 + 激励 - 做空成本 - 再平衡成本
```

## 风险分析

| 风险         | 描述                                                  |
| ------------ | ----------------------------------------------------- |
| 再平衡延迟   | 价格快速变化时来不及再平衡，Delta 偏离                |
| 资金费率反转 | 资金费率可能变为负值，做空方需要付费                  |
| 对冲不完美   | LP 的 Delta 不是线性的（CLMM 集中区间），难以精确对冲 |
| 多协议风险   | 策略涉及 LP + 借贷/永续合约，任一协议出问题都有影响   |
| 极端行情     | 闪崩时永续合约和现货价格可能脱钩，对冲失效            |
