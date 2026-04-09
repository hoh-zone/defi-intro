# 4.4 链上订单簿与 DeepBook

## 为什么需要订单簿

AMM 的核心问题是：价格由算法决定，不反映交易者的真实意图。当你用 AMM 买 1000 SUI 时，你不知道成交价是多少——直到交易执行。

订单簿解决了这个问题：**买家和卖家各自报价，系统撮合匹配。**

- Maker：挂限价单，提供流动性
- Taker：吃单，消耗流动性

## Sui 对象模型的天然优势

在 EVM 上，订单是合约存储中的一个 struct，修改需要 SLOAD/SSTORE，Gas 开销大。大量订单的遍历成本很高。

在 Sui 上，**每个订单是一个独立的对象**。这意味着：
- 下单/撤单只操作单个对象，不影响其他订单
- 并行执行：不同订单的操作可以并行处理
- 对象模型天然适合订单的创建、匹配、删除生命周期

```move
struct OrderBook<phantom A, phantom B> has key {
    id: UID,
    base_coin: Coin<A>,
    quote_coin: Coin<B>,
    next_order_id: u64,
    taker_fee_bps: u64,
    maker_fee_bps: u64,
}

struct Order<phantom A, phantom B> has key, store {
    id: UID,
    book_id: ID,
    owner: address,
    side: bool,
    price: u64,
    quantity: u64,
    filled: u64,
    order_id: u64,
}

const SIDE_BID: bool = true;
const SIDE_ASK: bool = false;
```

## 核心操作

### 下限价买单（Bid）

用户指定价格和数量，订单进入订单簿等待匹配。

```move
public fun place_bid<A, B>(
    book: &mut OrderBook<A, B>,
    payment: Coin<B>,
    price: u64,
    ctx: &mut TxContext,
): Order<A, B> {
    let quantity = coin::value(&payment) / price;
    let order = Order<A, B> {
        id: object::new(ctx),
        book_id: object::id(book),
        owner: tx_context::sender(ctx),
        side: SIDE_BID,
        price,
        quantity,
        filled: 0,
        order_id: book.next_order_id,
    };
    coin::merge(&mut book.quote_coin, payment);
    book.next_order_id = book.next_order_id + 1;
    order
}
```

### 撮合（Match）

当一个新的卖单到达时，系统从最高买价开始向下匹配。

```move
public fun match_order<A, B>(
    book: &mut OrderBook<A, B>,
    taker_order: &mut Order<A, B>,
    maker_order: &mut Order<A, B>,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    assert!(taker_order.side != maker_order.side, 1);
    let match_quantity = min(
        taker_order.quantity - taker_order.filled,
        maker_order.quantity - maker_order.filled,
    );
    let match_value = match_quantity * maker_order.price;
    taker_order.filled = taker_order.filled + match_quantity;
    maker_order.filled = maker_order.filled + match_quantity;
    let base_out = coin::take(&mut book.base_coin, match_quantity, ctx);
    let quote_out = coin::take(&mut book.quote_coin, match_value, ctx);
    (base_out, quote_out)
}
```

### 撤单

```move
public fun cancel_order<A, B>(
    book: &mut OrderBook<A, B>,
    order: Order<A, B>,
    ctx: &mut TxContext,
): Coin<B> {
    assert!(order.owner == tx_context::sender(ctx), 2);
    let remaining = if (order.side == SIDE_BID) {
        (order.quantity - order.filled) * order.price
    } else {
        order.quantity - order.filled
    };
    let refund = coin::take(&mut book.quote_coin, remaining, ctx);
    object::delete(order);
    refund
}
```

## AMM vs CLOB 对比

| 维度 | AMM | CLOB |
|------|-----|------|
| 价格发现 | 算法（池内比例） | 市场（买卖意愿） |
| 流动性来源 | LP 存入双边资产 | Maker 挂限价单 |
| 滑点 | 依赖池深度 | 依赖挂单密度 |
| 大额交易 | 高滑点 | 取决于订单簿深度 |
| 适用场景 | 长尾资产、简单交易 | 主流交易对、价格敏感交易 |
| Sui 实现 | 1个共享对象 | 订单可以是独立对象，并行友好 |
