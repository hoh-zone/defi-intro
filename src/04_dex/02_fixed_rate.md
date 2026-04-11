# 4.2 固定汇率兑换：最简单的 DEX

## 场景

你想把 USDC 兑换成 USDT。两者都是美元稳定币，理论上 1:1。最简单的实现方式是什么？

硬编码一个固定汇率。

## Move 实现

```move
module fixed_rate_dex {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientBalance: u64 = 0;
    const EInvalidAmount: u64 = 1;
    const EPoolPaused: u64 = 2;
    const EUnauthorized: u64 = 3;

    public struct FixedRatePool<phantom A, phantom B> has key {
        id: UID,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        rate_bps: u64,
        paused: bool,
    }

    public struct AdminCap has key, store {
        id: UID,
        pool_id: ID,
    }

    public fun create_pool<A, B>(
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        rate_bps: u64,
        ctx: &mut TxContext,
    ) {
        let pool = FixedRatePool<A, B> {
            id: object::new(ctx),
            balance_a: coin::into_balance(coin_a),
            balance_b: coin::into_balance(coin_b),
            rate_bps,
            paused: false,
        };
        let cap = AdminCap {
            id: object::new(ctx),
            pool_id: object::id(&pool),
        };
        transfer::share_object(pool);
        transfer::transfer(cap, ctx.sender());
    }

    public fun swap_a_to_b<A, B>(
        pool: &mut FixedRatePool<A, B>,
        input: Coin<A>,
        ctx: &mut TxContext,
    ): Coin<B> {
        assert!(!pool.paused, EPoolPaused);
        let amount_in = coin::value(&input);
        assert!(amount_in > 0, EInvalidAmount);
        let amount_out = amount_in * pool.rate_bps / 10000;
        assert!(balance::value(&pool.balance_b) >= amount_out, EInsufficientBalance);
        balance::join(&mut pool.balance_a, coin::into_balance(input));
        coin::take(&mut pool.balance_b, amount_out, ctx)
    }

    public fun swap_b_to_a<A, B>(
        pool: &mut FixedRatePool<A, B>,
        input: Coin<B>,
        ctx: &mut TxContext,
    ): Coin<A> {
        assert!(!pool.paused, EPoolPaused);
        let amount_in = coin::value(&input);
        assert!(amount_in > 0, EInvalidAmount);
        let inverse_rate = 10000 * 10000 / pool.rate_bps;
        let amount_out = amount_in * inverse_rate / 10000;
        assert!(balance::value(&pool.balance_a) >= amount_out, EInsufficientBalance);
        balance::join(&mut pool.balance_b, coin::into_balance(input));
        coin::take(&mut pool.balance_a, amount_out, ctx)
    }

    public fun add_liquidity<A, B>(
        _cap: &AdminCap,
        pool: &mut FixedRatePool<A, B>,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
    ) {
        balance::join(&mut pool.balance_a, coin::into_balance(coin_a));
        balance::join(&mut pool.balance_b, coin::into_balance(coin_b));
    }

    public fun pause<A, B>(_cap: &AdminCap, pool: &mut FixedRatePool<A, B>) {
        pool.paused = true;
    }
}
```

## 这个实现的特点

### 优点
- **零滑点**：无论交易多少，汇率始终是 1:1（或固定比率）
- **确定性**：输出金额可以精确计算
- **实现简单**：没有复杂的数学，只有乘除法

### 局限
- **只能处理价值相等的代币**：USDC/USDT 可以，SUI/USDC 不行
- **没有价格发现功能**：汇率是管理员设定的，不是市场决定的
- **流动性依赖管理员注入**：池子没钱了就停摆
- **没有激励机制**：没有人会因为提供流动性而获得收益

## 数值示例

USDC → USDT，rate_bps = 10000（1:1）：

| 操作 | 输入 | 输出 | 滑点 |
|------|------|------|------|
| Swap 100 USDC | 100 USDC | 100 USDT | 0% |
| Swap 1,000,000 USDC | 1,000,000 USDC | 1,000,000 USDT | 0% |

SUI → USDC，假设 rate_bps = 20000（1 SUI = 2 USDC）：

| 操作 | 输入 | 输出 | 滑点 |
|------|------|------|------|
| Swap 100 SUI | 100 SUI | 200 USDC | 0% |

但问题是：如果市场上 SUI 价格从 $2 变成 $1.8，这个池子的汇率还是 $2。管理员需要手动更新 `rate_bps`，否则就会被套利。

## 从固定汇率到 AMM 的跳板

固定汇率的根本问题：**它无法反映市场价格的变化。**

我们需要一种机制，让价格根据池子中两种代币的供需关系自动调整。这就是 AMM（自动做市商）要解决的问题。
