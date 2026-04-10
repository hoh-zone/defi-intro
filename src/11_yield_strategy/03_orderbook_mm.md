# 11.3 订单簿双边做市

## AMM 做市 vs 订单簿做市

```
AMM 做市（Cetus）：
  - 被动提供流动性，算法自动匹配
  - 无常损失不可避免
  - 不需要频繁操作
  - 适合大多数人

订单簿做市（DeepBook）：
  - 主动挂 bid/ask 单
  - 无无常损失（但库存风险）
  - 需要频繁调整报价
  - 适合专业做市商
```

## 订单簿做市的核心指标

### 1. 价差（Spread）

```
Spread = Ask Price - Bid Price
Spread % = (Ask - Bid) / Mid Price

目标：价差足够覆盖成本，但不能太宽以至于没有成交
```

### 2. 库存偏斜（Inventory Skew）

```
库存偏斜 = (买入量 - 卖出量) / 总投入量

偏斜为正：持有过多基础资产（价格下跌时有亏损风险）
偏斜为零：库存平衡（理想状态）
偏斜为负：持有过多计价资产（价格上涨时踏空）
```

### 3. 订单停留时间

```
停留时间 = 订单从挂出到成交或取消的平均时间

停留时间长：定价保守，成交少但安全
停留时间短：定价激进，成交多但风险大
```

## DeepBook 双边做市的 Move 实现

```move
module yield_strategy::orderbook_mm {
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::balance::{Self, Balance};

    const E_NOT_OWNER: u64 = 0;
    const E_INVALID_SPREAD: u64 = 1;
    const E_INSUFFICIENT_INVENTORY: u64 = 2;
    const PRECISION: u64 = 1_000_000_000;

    public struct MarketMaker has key {
        id: UID,
        base_balance: Balance<BaseCoin>,
        quote_balance: Balance<QuoteCoin>,
        mid_price: u64,
        spread_bps: u64,
        order_size: u64,
        inventory_limit_bps: u64,
        total_bought: u64,
        total_sold: u64,
        total_fees: u64,
        owner: address,
    }

    public fun initialize<BaseCoin, QuoteCoin>(
        base: Coin<BaseCoin>,
        quote: Coin<QuoteCoin>,
        spread_bps: u64,
        order_size: u64,
        ctx: &mut TxContext,
    ) {
        assert!(spread_bps > 0 && spread_bps < 10000, E_INVALID_SPREAD);
        let mm = MarketMaker {
            id: object::new(ctx),
            base_balance: coin::into_balance(base),
            quote_balance: coin::into_balance(quote),
            mid_price: 0,
            spread_bps,
            order_size,
            inventory_limit_bps: 3000,
            total_bought: 0,
            total_sold: 0,
            total_fees: 0,
            owner: tx_context::sender(ctx),
        };
        transfer::share_object(mm);
    }

    public fun update_price(
        mm: &mut MarketMaker,
        new_mid_price: u64,
    ) {
        mm.mid_price = new_mid_price;
    }

    public fun compute_quotes(mm: &MarketMaker): (u64, u64) {
        let half_spread = mm.mid_price * mm.spread_bps / 20000;
        let skew = inventory_skew(mm);
        let skew_adj = half_spread * skew / PRECISION;
        let bid = mm.mid_price - half_spread + skew_adj;
        let ask = mm.mid_price + half_spread + skew_adj;
        (bid, ask)
    }

    public fun inventory_skew(mm: &MarketMaker): u64 {
        let total = mm.total_bought + mm.total_sold;
        if (total == 0) { return 0 };
        if (mm.total_bought > mm.total_sold) {
            let excess = mm.total_bought - mm.total_sold;
            0 - (excess * PRECISION / total / 2)
        } else {
            let excess = mm.total_sold - mm.total_bought;
            excess * PRECISION / total / 2
        }
    }

    public fun place_bid<BaseCoin, QuoteCoin>(
        mm: &mut MarketMaker<BaseCoin, QuoteCoin>,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<QuoteCoin> {
        let (bid_price, _) = compute_quotes(mm);
        let cost = amount * bid_price / PRECISION;
        assert!(balance::value(&mm.quote_balance) >= cost, E_INSUFFICIENT_INVENTORY);
        mm.total_bought = mm.total_bought + amount;
        coin::take(&mut mm.quote_balance, cost, ctx)
    }

    public fun place_ask<BaseCoin, QuoteCoin>(
        mm: &mut MarketMaker<BaseCoin, QuoteCoin>,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<BaseCoin> {
        assert!(balance::value(&mm.base_balance) >= amount, E_INSUFFICIENT_INVENTORY);
        mm.total_sold = mm.total_sold + amount;
        coin::take(&mut mm.base_balance, amount, ctx)
    }

    public fun on_bid_filled<BaseCoin, QuoteCoin>(
        mm: &mut MarketMaker<BaseCoin, QuoteCoin>,
        base_received: Coin<BaseCoin>,
    ) {
        let value = coin::value(&base_received);
        balance::join(&mut mm.base_balance, coin::into_balance(base_received));
        mm.total_fees = mm.total_fees + value * mm.spread_bps / 20000;
    }

    public fun on_ask_filled<BaseCoin, QuoteCoin>(
        mm: &mut MarketMaker<BaseCoin, QuoteCoin>,
        quote_received: Coin<QuoteCoin>,
    ) {
        let value = coin::value(&quote_received);
        balance::join(&mut mm.quote_balance, coin::into_balance(quote_received));
        mm.total_fees = mm.total_fees + value * mm.spread_bps / 20000;
    }

    public fun total_pnl(mm: &MarketMaker): u64 {
        mm.total_fees
    }

    public fun inventory_value(mm: &MarketMaker, price: u64): u64 {
        let base_val = balance::value(&mm.base_balance) * price / PRECISION;
        let quote_val = balance::value(&mm.quote_balance);
        base_val + quote_val
    }
}
```

