# 4.4 Uniswap V2 完整实现

## 架构

Uniswap V2 是恒定乘积 AMM 的经典实现。核心组件：

- **Pair（交易对）**：存储两种代币的储备量
- **LP Token**：流动性提供者的份额凭证
- **Router**：辅助函数（非核心）

## Move 完整实现

```move
module uniswap_v2 {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientLiquidity: u64 = 0;
    const EInvalidAmount: u64 = 1;
    const EPoolPaused: u64 = 2;
    const EInvalidRatio: u64 = 3;
    const EInsufficientOutput: u64 = 4;
    const EUnauthorized: u64 = 5;
    const KLastMismatch: u64 = 6;

    public struct Pool<phantom A, phantom B> has key {
        id: UID,
        coin_a: Balance<A>,
        coin_b: Balance<B>,
        reserve_a: u64,
        reserve_b: u64,
        total_supply: u64,
        k_last: u128,
        fee_bps: u64,
        protocol_fee_bps: u64,
        paused: bool,
    }

    public struct LP<phantom A, phantom B> has key, store {
        id: UID,
        pool_id: ID,
        shares: u64,
    }

    public struct AdminCap has key, store {
        id: UID,
        pool_id: ID,
        fee_recipient: address,
    }

    public fun create_pool<A, B>(
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        fee_bps: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B>, AdminCap) {
        let pool = Pool<A, B> {
            id: object::new(ctx),
            coin_a: coin::into_balance(coin_a),
            coin_b: coin::into_balance(coin_b),
            reserve_a: 0,
            reserve_b: 0,
            total_supply: 0,
            k_last: 0,
            fee_bps,
            protocol_fee_bps: 500,
            paused: false,
        };
        let cap = AdminCap {
            id: object::new(ctx),
            pool_id: object::id(&pool),
            fee_recipient: ctx.sender(),
        };
        (pool, cap)
    }

    // === 流动性管理 ===

    public fun add_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        min_lp: u64,
        ctx: &mut TxContext,
    ): LP<A, B> {
        assert!(!pool.paused, EPoolPaused);
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, EInvalidAmount);

        mint_protocol_fee(pool);

        let shares = if (pool.total_supply == 0) {
            sqrt((amount_a as u128) * (amount_b as u128))
        } else {
            let shares_a = (amount_a as u128) * (pool.total_supply as u128) / (pool.reserve_a as u128);
            let shares_b = (amount_b as u128) * (pool.total_supply as u128) / (pool.reserve_b as u128);
            if (shares_a < shares_b) { shares_a } else { shares_b }
        };
        assert!(shares >= (min_lp as u128), EInsufficientOutput);

        pool.reserve_a = pool.reserve_a + amount_a;
        pool.reserve_b = pool.reserve_b + amount_b;
        pool.total_supply = pool.total_supply + (shares as u64);
        pool.k_last = (pool.reserve_a as u128) * (pool.reserve_b as u128);

        balance::join(&mut pool.coin_a, coin::into_balance(coin_a));
        balance::join(&mut pool.coin_b, coin::into_balance(coin_b));

        LP<A, B> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            shares: shares as u64,
        }
    }

    public fun remove_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        lp: LP<A, B>,
        min_a: u64,
        min_b: u64,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        assert!(object::id(pool) == lp.pool_id, EInvalidAmount);

        mint_protocol_fee(pool);

        let amount_a = (lp.shares as u128) * (pool.reserve_a as u128) / (pool.total_supply as u128);
        let amount_b = (lp.shares as u128) * (pool.reserve_b as u128) / (pool.total_supply as u128);
        assert!((amount_a as u64) >= min_a, EInsufficientOutput);
        assert!((amount_b as u64) >= min_b, EInsufficientOutput);

        pool.reserve_a = pool.reserve_a - (amount_a as u64);
        pool.reserve_b = pool.reserve_b - (amount_b as u64);
        pool.total_supply = pool.total_supply - lp.shares;
        pool.k_last = (pool.reserve_a as u128) * (pool.reserve_b as u128);

        let coin_a = coin::take(&mut pool.coin_a, amount_a as u64, ctx);
        let coin_b = coin::take(&mut pool.coin_b, amount_b as u64, ctx);
        .delete()(lp);
        (coin_a, coin_b)
    }

    // === 交易 ===

    public fun swap_exact_a_to_b<A, B>(
        pool: &mut Pool<A, B>,
        input: Coin<A>,
        min_output: u64,
        ctx: &mut TxContext,
    ): Coin<B> {
        assert!(!pool.paused, EPoolPaused);
        let amount_in = coin::value(&input);
        assert!(amount_in > 0, EInvalidAmount);

        let amount_out = get_amount_out(
            amount_in, pool.reserve_a, pool.reserve_b, pool.fee_bps
        );
        assert!(amount_out >= min_output, EInsufficientOutput);
        assert!(amount_out <= balance::value(&pool.coin_b), EInsufficientLiquidity);

        pool.reserve_a = pool.reserve_a + amount_in;
        pool.reserve_b = pool.reserve_b - amount_out;

        balance::join(&mut pool.coin_a, coin::into_balance(input));
        coin::take(&mut pool.coin_b, amount_out, ctx)
    }

    public fun swap_exact_b_to_a<A, B>(
        pool: &mut Pool<A, B>,
        input: Coin<B>,
        min_output: u64,
        ctx: &mut TxContext,
    ): Coin<A> {
        assert!(!pool.paused, EPoolPaused);
        let amount_in = coin::value(&input);
        assert!(amount_in > 0, EInvalidAmount);

        let amount_out = get_amount_out(
            amount_in, pool.reserve_b, pool.reserve_a, pool.fee_bps
        );
        assert!(amount_out >= min_output, EInsufficientOutput);
        assert!(amount_out <= balance::value(&pool.coin_a), EInsufficientLiquidity);

        pool.reserve_b = pool.reserve_b + amount_in;
        pool.reserve_a = pool.reserve_a - amount_out;

        balance::join(&mut pool.coin_b, coin::into_balance(input));
        coin::take(&mut pool.coin_a, amount_out, ctx)
    }

    // === 查询 ===

    public fun get_amount_out(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        fee_bps: u64,
    ): u64 {
        let amount_in_with_fee = ((amount_in as u128) * (10000 - fee_bps as u128)) / 10000;
        let numerator = amount_in_with_fee * (reserve_out as u128);
        let denominator = (reserve_in as u128) + amount_in_with_fee;
        (numerator / denominator) as u64
    }

    public fun quote(
        amount_a: u64,
        reserve_a: u64,
        reserve_b: u64,
    ): u64 {
        assert!(amount_a > 0, EInvalidAmount);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);
        ((amount_a as u128) * (reserve_b as u128) / (reserve_a as u128)) as u64
    }

    public fun get_price<A, B>(pool: &Pool<A, B>): u64 {
        if (pool.reserve_a == 0) { return 0 };
        ((pool.reserve_b as u128) * 1000000 / (pool.reserve_a as u128)) as u64
    }

    // === 内部函数 ===

    fun mint_protocol_fee<A, B>(pool: &mut Pool<A, B>) {
        let k_now = (pool.reserve_a as u128) * (pool.reserve_b as u128);
        if (pool.k_last != 0 && k_now > pool.k_last) {
            let k_growth = k_now - pool.k_last;
            let protocol_share = k_growth * (pool.protocol_fee_bps as u128) / 10000;
            if (protocol_share > 0) {
                let root = sqrt(protocol_share);
                pool.total_supply = pool.total_supply + (root as u64);
            };
        };
        pool.k_last = k_now;
    }

    fun sqrt(n: u128): u128 {
        if (n == 0) { return 0 };
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

## 关键设计决策

| 决策 | 原因 |
|------|------|
| `reserve_a/b` 独立于 `coin_a/b` | reserve 记录"记账值"，coin 记录"实际余额"，可以校验一致性 |
| `min_output` 参数 | 滑点保护，防止三明治攻击 |
| `k_last` 和协议费 | 协议从手续费中抽取一部分，通过 k 值增长计算 |
| 第一个 LP 用 `sqrt(x*y)` 计算份额 | 确保初始份额与注入的几何平均值成正比 |
| 后续 LP 取 `min(shares_a, shares_b)` | 防止通过不成比例的存款稀释现有 LP |

## 与固定汇率 DEX 的对比

| 维度 | 固定汇率 | Uniswap V2 |
|------|----------|-----------|
| 价格来源 | 管理员设定 | 池内比例自动调整 |
| 滑点 | 零 | 有，与交易量成正比 |
| 流动性提供 | 管理员注入 | 任何人都可以提供 |
| LP 激励 | 无 | 手续费分成 |
| 适用场景 | 稳定币互换 | 任意代币对 |
