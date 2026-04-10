# 8.6 Boost 与 VeToken 投票

## 问题的提出

基础累加器按质押量线性分配奖励：质押 100 份额得 10% 奖励，质押 200 份额得 20%。但这有一个问题：

> **短期投机者和长期支持者获得相同比例的奖励。**

协议希望奖励长期参与者，但基础累加器无法区分。解决方案：

1. **Boost**：锁仓时间越长，获得的奖励倍数越高
2. **VeToken 投票**：锁仓获得治理代币，用治理代币投票决定奖励分配

## Curve VeToken 模型

Curve 的 veCRV 是最经典的 Boost 模型：

```
锁仓 1 年 → 1 veCRV/CRV
锁仓 2 年 → 2 veCRV/CRV
锁仓 4 年 → 4 veCRV/CRV

基础奖励 = 40%（按质押量分配）
Boost 奖励 = 60%（按 veCRV 量分配）

用户的 boost 倍数：
  boost = min(4, 0.4 + 0.6 × user_veCRV / (total_veCRV × user_stake / total_stake))
```

## Boost 累加器的 Move 实现

```move
module liquidity_mining::boost_mining {
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::bag::{Self, Bag};
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;

    const E_ZERO_AMOUNT: u64 = 0;
    const E_UNAUTHORIZED: u64 = 1;
    const E_NOT_FOUND: u64 = 2;
    const E_LOCK_TOO_SHORT: u64 = 3;
    const E_ALREADY_LOCKED: u64 = 4;
    const PRECISION: u64 = 1_000_000_000;
    const BASE_RATIO: u64 = 400_000_000;
    const BOOST_RATIO: u64 = 600_000_000;
    const MAX_BOOST: u64 = 4;

    public struct BoostPool<phantom StakeCoin, phantom RewardCoin> has key {
        id: UID,
        total_stake: u64,
        total_boost_weight: u64,
        acc_base_per_share: u64,
        acc_boost_per_weight: u64,
        reward_rate_per_ms: u64,
        last_update_ms: u64,
        reward_balance: Coin<RewardCoin>,
        positions: Bag,
        locks: Bag,
        admin: address,
    }

    public struct Position has store {
        stake_amount: u64,
        base_reward_debt: u64,
        boost_reward_debt: u64,
    }

    public struct LockInfo has store {
        amount: u64,
        end_ms: u64,
        slope: u64,
    }

    public fun create<StakeCoin, RewardCoin>(
        initial_reward: Coin<RewardCoin>,
        duration_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let pool = BoostPool<StakeCoin, RewardCoin> {
            id: object::new(ctx),
            total_stake: 0,
            total_boost_weight: 0,
            acc_base_per_share: 0,
            acc_boost_per_weight: 0,
            reward_rate_per_ms: coin::value(&initial_reward) / duration_ms,
            last_update_ms: clock.timestamp_ms(),
            reward_balance: initial_reward,
            positions: bag::new(ctx),
            locks: bag::new(ctx),
            admin: tx_context::sender(ctx),
        };
        transfer::share_object(pool);
    }

    public fun lock_for_boost(
        pool: &mut BoostPool<_, _>,
        amount: u64,
        duration_ms: u64,
        user: address,
        clock: &Clock,
    ) {
        assert!(duration_ms >= 86_400_000 * 7, E_LOCK_TOO_SHORT);
        assert!(!bag::contains(&pool.locks, user), E_ALREADY_LOCKED);
        let max_duration_ms: u64 = 86_400_000 * 365 * 4;
        let normalized_duration = if (duration_ms > max_duration_ms) { max_duration_ms } else { duration_ms };
        let slope = amount * PRECISION / max_duration_ms;
        let boost_weight = slope * normalized_duration / PRECISION;
        let lock = LockInfo {
            amount,
            end_ms: clock.timestamp_ms() + duration_ms,
            slope,
        };
        bag::add(&mut pool.locks, user, lock);
        pool.total_boost_weight = pool.total_boost_weight + boost_weight;
    }

    fun get_user_boost_weight(
        pool: &BoostPool<_, _>,
        user: address,
        clock: &Clock,
    ): u64 {
        if (!bag::contains(&pool.locks, user)) { return 0 };
        let lock = bag::borrow<LockInfo>(&pool.locks, user);
        let now = clock.timestamp_ms();
        if (now >= lock.end_ms) { return 0 };
        let remaining = lock.end_ms - now;
        lock.slope * remaining / PRECISION
    }

    fun update_pool(
        pool: &mut BoostPool<_, _>,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();
        if (now <= pool.last_update_ms) { return };
        if (pool.total_stake == 0) {
            pool.last_update_ms = now;
            return;
        };
        let elapsed = now - pool.last_update_ms;
        let total_reward = pool.reward_rate_per_ms * elapsed;
        let base_reward = total_reward * BASE_RATIO / PRECISION;
        let boost_reward = total_reward * BOOST_RATIO / PRECISION;

        pool.acc_base_per_share = pool.acc_base_per_share + base_reward * PRECISION / pool.total_stake;

        if (pool.total_boost_weight > 0) {
            pool.acc_boost_per_weight = pool.acc_boost_per_weight + boost_reward * PRECISION / pool.total_boost_weight;
        };

        pool.last_update_ms = now;
    }

    public fun stake<StakeCoin, RewardCoin>(
        pool: &mut BoostPool<StakeCoin, RewardCoin>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        update_pool(pool, clock);
        let user = tx_context::sender(ctx);
        if (bag::contains(&pool.positions, user)) {
            let pos = bag::borrow_mut<Position>(&mut pool.positions, user);
            pos.base_reward_debt = (pos.stake_amount + amount) * pool.acc_base_per_share / PRECISION;
            let bw = get_user_boost_weight(pool, user, clock);
            pos.boost_reward_debt = bw * pool.acc_boost_per_weight / PRECISION;
            pos.stake_amount = pos.stake_amount + amount;
        } else {
            bag::add<Position>(&mut pool.positions, user, Position {
                stake_amount: amount,
                base_reward_debt: amount * pool.acc_base_per_share / PRECISION,
                boost_reward_debt: 0,
            });
        };
        pool.total_stake = pool.total_stake + amount;
    }

    public fun pending<StakeCoin, RewardCoin>(
        pool: &BoostPool<StakeCoin, RewardCoin>,
        user: address,
        clock: &Clock,
    ): u64 {
        if (!bag::contains(&pool.positions, user)) { return 0 };
        let pos = bag::borrow<Position>(&pool.positions, user);
        let base_pending = pos.stake_amount * pool.acc_base_per_share / PRECISION - pos.base_reward_debt;
        let bw = get_user_boost_weight(pool, user, clock);
        let boost_pending = bw * pool.acc_boost_per_weight / PRECISION - pos.boost_reward_debt;
        base_pending + boost_pending
    }
}
```

