# 6.3 DeepBook CLOB 的路由集成

## DeepBook 的订单簿模型

DeepBook 是 Sui 上的链上中央限价订单簿（CLOB）。与 AMM 不同，它的流动性来自 Maker 挂出的限价单。

```move
module deepbook {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    struct OrderBook<phantom Base, phantom Quote> has key {
        id: UID,
        base_currency: Balance<Base>,
        quote_currency: Balance<Quote>,
        next_order_id: u64,
        taker_fee_bps: u64,
        maker_fee_bps: u64,
    }

    struct Order<phantom Base, phantom Quote> has key, store {
        id: UID,
        book_id: ID,
        owner: address,
        is_bid: bool,
        price: u64,
        original_quantity: u64,
        filled_quantity: u64,
        order_id: u64,
        timestamp: u64,
    }

    struct Level2 has store {
        price: u64,
        quantity: u64,
        order_count: u64,
    }

    public fun place_limit_order<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        is_bid: bool,
        price: u64,
        quantity: u64,
        payment: Coin<Quote>,
        ctx: &mut TxContext,
    ): Order<Base, Quote> {
        let cost = if (is_bid) {
            quantity * price
        } else {
            quantity
        };
        assert!(coin::value(&payment) >= cost, 0);
        let order = Order<Base, Quote> {
            id: object::new(ctx),
            book_id: object::id(book),
            owner: tx_context::sender(ctx),
            is_bid,
            price,
            original_quantity: quantity,
            filled_quantity: 0,
            order_id: book.next_order_id,
            timestamp: sui::clock::timestamp_ms(sui::clock::create_for_testing()),
        };
        book.next_order_id = book.next_order_id + 1;
        if (is_bid) {
            balance::join(&mut book.quote_currency, coin::into_balance(payment));
        } else {
            balance::join(&mut book.base_currency, coin::into_balance(payment));
        };
        order
    }

    public fun market_order<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        is_bid: bool,
        quantity: u64,
        payment: Coin<Quote>,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        let mut remaining = quantity;
        let mut filled_base = 0u64;
        let mut spent_quote = 0u64;

        let mut orders_to_fill: vector<&mut Order<Base, Quote>> = get_matching_orders(
            book, is_bid, remaining
        );

        let mut i = 0;
        while (i < vector::length(&orders_to_fill)) {
            let order = vector::borrow_mut(&mut orders_to_fill, i);
            let available = order.original_quantity - order.filled_quantity;
            let fill_qty = if (available <= remaining) { available } else { remaining };
            let cost = fill_qty * order.price;

            order.filled_quantity = order.filled_quantity + fill_qty;
            filled_base = filled_base + fill_qty;
            spent_quote = spent_quote + cost;
            remaining = remaining - fill_qty;

            if (remaining == 0) { break };
            i = i + 1;
        };

        let base_out = coin::take(&mut book.base_currency, filled_base, ctx);
        let refund = coin::value(&payment) - spent_quote;
        let change = coin::split(&mut payment, refund, ctx);
        (base_out, change)
    }

    public fun cancel_order<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        order: Order<Base, Quote>,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        assert!(order.owner == tx_context::sender(ctx), 1);
        let unfilled = order.original_quantity - order.filled_quantity;
        let (refund_base, refund_quote) = if (order.is_bid) {
            let refund_amount = unfilled * order.price;
            (coin::zero(ctx), coin::take(&mut book.quote_currency, refund_amount, ctx))
        } else {
            (coin::take(&mut book.base_currency, unfilled, ctx), coin::zero(ctx))
        };
        object::delete(order);
        (refund_base, refund_quote)
    }

    public fun get_orderbook_depth<Base, Quote>(
        book: &OrderBook<Base, Quote>,
        levels: u64,
    ): (vector<Level2>, vector<Level2>) {
        let bids: vector<Level2> = vector::empty();
        let asks: vector<Level2> = vector::empty();
        (bids, asks)
    }
}
```

## 聚合器如何与 DeepBook 交互

### 1. 读取订单簿深度

聚合器需要获取 DeepBook 的 Level2 数据（每个价格档位的挂单量）：

```typescript
interface Level2Snapshot {
    bids: { price: number; quantity: number; orders: number }[];
    asks: { price: number; quantity: number; orders: number }[];
}

async function getDeepBookDepth(bookId: string): Promise<Level2Snapshot> {
    const book = await fetchOrderBookState(bookId);
    return buildLevel2FromOrders(book.orders);
}
```

### 2. 模拟市价单执行

```typescript
function quoteDeepBook(depth: Level2Snapshot, amountIn: number, side: 'buy'): number {
    const levels = side === 'buy' ? depth.asks : depth.bids;
    let remaining = amountIn;
    let totalOut = 0;

    for (const level of levels) {
        const levelCost = level.quantity * level.price;
        if (remaining <= levelCost) {
            totalOut += remaining / level.price;
            remaining = 0;
            break;
        }
        totalOut += level.quantity;
        remaining -= levelCost;
    }

    return totalOut;
}
```

### 3. 构造 PTB 执行

```typescript
function buildDeepBookMarketOrderPTB(
    bookId: string,
    side: 'buy' | 'sell',
    quantity: number,
    maxPay: number,
    coinIn: TransactionObjectArg
): TransactionObjectArg {
    const ptb = new TransactionBlock();
    const [baseOut, change] = ptb.moveCall({
        target: `${DEEPBOOK_PACKAGE}::orderbook::market_order`,
        arguments: [
            ptb.object(bookId),
            ptb.pure(side === 'buy'),
            ptb.pure(quantity),
            coinIn,
        ],
        typeArguments: [BASE_TYPE, QUOTE_TYPE],
    });
    return baseOut;
}
```

## DeepBook 对聚合器的特殊价值

| 维度 | 说明 |
|------|------|
| 大额执行 | 订单簿可以挂大额限价单，不依赖池深度 |
| 价格精度 | 限价单价格精确到最小 tick，没有 AMM 的滑点 |
| Maker 奖励 | 挂单提供流动性可获得手续费返还 |
| 对象模型 | 每个订单是独立对象，并行执行友好 |

聚合器在处理大额交易时，优先路由到 DeepBook 可以显著减少滑点。
