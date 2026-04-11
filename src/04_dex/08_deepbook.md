# 4.8 Orderbook：以 DeepBook 为例

## 为什么需要订单簿

AMM（V2/V3/DLMM/StableSwap）共同的特点是：价格由算法决定，不反映交易者的真实意图。

订单簿解决了这个问题：**买家和卖家各自报价，系统按价格优先撮合。**

## 核心概念

### Maker 和 Taker

- **Maker**：挂限价单，提供流动性。指定"我想在什么价格买/卖多少"
- **Taker**：吃单，消耗流动性。按 Maker 的价格立即成交

### 限价单

```move
public struct Order<phantom A, phantom B> has key, store {
    id: UID,
    book_id: ID,
    owner: address,
    is_bid: bool,         // true=买单, false=卖单
    price: u64,           // 报价（B per A）
    original_quantity: u64,
    filled_quantity: u64,
    order_id: u64,
    timestamp: u64,
}
```

### 订单簿深度

```
卖单（Asks）— 从低到高排列
  Ask: 2.05 USDC/SUI × 500
  Ask: 2.03 USDC/SUI × 300
  Ask: 2.01 USDC/SUI × 200
────────── 当前价格: 2.00 ──────────
  Bid: 1.99 USDC/SUI × 150
  Bid: 1.97 USDC/SUI × 400
  Bid: 1.95 USDC/SUI × 600
买单（Bids）— 从高到低排列
```

## Sui 对象模型对订单簿的天然优势

在 EVM 上，订单是合约存储中的 struct，大量订单遍历成本高。

在 Sui 上，**每个订单是一个独立的对象**：
- 下单/撤单只操作单个对象，不影响其他订单
- 并行执行：不同订单的操作可以并行处理
- 对象模型天然适合订单的创建、匹配、删除生命周期

## DeepBook 完整实现

