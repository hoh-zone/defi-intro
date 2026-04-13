# 4.27 Sui Orderbook 实现

以 DeepBook V3 为参考，分析 Sui 上 Orderbook DEX 的架构设计和实现。

## DeepBook V3 架构

```
核心组件:
  OrderBook — 共享对象，存储所有挂单
  Order     — 用户挂单（可作为独立对象）
  Account   — 用户账户（存储余额和订单引用）

外部组件:
  Keeper Bot — 触发撮合的链下服务
  Frontend   — 用户界面
```

## 关键数据结构

### OrderBook

```move
public struct OrderBook<phantom A, phantom B> has key {
    id: UID,
    // 买盘：按价格降序排列
    bids: Table<u64, PriceLevel>,
    // 卖盘：按价格升序排列
    asks: Table<u64, PriceLevel>,
    // 基础参数
    tick_size: u64,        // 最小价格变动
    lot_size: u64,         // 最小交易量
    // 手续费
    maker_fee: u64,        // Maker 手续费（可能为负 = 返还）
    taker_fee: u64,        // Taker 手续费
}
```

### PriceLevel

```move
public struct PriceLevel has store {
    // 该价位上的所有订单
    orders: vector<OrderInfo>,
    // 该价位的总数量
    total_quantity: u64,
}

public struct OrderInfo has store {
    order_id: ID,
    owner: address,
    quantity: u64,      // 剩余数量
    timestamp: u64,     // 用于时间优先
}
```

## 核心函数

### 挂单（Place Order）

```move
public fun place_order<A, B>(
    book: &mut OrderBook<A, B>,
    account: &mut Account,
    is_bid: bool,        // true=买单, false=卖单
    price: u64,          // 限价
    quantity: u64,       // 数量
    ctx: &mut TxContext,
): ID {
    // 1. 验证价格和数量
    assert!(price > 0, EInvalidPrice);
    assert!(quantity >= book.lot_size, EInvalidQuantity);
    assert!(quantity % book.lot_size == 0, EInvalidQuantity);

    // 2. 锁定保证金
    if (is_bid) {
        // 买单: 锁定 price × quantity 的 B 代币
        let required = (quantity as u128) * (price as u128);
        // 从账户余额中锁定
    } else {
        // 卖单: 锁定 quantity 的 A 代币
        // 从账户余额中锁定
    };

    // 3. 尝试立即撮合
    let filled = match_and_fill(book, is_bid, price, quantity);

    // 4. 未成交部分挂入订单簿
    if (filled < quantity) {
        let remaining = quantity - filled;
        insert_order(book, is_bid, price, remaining, ctx);
    };

    // 返回订单 ID
}
```

### 撮合（Match and Fill）

```move
fun match_and_fill<A, B>(
    book: &mut OrderBook<A, B>,
    is_bid: bool,
    price: u64,
    quantity: u64,
): u64 {
    let mut remaining = quantity;
    let mut filled = 0;

    // 遍历对手盘
    if (is_bid) {
        // 买单 → 匹配卖盘（从最低价开始）
        let mut best_ask = get_best_ask(book);
        while (remaining > 0 && best_ask <= price) {
            let level = book.asks[best_ask];
            let fill_qty = min(remaining, level.total_quantity);
            // 执行成交
            execute_fill(book, best_ask, fill_qty, is_bid);
            remaining = remaining - fill_qty;
            filled = filled + fill_qty;
            best_ask = get_best_ask(book);
        };
    } else {
        // 卖单 → 匹配买盘（从最高价开始）
        let mut best_bid = get_best_bid(book);
        while (remaining > 0 && best_bid >= price) {
            let level = book.bids[best_bid];
            let fill_qty = min(remaining, level.total_quantity);
            execute_fill(book, best_bid, fill_qty, !is_bid);
            remaining = remaining - fill_qty;
            filled = filled + fill_qty;
            best_bid = get_best_bid(book);
        };
    };

    filled
}
```

### 取消订单

```move
public fun cancel_order<A, B>(
    book: &mut OrderBook<A, B>,
    account: &mut Account,
    order_id: ID,
    is_bid: bool,
) {
    // 1. 找到订单
    // 2. 验证订单属于调用者
    // 3. 从价位中移除
    // 4. 释放锁定的保证金
    // 5. 如果该价位为空，删除价位
}
```

## Keeper Bot 机制

```
为什么需要 Keeper Bot:

在传统链上 Orderbook 中，撮合在每笔交易中自动执行
但在 Sui 上，shared object 的并发访问有限制

DeepBook 的方案:
  1. 用户挂单 → 订单写入 OrderBook
  2. Keeper Bot 检测到新订单
  3. Keeper Bot 提交撮合交易
  4. 撮合执行，双方成交

Keeper Bot 的激励:
  - 撮合手续费的一部分
  - 或协议代币奖励

替代方案: 自撮合（Self-Matching）
  - 用户的挂单交易本身包含撮合逻辑
  - 不需要外部 Keeper
  - 但 Gas 成本更高
```

## 手续费结构

```
DeepBook V3 的手续费设计:

Maker Fee: -0.01%（返还）到 0.02%
  → 鼓励提供流动性
  → Maker 挂单增加深度

Taker Fee: 0.05% 到 0.10%
  → 消耗流动性支付更高费用
  → 手续费用于 Keeper 激励和协议金库

净手续费:
  如果 Maker Fee = -0.01%, Taker Fee = 0.05%
  一笔交易的总手续费 = 0.04%
  → 比大多数 AMM（0.3%）更低
```

## Sui 特有优势

```
1. 对象模型:
   → 订单可作为独立对象
   → 用户可以直接拥有和管理自己的订单
   → 不需要全局 mapping

2. 动态字段:
   → PriceLevel 使用 dynamic_field 存储
   → 按需分配，不需要预设价位数量

3. 并行执行:
   → 不同交易对的撮合可以并行
   → 不会因为 SUI/USDC 的繁忙阻塞 ETH/USDC

4. PTB 组合:
   → 挂限价单 + 闪电贷 + DEX Swap
   → 在一个原子操作中完成复杂策略
```

## 架构评估

```
DeepBook 的优势:
  ✅ 专业级交易体验
  ✅ 低手续费（Maker 返还）
  ✅ 与 Sui 生态深度集成
  ✅ 被多个聚合器接入

DeepBook 的挑战:
  ⚠️ Keeper Bot 依赖（如果 Keeper 不活跃，撮合延迟）
  ⚠️ 长尾资产流动性不足（需要足够的 Maker）
  ⚠️ Gas 成本高于 AMM（撮合逻辑更复杂）

总结: DeepBook 填补了 Sui 生态中专业交易的基础设施空白，
      但 AMM 仍然是大众交易的首选。
```
