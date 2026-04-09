# 4.7 StableSwap：稳定币互换的特殊曲线

## 问题

USDC/USDT 应该 1:1 兑换。但用 Uniswap V2 的 x·y=k 曲线，即使在 1:1 附近也有滑点：

```
USDC/USDT 池: 1,000,000 / 1,000,000
Swap 100,000 USDC → USDT:
输出 = 100,000 × 1,000,000 / (1,000,000 + 100,000) = 90,909
滑点 = 9.1%
```

对于应该 1:1 的稳定币对，9% 的滑点不可接受。

## StableSwap 曲线

Curve 的 StableSwap 曲线在 1:1 附近几乎是直线（零滑点），只在极端情况下弯曲：

$$A \cdot n^n \cdot \sum x_i + D = A \cdot D \cdot n^n + \frac{D^{n+1}}{n^n \cdot \prod x_i}$$

其中 $A$ 是放大系数，$D$ 是总储备的不变量。

当 $A$ 很大时，曲线接近直线（1:1）；当 $A = 0$ 时，退化为 x·y=k。

```
价格
  |        /
  |       /  ← x·y=k（V2 AMM）
  |      /
  |     /
  |----/---------- StableSwap（A 很大时几乎是平的）
  |   /
  |  /
  | /
  |/___________ 数量
```

## Move 实现

```move
module stableswap {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInvalidAmount: u64 = 300;
    const EInsufficientLiquidity: u64 = 301;
    const EPoolPaused: u64 = 302;
    const EConvergenceFailed: u64 = 303;

    struct Pool<phantom A, phantom B> has key {
        id: UID,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        amp_factor: u64,
        fee_bps: u64,
        admin_fee_bps: u64,
        paused: bool,
    }

    struct LP<phantom A, phantom B> has key, store {
        id: UID,
        pool_id: ID,
        shares: u64,
    }

    struct AdminCap has key, store {
        id: UID,
        pool_id: ID,
    }

    public fun create_pool<A, B>(
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        amp_factor: u64,
        fee_bps: u64,
        ctx: &mut TxContext,
    ) {
        let pool = Pool<A, B> {
            id: object::new(ctx),
            balance_a: coin::into_balance(coin_a),
            balance_b: coin::into_balance(coin_b),
            amp_factor,
            fee_bps,
            admin_fee_bps: 500,
            paused: false,
        };
        transfer::share_object(pool);
    }

    public fun swap_a_to_b<A, B>(
        pool: &mut Pool<A, B>,
        input: Coin<A>,
        min_output: u64,
        ctx: &mut TxContext,
    ): Coin<B> {
        assert!(!pool.paused, EPoolPaused);
        let amount_in = coin::value(&input);
        assert!(amount_in > 0, EInvalidAmount);

        let balance_a = balance::value(&pool.balance_a);
        let balance_b = balance::value(&pool.balance_b);
        let new_balance_a = balance_a + amount_in;

        let d = get_d(new_balance_a, balance_b, pool.amp_factor);
        let new_balance_b = get_y(d, new_balance_a, pool.amp_factor);
        let amount_out = balance_b - new_balance_b;

        let fee = amount_out * pool.fee_bps / 10000;
        let amount_out_after_fee = amount_out - fee;
        assert!(amount_out_after_fee >= min_output, EInsufficientLiquidity);

        balance::join(&mut pool.balance_a, coin::into_balance(input));
        coin::take(&mut pool.balance_b, amount_out_after_fee, ctx)
    }

    public fun get_d(x: u64, y: u64, amp: u64): u64 {
        let s = x + y;
        if (s == 0) { return 0 };
        let n = 2u128;
        let amp_n = (amp as u128) * n;
        let mut d = s as u128;
        let mut i = 0;
        while (i < 255) {
            let d_prev = d;
            let sum_prod = ((d as u128) * (d as u128) / (x as u128)) / (y as u128);
            let d_new = ((amp_n * s as u128) + (n * sum_prod * d)) * d
                / ((amp_n - 1) * d + (n + 1) * sum_prod);
            if (d_new == d_prev) { break };
            d = d_new;
            i = i + 1;
        };
        d as u64
    }

    public fun get_y(d: u64, x: u64, amp: u64): u64 {
        let n = 2u128;
        let amp_n = (amp as u128) * n;
        let d_u128 = d as u128;
        let c = d_u128 * d_u128 / (x as u128);
        c = c * d_u128 / (amp_n * n * n);
        let b = x as u128 + d_u128 / amp_n;
        let mut y = d_u128;
        let mut i = 0;
        while (i < 255) {
            let y_prev = y;
            y = (y * y + c) / (2 * y + b - d_u128);
            if (y == y_prev) { break };
            i = i + 1;
        };
        y as u64
    }

    public fun get_amount_out(
        pool: &Pool<A, B>,
        amount_in: u64,
        zero_for_one: bool,
    ): u64 {
        let balance_a = balance::value(&pool.balance_a);
        let balance_b = balance::value(&pool.balance_b);
        if (zero_for_one) {
            let d = get_d(balance_a + amount_in, balance_b, pool.amp_factor);
            let new_b = get_y(d, balance_a + amount_in, pool.amp_factor);
            balance_b - new_b
        } else {
            let d = get_d(balance_a, balance_b + amount_in, pool.amp_factor);
            let new_a = get_y(d, balance_b + amount_in, pool.amp_factor);
            balance_a - new_a
        }
    }
}
```

## 数值对比

USDC/USDT 池：1,000,000 / 1,000,000，amp = 100

| Swap 金额 | V2 输出 | StableSwap 输出 | StableSwap 滑点 |
|-----------|---------|-----------------|-----------------|
| 1,000 | 999 | ~1000 | ~0% |
| 10,000 | 9,901 | ~9,999 | ~0.01% |
| 100,000 | 90,909 | ~99,500 | ~0.5% |
| 500,000 | 333,333 | ~480,000 | ~4% |

StableSwap 在小额交易时几乎没有滑点，只有在大额交易时才出现明显偏差。

## amp_factor 的选择

| amp 值 | 适用场景 | 价格范围 |
|--------|----------|----------|
| 1 | 等同于 V2 AMM | 任意 |
| 10 | 波动较大的相关资产 | 较宽 |
| 100 | 稳定币对 | 极窄 |
| 1000 | 高度锚定的代币 | 几乎 1:1 |
