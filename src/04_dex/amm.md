# 4.2 AMM：恒定乘积做市商

## 核心公式

$$x \cdot y = k$$

其中：
- $x$ = 池中代币 A 的数量
- $y$ = 池中代币 B 的数量
- $k$ = 常数（在无手续费的情况下不变）

当一个用户用 $\Delta x$ 的代币 A 换代币 B 时：

$$\Delta y = y - \frac{k}{x + \Delta x}$$

## 完整 Move 实现

```move
module amm {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientLiquidity: u64 = 0;
    const EInvalidAmount: u64 = 1;
    const EPoolPaused: u64 = 2;

    struct Pool<phantom A, phantom B> has key {
        id: UID,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        fee_bps: u64,
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
        fee_bps: u64,
        ctx: &mut TxContext,
    ) {
        let pool = Pool<A, B> {
            id: object::new(ctx),
            coin_a,
            coin_b,
            fee_bps,
            paused: false,
        };
        let cap = AdminCap {
            id: object::new(ctx),
            pool_id: object::id(&pool),
        };
        transfer::transfer(pool, tx_context::sender(ctx));
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    public fun provide_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        ctx: &mut TxContext,
    ): LP<A, B> {
        assert!(!pool.paused, EPoolPaused);
        let ra = coin::value(&coin_a);
        let rb = coin::value(&coin_b);
        let pa = coin::value(&pool.coin_a);
        let pb = coin::value(&pool.coin_b);
        assert!(ra * pb == rb * pa, EInvalidAmount);
        let shares = if (pa == 0) {
            sqrt(ra * rb)
        } else {
            ra * 1000000 / pa
        };
        coin::merge(&mut pool.coin_a, coin_a);
        coin::merge(&mut pool.coin_b, coin_b);
        LP<A, B> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            shares,
        }
    }

    public fun swap_a_to_b<A, B>(
        pool: &mut Pool<A, B>,
        input: Coin<A>,
        ctx: &mut TxContext,
    ): Coin<B> {
        assert!(!pool.paused, EPoolPaused);
        let amount_in = coin::value(&input);
        let reserve_a = coin::value(&pool.coin_a);
        let reserve_b = coin::value(&pool.coin_b);
        let fee = amount_in * pool.fee_bps / 10000;
        let amount_in_after_fee = amount_in - fee;
        let amount_out = get_amount_out(amount_in_after_fee, reserve_a, reserve_b);
        assert!(amount_out > 0, EInsufficientLiquidity);
        assert!(amount_out < reserve_b, EInsufficientLiquidity);
        coin::merge(&mut pool.coin_a, input);
        coin::take(&mut pool.coin_b, amount_out, ctx)
    }

    public fun swap_b_to_a<A, B>(
        pool: &mut Pool<A, B>,
        input: Coin<B>,
        ctx: &mut TxContext,
    ): Coin<A> {
        assert!(!pool.paused, EPoolPaused);
        let amount_in = coin::value(&input);
        let reserve_a = coin::value(&pool.coin_a);
        let reserve_b = coin::value(&pool.coin_b);
        let fee = amount_in * pool.fee_bps / 10000;
        let amount_in_after_fee = amount_in - fee;
        let amount_out = get_amount_out(amount_in_after_fee, reserve_b, reserve_a);
        assert!(amount_out > 0, EInsufficientLiquidity);
        assert!(amount_out < reserve_a, EInsufficientLiquidity);
        coin::merge(&mut pool.coin_b, input);
        coin::take(&mut pool.coin_a, amount_out, ctx)
    }

    public fun remove_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        lp: LP<A, B>,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        assert!(object::id(pool) == lp.pool_id, EInvalidAmount);
        let ra = coin::value(&pool.coin_a);
        let rb = coin::value(&pool.coin_b);
        let amount_a = lp.shares * ra / 1000000;
        let amount_b = lp.shares * rb / 1000000;
        let coin_a = coin::take(&mut pool.coin_a, amount_a, ctx);
        let coin_b = coin::take(&mut pool.coin_b, amount_b, ctx);
        object::delete(lp);
        (coin_a, coin_b)
    }

    public fun get_amount_out(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64,
    ): u64 {
        let numerator = (amount_in as u128) * (reserve_out as u128);
        let denominator = (reserve_in as u128) + (amount_in as u128);
        (numerator / denominator) as u64
    }

    fun sqrt(n: u64): u64 {
        let mut x = n;
        let mut y = (x + 1) / 2;
        while (y < x) {
            x = y;
            y = (x + n / x) / 2;
        };
        x
    }
}
```

## 数值示例

初始状态：SUI/USDC 池
- reserve_a (SUI) = 1,000
- reserve_b (USDC) = 2,000
- k = 2,000,000
- 费率 = 0.3% (30 bps)

用户 swap 100 USDC → SUI：
1. fee = 100 * 30 / 10000 = 0.3 USDC
2. amount_in_after_fee = 99.7 USDC
3. amount_out = 99.7 * 1000 / (2000 + 99.7) = 47.46 SUI
4. 交易后：reserve_a = 952.54, reserve_b = 2099.7
5. 新价格 = 2099.7 / 952.54 = 2.203 USDC/SUI（之前是 2.0）

## 滑点

滑点 = 实际成交价与期望价的偏差。

期望价格（池内边际价格）：2.0 USDC/SUI
实际成交价：100 / 47.46 = 2.108 USDC/SUI
滑点：(2.108 - 2.0) / 2.0 = 5.4%

交易量越大，滑点越高。池子越深，同等交易量的滑点越低。

## 无常损失（Impermanent Loss）

LP 提供流动性后，如果池内价格发生变化，LP 取回的资产价值会低于"持有不动"的价值。这个差额就是无常损失。

| 价格变化 | IL (%) |
|----------|--------|
| 1.25x | 0.6% |
| 1.5x | 2.0% |
| 2.0x | 5.7% |
| 3.0x | 13.4% |
| 5.0x | 25.5% |

"无常"是因为如果价格回到初始值，损失消失。但如果价格永远不回来，这个损失就是永久的。LP 需要手续费收益来弥补无常损失。
