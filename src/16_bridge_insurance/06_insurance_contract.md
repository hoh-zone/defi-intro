# 16.6 保险合约完整实现

## 参数型保险的完整 Move 实现

```move
module insurance::parametric {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::clock::Clock;
    use sui::event;
    use sui::table::{Self, Table};
    use sui::math;

    const E_UNAUTHORIZED: u64 = 0;
    const E_POLICY_EXPIRED: u64 = 1;
    const E_NOT_TRIGGERED: u64 = 2;
    const E_ALREADY_CLAIMED: u64 = 3;
    const E_INSUFFICIENT_POOL: u64 = 4;
    const E_INVALID_AMOUNT: u64 = 5;
    const E_POLICY_ACTIVE: u64 = 6;

    public struct InsurancePool<phantom PayoutCoin> has key {
        id: UID,
        capital: Balance<PayoutCoin>,
        total_exposure: u64,
        max_exposure_ratio_bps: u64,
        policies: Table<u64, Policy>,
        policy_counter: u64,
        trigger_condition: TriggerCondition,
        admin: address,
    }

    public struct Policy has store {
        holder: address,
        coverage_amount: u64,
        premium_paid: u64,
        start_ms: u64,
        end_ms: u64,
        claimed: bool,
        trigger_price: u64,
    }

    public struct TriggerCondition has store {
        price_feed_id: address,
        trigger_type: u8,
        threshold_value: u64,
        duration_ms: u64,
        triggered_since_ms: u64,
        is_triggered: bool,
    }

    public struct PolicyPurchased has copy, drop {
        policy_id: u64,
        holder: address,
        coverage: u64,
        premium: u64,
        end_ms: u64,
    }

    public struct ClaimPaid has copy, drop {
        policy_id: u64,
        holder: address,
        payout: u64,
    }

    public struct PoolCapitalized has copy, drop {
        provider: address,
        amount: u64,
    }

    public fun create_pool<PayoutCoin>(
        seed: Coin<PayoutCoin>,
        trigger_type: u8,
        threshold_value: u64,
        duration_ms: u64,
        max_exposure_ratio_bps: u64,
        ctx: &mut TxContext,
    ) {
        let pool = InsurancePool<PayoutCoin> {
            id: object::new(ctx),
            capital: coin::into_balance(seed),
            total_exposure: 0,
            max_exposure_ratio_bps,
            policies: table::new(ctx),
            policy_counter: 0,
            trigger_condition: TriggerCondition {
                price_feed_id: @0x0,
                trigger_type,
                threshold_value,
                duration_ms,
                triggered_since_ms: 0,
                is_triggered: false,
            },
            admin: tx_context::sender(ctx),
        };
        transfer::share_object(pool);
    }

    public fun provide_capital<PayoutCoin>(
        pool: &mut InsurancePool<PayoutCoin>,
        coin: Coin<PayoutCoin>,
        ctx: &mut TxContext,
    ) {
        let amount = coin::value(&coin);
        balance::join(&mut pool.capital, coin::into_balance(coin));
        event::emit(PoolCapitalized {
            provider: tx_context::sender(ctx),
            amount,
        });
    }

    public fun purchase_policy<PayoutCoin>(
        pool: &mut InsurancePool<PayoutCoin>,
        premium: Coin<PayoutCoin>,
        coverage_amount: u64,
        duration_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        let premium_amount = coin::value(&premium);
        assert!(premium_amount > 0, E_INVALID_AMOUNT);
        assert!(coverage_amount > 0, E_INVALID_AMOUNT);
        let new_exposure = pool.total_exposure + coverage_amount;
        let max_coverage = balance::value(&pool.capital) * pool.max_exposure_ratio_bps / 10000;
        assert!(new_exposure <= max_coverage, E_INSUFFICIENT_POOL);
        balance::join(&mut pool.capital, coin::into_balance(premium));
        let policy_id = pool.policy_counter;
        pool.policy_counter = pool.policy_counter + 1;
        let policy = Policy {
            holder: tx_context::sender(ctx),
            coverage_amount,
            premium_paid: premium_amount,
            start_ms: clock.timestamp_ms(),
            end_ms: clock.timestamp_ms() + duration_ms,
            claimed: false,
            trigger_price: pool.trigger_condition.threshold_value,
        };
        table::add(&mut pool.policies, policy_id, policy);
        pool.total_exposure = new_exposure;
        event::emit(PolicyPurchased {
            policy_id,
            holder: tx_context::sender(ctx),
            coverage: coverage_amount,
            premium: premium_amount,
            end_ms: clock.timestamp_ms() + duration_ms,
        });
        policy_id
    }

    public fun update_trigger<PayoutCoin>(
        pool: &mut InsurancePool<PayoutCoin>,
        current_price: u64,
        clock: &Clock,
    ) {
        let trigger = &mut pool.trigger_condition;
        if (trigger.trigger_type == 0) {
            let below = current_price < trigger.threshold_value;
            if (below && !trigger.is_triggered) {
                trigger.is_triggered = true;
                trigger.triggered_since_ms = clock.timestamp_ms();
            } else if (!below) {
                trigger.is_triggered = false;
                trigger.triggered_since_ms = 0;
            };
        } else {
            let above = current_price > trigger.threshold_value;
            if (above && !trigger.is_triggered) {
                trigger.is_triggered = true;
                trigger.triggered_since_ms = clock.timestamp_ms();
            } else if (!above) {
                trigger.is_triggered = false;
                trigger.triggered_since_ms = 0;
            };
        };
    }

    public fun is_trigger_active<PayoutCoin>(pool: &InsurancePool<PayoutCoin>, clock: &Clock): bool {
        let trigger = &pool.trigger_condition;
        if (!trigger.is_triggered) { return false };
        let elapsed = clock.timestamp_ms() - trigger.triggered_since_ms;
        elapsed >= trigger.duration_ms
    }

    public fun claim<PayoutCoin>(
        pool: &mut InsurancePool<PayoutCoin>,
        policy_id: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<PayoutCoin> {
        assert!(is_trigger_active(pool, clock), E_NOT_TRIGGERED);
        let policy = table::borrow_mut(&mut pool.policies, policy_id);
        assert!(tx_context::sender(ctx) == policy.holder, E_UNAUTHORIZED);
        assert!(clock.timestamp_ms() <= policy.end_ms, E_POLICY_EXPIRED);
        assert!(!policy.claimed, E_ALREADY_CLAIMED);
        policy.claimed = true;
        pool.total_exposure = pool.total_exposure - policy.coverage_amount;
        let payout = policy.coverage_amount;
        assert!(balance::value(&pool.capital) >= payout, E_INSUFFICIENT_POOL);
        event::emit(ClaimPaid {
            policy_id,
            holder: tx_context::sender(ctx),
            payout,
        });
        coin::take(&mut pool.capital, payout, ctx)
    }

    public fun pool_capacity<PayoutCoin>(pool: &InsurancePool<PayoutCoin>): u64 {
        let capital = balance::value(&pool.capital);
        capital * pool.max_exposure_ratio_bps / 10000
    }

    public fun remaining_capacity<PayoutCoin>(pool: &InsurancePool<PayoutCoin>): u64 {
        let cap = pool_capacity(pool);
        if (pool.total_exposure >= cap) { 0 } else { cap - pool.total_exposure }
    }

    public fun calculate_premium(
        coverage_amount: u64,
        probability_bps: u64,
        duration_days: u64,
        risk_multiplier_bps: u64,
    ): u64 {
        let annual_expected_loss = coverage_amount * probability_bps / 10000;
        let daily_premium = annual_expected_loss / 365;
        daily_premium * duration_days * risk_multiplier_bps / 10000
    }
}
```

