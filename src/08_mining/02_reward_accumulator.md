# 8.2 奖励累加器：Move 基础实现

## 核心数学

奖励累加器（Reward Accumulator）是所有流动性挖矿的基础数据结构。问题定义：

> 有 N 个用户质押了不同数量的资产，奖励以固定速率 R 持续产生。用户可以随时存入或取出。如何精确计算每个用户应得的奖励？

解法：**每份额累计奖励**（reward per share）。

```
设：
  S(t) = 时刻 t 的总质押量
  R    = 每单位时间奖励量
  Δt   = 距上次更新的时间间隔

则：
  reward_per_share += R × Δt / S(t)

每个用户的奖励：
  user_reward = user_stake × (reward_per_share - user_reward_debt)
  user_reward_debt = user_stake × reward_per_share
```

`user_reward_debt` 的含义是"上次交互时，该用户按份额应得的累计奖励"。差值就是自上次以来新增的奖励。

### 为什么不用"直接累加"

直觉上可以给每个用户每秒加 `user_stake / total_stake * R` 的奖励。但这样全局每秒需要遍历所有用户——O(N) 的链上操作，不可行。

累加器的巧妙之处：**只在用户交互时计算**。全局只维护一个 `reward_per_share` 变量，每个用户记住自己的 `reward_debt`。O(1) 更新。

## 完整 Move 实现

```move
module liquidity_mining::accumulator;

use sui::bag::{Self, Bag};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::object::{Self, UID};
use sui::sui::SUI;
use sui::tx_context::TxContext;

#[error]
const EInsufficientStake: vector<u8> = b"Insufficient Stake";
#[error]
const EZeroStake: vector<u8> = b"Zero Stake";
#[error]
const EPoolNotStarted: vector<u8> = b"Pool Not Started";
#[error]
const ENotStaker: vector<u8> = b"Not Staker";

const PRECISION: u64 = 1_000_000_000;

public struct RewardPool<phantom StakeCoin, phantom RewardCoin> has key {
    id: UID,
    total_stake: u64,
    acc_reward_per_share: u64,
    reward_rate_per_ms: u64,
    last_update_ms: u64,
    period_finish_ms: u64,
    reward_coins: Coin<RewardCoin>,
    stakes: Bag,
}

public struct UserStake has store {
    amount: u64,
    reward_debt: u64,
}

public fun create_pool<StakeCoin, RewardCoin>(
    reward_amount: Coin<RewardCoin>,
    duration_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let reward_value = coin::value(&reward_amount);
    let rate = reward_value / duration_ms;
    let pool = RewardPool<StakeCoin, RewardCoin> {
        id: object::new(ctx),
        total_stake: 0,
        acc_reward_per_share: 0,
        reward_rate_per_ms: rate,
        last_update_ms: clock.timestamp_ms(),
        period_finish_ms: clock.timestamp_ms() + duration_ms,
        reward_coins: reward_amount,
        stakes: bag::new(ctx),
    };
    transfer::share_object(pool);
}

fun update_reward<StakeCoin, RewardCoin>(
    pool: &mut RewardPool<StakeCoin, RewardCoin>,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();
    if (now <= pool.last_update_ms) { return };
    if (pool.total_stake == 0) {
        pool.last_update_ms = now;
        return;
    };
    let end = if (now < pool.period_finish_ms) { now } else { pool.period_finish_ms };
    let elapsed = end - pool.last_update_ms;
    let reward = pool.reward_rate_per_ms * elapsed;
    pool.acc_reward_per_share = pool.acc_reward_per_share + (reward * PRECISION / pool.total_stake);
    pool.last_update_ms = if (now < pool.period_finish_ms) { now } else { pool.period_finish_ms };
}

public fun stake<StakeCoin, RewardCoin>(
    pool: &mut RewardPool<StakeCoin, RewardCoin>,
    coin: Coin<StakeCoin>,
    user: address,
    clock: &Clock,
) {
    update_reward<StakeCoin, RewardCoin>(pool, clock);
    let amount = coin::value(&coin);
    assert!(amount > 0, EZeroStake);

    if (bag::contains(&pool.stakes, user)) {
        let user_stake = bag::borrow_mut<UserStake>(&mut pool.stakes, user);
        let pending =
            user_stake.amount * pool.acc_reward_per_share / PRECISION - user_stake.reward_debt;
        user_stake.reward_debt =
            (user_stake.amount + amount) * pool.acc_reward_per_share / PRECISION;
        user_stake.amount = user_stake.amount + amount;
    } else {
        let user_stake = UserStake {
            amount,
            reward_debt: amount * pool.acc_reward_per_share / PRECISION,
        };
        bag::add(&mut pool.stakes, user, user_stake);
    };

    coin::put(&mut pool.reward_coins, coin);
    pool.total_stake = pool.total_stake + amount;
}

public fun unstake<StakeCoin, RewardCoin>(
    pool: &mut RewardPool<StakeCoin, RewardCoin>,
    amount: u64,
    user: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<StakeCoin> {
    update_reward<StakeCoin, RewardCoin>(pool, clock);
    assert!(bag::contains(&pool.stakes, user), ENotStaker);
    let user_stake = bag::borrow_mut<UserStake>(&mut pool.stakes, user);
    assert!(user_stake.amount >= amount, EInsufficientStake);
    user_stake.amount = user_stake.amount - amount;
    user_stake.reward_debt = user_stake.amount * pool.acc_reward_per_share / PRECISION;

    pool.total_stake = pool.total_stake - amount;
    coin::take(&mut pool.reward_coins, amount, ctx)
}

public fun claim<StakeCoin, RewardCoin>(
    pool: &mut RewardPool<StakeCoin, RewardCoin>,
    user: address,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<RewardCoin> {
    update_reward<StakeCoin, RewardCoin>(pool, clock);
    assert!(bag::contains(&pool.stakes, user), ENotStaker);
    let user_stake = bag::borrow_mut<UserStake>(&mut pool.stakes, user);
    let pending =
        user_stake.amount * pool.acc_reward_per_share / PRECISION - user_stake.reward_debt;
    user_stake.reward_debt = user_stake.amount * pool.acc_reward_per_share / PRECISION;
    coin::take(&mut pool.reward_coins, pending, ctx)
}

public fun pending_reward<StakeCoin, RewardCoin>(
    pool: &RewardPool<StakeCoin, RewardCoin>,
    user: address,
    clock: &Clock,
): u64 {
    if (!bag::contains(&pool.stakes, user)) { return 0 };
    let user_stake = bag::borrow<UserStake>(&pool.stakes, user);
    let now = clock.timestamp_ms();
    let end = if (now < pool.period_finish_ms) { now } else { pool.period_finish_ms };
    let elapsed = if (end > pool.last_update_ms) { end - pool.last_update_ms } else { 0 };
    let acc =
        pool.acc_reward_per_share + (pool.reward_rate_per_ms * elapsed * PRECISION / (if (pool.total_stake == 0) { 1 } else { pool.total_stake }));
    user_stake.amount * acc / PRECISION - user_stake.reward_debt
}
```

