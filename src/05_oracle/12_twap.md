# 5.12 TWAP：时间加权平均价格

## TWAP 的原理

TWAP（Time-Weighted Average Price）不是预言机，而是从 AMM 池中计算平均价格的方法。它是预言机的补充：

```
预言机价格：
  来自外部数据源（Pyth/Supra/Switchboard）
  → 快速、准确，但依赖外部信任假设

TWAP 价格：
  从链上 AMM 池的累积价格计算
  → 无需外部信任，但更新慢、容易被短期操纵影响
```

### 数学原理

```
累积价格（Cumulative Price）：
  cumulative_price += spot_price × Δt

TWAP 计算：
  TWAP = (cumulative_price_now - cumulative_price_old) / time_elapsed

直觉：
  把每一瞬间的价格按时间加权，时间越长，短期操纵的影响越小
```

## 完整 Move 实现

```move
module oracle::twap {
    use sui::object::{Self, UID};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::balance::Balance;
    use sui::tx_context::TxContext;
    use sui::event;

    const EZeroTime: u64 = 0;
    const EInsufficientHistory: u64 = 1;

    public struct TwapPool has key {
        id: UID,
        coin_a_balance: Balance<A>,
        coin_b_balance: Balance<B>,
        cumulative_price_a_in_b: u128,
        cumulative_price_b_in_a: u128,
        last_update_ms: u64,
        last_price_a_in_b: u64,
        observations: vector<Observation>,
        max_observations: u64,
    }

    public struct Observation has store {
        timestamp_ms: u64,
        cumulative_price: u128,
    }

    public struct TwapResult has store {
        twap_price: u64,
        start_time_ms: u64,
        end_time_ms: u64,
        observations_used: u64,
    }

    public fun create<A, B>(
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, 0);
        let initial_price = amount_b * 1_000_000_000 / amount_a;
        let pool = TwapPool<A, B> {
            id: object::new(ctx),
            coin_a_balance: coin::into_balance(coin_a),
            coin_b_balance: coin::into_balance(coin_b),
            cumulative_price_a_in_b: 0,
            cumulative_price_b_in_a: 0,
            last_update_ms: clock.timestamp_ms(),
            last_price_a_in_b: initial_price,
            observations: vector::empty(),
            max_observations: 100,
        };
        transfer::share_object(pool);
    }

    public fun update<A, B>(
        pool: &mut TwapPool<A, B>,
        clock: &Clock,
    ) {
        let now = clock.timestamp_ms();
        if (now <= pool.last_update_ms) { return };
        let elapsed = (now - pool.last_update_ms) as u128;
        let balance_a = balance::value(&pool.coin_a_balance);
        let balance_b = balance::value(&pool.coin_b_balance);
        if (balance_a == 0) { return };
        let spot_price = (balance_b as u128) * 1_000_000_000 / (balance_a as u128);
        pool.cumulative_price_a_in_b = pool.cumulative_price_a_in_b + spot_price * elapsed;
        pool.last_price_a_in_b = (spot_price as u64);
        pool.last_update_ms = now;
        if (pool.observations.length() >= pool.max_observations) {
            pool.observations.remove(0);
        };
        pool.observations.push_back(Observation {
            timestamp_ms: now,
            cumulative_price: pool.cumulative_price_a_in_b,
        });
    }

    public fun get_twap<A, B>(
        pool: &TwapPool<A, B>,
        window_ms: u64,
        clock: &Clock,
    ): TwapResult {
        let now = clock.timestamp_ms();
        let start_time = now - window_ms;
        assert!(pool.observations.length() >= 2, EInsufficientHistory);
        let mut start_cumulative = 0u128;
        let mut end_cumulative = 0u128;
        let mut found = false;
        let mut i = 0;
        while (i < pool.observations.length()) {
            let obs = pool.observations.borrow(i);
            if (obs.timestamp_ms >= start_time && !found) {
                start_cumulative = obs.cumulative_price;
                found = true;
            };
            end_cumulative = obs.cumulative_price;
            i = i + 1;
        };
        assert!(found, EInsufficientHistory);
        let time_elapsed = (now - start_time) as u128;
        assert!(time_elapsed > 0, EZeroTime);
        let twap = ((end_cumulative - start_cumulative) / time_elapsed) as u64;
        TwapResult {
            twap_price: twap,
            start_time_ms: start_time,
            end_time_ms: now,
            observations_used: pool.observations.length(),
        }
    }

    public fun twap_price(result: &TwapResult): u64 {
        result.twap_price
    }
}
```

## TWAP 作为预言机补充

```
使用场景：

场景 1：AMM 价格交叉验证
  Pyth 说 SUI = $1.20
  TWAP 说 SUI = $1.18
  偏差 1.7% → 可接受

场景 2：Fallback 价格源
  如果所有外部预言机都不可用
  使用 TWAP 作为最后手段

场景 3：操纵检测
  如果 Pyth 价格偏离 TWAP > 5%
  → 可能有人在操纵预言机

场景 4：低价值资产
  某些长尾代币没有预言机支持
  TWAP 是唯一的价格来源
```

## TWAP 的操纵成本

```
操纵 TWAP 的成本随时间窗口指数增长：

操纵 1 分钟 TWAP：
  需要在 1 分钟内持续操纵 AMM 价格
  成本 ≈ pool_liquidity × target_deviation

操纵 1 小时 TWAP：
  需要在 1 小时内持续操纵
  成本 ≈ pool_liquidity × target_deviation × 60

操纵 1 天 TWAP：
  成本 ≈ pool_liquidity × target_deviation × 1440

结论：TWAP 窗口越长，操纵成本越高
推荐窗口：30 分钟到 4 小时
```

## 风险分析

| 风险 | 描述 |
|---|---|
| 低流动性池 | TWAP 在低流动性池中容易操纵 |
| 数据延迟 | TWAP 反映的是过去一段时间的平均价格，不是实时价格 |
| 观测点不足 | 如果 update 调用不频繁，TWAP 精度低 |
| 仅限 AMM | TWAP 只能从 AMM 池计算，无法用于订单簿 DEX |
