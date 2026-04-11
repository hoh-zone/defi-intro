# 4.5 Uniswap V3 集中流动性

## V2 的问题：资金效率低

Uniswap V2 的流动性均匀分布在 (0, ∞) 的价格范围内。但实际交易集中在很窄的区间。

```
SUI/USDC 池，价格在 1.8-2.2 之间波动 95% 的时间
但 V2 把流动性浪费在 0.001 和 10000 这种极端价格上

实际有用的流动性可能只有总量的 5%
```

Uniswap V3 的解决方案：**让 LP 选择价格区间，只在这个区间内提供流动性。**

## Tick 机制

价格空间被离散化为 tick。每个 tick 对应一个价格：

$$p(i) = 1.0001^i$$

| tick | 价格 |
|------|------|
| 0 | 1.0 |
| 100 | ~1.01 |
| 10000 | ~2.718 (e) |
| -10000 | ~0.368 (1/e) |
| 23026 | ~10.0 |

LP 选择 [tick_lower, tick_upper] 作为价格区间。

## 核心数学

### 流动性与虚拟储备的关系

$$L = \sqrt{x \cdot y}$$

在区间 $[p_a, p_b]$ 内提供流动性 $L$ 时，需要的代币数量取决于当前价格 $p$ 相对于区间的位置：

$$x = L \cdot \frac{\sqrt{p_b} - \sqrt{p}}{\sqrt{p} \cdot \sqrt{p_b}} \quad \text{(if } p_a \leq p \leq p_b\text{)}$$

$$y = L \cdot (\sqrt{p} - \sqrt{p_a}) \quad \text{(if } p_a \leq p \leq p_b\text{)}$$

### Swap 计算

swap 时逐个 tick 步进：

$$\Delta y = L \cdot (\sqrt{p_{current}} - \sqrt{p_{target}})$$

$$\Delta x = L \cdot \frac{\sqrt{p_{target}} - \sqrt{p_{current}}}{\sqrt{p_{current}} \cdot \sqrt{p_{target}}}$$

## Move 实现