## 关键设计决策

### PRECISION 常量

```move
const PRECISION: u64 = 1_000_000_000;
```

Move 使用整数运算，没有浮点数。`reward_per_share` 可能非常小（例如 0.000001 token/share），所以乘以 `PRECISION`（10^9）来保留精度。

这等价于 Solidity 中的 `1e18` 或 `1e12` 精度因子。选择 10^9 是因为 Sui 的 Coin 通常使用 9 位小数。

### reward_debt 更新时机

每次用户交互（stake/unstake/claim）都更新 `reward_debt`：

- 先结算已积累的奖励
- 再按新的份额数重置 debt

如果忘记这一步，用户可以通过频繁 stake/unstake 来重复领取奖励——一个经典的挖矿合约漏洞。

### 零质押保护

```move
if (pool.total_stake == 0) {
    pool.last_update_ms = now;
    return;
};
```

当 `total_stake = 0` 时，如果继续计算 `reward / total_stake`，会除零崩溃。但奖励仍在产生——所以我们只更新时间戳，不更新累加器。奖励实际上"丢失"了。

**设计选择**：这是故意的。如果没有人质押，奖励不应该积累给未来第一个进来的用户。否则第一个质押者可以立刻获得一大笔奖励。

## 风险分析

| 风险         | 描述                                     | 防护                                                  |
| ------------ | ---------------------------------------- | ----------------------------------------------------- |
| 精度丢失     | 整数除法截断可能导致小份额用户的奖励为 0 | PRECISION 足够大，且只在 claim 时实际分发             |
| 奖励耗尽     | `coin::take` 可能因余额不足而 abort      | 需要在 `reward_rate` 设置时确保总奖励足够覆盖整个周期 |
| reentrancy   | Sui Move 的对象模型天然防止重入          | —                                                     |
| 空池奖励丢失 | total_stake=0 期间的奖励无法被任何人领取 | 如上所述，这是设计选择                                |