```move
module deepbook {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientBalance: u64 = 400;
    const EOrderNotFillable: u64 = 401;
    const ENotOwner: u64 = 402;
    const EBookPaused: u64 = 403;
    const EInvalidPrice: u64 = 404;
    const EInvalidQuantity: u64 = 405;

    public struct OrderBook<phantom Base, phantom Quote> has key {
        id: UID,
        base_balance: Balance<Base>,
        quote_balance: Balance<Quote>,
        next_order_id: u64,
        taker_fee_bps: u64,
        maker_rebate_bps: u64,
        min_base_quantity: u64,
        tick_size: u64,
        paused: bool,
    }

    public struct Order<phantom Base, phantom Quote> has key, store {
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

    public struct Level has store {
        price: u64,
        total_quantity: u64,
        order_count: u64,
    }

    public struct FillEvent has copy, drop {
        order_id: u64,
        maker: address,
        taker: address,
        price: u64,
        quantity: u64,
        is_bid: bool,
    }

    // === 创建订单簿 ===

    public fun create_book<Base, Quote>(
        taker_fee_bps: u64,
        maker_rebate_bps: u64,
        tick_size: u64,
        ctx: &mut TxContext,
    ): OrderBook<Base, Quote> {
        OrderBook<Base, Quote> {
            id: object::new(ctx),
            base_balance: balance::zero<Base>(),
            quote_balance: balance::zero<Quote>(),
            next_order_id: 0,
            taker_fee_bps,
            maker_rebate_bps,
            min_base_quantity: 0,
            tick_size,
            paused: false,
        }
    }

    // === 限价单 ===

    public fun place_bid<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        price: u64,
        quantity: u64,
        payment: Coin<Quote>,
        ctx: &mut TxContext,
    ): Order<Base, Quote> {
        assert!(!book.paused, EBookPaused);
        assert!(price > 0, EInvalidPrice);
        assert!(quantity >= book.min_base_quantity, EInvalidQuantity);

        let cost = ((quantity as u128) * (price as u128) / 1000000) as u64;
        let fee = cost * book.taker_fee_bps / 10000;
        let total_cost = cost + fee;
        assert!(coin::value(&payment) >= total_cost, EInsufficientBalance);

        let order = Order<Base, Quote> {
            id: object::new(ctx),
            book_id: object::id(book),
            owner: ctx.sender(),
            is_bid: true,
            price,
            original_quantity: quantity,
            filled_quantity: 0,
            order_id: book.next_order_id,
            timestamp: sui::clock::timestamp_ms(sui::clock::create_for_testing()),
        };
        book.next_order_id = book.next_order_id + 1;
        balance::join(&mut book.quote_balance, coin::into_balance(payment));
        order
    }

    public fun place_ask<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        price: u64,
        quantity: u64,
        payment: Coin<Base>,
        ctx: &mut TxContext,
    ): Order<Base, Quote> {
        assert!(!book.paused, EBookPaused);
        assert!(price > 0, EInvalidPrice);
        assert!(quantity >= book.min_base_quantity, EInvalidQuantity);
        assert!(coin::value(&payment) >= quantity, EInsufficientBalance);

        let order = Order<Base, Quote> {
            id: object::new(ctx),
            book_id: object::id(book),
            owner: ctx.sender(),
            is_bid: false,
            price,
            original_quantity: quantity,
            filled_quantity: 0,
            order_id: book.next_order_id,
            timestamp: sui::clock::timestamp_ms(sui::clock::create_for_testing()),
        };
        book.next_order_id = book.next_order_id + 1;
        balance::join(&mut book.base_balance, coin::into_balance(payment));
        order
    }

    // === 市价单 ===

    public fun market_buy<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        max_quote: u64,
        payment: Coin<Quote>,
        asks: &mut vector<&mut Order<Base, Quote>>,
        ctx: &mut TxContext,
    ): Coin<Base> {
        assert!(!book.paused, EBookPaused);
        let mut remaining_quote = coin::value(&payment);
        let mut total_base = 0u64;
        balance::join(&mut book.quote_balance, coin::into_balance(payment));

        let mut i = 0;
        while (i < vector::length(asks) && remaining_quote > 0) {
            let ask = vector::borrow_mut(asks, i);
            let available = ask.original_quantity - ask.filled_quantity;
            let ask_cost = ((available as u128) * (ask.price as u128) / 1000000) as u64;

            let (fill_qty, fill_cost) = if (remaining_quote >= ask_cost) {
                (available, ask_cost)
            } else {
                let qty = ((remaining_quote as u128) * 1000000 / (ask.price as u128)) as u64;
                (qty, remaining_quote)
            };

            ask.filled_quantity = ask.filled_quantity + fill_qty;
            total_base = total_base + fill_qty;
            remaining_quote = remaining_quote - fill_cost;
            i = i + 1;
        };

        assert!(total_base > 0, EOrderNotFillable);
        coin::take(&mut book.base_balance, total_base, ctx)
    }

    // === 撤单 ===

    public fun cancel_order<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        order: Order<Base, Quote>,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        assert!(order.owner == ctx.sender(), ENotOwner);
        let unfilled = order.original_quantity - order.filled_quantity;
        let (refund_base, refund_quote) = if (order.is_bid) {
            let refund = ((unfilled as u128) * (order.price as u128) / 1000000) as u64;
            (coin::zero(ctx), coin::take(&mut book.quote_balance, refund, ctx))
        } else {
            (coin::take(&mut book.base_balance, unfilled, ctx), coin::zero(ctx))
        };
        .delete()(order);
        (refund_base, refund_quote)
    }

    // === 查询 ===

    public fun get_spread(
        best_bid_price: u64,
        best_ask_price: u64,
    ): u64 {
        assert!(best_ask_price >= best_bid_price, EInvalidPrice);
        let mid = (best_bid_price + best_ask_price) / 2;
        (best_ask_price - best_bid_price) * 10000 / mid
    }

    public fun get_mid_price(
        best_bid_price: u64,
        best_ask_price: u64,
    ): u64 {
        (best_bid_price + best_ask_price) / 2
    }
}
```

## DeepBook 在 Sui 上的特点

| 特点 | 说明 |
|------|------|
| 全链上撮合 | 订单匹配在链上完成，不依赖链下服务 |
| Maker 返佣 | Maker 手续费低于 Taker，鼓励挂单 |
| 对象并行 | 每个订单是独立对象，Sui 并行执行友好 |
| 深度聚合 | 提供链上 Level2 数据供聚合器使用 |
| 权限管理 | 管理员可设置最小下单量、tick size 等 |

## AMM vs 订单簿 适用场景

| 场景 | 推荐 | 原因 |
|------|------|------|
| 新代币（低流动性） | AMM | 只需初始资金，无需挂单等待 |
| 稳定币互换 | StableSwap | 接近零滑点 |
| 主流交易对（高流动性） | DLMM 或订单簿 | 资金效率高 |
| 大额交易 | 订单簿 | 精确限价，无滑点 |
| 做市 | 订单簿 | 可以精确控制买卖价差 |
| 被动收益 | DLMM | 集中流动性手续费更高 |