```move
module uniswap_v3 {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientLiquidity: u64 = 100;
    const EInvalidTick: u64 = 101;
    const EPositionNotActive: u64 = 102;
    const EPoolPaused: u64 = 103;
    const EInvalidAmount: u64 = 104;

    public struct Pool<phantom A, phantom B> has key {
        id: UID,
        coin_a: Balance<A>,
        coin_b: Balance<B>,
        sqrt_price: u128,
        current_tick: u64,
        tick_spacing: u64,
        liquidity: u128,
        fee_growth_global_a: u128,
        fee_growth_global_b: u128,
        fee_bps: u64,
        paused: bool,
    }

    public struct TickInfo has store {
        liquidity_gross: u128,
        fee_growth_outside_a: u128,
        fee_growth_outside_b: u128,
        initialized: bool,
    }

    public struct Position<phantom A, phantom B> has key, store {
        id: UID,
        pool_id: ID,
        tick_lower: u64,
        tick_upper: u64,
        liquidity: u128,
        fee_growth_inside_last_a: u128,
        fee_growth_inside_last_b: u128,
        tokens_owed_a: u64,
        tokens_owed_b: u64,
    }

    public struct AdminCap has key, store {
        id: UID,
        pool_id: ID,
    }

    public fun create_pool<A, B>(
        initial_a: Coin<A>,
        initial_b: Coin<B>,
        initial_sqrt_price: u128,
        tick_spacing: u64,
        fee_bps: u64,
        ctx: &mut TxContext,
    ): Pool<A, B> {
        let amount_a = coin::value(&initial_a);
        let amount_b = coin::value(&initial_b);
        let liquidity = if (initial_sqrt_price == 0) {
            sqrt((amount_a as u128) * (amount_b as u128))
        } else {
            calculate_liquidity_from_amounts(
                amount_a, amount_b, initial_sqrt_price
            )
        };
        Pool<A, B> {
            id: object::new(ctx),
            coin_a: coin::into_balance(initial_a),
            coin_b: coin::into_balance(initial_b),
            sqrt_price: initial_sqrt_price,
            current_tick: sqrt_price_to_tick(initial_sqrt_price),
            tick_spacing,
            liquidity,
            fee_growth_global_a: 0,
            fee_growth_global_b: 0,
            fee_bps,
            paused: false,
        }
    }

    public fun add_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        tick_lower: u64,
        tick_upper: u64,
        coin_input_a: Coin<A>,
        coin_input_b: Coin<B>,
        amount_a_min: u64,
        amount_b_min: u64,
        ctx: &mut TxContext,
    ): (Position<A, B>, Coin<A>, Coin<B>) {
        assert!(!pool.paused, EPoolPaused);
        assert!(tick_lower < tick_upper, EInvalidTick);
        assert!(tick_lower % pool.tick_spacing == 0, EInvalidTick);
        assert!(tick_upper % pool.tick_spacing == 0, EInvalidTick);

        let amount_a_desired = coin::value(&coin_input_a);
        let amount_b_desired = coin::value(&coin_input_b);

        let (amount_a, amount_b, liquidity) = calculate_position_amounts(
            pool.sqrt_price,
            tick_lower,
            tick_upper,
            amount_a_desired,
            amount_b_desired,
        );
        assert!(amount_a >= amount_a_min, EInvalidAmount);
        assert!(amount_b >= amount_b_min, EInvalidAmount);

        update_tick(pool, tick_lower, liquidity, true);
        update_tick(pool, tick_upper, liquidity, true);

        if (tick_lower <= pool.current_tick && pool.current_tick < tick_upper) {
            pool.liquidity = pool.liquidity + liquidity;
        };

        let position = Position<A, B> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            tick_lower,
            tick_upper,
            liquidity,
            fee_growth_inside_last_a: pool.fee_growth_global_a,
            fee_growth_inside_last_b: pool.fee_growth_global_b,
            tokens_owed_a: 0,
            tokens_owed_b: 0,
        };

        let refund_a = if (amount_a_desired > amount_a) {
            coin::split(&mut coin_input_a, amount_a_desired - amount_a, ctx)
        } else { coin::zero(ctx) };
        let refund_b = if (amount_b_desired > amount_b) {
            coin::split(&mut coin_input_b, amount_b_desired - amount_b, ctx)
        } else { coin::zero(ctx) };

        balance::join(&mut pool.coin_a, coin::into_balance(coin_input_a));
        balance::join(&mut pool.coin_b, coin::into_balance(coin_input_b));

        (position, refund_a, refund_b)
    }

    public fun swap<A, B>(
        pool: &mut Pool<A, B>,
        amount_in: u64,
        zero_for_one: bool,
        sqrt_price_limit: u128,
        ctx: &mut TxContext,
    ): Coin<B> {
        assert!(!pool.paused, EPoolPaused);
        let mut remaining = amount_in;
        let mut total_output = 0u64;

        while (remaining > 0 && pool.liquidity > 0) {
            let (amount_used, amount_out, new_sqrt_price, new_tick) =
                compute_swap_step(
                    pool.sqrt_price,
                    sqrt_price_limit,
                    pool.liquidity,
                    remaining,
                    pool.fee_bps,
                );
            remaining = remaining - amount_used;
            total_output = total_output + amount_out;
            pool.sqrt_price = new_sqrt_price;

            if (new_tick != pool.current_tick) {
                cross_tick(pool, new_tick);
                pool.current_tick = new_tick;
            };
        };

        assert!(total_output > 0, EInsufficientLiquidity);
        coin::take(&mut pool.coin_b, total_output, ctx)
    }

    public fun collect_fees<A, B>(
        pool: &mut Pool<A, B>,
        position: &mut Position<A, B>,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        update_position_fees(pool, position);
        let owed_a = position.tokens_owed_a;
        let owed_b = position.tokens_owed_b;
        position.tokens_owed_a = 0;
        position.tokens_owed_b = 0;
        (
            coin::take(&mut pool.coin_a, owed_a, ctx),
            coin::take(&mut pool.coin_b, owed_b, ctx),
        )
    }

    // === 内部计算 ===

    fun compute_swap_step(
        sqrt_price_current: u128,
        sqrt_price_target: u128,
        liquidity: u128,
        amount_remaining: u64,
        fee_bps: u64,
    ): (u64, u64, u128, u64) {
        let amount_in = get_amount_in_from_delta(
            sqrt_price_current, sqrt_price_target, liquidity
        );
        let amount_in_with_fee = ((amount_in as u128) * (10000 - fee_bps as u128) / 10000) as u64;
        let (used, sqrt_price_new) = if (amount_remaining >= amount_in_with_fee) {
            (amount_in_with_fee, sqrt_price_target)
        } else {
            (amount_remaining, get_next_sqrt_price_from_amount(
                sqrt_price_current, liquidity, amount_remaining
            ))
        };
        let amount_out = get_amount_out_from_delta(
            sqrt_price_current, sqrt_price_new, liquidity
        );
        let new_tick = sqrt_price_to_tick(sqrt_price_new);
        (used, amount_out, sqrt_price_new, new_tick)
    }

    fun get_amount_out_from_delta(
        sqrt_price_a: u128, sqrt_price_b: u128, liquidity: u128,
    ): u64 {
        let delta = if (sqrt_price_a > sqrt_price_b) {
            sqrt_price_a - sqrt_price_b
        } else {
            sqrt_price_b - sqrt_price_a
        };
        ((liquidity * delta) >> 64) as u64
    }

    fun get_amount_in_from_delta(
        sqrt_price_a: u128, sqrt_price_b: u128, liquidity: u128,
    ): u64 {
        let delta = if (sqrt_price_a > sqrt_price_b) {
            sqrt_price_a - sqrt_price_b
        } else {
            sqrt_price_b - sqrt_price_a
        };
        let denominator = sqrt_price_a * sqrt_price_b >> 64;
        (liquidity * delta / denominator) as u64
    }

    fun sqrt_price_to_tick(sqrt_price: u128): u64 {
        let price = (sqrt_price * sqrt_price) >> 128;
        ((price as u64) * 10000 / 100000000) as u64
    }

    fun tick_to_sqrt_price(tick: u64): u128 {
        let price = (tick as u128) * 100000000 / 10000;
        sqrt(price)
    }

    fun sqrt(n: u128): u128 {
        if (n == 0) { return 0 };
        let mut x = n;
        let mut y = (x + 1) / 2;
        while (y < x) { x = y; y = (x + n / x) / 2 };
        x
    }
}
```

## 资金效率对比

SUI/USDC 在 1.8-2.2 区间内波动：

| 指标 | Uniswap V2 | V3（4% 区间） |
|------|-----------|---------------|
| 1000 USDC 资金效率 | 1x | ~25x |
| 手续费收益 | 基准 | ~25x（区间内） |
| 需要主动管理 | 否 | 是 |
| 价格移出区间风险 | 无 | 单边持仓 |

V3 的效率提升不是免费的——LP 需要主动管理仓位，价格移出区间时资金变为单边持仓。
