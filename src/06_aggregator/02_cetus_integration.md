# 6.2 Cetus CLMM 的路由集成

## Cetus 的集中流动性模型

Cetus 使用 CLMM（Concentrated Liquidity Market Maker），类似于 Uniswap V3。流动性集中在价格区间内，每个 tick 有独立的流动性状态。

```move
module cetus_clmm {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};

    struct Pool has key {
        id: UID,
        coin_a_type: u8,
        coin_b_type: u8,
        current_tick: u64,
        tick_spacing: u64,
        fee_bps: u64,
        sqrt_price: u128,
        liquidity: u128,
        fee_growth_global_a: u128,
        fee_growth_global_b: u128,
    }

    struct TickBitmap has key {
        id: UID,
        pool_id: ID,
        bitmap: vector<u64>,
    }

    struct Position has key, store {
        id: UID,
        pool_id: ID,
        tick_lower: u64,
        tick_upper: u64,
        liquidity: u128,
        tokens_owed_a: u64,
        tokens_owed_b: u64,
    }

    public fun swap_a_to_b(
        pool: &mut Pool,
        tick_bitmap: &mut TickBitmap,
        amount_in: u64,
        sqrt_price_limit: u128,
        ctx: &mut TxContext,
    ): (Coin<A>, u64) {
        let mut remaining = amount_in;
        let mut total_output = 0u64;
        let mut fee_paid = 0u64;

        while (remaining > 0) {
            let (amount_used, amount_out, new_sqrt_price, new_tick) =
                compute_swap_step(pool, remaining, sqrt_price_limit);
            remaining = remaining - amount_used;
            total_output = total_output + amount_out;
            pool.sqrt_price = new_sqrt_price;
            pool.current_tick = new_tick;

            if (remaining > 0) {
                cross_tick(pool, tick_bitmap, new_tick);
            };
        };

        pool.liquidity = recalculate_liquidity(pool, tick_bitmap);
        (coin::mint(&mut get_treasury(), total_output, ctx), total_output)
    }

    fun compute_swap_step(
        pool: &Pool,
        amount_remaining: u64,
        sqrt_price_limit: u128,
    ): (u64, u64, u128, u64) {
        let tick_current = pool.current_tick;
        let tick_next = find_next_initialized_tick(pool, tick_current);
        let sqrt_price_next = tick_to_sqrt_price(tick_next);
        let sqrt_price_target = if (sqrt_price_next < sqrt_price_limit) {
            sqrt_price_next
        } else {
            sqrt_price_limit
        };
        let amount_in = calculate_amount_in(
            pool.sqrt_price, sqrt_price_target, pool.liquidity
        );
        let amount_in_with_fee = amount_in * (10000 - pool.fee_bps) / 10000;
        let (used, sqrt_price_new) = if (amount_remaining >= amount_in_with_fee) {
            (amount_in_with_fee, sqrt_price_target)
        } else {
            (amount_remaining, calculate_new_sqrt_price(
                pool.sqrt_price, pool.liquidity, amount_remaining
            ))
        };
        let amount_out = calculate_amount_out(
            pool.sqrt_price, sqrt_price_new, pool.liquidity
        );
        let new_tick = sqrt_price_to_tick(sqrt_price_new);
        (used, amount_out, sqrt_price_new, new_tick)
    }
}
```

## 聚合器如何与 Cetus 交互

### 1. 读取链上状态

聚合器需要获取每个池子的：
- `sqrt_price`（当前价格）
- `liquidity`（当前 tick 的流动性）
- `fee_bps`（手续费率）
- Tick Bitmap（哪些 tick 有流动性）

### 2. 链下模拟

```typescript
async function quoteCetus(poolId: string, amountIn: number): Promise<number> {
    const pool = await fetchPoolState(poolId);
    let remaining = amountIn;
    let totalOut = 0;
    let sqrtPrice = pool.sqrtPrice;
    let currentTick = pool.currentTick;
    let liquidity = pool.liquidity;

    while (remaining > 0) {
        const nextTick = findNextInitializedTick(pool.tickBitmap, currentTick);
        const step = computeSwapStep(sqrtPrice, liquidity, remaining, nextTick);
        totalOut += step.amountOut;
        remaining -= step.amountUsed;
        sqrtPrice = step.sqrtPriceNew;
        currentTick = step.newTick;
        if (remaining > 0) {
            liquidity = getLiquidityAtTick(pool, currentTick);
        }
    }
    return totalOut;
}
```

### 3. 构造 PTB 执行

```typescript
function buildCetusSwapPTB(
    poolId: string,
    amountIn: number,
    minAmountOut: number,
    coinIn: TransactionObjectArg
): TransactionObjectArg {
    const ptb = new TransactionBlock();
    const [coinOut] = ptb.moveCall({
        target: `${CETUS_PACKAGE}::pool::swap_a_to_b`,
        arguments: [
            ptb.object(poolId),
            ptb.object(TICK_BITMAP_ID),
            ptb.pure(amountIn),
            ptb.pure(MIN_SQRT_PRICE),
        ],
        typeArguments: [COIN_A_TYPE, COIN_B_TYPE],
    });
    return coinOut;
}
```

## Cetus 的特点对聚合器的影响

| 特点 | 影响 |
|------|------|
| 集中流动性 | 同一池子在不同价格区间流动性不同，拆单需要考虑 tick 位置 |
| 多费率档位 | 同一交易对可能有多个不同费率的池子，聚合器需要比较 |
| 闪电聚合 | Cetus 自带的跨池路由功能，聚合器可以利用 |
| Tick 跳跃 | swap 可能跨越多个 tick，每个 tick 流动性不同 |
