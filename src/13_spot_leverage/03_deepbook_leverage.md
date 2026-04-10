# 13.3 DeepBook 上的杠杆做市

## 做市商为什么需要杠杆

做市商（Market Maker）在 DeepBook 上挂限价单提供流动性。资金效率问题：如果在每个价格档位都挂单，需要大量资金。杠杆做市允许做市商用借来的资金扩大挂单规模。

## 杠杆做市的机制

```
1. 做市商存入 1000 USDC 作为抵押品
2. 从借贷市场借入 500 SUI + 500 USDC
3. 在 DeepBook 上同时挂买卖单：
   - Bid: 400 USDC @ $1.95 买入 ~205 SUI
   - Ask: 400 SUI @ $2.05 卖出获得 ~$820
4. 赚取买卖价差: $2.05 - $1.95 = $0.10/SUI
5. 用价差支付借款利息
```

## Move 实现

```move
module deepbook_leverage_mm {
    use deepbook::{Self, OrderBook, Order};
    use lending::{Self, Market, DepositReceipt, BorrowReceipt};
    use sui::coin::{Self, Coin};
    use sui::tx_context::{Self, TxContext};

    const EInsufficientSpread: u64 = 900;
    const EHealthFactorTooLow: u64 = 901;

    struct LeverageMMPosition has key, store {
        id: UID,
        owner: address,
        market_id: ID,
        book_id: ID,
        collateral_amount: u64,
        borrowed_base: u64,
        borrowed_quote: u64,
        bid_orders: vector<ID>,
        ask_orders: vector<ID>,
        entry_spread_bps: u64,
        created_at: u64,
    }

    public fun open_leverage_mm<Base, Quote>(
        lending_market: &mut Market,
        order_book: &mut OrderBook<Base, Quote>,
        collateral: Coin<Quote>,
        borrow_base_amount: u64,
        borrow_quote_amount: u64,
        bid_price: u64,
        ask_price: u64,
        bid_quantity: u64,
        ask_quantity: u64,
        ctx: &mut TxContext,
    ): (LeverageMMPosition, vector<Order<Base, Quote>>) {
        let collateral_amount = coin::value(&collateral);
        let deposit = lending::supply(lending_market, collateral, ctx);
        lending::enable_collateral(&mut deposit);

        let hf = lending::calculate_health_factor(
            lending_market, &deposit, borrow_base_amount, borrow_quote_amount
        );
        assert!(hf >= 10000, EHealthFactorTooLow);

        let borrowed_base = lending::borrow_base(lending_market, borrow_base_amount, &deposit, ctx);
        let borrowed_quote = lending::borrow_quote(lending_market, borrow_quote_amount, &deposit, ctx);

        let spread_bps = (ask_price - bid_price) * 10000 / bid_price;
        assert!(spread_bps >= 50, EInsufficientSpread);

        let bid_order = deepbook::place_limit_order(
            order_book,
            true,
            bid_price,
            bid_quantity,
            borrowed_quote,
            ctx,
        );

        let ask_order = deepbook::place_limit_order(
            order_book,
            false,
            ask_price,
            ask_quantity,
            borrowed_base,
            ctx,
        );

        let position = LeverageMMPosition {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            market_id: object::id(lending_market),
            book_id: object::id(order_book),
            collateral_amount,
            borrowed_base: borrow_base_amount,
            borrowed_quote: borrow_quote_amount,
            bid_orders: vector::singleton(object::id(&bid_order)),
            ask_orders: vector::singleton(object::id(&ask_order)),
            entry_spread_bps: spread_bps,
            created_at: sui::clock::timestamp_ms(sui::clock::create_for_testing()),
        };

        (position, vector::empty())
    }

    public fun close_leverage_mm<Base, Quote>(
        lending_market: &mut Market,
        order_book: &mut OrderBook<Base, Quote>,
        position: LeverageMMPosition,
        bid_orders: vector<Order<Base, Quote>>,
        ask_orders: vector<Order<Base, Quote>>,
        ctx: &mut TxContext,
    ) {
        let mut i = 0;
        while (i < vector::length(&bid_orders)) {
            let order = vector::borrow_mut(&mut bid_orders, i);
            let (_, refund) = deepbook::cancel_order(order_book, order, ctx);
            lending::repay_quote(lending_market, refund, ctx);
            i = i + 1;
        };

        let mut j = 0;
        while (j < vector::length(&ask_orders)) {
            let order = vector::borrow_mut(&mut ask_orders, j);
            let (refund_base, _) = deepbook::cancel_order(order_book, order, ctx);
            lending::repay_base(lending_market, refund_base, ctx);
            j = j + 1;
        };

        object::delete(position);
    }
}
```

## 做市策略的风险

| 风险 | 描述 | 缓解措施 |
|------|------|----------|
| 库存风险 | 单边成交导致持仓偏移 | 动态调价、库存对冲 |
| 价格风险 | 持仓方向与市场相反 | 限制最大敞口 |
| 清算风险 | 抵押品价值下降触发清算 | 设置安全保证金缓冲 |
| 订单被吃 | 挂单被大额吃单扫过 | 分层挂单、限制单笔量 |
| 借款成本 | 利率上升压缩利润 | 监控利率、设置止损 |

## 做市收益计算

```move
public fun calculate_mm_profit(
    filled_bid_quantity: u64,
    filled_ask_quantity: u64,
    bid_price: u64,
    ask_price: u64,
    borrow_base_cost: u64,
    borrow_quote_cost: u64,
    taker_fees_paid: u64,
): i128 {
    let gross_profit = (filled_bid_quantity as i128)
        * ((ask_price - bid_price) as i128)
        / (bid_price as i128);
    let total_cost = (borrow_base_cost + borrow_quote_cost + taker_fees_paid) as i128;
    gross_profit - total_cost
}
```

做市盈利的条件：价差收入 > 借款成本 + 手续费 + 库存损失。
