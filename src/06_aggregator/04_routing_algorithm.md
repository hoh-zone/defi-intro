# 6.4 路径搜索与拆单算法

## 单源路由 vs 多源拆单

### 单源路由

整笔交易全部走一个 DEX。简单但可能不是最优。

```
输入: 10000 USDC
路由: 100% → Cetus
输出: 5000 SUI
```

### 多源拆单

将交易拆分到多个 DEX，每个 DEX 执行一部分。总输出可能更大。

```
输入: 10000 USDC
拆单:
  40% → Cetus  → 2010 SUI  (价格 1.990)
  35% → DeepBook → 1770 SUI  (价格 1.983)
  25% → Kriya  → 1255 SUI  (价格 1.990)
总计: 5035 SUI  (比单源多 35 SUI)
```

## 拆单的数学原理

给定两个流动性源 $f_1$ 和 $f_2$，要最大化总输出：

$$\max f_1(x_1) + f_2(x_2) \quad \text{s.t.} \quad x_1 + x_2 = X$$

最优条件是两个源的边际输出率相等：

$$f_1'(x_1) = f_2'(x_2)$$

### AMM 的边际输出率

$$f'(x) = \frac{(1-fee) \cdot R_B \cdot R_A}{(R_A + (1-fee) \cdot x)^2}$$

### 订单簿的边际输出率

离散的——在每个价格档位上是常数。

## Move 实现：两源拆单

```move
module aggregator_split {
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};

    const EInsufficientOutput: u64 = 600;

    struct SplitRoute has store {
        pool_a_id: ID,
        pool_b_id: ID,
        share_a_bps: u64,
        amount_in: u64,
        min_output: u64,
        deadline: u64,
    }

    public fun execute_split<A, B, Quote>(
        route: &SplitRoute,
        pool_a: &mut PoolA,
        pool_b: &mut PoolB,
        input: Coin<Quote>,
        ctx: &mut TxContext,
    ): Coin<B> {
        let total_input = coin::value(&input);
        let input_a = total_input * route.share_a_bps / 10000;
        let input_b = total_input - input_a;

        let coin_a = coin::split(&mut input, input_a, ctx);
        let coin_b = input;

        let out_a = swap_in_pool_a(pool_a, coin_a, ctx);
        let out_b = swap_in_pool_b(pool_b, coin_b, ctx);

        let total_out = coin::value(&out_a) + coin::value(&out_b);
        assert!(total_out >= route.min_output, EInsufficientOutput);

        coin::merge(&mut out_a, out_b);
        out_a
    }
}
```

## 多跳路径

拆单之外，聚合器还支持多跳路径——通过中间代币中转获得更好的价格。

```
直接路径: USDC → SUI
多跳路径: USDC → USDT → SUI (如果 USDT/SUI 池有更好的价格)
```

```move
struct MultiHopRoute has store {
    hops: vector<Hop>,
    min_output: u64,
    deadline: u64,
}

struct Hop has store {
    pool_id: ID,
    dex_type: u8,
}

public fun execute_multi_hop<A, B, C>(
    route: &MultiHopRoute,
    input: Coin<A>,
    pool_ab: &mut PoolAB,
    pool_bc: &mut PoolBC,
    ctx: &mut TxContext,
): Coin<C> {
    let intermediate = swap_ab(pool_ab, input, ctx);
    let final_out = swap_bc(pool_bc, intermediate, ctx);
    assert!(coin::value(&final_out) >= route.min_output, EInsufficientOutput);
    final_out
}
```

## PTB 编排

Sui 的 Programmable Transaction Blocks 让聚合器可以在单笔交易中编排多个 DEX 调用：

```typescript
function buildAggregatorPTB(
    splits: Split[],
    inputCoin: TransactionObjectArg
): TransactionObjectArg {
    const ptb = new TransactionBlock();

    let totalOutputCoin: TransactionObjectArg | null = null;

    for (const split of splits) {
        const [splitCoin] = ptb.splitCoins(inputCoin, [ptb.pure(split.amount)]);

        let outputCoin: TransactionObjectArg;
        switch (split.dex) {
            case 'cetus':
                outputCoin = buildCetusSwap(ptb, split.poolId, splitCoin);
                break;
            case 'deepbook':
                outputCoin = buildDeepBookMarketOrder(ptb, split.bookId, splitCoin);
                break;
        }

        if (totalOutputCoin === null) {
            totalOutputCoin = outputCoin;
        } else {
            ptb.mergeCoins(totalOutputCoin, [outputCoin]);
        }
    }

    return totalOutputCoin!;
}
```

## 滑点保护

拆单和聚合器执行不保证最终价格。保护机制：

1. **min_output**：用户设置最低输出量，低于此值交易回滚
2. **deadline**：报价有过期时间
3. **部分执行**：如果一个 DEX 的流动性不足，可以跳过该路径

```move
public fun validate_execution(
    plan: &RoutePlan,
    actual_output: u64,
    timestamp: u64,
) {
    assert!(timestamp <= plan.deadline, ERouteExpired);
    assert!(actual_output >= plan.min_output, EInsufficientOutput);
}
```
