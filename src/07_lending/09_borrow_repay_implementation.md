# 7.9 Move 实现 Borrow / Repay

本节逐行分析 `lending_market` 中的 borrow 和 repay 函数实现。

## borrow 函数

```move
// code/lending_market/sources/market.move

public fun borrow<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    deposit_receipt: &DepositReceipt<Collateral, Borrow>,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<Borrow>, BorrowReceipt<Collateral, Borrow>) {
```

```
参数:
  market: 借贷市场（Shared Object，需要 &mut）
  deposit_receipt: 存款凭证（只读引用，不消耗）
  amount: 借款金额
  ctx: 交易上下文

返回:
  Coin<Borrow>: 借到的代币
  BorrowReceipt: 债务凭证（Owned Object）
```

### 步骤 1: 输入验证

```move
    assert!(amount > 0, EInvalidAmount);
    assert!(object::id(market) == deposit_receipt.market_id, EReceiptMismatch);
```

```
检查:
  → amount > 0: 不允许零借款
  → Receipt 属于当前 Market: 防止跨市场使用
```

### 步骤 2: 流动性检查

```move
    assert!(balance::value(&market.borrow_vault) >= amount, EInsufficientLiquidity);
```

```
确保池中有足够的可借资产:
  borrow_vault: LP 提供的可借资产
  如果所有资金已被借出 → 拒绝借款
```

### 步骤 3: Health Factor 检查

```move
    let hf = health_factor(
        deposit_receipt.collateral_amount,
        amount,                         // 本次借款后的总债务
        market.collateral_factor_bps,
    );
    assert!(hf.value_bps > BPS_BASE, EHealthFactorTooLow);
```

```
关键安全检查:
  collateral_amount: 用户的抵押品数量
  amount: 本次借款金额（简化：视为用户的全部债务）
  collateral_factor_bps: 抵押因子（如 7500 = 75%）

  HF = collateral × factor / debt
  必须满足 HF > 1.0（即 > 10000 bps）

  例: 抵押 100 SUI，factor=75%，借款 60 USDC
  HF = 100 × 7500 / 60 = 12500 bps = 1.25 > 1.0 ✅

  例: 抵押 100 SUI，factor=75%，借款 80 USDC
  HF = 100 × 7500 / 80 = 9375 bps = 0.9375 < 1.0 ❌
```

### 步骤 4: 状态更新

```move
    market.total_borrow = market.total_borrow + amount;

    sui::event::emit(BorrowEvent {
        borrower: ctx.sender(),
        borrow_amount: amount,
    });

    let borrow_coin = coin::take(&mut market.borrow_vault, amount, ctx);
```

```
更新:
  1. 增加 total_borrow（追踪总借款量）
  2. 发出 BorrowEvent（链上可观测）
  3. 从 borrow_vault 取出代币给借款人
```

### 步骤 5: 创建 BorrowReceipt

```move
    let borrow_receipt = BorrowReceipt<Collateral, Borrow> {
        id: object::new(ctx),
        market_id: object::id(market),
        borrow_amount: amount,
    };

    (borrow_coin, borrow_receipt)
}
```

```
返回两个值:
  borrow_coin: 借到的代币（用户可以立即使用）
  borrow_receipt: 债务凭证（用户必须保存，用于还款和清算）
```

## repay 函数

```move
public fun repay<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    borrow_receipt: BorrowReceipt<Collateral, Borrow>,
    coin: Coin<Borrow>,
    ctx: &TxContext,
) {
    assert!(object::id(market) == borrow_receipt.market_id, EReceiptMismatch);

    let repay_amount = coin::value(&coin);
    let debt = borrow_receipt.borrow_amount;
    assert!(repay_amount == debt, EInvalidAmount);
```

```
还款逻辑:
  1. 验证 Receipt 属于当前 Market
  2. 获取还款金额和债务金额
  3. 必须精确还清全部债务（简化模型）

  注意: repay_amount == debt
  → 不支持部分还款（生产级协议支持）
```

### 状态更新和清理

```move
    market.total_borrow = market.total_borrow - debt;
    balance::join(&mut market.borrow_vault, coin::into_balance(coin));

    // 销毁 BorrowReceipt
    let BorrowReceipt { id, market_id: _, borrow_amount: _ } = borrow_receipt;
    id.delete();

    sui::event::emit(RepayEvent {
        repayer: tx_context::sender(ctx),
        repay_amount,
    });
}
```

```
还款流程:
  1. 减少 total_borrow
  2. 将还款代币放回 borrow_vault
  3. 销毁 BorrowReceipt（债务清除）
  4. 发出 RepayEvent

Receipt 的销毁:
  → 解构 BorrowReceipt
  → 删除其 UID
  → Receipt 不再存在 = 债务已清
```

## 完整的 Borrow-Repay 流程

```
步骤 1: 供应抵押品
  supply_collateral(market, 1000 SUI coins)
  → DepositReceipt { collateral_amount: 1000 }

步骤 2: 借款
  borrow(market, &deposit_receipt, 600 USDC)
  → 检查 HF: 1000 × 7500 / 600 = 12500 > 10000 ✅
  → 获得 600 USDC coins
  → BorrowReceipt { borrow_amount: 600 }

步骤 3: 使用借来的资金（交易、投资等）
  ...

步骤 4: 还款
  repay(market, borrow_receipt, 600 USDC coins)
  → 销毁 BorrowReceipt
  → 债务清除

步骤 5: 取回抵押品
  withdraw_collateral(market, deposit_receipt, ...)
  → 获得 1000 SUI coins
  → 销毁 DepositReceipt
```

## 简化模型的局限

```
lending_market 的简化:
  1. 每次借款创建新 Receipt（不合并债务）
  2. 还款必须精确还清（不支持部分还款）
  3. 假设 1:1 价格（实际需要预言机）
  4. 不计算利息累积（简化演示）

生产级需要:
  → 合并多笔债务为单一余额
  → 支持部分还款
  → 集成预言机获取价格
  → 利息按区块累积（使用 Index）
```

## 总结

```
borrow() 的安全防线:
  1. 非零金额检查
  2. Receipt 归属检查
  3. 流动性充足检查
  4. Health Factor > 1 检查
  5. 状态更新 + 事件发射

repay() 的流程:
  验证 → 还款 → 销毁 Receipt → 事件

这两个函数构成了借贷协议的核心"借款引擎"
```
