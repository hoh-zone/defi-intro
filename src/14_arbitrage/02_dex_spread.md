# 12.2 DEX 价差套利

## 最基本的套利

同一个交易对在两个 DEX 上价格不同：

```
Cetus: 1 SUI = 2.00 USDC
DeepBook: 1 SUI = 2.05 USDC

操作：
  1. 在 Cetus 用 1000 USDC 买入 500 SUI
  2. 在 DeepBook 卖出 500 SUI 获得 1025 USDC
  3. 利润：25 USDC - Gas
```

## Move 实现

```move
module dex_arbitrage {
    use amm::Pool;
    use orderbook::{Self, OrderBook};
    use sui::coin::{Self, Coin};
    use sui::tx_context::{Self, TxContext};

    const ENoArbitrage: u64 = 1000;

    public fun arbitrage_amm_to_amm<A, B>(
        pool_buy: &mut Pool<A, B>,
        pool_sell: &mut Pool<B, A>,
        input_amount: u64,
        min_profit: u64,
        ctx: &mut TxContext,
    ): Coin<B> {
        let input_coin = coin::mint_for_testing<B>(input_amount, ctx);

        let intermediate = amm::swap_b_to_a(pool_buy, input_coin, ctx);
        let intermediate_amount = coin::value(&intermediate);

        let output = amm::swap_a_to_b(pool_sell, intermediate, ctx);
        let output_amount = coin::value(&output);

        let profit = output_amount - input_amount;
        assert!(profit >= min_profit, ENoArbitrage);
        output
    }

    public fun arbitrage_amm_to_orderbook<Base, Quote>(
        amm_pool: &mut Pool<Quote, Base>,
        orderbook: &mut OrderBook<Base, Quote>,
        input_amount: u64,
        min_profit: u64,
        ctx: &mut TxContext,
    ): Coin<Quote> {
        let input_coin = coin::mint_for_testing<Quote>(input_amount, ctx);

        let base_coin = amm::swap_quote_to_base(amm_pool, input_coin, ctx);
        let base_amount = coin::value(&base_coin);

        let best_bid = orderbook::get_best_bid(orderbook);
        let amm_price = amm::get_price(amm_pool);
        assert!(best_bid > amm_price, ENoArbitrage);

        let output = orderbook::market_sell(orderbook, base_coin, ctx);
        let output_amount = coin::value(&output);

        let profit = output_amount - input_amount;
        assert!(profit >= min_profit, ENoArbitrage);
        output
    }
}
```

## PTB 编排

在 Sui 上，通过 Programmable Transaction Blocks 在单笔交易中完成跨 DEX 套利：

```typescript
function buildArbitragePTB(
    cetusPoolId: string,
    deepBookId: string,
    amountIn: number,
    minProfit: number
): TransactionBlock {
    const ptb = new TransactionBlock();

    // Step 1: 在 Cetus 买入 SUI
    const [suiCoin] = ptb.moveCall({
        target: `${CETUS}::pool::swap_a_to_b`,
        arguments: [
            ptb.object(cetusPoolId),
            ptb.pure(amountIn),
        ],
        typeArguments: [USDC_TYPE, SUI_TYPE],
    });

    // Step 2: 在 DeepBook 卖出 SUI
    const [usdcOut, change] = ptb.moveCall({
        target: `${DEEPBOOK}::orderbook::market_sell`,
        arguments: [
            ptb.object(deepBookId),
            suiCoin,
        ],
        typeArguments: [SUI_TYPE, USDC_TYPE],
    });

    // Step 3: 验证利润
    ptb.moveCall({
        target: `${ARBITRAGE}::verify_profit`,
        arguments: [
            usdcOut,
            ptb.pure(amountIn),
            ptb.pure(minProfit),
        ],
    });

    return ptb;
}
```

## 最优输入量计算

套利利润不是输入量越大越好——滑点会随输入量增加。最优输入量是利润最大化的点：

$$\frac{d(\text{Profit})}{d(\text{Input})} = 0$$

```move
public fun calculate_optimal_input(
    reserve_a_buy: u64,
    reserve_b_buy: u64,
    reserve_a_sell: u64,
    reserve_b_sell: u64,
    fee_bps: u64,
): u64 {
    let r_a1 = reserve_a_buy as u128;
    let r_b1 = reserve_b_buy as u128;
    let r_a2 = reserve_a_sell as u128;
    let r_b2 = reserve_b_sell as u128;
    let f = (10000 - fee_bps) as u128;

    let numerator = r_b1 * r_b2 * f * (r_a1 + r_a2);
    let sqrt_part = sqrt(numerator * f * r_b1 * r_b2);
    let optimal = (sqrt_part - r_b1 * r_b2 * f) / (r_b1 * f + r_b2);
    optimal as u64
}
```

## 价差消失的速度

套利者之间竞争。价差通常在 1-3 个区块内被消除。先到的套利者获得利润，后来的无利可图。这导致了 Gas 竞价战争（PGA），详见 12.7。
