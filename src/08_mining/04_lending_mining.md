# 8.4 借贷流动性挖矿算法

## 借贷挖矿与 DEX 挖矿的区别

DEX 挖矿激励用户**提供流动性**（质押 LP Token）。借贷挖矿同时激励两种行为：

- **存款激励**：鼓励用户存入资产，为协议提供可借出资金
- **借款激励**：鼓励用户借款，提高资金利用率

两种激励的权重不同，反映了协议的策略：

```
保守策略：高存款激励 + 低借款激励
  → 吸引存款，保持高流动性，降低清算风险
  → 适合新协议冷启动

激进策略：低存款激励 + 高借款激励
  → 推高资金利用率，但可能增加清算风险
  → 适合成熟协议追求收益

极端策略：借款激励 > 借款利息
  → 实际利率为负，鼓励杠杆借贷
  → 典型的 mercenary capital 陷阱
```

## 完整 Move 实现

```move
module liquidity_mining::lending_mining;

use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::math;
use sui::object::{Self, UID};
use sui::table::{Self, Table};
use sui::tx_context::TxContext;

#[error]
const EUnauthorized: vector<u8> = b"Unauthorized";
#[error]
const EZeroAmount: vector<u8> = b"Zero Amount";
#[error]
const ENotFound: vector<u8> = b"Not Found";
const PRECISION: u64 = 1_000_000_000;

public struct LendingMiningMaster<phantom RewardCoin> has key {
    id: UID,
    reward_rate_per_ms: u64,
    last_update_ms: u64,
    markets: Table<address, MarketInfo>,
    reward_balance: Coin<RewardCoin>,
    admin: address,
}

public struct MarketInfo has store {
    supply_stake: u64,
    borrow_stake: u64,
    supply_weight: u64,
    borrow_weight: u64,
    supply_acc_per_share: u64,
    borrow_acc_per_share: u64,
    last_supply_acc_per_weight: u64,
    last_borrow_acc_per_weight: u64,
    supply_positions: Bag,
    borrow_positions: Bag,
}

public struct SupplyPosition has store {
    amount: u64,
    reward_debt: u64,
}

public struct BorrowPosition has store {
    amount: u64,
    reward_debt: u64,
}

public struct GlobalAccumulator has store {
    supply_acc_per_weight: u64,
    borrow_acc_per_weight: u64,
    total_supply_weight: u64,
    total_borrow_weight: u64,
}

public fun initialize<RewardCoin>(
    reward: Coin<RewardCoin>,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let rate = coin::value(&reward) / duration_ms;
    let master = LendingMiningMaster<RewardCoin> {
        id: object::new(ctx),
        reward_rate_per_ms: rate,
        last_update_ms: clock.timestamp_ms(),
        markets: table::new(ctx),
        reward_balance: reward,
        admin: ctx.sender(),
    };
    transfer::share_object(master);
}

public fun add_market<RewardCoin>(
    master: &mut LendingMiningMaster<RewardCoin>,
    market_id: address,
    supply_weight: u64,
    borrow_weight: u64,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == master.admin, EUnauthorized);
    let market = MarketInfo {
        supply_stake: 0,
        borrow_stake: 0,
        supply_weight,
        borrow_weight,
        supply_acc_per_share: 0,
        borrow_acc_per_share: 0,
        last_supply_acc_per_weight: 0,
        last_borrow_acc_per_weight: 0,
        supply_positions: bag::new(ctx),
        borrow_positions: bag::new(ctx),
    };
    table::add(&mut master.markets, market_id, market);
}

fun update_market<RewardCoin>(
    master: &mut LendingMiningMaster<RewardCoin>,
    market_id: address,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();
    if (now <= master.last_update_ms) { return };
    let elapsed = now - master.last_update_ms;
    let reward_delta = master.reward_rate_per_ms * elapsed * PRECISION;

    let mut total_supply_weight = 0u64;
    let mut total_borrow_weight = 0u64;
    let mut i = 0;
    let keys = table::keys(&master.markets);
    while (i < keys.length()) {
        let mkt = table::borrow(&master.markets, *keys.element_at(i));
        total_supply_weight = total_supply_weight + mkt.supply_weight;
        total_borrow_weight = total_borrow_weight + mkt.borrow_weight;
        i = i + 1;
    };

    let supply_acc_delta = if (total_supply_weight > 0) { reward_delta / 2 / total_supply_weight }
    else { 0 };
    let borrow_acc_delta = if (total_borrow_weight > 0) { reward_delta / 2 / total_borrow_weight }
    else { 0 };

    let pool = table::borrow_mut(&mut master.markets, market_id);
    if (pool.supply_stake > 0 && pool.supply_weight > 0) {
        let delta = supply_acc_delta * pool.supply_weight;
        pool.supply_acc_per_share = pool.supply_acc_per_share + delta / pool.supply_stake;
    };
    pool.last_supply_acc_per_weight = pool.last_supply_acc_per_weight + supply_acc_delta;
    if (pool.borrow_stake > 0 && pool.borrow_weight > 0) {
        let delta = borrow_acc_delta * pool.borrow_weight;
        pool.borrow_acc_per_share = pool.borrow_acc_per_share + delta / pool.borrow_stake;
    };
    pool.last_borrow_acc_per_weight = pool.last_borrow_acc_per_weight + borrow_acc_delta;
    master.last_update_ms = now;
}

public fun deposit_supply<RewardCoin>(
    master: &mut LendingMiningMaster<RewardCoin>,
    market_id: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EZeroAmount);
    update_market(master, market_id, clock);
    let user = ctx.sender();
    let market = table::borrow_mut(&mut master.markets, market_id);
    if (bag::contains(&market.supply_positions, user)) {
        let pos = bag::borrow_mut<SupplyPosition>(&mut market.supply_positions, user);
        pos.reward_debt = (pos.amount + amount) * market.supply_acc_per_share / PRECISION;
        pos.amount = pos.amount + amount;
    } else {
        bag::add<SupplyPosition>(
            &mut market.supply_positions,
            user,
            SupplyPosition {
                amount,
                reward_debt: amount * market.supply_acc_per_share / PRECISION,
            },
        );
    };
    market.supply_stake = market.supply_stake + amount;
}

public fun withdraw_supply<RewardCoin>(
    master: &mut LendingMiningMaster<RewardCoin>,
    market_id: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_market(master, market_id, clock);
    let user = ctx.sender();
    let market = table::borrow_mut(&mut master.markets, market_id);
    assert!(bag::contains(&market.supply_positions, user), ENotFound);
    let pos = bag::borrow_mut<SupplyPosition>(&mut market.supply_positions, user);
    assert!(pos.amount >= amount, EZeroAmount);
    pos.amount = pos.amount - amount;
    pos.reward_debt = pos.amount * market.supply_acc_per_share / PRECISION;
    market.supply_stake = market.supply_stake - amount;
}

public fun deposit_borrow<RewardCoin>(
    master: &mut LendingMiningMaster<RewardCoin>,
    market_id: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, EZeroAmount);
    update_market(master, market_id, clock);
    let user = ctx.sender();
    let market = table::borrow_mut(&mut master.markets, market_id);
    if (bag::contains(&market.borrow_positions, user)) {
        let pos = bag::borrow_mut<BorrowPosition>(&mut market.borrow_positions, user);
        pos.reward_debt = (pos.amount + amount) * market.borrow_acc_per_share / PRECISION;
        pos.amount = pos.amount + amount;
    } else {
        bag::add<BorrowPosition>(
            &mut market.borrow_positions,
            user,
            BorrowPosition {
                amount,
                reward_debt: amount * market.borrow_acc_per_share / PRECISION,
            },
        );
    };
    market.borrow_stake = market.borrow_stake + amount;
}

public fun withdraw_borrow<RewardCoin>(
    master: &mut LendingMiningMaster<RewardCoin>,
    market_id: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    update_market(master, market_id, clock);
    let user = ctx.sender();
    let market = table::borrow_mut(&mut master.markets, market_id);
    assert!(bag::contains(&market.borrow_positions, user), ENotFound);
    let pos = bag::borrow_mut<BorrowPosition>(&mut market.borrow_positions, user);
    assert!(pos.amount >= amount, EZeroAmount);
    pos.amount = pos.amount - amount;
    pos.reward_debt = pos.amount * market.borrow_acc_per_share / PRECISION;
    market.borrow_stake = market.borrow_stake - amount;
}

public fun claim<RewardCoin>(
    master: &mut LendingMiningMaster<RewardCoin>,
    market_id: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RewardCoin> {
    update_market(master, market_id, clock);
    let user = ctx.sender();
    let market = table::borrow_mut(&mut master.markets, market_id);
    let mut total_pending = 0u64;
    if (bag::contains(&market.supply_positions, user)) {
        let pos = bag::borrow_mut<SupplyPosition>(&mut market.supply_positions, user);
        let pending = pos.amount * market.supply_acc_per_share / PRECISION - pos.reward_debt;
        pos.reward_debt = pos.amount * market.supply_acc_per_share / PRECISION;
        total_pending = total_pending + pending;
    };
    if (bag::contains(&market.borrow_positions, user)) {
        let pos = bag::borrow_mut<BorrowPosition>(&mut market.borrow_positions, user);
        let pending = pos.amount * market.borrow_acc_per_share / PRECISION - pos.reward_debt;
        pos.reward_debt = pos.amount * market.borrow_acc_per_share / PRECISION;
        total_pending = total_pending + pending;
    };
    coin::take(&mut master.reward_balance, total_pending, ctx)
}
```