## 库存管理策略

### 目标库存做市

核心思想：保持基础资产和计价资产的库存接近目标比例。

```
目标库存 = 总价值的 50% 基础资产 + 50% 计价资产

当库存偏斜时：
  持有过多基础资产 → 降低 bid 价格，提高 ask 价格（鼓励卖、抑制买）
  持有过多计价资产 → 提高 bid 价格，降低 ask 价格（鼓励买、抑制卖）
```

### 库存风险的量化

```
库存风险 = 库存偏斜 × 价格波动率 × 时间

示例：
  库存偏斜 = 20%（基础资产占比 70%）
  日波动率 = 5%
  持有周期 = 7 天

  风险敞口 ≈ 20% × 5% × √7 ≈ 2.6%
  即：7 天内库存风险约 2.6% 的总价值
```

## DeepBook 做市的实际考量

DeepBook 是 Sui 上的 CLOB 订单簿 DEX。做市时需要考虑：

```
1. 账户模型：DeepBook 使用 Account 对象管理用户余额
2. 挂单限制：每个账户有最大挂单数量
3. Gas 优化：频繁撤单重挂消耗 gas
4. Maker 返佣：DeepBook 对 maker 有手续费返佣激励
5. 最小订单量：不同交易对有不同的最小下单量
```

## AMM 做市 vs 订单簿做市对比

| 维度 | AMM LP | 订单簿 MM |
|---|---|---|
| 无常损失 | 有 | 无 |
| 库存风险 | 有（被动的） | 有（主动的） |
| 资金效率 | 低（全区间）/ 高（集中） | 高（只在最优价位挂单） |
| 操作复杂度 | 低 | 高 |
| 适合人群 | 大多数人 | 专业交易者 |
| Gas 成本 | 低（一次 deposit） | 高（频繁挂单撤单） |

## 风险分析

| 风险 | 描述 |
|---|---|
| 库存积累 | 单边行情下，做市商持续买入（或卖出），库存严重偏斜 |
| 被信息优势者剥削 | 知情交易者总是在你这边成交，你承担逆向选择成本 |
| Gas 成本 | 频繁调整报价消耗大量 gas |
| 流动性不足 | 如果对手盘太少，报价长时间不成交 |