## 保费定价的数学

```
年化保费 = 保额 × 事件概率 × 损失率 × 风险调整系数

示例：
  协议 TVL：$100M
  被攻击概率：3%/年
  平均损失率：70%
  风险调整系数：2.0

  保额 $10,000 的年保费：
  = $10,000 × 0.03 × 0.70 × 2.0
  = $420（4.2% 费率）
```

## 资金池管理

```
资金池设计：
  总资金 = 资本提供者的资金 + 累计保费收入
  最大敞口 = 总资金 × max_exposure_ratio（如 80%）
  剩余容量 = 最大敞口 - 已承保金额

资本提供者的收益：
  保费收入 + 未赔付的保单
  风险：赔付时从资金池中支出

触发条件检查：
  预言机价格更新 → 检查是否满足触发条件
  → 如果满足且持续 duration_ms → 触发激活
  → 保单持有人可以 claim
```

## 风险分析

| 风险 | 描述 |
|---|---|
| 资金池耗尽 | 多个保单同时触发赔付，资金池不足以覆盖 |
| 预言机操纵 | 攻击者操纵价格触发条件来骗取赔付 |
| 定价不准 | 保费太低无法覆盖损失，太高没人买 |
| 流动性锁定 | 资本提供者的资金被长期锁定 |
| 关联风险 | 被保险的协议之间高度相关，系统性事件导致集中赔付 |
