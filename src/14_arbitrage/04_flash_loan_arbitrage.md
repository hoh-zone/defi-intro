# 14.4 闪电贷零资本套利

## 为什么闪电贷改变了套利

在闪电贷出现之前，套利者需要持有大量资本。10 万 USDC 的价差套利需要 10 万 USDC 的本金。

闪电贷让套利者可以在**零资本**的情况下执行套利：借入资金、执行策略、偿还借款，全部在同一笔交易中完成。

## 完整套利机器人

```move
module flash_loan_arbitrage {
    use flash_loan::{Self, FlashLoanPool};
    use amm::Pool;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientProfit: u64 = 2000;
    const ERepaymentFailed: u64 = 2001;

    struct ArbitrageResult has store {
        gross_profit: u64,
        flash_loan_fee: u64,
        gas_cost: u64,
        net_profit: u64,
    }

    /// 场景 1: DEX 价差套利
    /// 从闪电贷借入 USDC → 在低价 DEX 买入 SUI → 在高价 DEX 卖出 SUI → 偿还
    public fun dex_spread_arbitrage<Quote, Base>(
        flash_pool: &mut FlashLoanPool<Quote>,
        pool_buy: &mut Pool<Quote, Base>,
        pool_sell: &mut Pool<Base, Quote>,
        borrow_amount: u64,
        min_net_profit: u64,
        ctx: &mut TxContext,
    ): ArbitrageResult {
        let (loan, total_due) = flash_loan::borrow(flash_pool, borrow_amount, ctx);
        let fee = total_due - borrow_amount;

        let base_coin = amm::swap_quote_to_base(pool_buy, loan, ctx);
        let quote_coin = amm::swap_base_to_quote(pool_sell, base_coin, ctx);

        let received = coin::value(&quote_coin);
        assert!(received >= total_due, ERepaymentFailed);

        let gross_profit = received - total_due;
        let (repayment, profit) = if (received > total_due) {
            let profit_coin = coin::split(&mut quote_coin, received - total_due, ctx);
            (quote_coin, profit_coin)
        } else {
            (quote_coin, coin::zero(ctx))
        };
        flash_loan::repay(flash_pool, repayment, total_due);

        let net_profit = coin::value(&profit);
        assert!(net_profit >= min_net_profit, EInsufficientProfit);
        transfer::transfer(profit, tx_context::sender(ctx));

        ArbitrageResult {
            gross_profit,
            flash_loan_fee: fee,
            gas_cost: 0,
            net_profit,
        }
    }

    /// 场景 2: 清算+DEX 组合套利
    /// 借入还款代币 → 执行清算获得抵押品 → 在 DEX 卖出 → 偿还
    public fun liquidation_arbitrage<Collateral, Debt>(
        flash_pool: &mut FlashLoanPool<Debt>,
        lending_market: &mut LendingMarket,
        dex_pool: &mut Pool<Collateral, Debt>,
        borrower_position: &mut BorrowPosition,
        ctx: &mut TxContext,
    ): Coin<Debt> {
        let debt_amount = lending::get_debt_amount(borrower_position);
        let (loan, total_due) = flash_loan::borrow(flash_pool, debt_amount, ctx);

        let seized_collateral = lending::liquidate_with_coin(
            lending_market,
            borrower_position,
            loan,
            ctx,
        );

        let collateral_value = coin::value(&seized_collateral);
        let output = amm::swap_base_to_quote(dex_pool, seized_collateral, ctx);
        let output_amount = coin::value(&output);

        assert!(output_amount >= total_due, ERepaymentFailed);

        let (repayment, profit) = coin::split(&mut output, output_amount - total_due, ctx);
        flash_loan::repay(flash_pool, repayment, total_due);
        transfer::transfer(profit, tx_context::sender(ctx));

        output
    }

    /// 场景 3: 稳定币锚定套利
    /// CDP 稳定币脱锚 → 低价买入 → 在 CDP 赎回抵押品 → 卖出获利
    public fun peg_arbitrage<Stable, Collateral>(
        flash_pool: &mut FlashLoanPool<Stable>,
        cdp_system: &mut CDPSystem,
        dex_pool: &mut Pool<Stable, Collateral>,
        stable_amount: u64,
        ctx: &mut TxContext,
    ): Coin<Collateral> {
        let (loan, total_due) = flash_loan::borrow(flash_pool, stable_amount, ctx);

        let collateral_out = cdp::redeem(cdp_system, loan, ctx);
        let collateral_value = coin::value(&collateral_out);

        let partial = coin::split(
            &mut collateral_out,
            collateral_value / 2,
            ctx,
        );
        let stable_from_dex = amm::swap_base_to_quote(dex_pool, partial, ctx);
        let stable_amount_received = coin::value(&stable_from_dex);

        assert!(stable_amount_received >= total_due, ERepaymentFailed);
        let (repayment, _) = coin::split(&mut stable_from_dex, total_due, ctx);
        flash_loan::repay(flash_pool, repayment, total_due);

        transfer::transfer(stable_from_dex, tx_context::sender(ctx));
        collateral_out
    }
}
```

## 利润计算

```
零资本套利的利润公式:

Profit = Output - Input - FlashLoanFee - Gas
       = Output - Input - Input × fee_bps/10000 - Gas

盈亏平衡条件:
Output ≥ Input × (1 + fee_bps/10000) + Gas
```

| 闪电贷费率 | 盈亏平衡价差（不含 Gas） |
|-----------|------------------------|
| 0.05% | > 0.05% |
| 0.09% (Aave) | > 0.09% |
| 0.3% | > 0.3% |

闪电贷费率是套利的"入场门票"。价差必须超过费率才有可能盈利。