## Gauge 投票：分配权的民主化

Curve 的另一个创新是 **Gauge Voting**：

```
1. 用户锁仓 CRV → 获得 veCRV
2. 用户用 veCRV 为不同的流动性池投票
3. 每个池子获得的投票比例 = 它在总奖励中的分配比例
```

这把"奖励怎么分"的权力从协议团队转移到了社区。

### Gauge 投票的 Move 实现

```move
module liquidity_mining::gauge_voting {
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::bag::{Self, Bag};
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::table::{Self, Table};

    const E_ZERO_VOTE: u64 = 0;
    const E_NO_POWER: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;

    public struct VoteEscrow has key {
        id: UID,
        total_power: u64,
        gauge_votes: Table<address, u64>,
        voter_power: Bag,
        gauges: vector<address>,
    }

    public struct VoterPower has store {
        used: u64,
        allocations: Bag,
    }

    public fun create(ctx: &mut TxContext) {
        let ve = VoteEscrow {
            id: object::new(ctx),
            total_power: 0,
            gauge_votes: table::new(ctx),
            voter_power: bag::new(ctx),
            gauges: vector::empty(),
        };
        transfer::share_object(ve);
    }

    public fun vote(
        ve: &mut VoteEscrow,
        gauge_id: address,
        weight: u64,
        ctx: &mut TxContext,
    ) {
        let voter = tx_context::sender(ctx);
        assert!(bag::contains(&ve.voter_power, voter), E_NO_VOTE);
        let power = bag::borrow_mut<VoterPower>(&mut ve.voter_power, voter);

        if (bag::contains(&power.allocations, gauge_id)) {
            let old_weight = *bag::borrow<u64>(&power.allocations, gauge_id);
            if (table::contains(&ve.gauge_votes, gauge_id)) {
                let current = table::borrow_mut(&mut ve.gauge_votes, gauge_id);
                *current = *current - old_weight + weight;
            };
            ve.total_power = ve.total_power - old_weight + weight;
            power.used = power.used - old_weight + weight;
        } else {
            if (!table::contains(&ve.gauge_votes, gauge_id)) {
                table::add(&mut ve.gauge_votes, gauge_id, weight);
                ve.gauges.push_back(gauge_id);
            } else {
                let current = table::borrow_mut(&mut ve.gauge_votes, gauge_id);
                *current = *current + weight;
            };
            ve.total_power = ve.total_power + weight;
            power.used = power.used + weight;
        };

        bag::add(&mut power.allocations, gauge_id, weight);
    }

    public fun gauge_weight(ve: &VoteEscrow, gauge_id: address): u64 {
        if (table::contains(&ve.gauge_votes, gauge_id)) {
            *table::borrow(&ve.gauge_votes, gauge_id)
        } else {
            0
        }
    }

    public fun gauge_share(ve: &VoteEscrow, gauge_id: address): u64 {
        if (ve.total_power == 0) { return 0 };
        let w = gauge_weight(ve, gauge_id);
        w * 1_000_000_000 / ve.total_power
    }
}
```

## Boost 效果示例

```
用户 A：质押 1000 LP，锁仓 4 年 → boost 倍数 3.5x
用户 B：质押 1000 LP，无锁仓   → boost 倍数 1.0x

总奖励 = 100 token/day
基础奖励（40%）= 40 token，按质押量均分 → 各得 20
Boost 奖励（60%）= 60 token，按 boost weight 分 → A 得 52.5，B 得 7.5

用户 A 总计：72.5 token/day（实际倍数 1.45x）
用户 B 总计：27.5 token/day（实际倍数 0.55x）
```

## 风险分析

| 风险 | 描述 |
|---|---|
| Vote buying | 大户通过 OTC 购买 veToken 集中投票权，将奖励导向自己的池子 |
| Boost 上限 | MAX_BOOST=4 意味着长期锁仓者的奖励上限是短期的 4 倍，但差距可能不够大 |
| 锁仓流动性 | 锁仓期间资产不可用，用户面临机会成本 |
| 治理集中 | 少数大鲸鱼可能控制大部分 veToken，实质上中心化了奖励分配 |
| Gauge bribery | 项目方通过贿赂 veToken 持有者来获得更多 gauge weight |
