# 13.5 Sui 现货杠杆案例与风控

## Cetus 杠杆产品

Cetus 提供的杠杆功能特点：
- 通过 Cetus 借贷市场 + Cetus CLMM 池的组合实现
- 支持多种交易对的杠杆做多/做空
- 杠杆开仓和减仓通过 PTB 在单笔交易中完成
- 清算通过 Cetus 借贷的清算机制处理

### 杠杆做多 SUI

```
1. 存入 USDC 到 Cetus 借贷市场
2. 借出 SUI
3. （如果做多：需要先借 USDC 买入 SUI）
4. 持有 SUI 敞口
5. SUI 上涨时卖出获利
```

### 杠杆做空 SUI

```
1. 存入 USDC 到 Cetus 借贷市场
2. 借出 SUI
3. 在 Cetus DEX 卖出 SUI 获得 USDC
4. 持有 USDC（SUI 下跌时获利）
5. SUI 下跌后买回 SUI 偿还借款
```

## DeepBook + 借贷的杠杆组合

DeepBook 本身不提供杠杆功能，但用户可以：
1. 在借贷协议（如 Scallop、Suilend）借入资金
2. 在 DeepBook 上执行交易
3. DeepBook 的精确限价单对杠杆交易者更有利

```move
module leverage_via_deepbook {
    use deepbook::{Self, OrderBook};
    use lending::{Self, Market};
    use sui::coin::Coin;
    use sui::tx_context::TxContext;

    public fun leveraged_short<Base, Quote>(
        lending_market: &mut Market,
        order_book: &mut OrderBook<Base, Quote>,
        collateral: Coin<Quote>,
        borrow_amount: u64,
        sell_price: u64,
        buyback_price: u64,
        ctx: &mut TxContext,
    ) {
        let deposit = lending::supply(lending_market, collateral, ctx);
        lending::enable_collateral(&mut deposit);
        let borrowed_base = lending::borrow_base(lending_market, borrow_amount, &deposit, ctx);
        let (base_coin, _) = deepbook::market_order(order_book, false, borrow_amount, borrowed_base, ctx);
        let proceeds = coin::value(&base_coin);
        assert!(proceeds >= borrow_amount * sell_price / 1000000, 999);
    }
}
```

## 风控清单

| 风控措施 | 说明 | 实现方式 |
|----------|------|----------|
| 最大杠杆限制 | 限制单仓位的最大杠杆倍数 | 协议级参数 |
| LTV 上限 | 限制可借金额与抵押品的比例 | 每种资产独立设置 |
| 清算阈值 | 触发清算的抵押率下限 | LTV + 缓冲 |
| 全局借款上限 | 限制协议总借款量 | debt_ceiling |
| 单用户借款上限 | 限制单个用户的借款量 | user_debt_cap |
| 利率缓冲 | 当利率飙升时限制新借款 | 利用率阈值 |
| 紧急暂停 | 极端情况下停止所有操作 | AdminCap + 多签 |
| 保险基金 | 覆盖清算产生的坏账 | reserve_factor 提取 |

## 现货杠杆 vs 永续合约 vs CDP

| 维度 | 现货杠杆 | 永续合约 | CDP |
|------|----------|----------|-----|
| 杠杆来源 | 借贷 | 保证金 | 抵押 |
| 资产持有 | 持有真实资产 | 持有合约 | 持有稳定币 |
| 资金效率 | 中 | 高 | 低 |
| 清算方式 | 抵押品出售 | 保证金扣完 | 抵押品出售 |
| 资金费率 | 无 | 有 | 无（但有稳定费） |
| 适用场景 | 看多某资产 | 双向交易 | 铸造稳定币 |
| Sui 实现路径 | 借贷 + DEX | PerpMarket | CDPSystem |
