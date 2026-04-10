# 7.3 闪电贷：无抵押瞬时借贷

## 什么是闪电贷

闪电贷允许用户在**不提供任何抵押品**的情况下借入资金，条件是：**在同一笔交易内偿还本金和手续费。**

如果用户未能在交易结束前偿还，整笔交易回滚——就像从未发生过一样。

## 为什么闪电贷是安全的

安全性来自区块链的原子性：一笔交易要么全部成功，要么全部回滚。不存在"借了钱但没还"的中间状态。

```
交易开始
  ├── 借出 10000 USDC
  ├── 用户执行套利/清算/其他操作
  ├── 检查：用户是否偿还了 10000 USDC + 手续费？
  │   ├── 是 → 交易成功，手续费归池子
  │   └── 否 → 交易回滚，一切恢复原状
交易结束
```

## Move 实现

```move
module flash_loan {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientLiquidity: u64 = 200;
    const ERepaymentFailed: u64 = 201;
    const EUnauthorized: u64 = 202;
    const EPoolPaused: u64 = 203;

    struct FlashLoanPool<phantom T> has key {
        id: UID,
        treasury: Balance<T>,
        fee_bps: u64,
        paused: bool,
    }

    struct FlashLoanCap has key, store {
        id: UID,
        pool_id: ID,
    }

    public fun init<T>(fee_bps: u64, ctx: &mut TxContext) {
        let pool = FlashLoanPool<T> {
            id: object::new(ctx),
            treasury: balance::zero<T>(),
            fee_bps,
            paused: false,
        };
        let cap = FlashLoanCap {
            id: object::new(ctx),
            pool_id: object::id(&pool),
        };
        transfer::share_object(pool);
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    public fun fund_pool<T>(
        _cap: &FlashLoanCap,
        pool: &mut FlashLoanPool<T>,
        coin: Coin<T>,
    ) {
        balance::join(&mut pool.treasury, coin::into_balance(coin));
    }

    public fun borrow<T>(
        pool: &mut FlashLoanPool<T>,
        amount: u64,
        ctx: &mut TxContext,
    ): (Coin<T>, u64) {
        assert!(!pool.paused, EPoolPaused);
        assert!(balance::value(&pool.treasury) >= amount, EInsufficientLiquidity);
        let fee = (amount as u128) * (pool.fee_bps as u128) / 10000;
        let total_due = amount + (fee as u64);
        let loan_coin = coin::take(&mut pool.treasury, amount, ctx);
        (loan_coin, total_due)
    }

    public fun repay<T>(
        pool: &mut FlashLoanPool<T>,
        repayment: Coin<T>,
        expected_total: u64,
    ) {
        let repaid = coin::value(&repayment);
        assert!(repaid >= expected_total, ERepaymentFailed);
        balance::join(&mut pool.treasury, coin::into_balance(repayment));
    }

    public fun set_fee<T>(
        _cap: &FlashLoanCap,
        pool: &mut FlashLoanPool<T>,
        new_fee_bps: u64,
    ) {
        pool.fee_bps = new_fee_bps;
    }

    public fun pause<T>(_cap: &FlashLoanCap, pool: &mut FlashLoanPool<T>) {
        pool.paused = true;
    }

    public fun unpause<T>(_cap: &FlashLoanCap, pool: &mut FlashLoanPool<T>) {
        pool.paused = false;
    }
}
```

## 使用示例：套利机器人

```move
module arbitrage_bot {
    use flash_loan::{Self, FlashLoanPool};
    use amm::{Self, Pool};
    use sui::coin::Coin;
    use sui::tx_context::TxContext;

    public fun execute_arbitrage<T>(
        flash_pool: &mut FlashLoanPool<T>,
        pool_a: &mut Pool<T, phantom USDC>,
        pool_b: &mut Pool<T, phantom USDC>,
        borrow_amount: u64,
        ctx: &mut TxContext,
    ) {
        let (loan_coin, total_due) = flash_loan::borrow(flash_pool, borrow_amount, ctx);

        let usdc_from_a = amm::swap_a_to_b(pool_a, loan_coin, ctx);

        let final_coin = amm::swap_b_to_a(pool_b, usdc_from_a, ctx);

        let final_amount = coin::value(&final_coin);
        assert!(final_amount >= total_due, 999);

        let (repayment, profit) = split_coin(final_coin, total_due, ctx);

        flash_loan::repay(flash_pool, repayment, total_due);
        transfer::transfer(profit, tx_context::sender(ctx));
    }

    fun split_coin<T>(
        coin: Coin<T>,
        split_at: u64,
        ctx: &mut TxContext,
    ): (Coin<T>, Coin<T>) {
        let profit = coin::split(coin, split_at, ctx);
        (coin, profit)
    }
}
```

这个套利示例展示了闪电贷的典型用法：
1. 从闪电贷池借入 SUI
2. 在 DEX A 卖出 SUI 获得 USDC
3. 在 DEX B 用 USDC 买回 SUI
4. 偿还闪电贷（本金 + 手续费）
5. 保留利润

## 使用示例：清算机器人

```move
module liquidation_bot {
    use flash_loan::{Self, FlashLoanPool};
    use lending::{Self, Market, BorrowPosition};
    use sui::coin::Coin;
    use sui::tx_context::TxContext;

    public fun flash_liquidate<T>(
        flash_pool: &mut FlashLoanPool<T>,
        market: &mut Market,
        borrow_position: BorrowPosition,
        ctx: &mut TxContext,
    ) {
        let debt_amount = lending::get_debt_amount(&borrow_position);
        let (loan_coin, total_due) = flash_loan::borrow(flash_pool, debt_amount, ctx);

        let seized_collateral = lending::liquidate_with_repayment(
            market,
            borrow_position,
            loan_coin,
            ctx,
        );

        let seized_value = coin::value(&seized_collateral);
        assert!(seized_value >= total_due, 999);

        let (repayment, bonus) = coin::split(seized_collateral, total_due, ctx);
        flash_loan::repay(flash_pool, repayment, total_due);
        transfer::transfer(bonus, tx_context::sender(ctx));
    }
}
```

清算机器人的逻辑：
1. 借入与债务等额的代币
2. 替借款人偿还债务
3. 获得抵押品（含清算奖励）
4. 偿还闪电贷
5. 保留清算奖励作为利润

## 闪电贷的常见用途

| 用途 | 描述 | 风险 |
|------|------|------|
| 套利 | 利用不同 DEX 的价格差 | 低（无利可图时交易自动回滚） |
| 清算 | 借入代币替人还债，获得清算奖励 | 中（需要计算清算是否有利） |
| 自我清算 | 借入代币还自己的债，避免清算罚金 | 低 |
| 攻击 | 操纵价格、利用协议漏洞 | 高（详见第17章） |

## 安全考量

闪电贷本身不是攻击工具——它只是让"无资本"的人也能执行原本需要大量资金的交易。攻击的根本原因不是闪电贷，而是协议的漏洞（如价格依赖单一来源、缺少 TWAP 保护）。
