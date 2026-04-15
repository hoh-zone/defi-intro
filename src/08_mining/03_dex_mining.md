# 8.3 DEX 流动性挖矿算法

## DEX 挖矿的业务逻辑

DEX 流动性挖矿的核心流程：

```
1. 用户在 DEX 添加流动性 → 获得 LP Token
2. 用户将 LP Token 质押到挖矿合约
3. 合约按质押份额持续发放奖励代币
4. 用户随时可以取消质押并领取奖励
```

与基础累加器的区别在于：**多池并行分发**。一个 DEX 可能有几十个交易对，每个交易对都有一个挖矿池，共享一个总奖励预算。需要解决的问题是：如何在多个池子之间分配有限的奖励？

## 多池权重分发

```move
module liquidity_mining::dex_mining;

use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::math::max;
use sui::object::{Self, UID};
use sui::table::{Self, Table};
use sui::tx_context::TxContext;

#[error]
const EZeroAmount: vector<u8> = b"Zero Amount";
#[error]
const EUnauthorized: vector<u8> = b"Unauthorized";
#[error]
const EPoolNotFound: vector<u8> = b"Pool Not Found";
#[error]
const EInvalidWeight: vector<u8> = b"Invalid Weight";
const PRECISION: u64 = 1_000_000_000;

public struct MiningMaster<phantom RewardCoin> has key {
    id: UID,
    total_weight: u64,
    reward_rate_per_ms: u64,
    last_update_ms: u64,
    global_acc_per_weight: u64,
    pools: Table<address, MiningPool>,
    admin: address,
}

public struct MiningPool has store {
    lp_coin_type: String,
    total_stake: u64,
    weight: u64,
    acc_reward_per_share: u64,
    last_acc_per_weight: u64,
    stakes: Bag,
}

public struct UserPosition has store {
    amount: u64,
    reward_debt: u64,
}

public fun initialize<RewardCoin>(
    initial_reward: Coin<RewardCoin>,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let reward_value = coin::value(&initial_reward);
    let rate = reward_value / duration_ms;
    let master = MiningMaster<RewardCoin> {
        id: object::new(ctx),
        total_weight: 0,
        reward_rate_per_ms: rate,
        last_update_ms: clock.timestamp_ms(),
        global_acc_per_weight: 0,
        pools: table::new(ctx),
        admin: ctx.sender(),
    };
    transfer::public_share_object(master);
    transfer::public_freeze_object(initial_reward);
}

public fun add_pool<RewardCoin>(
    master: &mut MiningMaster<RewardCoin>,
    pool_id: address,
    lp_coin_type: String,
    weight: u64,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == master.admin, EUnauthorized);
    assert!(weight > 0, EInvalidWeight);
    assert!(!table::contains(&master.pools, pool_id), EPoolNotFound);
    let pool = MiningPool {
        lp_coin_type,
        total_stake: 0,
        weight,
        acc_reward_per_share: 0,
        last_acc_per_weight: master.global_acc_per_weight,
        stakes: bag::new(ctx),
    };
    master.total_weight = master.total_weight + weight;
    table::add(&mut master.pools, pool_id, pool);
}

fun update_pool<RewardCoin>(
    master: &mut MiningMaster<RewardCoin>,
    pool_id: address,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();
    if (now <= master.last_update_ms) { return };
    if (master.total_weight == 0) {
        master.last_update_ms = now;
        return;
    };
    let elapsed = now - master.last_update_ms;
    let global_acc =
        master.global_acc_per_weight + (master.reward_rate_per_ms * elapsed * PRECISION / master.total_weight);
    let pool = table::borrow_mut(&mut master.pools, pool_id);
    if (pool.total_stake > 0) {
        let pool_reward_delta = (global_acc - pool.last_acc_per_weight) * pool.weight;
        pool.acc_reward_per_share =
            pool.acc_reward_per_share + pool_reward_delta / pool.total_stake;
    };
    pool.last_acc_per_weight = global_acc;
    master.global_acc_per_weight = global_acc;
    master.last_update_ms = now;
}

public fun deposit<RewardCoin, LpCoin>(
    master: &mut MiningMaster<RewardCoin>,
    pool_id: address,
    lp_coin: Coin<LpCoin>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount = coin::value(&lp_coin);
    assert!(amount > 0, EZeroAmount);
    update_pool(master, pool_id, clock);
    let user = ctx.sender();
    let pool = table::borrow_mut(&mut master.pools, pool_id);
    if (bag::contains(&pool.stakes, user)) {
        let pos = bag::borrow_mut<UserPosition>(&mut pool.stakes, user);
        let pending = pos.amount * pool.acc_reward_per_share / PRECISION - pos.reward_debt;
        pos.reward_debt = (pos.amount + amount) * pool.acc_reward_per_share / PRECISION;
        pos.amount = pos.amount + amount;
    } else {
        bag::add<UserPosition>(
            &mut pool.stakes,
            user,
            UserPosition {
                amount,
                reward_debt: amount * pool.acc_reward_per_share / PRECISION,
            },
        );
    };
    pool.total_stake = pool.total_stake + amount;
    coin::destroy_zero(lp_coin);
}

public fun withdraw<RewardCoin, LpCoin>(
    master: &mut MiningMaster<RewardCoin>,
    pool_id: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<LpCoin> {
    update_pool(master, pool_id, clock);
    let user = ctx.sender();
    let pool = table::borrow_mut(&mut master.pools, pool_id);
    assert!(bag::contains(&pool.stakes, user), EUnauthorized);
    let pos = bag::borrow_mut<UserPosition>(&mut pool.stakes, user);
    assert!(pos.amount >= amount, EZeroAmount);
    pos.amount = pos.amount - amount;
    pos.reward_debt = pos.amount * pool.acc_reward_per_share / PRECISION;
    pool.total_stake = pool.total_stake - amount;
    coin::zero(ctx)
}

public fun set_weight<RewardCoin>(
    master: &mut MiningMaster<RewardCoin>,
    pool_id: address,
    new_weight: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == master.admin, EUnauthorized);
    let pool = table::borrow_mut(&mut master.pools, pool_id);
    let old_weight = pool.weight;
    master.total_weight = master.total_weight - old_weight + new_weight;
    pool.weight = new_weight;
}
```

