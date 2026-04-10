# 14.5 清算套利

## 清算为什么是套利

当借款人的抵押率跌破阈值时，协议需要出售其抵押品来偿还债务。清算者可以以折扣价购买抵押品——折扣就是利润。

```
用户存入 1000 SUI（$2/枚 = $2000）
借出 1200 USDC
抵押率 = 2000/1200 = 166%

SUI 跌到 $1.4:
抵押率 = 1400/1200 = 116% < 130%（清算阈值）

清算者:
  1. 偿还 1200 USDC（或部分）
  2. 获得 1200 × 1.05 = 1260 SUI（5% 罚金加成）
  3. 卖出 1260 SUI × $1.4 = $1764
  4. 利润: $1764 - $1200 = $564
```

## 清算机器人实现

```move
module liquidation_bot {
    use lending::{Self, Market, BorrowPosition, DepositPosition};
    use amm::Pool;
    use flash_loan::FlashLoanPool;
    use sui::coin::{Self, Coin};
    use sui::tx_context::{Self, TxContext};

    const ENotLiquidatable: u64 = 3000;
    const EInsufficientProfit: u64 = 3001;

    /// 方式 1: 自有资金清算
    /// 清算者持有还款代币，直接执行清算
    public fun liquidate_with_own_funds<Collateral, Debt>(
        market: &mut Market,
        dex_pool: &mut Pool<Collateral, Debt>,
        borrower_deposits: &mut vector<&mut DepositPosition>,
        borrower_borrows: &mut vector<&mut BorrowPosition>,
        repayment: Coin<Debt>,
        ctx: &mut TxContext,
    ): Coin<Collateral> {
        let hf = lending::calculate_health_factor(
            market, borrower_deposits, borrower_borrows
        );
        assert!(hf < 10000, ENotLiquidatable);

        let seized = lending::liquidate(
            market, borrower_deposits, borrower_borrows, repayment, ctx
        );

        let output = amm::swap_base_to_quote(dex_pool, seized, ctx);
        output
    }

    /// 方式 2: 闪电贷清算（零资本）
    public fun liquidate_with_flash_loan<Collateral, Debt>(
        flash_pool: &mut FlashLoanPool<Debt>,
        market: &mut Market,
        dex_pool: &mut Pool<Collateral, Debt>,
        borrower_deposits: &mut vector<&mut DepositPosition>,
        borrower_borrows: &mut vector<&mut BorrowPosition>,
        ctx: &mut TxContext,
    ): Coin<Debt> {
        let debt_amount = lending::get_total_debt(borrower_borrows);
        let max_liquidate = debt_amount / 2;
        let (loan, total_due) = flash_loan::borrow(flash_pool, max_liquidate, ctx);

        let hf = lending::calculate_health_factor(
            market, borrower_deposits, borrower_borrows
        );
        assert!(hf < 10000, ENotLiquidatable);

        let seized = lending::liquidate(
            market, borrower_deposits, borrower_borrows, loan, ctx
        );

        let sold = amm::swap_base_to_quote(dex_pool, seized, ctx);
        let sold_amount = coin::value(&sold);
        assert!(sold_amount >= total_due, EInsufficientProfit);

        let (repayment, profit) = coin::split(&mut sold, sold_amount - total_due, ctx);
        flash_loan::repay(flash_pool, repayment, total_due);
        transfer::transfer(profit, tx_context::sender(ctx));

        sold
    }

    /// 监控函数：扫描链上所有仓位，找到可清算的
    /// 通常由链下服务调用
    public fun scan_positions(
        market: &Market,
        positions: &vector<BorrowPosition>,
        price_feed: &PriceFeed,
    ): vector<u64> {
        let mut liquidatable = vector::empty();
        let mut i = 0;
        while (i < vector::length(positions)) {
            let pos = vector::borrow(positions, i);
            let collateral_value = get_collateral_value(market, pos, price_feed);
            let debt_value = get_debt_value(market, pos, price_feed);
            let hf = collateral_value * 10000 / debt_value;
            if (hf < 10000) {
                vector::push_back(&mut liquidatable, i as u64);
            };
            i = i + 1;
        };
        liquidatable
    }
}
```

## 清算的经济学

清算者的利润 = 清算折扣 - DEX 滑点 - Gas - 闪电贷费率（如有）

```
利润 = seized_collateral × discount_rate
      - seized_collateral × dex_slippage
      - gas_cost
      - flash_loan_fee
```

清算无利可图的三个原因：
1. **Gas 竞争**：多个清算者竞争，Gas 被推高
2. **抵押品无流动性**：DEX 上卖不出好价格
3. **折扣太低**：协议的清算罚金不够覆盖成本

## 清算策略对比

| 策略 | 资本需求 | 风险 | 复杂度 |
|------|----------|------|--------|
| 自有资金清算 | 高 | 中 | 低 |
| 闪电贷清算 | 零 | 低 | 中 |
| 闪电贷+DEX 组合 | 零 | 低 | 高 |
| 自动化监控+执行 | 取决于策略 | 取决于策略 | 最高 |
