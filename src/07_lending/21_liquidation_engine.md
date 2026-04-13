# 7.21 Move 实现 Liquidation Engine

本节逐行分析 lending_market 中的 liquidate 函数。

## liquidate 函数签名

```move
public fun liquidate<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    borrow_receipt: BorrowReceipt<Collateral, Borrow>,
    repay_coin: Coin<Borrow>,
    deposit_receipt: &mut DepositReceipt<Collateral, Borrow>,
    ctx: &mut TxContext,
): Coin<Collateral>
```

```
参数:
  market: 借贷市场（Shared Object）
  borrow_receipt: 借款人的债务凭证（会被销毁）
  repay_coin: 清算人的还款代币
  deposit_receipt: 借款人的存款凭证（会被修改，减少抵押品）
  ctx: 交易上下文

返回:
  Coin<Collateral>: 没收的抵押品（给清算人）

注意:
  → borrow_receipt 按值传入（会被消耗/销毁）
  → deposit_receipt 按可变引用传入（只修改，不销毁）
  → 清算人需要持有借款人的两张 Receipt
```

## 步骤 1: 验证 Receipt 归属

```move
    assert!(object::id(market) == borrow_receipt.market_id, EReceiptMismatch);
    assert!(object::id(market) == deposit_receipt.market_id, EReceiptMismatch);
```

```
确保两张 Receipt 都属于当前 Market:
  → 防止跨市场操作
  → 防止伪造 Receipt
```

## 步骤 2: 验证还款金额

```move
    let repay_amount = coin::value(&repay_coin);
    let debt = borrow_receipt.borrow_amount;
    assert!(repay_amount == debt, EInvalidAmount);
```

```
全额清算模式:
  → 必须还清全部债务（repay == debt）
  → 不支持部分还款

生产级改为:
  assert!(repay_amount <= debt * close_factor / 10000);
  → 允许部分还款
```

## 步骤 3: 验证可清算

```move
    let hf = health_factor(
        deposit_receipt.collateral_amount,
        debt,
        market.liquidation_threshold_bps,  // ← 使用 threshold，不是 factor
    );
    assert!(hf.value_bps < BPS_BASE, ENotLiquidatable);
```

```
关键安全检查:
  → 使用 liquidation_threshold（不是 collateral_factor）
  → HF 必须 < 1.0（< 10000 bps）
  → 防止清算健康仓位

  如果 HF >= 1.0:
  → 仓位仍然健康
  → 不允许清算
  → 交易 abort，报 ENotLiquidatable
```

## 步骤 4: 计算没收金额

```move
    let seized_amount = debt * (BPS_BASE + market.liquidation_bonus_bps) / BPS_BASE;

    let seized_amount = if (seized_amount > deposit_receipt.collateral_amount) {
        deposit_receipt.collateral_amount
    } else {
        seized_amount
    };
```

```
没收计算:
  seized = debt × (100% + bonus)
  例: debt = 1000, bonus = 5%
  seized = 1000 × 1.05 = 1050

上限保护:
  → 不能没收超过借款人的全部抵押品
  → 防止 seized > collateral 的不合理情况

  if seized > collateral:
    seized = collateral（最多没收全部）
```

## 步骤 5: 更新状态

```move
    assert!(balance::value(&market.collateral_vault) >= seized_amount, EInsufficientCollateral);

    // 更新借款人的存款凭证
    deposit_receipt.collateral_amount = deposit_receipt.collateral_amount - seized_amount;

    // 更新市场状态
    market.total_borrow = market.total_borrow - debt;
    market.total_collateral = market.total_collateral - seized_amount;
```

```
状态更新:
  1. 确保池中有足够的抵押品
  2. 减少借款人的 collateral_amount（DepositReceipt 被修改）
  3. 减少 total_borrow（债务被清偿）
  4. 减少 total_collateral（抵押品被没收）

  注意: deposit_receipt 仍然存在
  → 如果 collateral_amount > 0，借款人还有剩余抵押品
  → 如果 collateral_amount == 0，借款人失去所有抵押品
```

## 步骤 6: 完成清算

```move
    // 将还款放入 borrow_vault
    balance::join(&mut market.borrow_vault, coin::into_balance(repay_coin));

    // 销毁 BorrowReceipt（债务清除）
    let BorrowReceipt { id, market_id: _, borrow_amount: _ } = borrow_receipt;
    id.delete();

    sui::event::emit(LiquidationEvent {
        liquidator: ctx.sender(),
        repay_amount: debt,
        seized_collateral: seized_amount,
    });

    // 返回没收的抵押品给清算人
    coin::take(&mut market.collateral_vault, seized_amount, ctx)
}
```

```
清算完成:
  1. 还款资金回到 borrow_vault
  2. BorrowReceipt 被销毁（债务清除）
  3. 发出 LiquidationEvent
  4. 返回抵押品给清算人

清理后的状态:
  borrow_receipt: 已销毁
  deposit_receipt: collateral_amount 已减少
  market: total_borrow ↓, total_collateral ↓
```

## 完整清算示例

```
初始:
  Alice: DepositReceipt { collateral: 10000 SUI }
  Alice: BorrowReceipt { borrow: 7000 USDC }
  Market: bonus = 500 bps (5%)

SUI 价格下跌，HF < 1 → 可清算

清算人执行:
  1. 准备 7000 USDC
  2. 调用 liquidate(market, borrow_receipt, 7000 USDC, deposit_receipt)

  验证:
  → receipts match market ✅
  → repay == debt (7000 == 7000) ✅
  → HF < 1.0 ✅

  计算:
  → seized = 7000 × 1.05 = 7350 SUI
  → 7350 < 10000 → 不需要 cap

  结果:
  → 清算人获得 7350 SUI
  → Alice 剩余: 10000 - 7350 = 2650 SUI
  → BorrowReceipt 销毁
  → DepositReceipt.collateral_amount = 2650

  清算人利润:
  → 支出 7000 USDC
  → 获得 7350 SUI（如果 SUI = $1，值 $7350）
  → 毛利润 = $350（5% bonus）
```

## 总结

```
liquidate() 的完整流程:
  1. 验证 Receipt 归属
  2. 验证全额还款
  3. 验证 HF < 1.0（可清算）
  4. 计算 seized = debt × (1 + bonus)，cap at collateral
  5. 更新所有状态
  6. 销毁 BorrowReceipt
  7. 返回抵押品给清算人

安全保证:
  → 只有不健康的仓位可以被清算
  → 不能没收超过借款人的全部抵押品
  → 所有状态变更保持一致
```