## 借贷挖矿的关键设计

### 存款/借款分离

每个市场维护两套独立的累加器：

```
供应侧：supply_acc_per_share += supply_reward_delta / total_supply_stake
借款侧：borrow_acc_per_share += borrow_reward_delta / total_borrow_stake
```

这允许协议对存款和借款设置不同的激励强度。

### 50/50 分配默认值

```move
let supply_acc_delta = reward_delta / 2 / total_supply_weight;
let borrow_acc_delta = reward_delta / 2 / total_borrow_weight;
```

默认将总奖励平均分配给供应侧和借款侧。实际协议可能用不同的比例（如 70/30 或 40/60）。

### Navi 风格的实际做法

Navi Protocol 的激励结构：

```
市场        存款激励    借款激励    说明
SUI         高          中         鼓励存入原生代币
USDC        中          高         鼓励借出稳定币
WETH        中          中         平衡
vSUI        极高        低         与 LSD 协议合作激励
```

Navi 使用 `emission_rate` 参数控制每个市场的代币释放速度，并通过治理定期调整。

## 风险分析

| 风险         | 描述                                                                    |
| ------------ | ----------------------------------------------------------------------- |
| 过度借款激励 | 如果借款激励 > 借款利息，实际借款利率为负，用户会无限循环借贷           |
| 激励套利     | 存入资产获得存款激励 → 抵押借出同一资产 → 借款也获得激励 → 净赚双份奖励 |
| 坏账积累     | 激励驱动的借款可能忽视清算风险，市场暴跌时产生大量坏账                  |
| 代币通胀     | 持续高激励导致代币大量增发，价格下行压力                                |