## 权重分发的数学

核心公式：

```
全局累加器（每单位权重每毫秒奖励）：
  global_acc_per_weight += rate_per_ms × Δt / total_weight

单个池子获得的奖励增量：
  pool_reward_delta = (global_acc - pool.last_acc) × pool.weight

池子每份额累加器：
  pool_acc_per_share += pool_reward_delta / pool.total_stake
```

**两级累加器**：全局按权重分配给池子，池子按份额分配给用户。

### 权重示例

假设有三个池子，总奖励 100 token/天：

| 池子     | 权重 | 分配比例 | 日奖励 |
| -------- | ---- | -------- | ------ |
| SUI/USDC | 50   | 50%      | 50     |
| ETH/USDC | 30   | 30%      | 30     |
| MEME/SUI | 20   | 20%      | 20     |

管理员可以随时调整权重，激励会立即按新权重分配。

## Cetus 风格的挖矿

Cetus DEX 的实际挖矿架构：

```
┌─────────────────────────────────────────┐
│              IncentiveMaster             │
│  ├─ Pool 1: SUI/USDC (weight: 50)       │
│  │   └─ 用户质押 SUI/USDC LP Token      │
│  ├─ Pool 2: ETH/USDC (weight: 30)       │
│  │   └─ 用户质押 ETH/USDC LP Token      │
│  └─ Pool 3: CETUS/USDC (weight: 20)     │
│      └─ 用户质押 CETUS/USDC LP Token    │
│                                         │
│  奖励来源：协议国库 CETUS 代币           │
│  分配方式：按权重比例分发到各池           │
└─────────────────────────────────────────┘
```

Cetus 使用 CLMM（集中流动性），LP Token 实际上是 NFT（代表特定的价格区间仓位）。挖矿时需要将 NFT 质押，奖励按仓位内的流动性大小而非 LP Token 数量分配。

## 风险分析

| 风险              | 描述                                                                  |
| ----------------- | --------------------------------------------------------------------- |
| 权重操控          | 管理员可以随时改权重——如果权重被集中到低流动性池，该池的 APR 会异常高 |
| LP Token 价值风险 | 用户暴露在 LP Token 的无常损失风险 + 奖励代币的价格风险上，双重风险   |
| 提前撤资          | 如果奖励不够覆盖无常损失，LP 可能集体撤资，导致 DEX 流动性枯竭        |
| 合约升级风险      | 多池合约复杂度高，升级时可能引入新的漏洞                              |
