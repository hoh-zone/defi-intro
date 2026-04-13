# 7.13 Move 实现抵押管理

本节分析 lending_market 中的抵押品存入和取回实现。

## supply_collateral — 存入抵押品

```move
public fun supply_collateral<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    coin: Coin<Collateral>,
    ctx: &mut TxContext,
): DepositReceipt<Collateral, Borrow> {
    let amount = coin::value(&coin);
    assert!(amount > 0, EInvalidAmount);

    market.total_collateral = market.total_collateral + amount;
    balance::join(&mut market.collateral_vault, coin::into_balance(coin));

    sui::event::emit(SupplyEvent {
        supplier: ctx.sender(),
        collateral_amount: amount,
    });

    DepositReceipt<Collateral, Borrow> {
        id: object::new(ctx),
        market_id: object::id(market),
        collateral_amount: amount,
    }
}
```

```
执行步骤:
  1. 获取存入金额
  2. 验证金额 > 0
  3. 增加 total_collateral（记账）
  4. 将 Coin 转为 Balance 并存入 collateral_vault
  5. 发出 SupplyEvent
  6. 创建并返回 DepositReceipt

注意:
  → 不需要 Health Factor 检查（只是存入，没有借款）
  → 任何人都可以存入抵押品
  → Coin 被消耗，变成 Balance 存入池子
```

## withdraw_collateral — 取回抵押品

```move
public fun withdraw_collateral<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    deposit_receipt: DepositReceipt<Collateral, Borrow>,
    borrow_receipt: &BorrowReceipt<Collateral, Borrow>,
    ctx: &mut TxContext,
): Coin<Collateral> {
```

```
参数:
  market: 借贷市场
  deposit_receipt: 存款凭证（会被消耗/销毁）
  borrow_receipt: 借款凭证（只读引用，用于计算 HF）
  ctx: 交易上下文

为什么需要 borrow_receipt:
  → 取回抵押品后需要检查 HF 是否仍然安全
  → 需要知道当前债务是多少
```

### 验证和 HF 检查

```move
    assert!(object::id(market) == deposit_receipt.market_id, EReceiptMismatch);
    assert!(object::id(market) == borrow_receipt.market_id, EReceiptMismatch);

    let collateral_amount = deposit_receipt.collateral_amount;

    let hf = health_factor(
        collateral_amount,
        borrow_receipt.borrow_amount,
        market.collateral_factor_bps,
    );
    assert!(hf.value_bps > BPS_BASE, EHealthFactorTooLow);
```

```
检查流程:
  1. 验证两张 Receipt 都属于当前 Market
  2. 获取存款金额
  3. 计算 Health Factor（使用 collateral_factor）
  4. HF 必须 > 1.0

重要:
  → 这里用 collateral_factor（不是 liquidation_threshold）
  → 取款后 HF 仍需 > 1.0 = 仍有安全缓冲
  → 确保取款不会让仓位立刻进入可清算状态
```

### 状态更新

```move
    assert!(balance::value(&market.collateral_vault) >= collateral_amount, EInsufficientCollateral);

    market.total_collateral = market.total_collateral - collateral_amount;

    let DepositReceipt { id, market_id: _, collateral_amount: _ } = deposit_receipt;
    id.delete();

    sui::event::emit(WithdrawEvent {
        withdrawer: ctx.sender(),
        collateral_amount,
    });

    coin::take(&mut market.collateral_vault, collateral_amount, ctx)
}
```

```
取款流程:
  1. 确保池中有足够抵押品
  2. 减少 total_collateral
  3. 销毁 DepositReceipt
  4. 发出事件
  5. 从 collateral_vault 取出代币返回

Receipt 销毁:
  → 解构 DepositReceipt
  → 删除 UID
  → 不再持有 → 抵押品已取回
```

## 完整操作示例

```
测试场景（来自 market_test.move）:

1. 初始化:
   create_market<SUI, USDC>(
     collateral_factor: 7500,     // 75%
     liquidation_threshold: 8000, // 80%
     liquidation_bonus: 500,      // 5%
     base_rate: 200, kink: 8000,
     multiplier: 1000, jump: 5000
   )

2. 供应流动性:
   add_liquidity(market, 10000 USDC)

3. 存入抵押品:
   supply_collateral(market, 1000 SUI coins)
   → DepositReceipt { collateral_amount: 1000 }

4. 借款:
   borrow(market, &deposit_receipt, 5000)
   → HF = 1000 × 7500 / 5000 = 1500 > 10000 ✅
   → Wait... HF should be: 1000 * 7500 / 5000 = 1500 bps
   → Actually HF = 1000 × 7500 / 5000 = 1500
   → 1500 < 10000... need more collateral or less borrow

   实际测试中:
   deposit 10000 SUI, borrow 5000 USDC
   HF = 10000 × 7500 / 5000 = 15000 > 10000 ✅

5. 还款:
   repay(market, borrow_receipt, 5000 USDC)
   → 销毁 BorrowReceipt

6. 取回抵押品:
   withdraw_collateral(market, deposit_receipt, ...)
   → 但需要 borrow_receipt...（简化限制）
```

## 简化模型 vs 生产级

```
lending_market 简化:
  → 取款时需要传入 BorrowReceipt（知道当前债务）
  → 不支持"无借款时直接取回"的场景
  → Receipt 的关联管理复杂

生产级改进:
  → 使用 Account 对象统一管理用户的存款和借款
  → Account 内部追踪所有 Receipt
  → 取款时自动检查 HF，无需外部传入 Receipt

  public struct Account has key {
    deposits: Table<TypeID, DepositInfo>,
    borrows: Table<TypeID, BorrowInfo>,
  }
```

## 总结

```
抵押管理的两个核心函数:

supply_collateral:
  存入 Coin → 创建 DepositReceipt
  → 无需 HF 检查（只是存款）
  → 增加 total_collateral

withdraw_collateral:
  销毁 DepositReceipt → 返还 Coin
  → 需要 HF > 1 检查（取款后仍安全）
  → 减少 total_collateral

安全保证:
  任何时候，用户的 HF > 1
  → 抵押品价值 × factor > 债务
  → 系统偿付能力有保障
```
