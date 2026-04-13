# 7.20 部分清算 vs 全额清算

清算可以一次性还清全部债务，也可以只偿还部分。本节分析两种模式的优劣。

## 全额清算

```
lending_market 使用全额清算:
  → 清算人一次性还清全部债务
  → 没收 debt × (1 + bonus) 的抵押品
  → 借款人的 BorrowReceipt 被销毁

代码中的要求:
  assert!(repay_amount == debt, EInvalidAmount);
  → 必须还清全部债务

优点:
  → 实现简单
  → 彻底清理不健康仓位
  → 系统立即恢复安全

缺点:
  → 对借款人影响大（可能失去所有抵押品）
  → 需要清算人有大量资金
  → 大仓位可能难以一次性清算
```

## 部分清算

```
生产级协议（Aave/Compound）使用部分清算:
  → 清算人只偿还部分债务
  → 按比例没收抵押品
  → 借款人的仓位变小但仍存在

Close Factor:
  → 一次清算最多偿还的债务比例
  → 通常为 50%
  → 例: 债务 1000 USDC，最多偿还 500 USDC

部分清算的计算:
  repay_amount ≤ debt × close_factor
  seized = repay_amount × (1 + bonus)

  例:
  debt = 1000, close_factor = 50%, bonus = 5%
  repay = 500, seized = 525

  清算后:
  debt = 500, collateral -= 525
  HF 可能恢复 > 1.0 → 安全
```

## 数值对比

### 场景: SUI 价格暴跌

```
初始状态:
  抵押: 10000 SUI（$2.00）= $20000
  债务: 15000 USDC
  HF = 20000 × 80% / 15000 = 1.067

SUI 跌到 $1.80:
  collateral = $18000
  HF = 18000 × 80% / 15000 = 0.96 → 可清算

全额清算 (bonus=5%):
  repay: 15000 USDC
  seized: 15000 × 1.05 = 15750 SUI
  Alice 剩余: 10000 - 15750 = 0 SUI（全部没收）
  Alice 损失: 100% 抵押品

部分清算 (close_factor=50%, bonus=5%):
  repay: 7500 USDC
  seized: 7500 × 1.05 = 7875 SUI
  Alice 剩余: 10000 - 7875 = 2125 SUI（值 $3825）
  新 debt: 7500 USDC
  新 HF: 2125 × 1.80 × 80% / 7500 = 0.408... still < 1

  → 可能需要多次部分清算
  → 但 Alice 至少保留了部分抵押品
```

### 场景: 轻微不健康

```
初始状态:
  抵押: 10000 SUI（$2.00）= $20000
  债务: 15000 USDC

SUI 跌到 $1.93:
  collateral = $19300
  HF = 19300 × 80% / 15000 = 1.029 → 刚刚可清算

全额清算:
  repay: 15000, seized: 15750 SUI
  Alice 剩余: 0（被全额清算，损失巨大）

部分清算 (close_factor=50%):
  repay: 7500, seized: 7875 SUI
  Alice 剩余: 2125 SUI（值 $4101）
  新 debt: 7500
  新 HF: 2125 × 1.93 × 80% / 7500 = 0.437... still bad

  实际上 HF 仍然 < 1，需要更多清算
```

## 为什么生产级使用部分清算

```
1. 对借款人更友好
   → 不会一次性失去所有抵押品
   → 给借款人恢复的机会

2. 降低清算门槛
   → 清算人不需要一次准备所有还款资金
   → 小清算人也能参与

3. 更好的风险分布
   → 多次清算分散在多个区块
   → 减少单笔大额清算的市场冲击

4. 可组合性
   → 可以用闪电贷执行部分清算
   → 闪电贷金额更小，更容易获得
```

## 部分清算的 Move 实现思路

```move
// 修改 liquidate 支持部分清算
public fun partial_liquidate<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    borrow_receipt: &mut BorrowReceipt<Collateral, Borrow>,
    repay_coin: Coin<Borrow>,
    deposit_receipt: &mut DepositReceipt<Collateral, Borrow>,
    close_factor_bps: u64,  // 如 5000 = 50%
    ctx: &mut TxContext,
): Coin<Collateral> {
    let repay_amount = coin::value(&repay_coin);
    let debt = borrow_receipt.borrow_amount;

    // 验证可清算
    let hf = health_factor(
        deposit_receipt.collateral_amount,
        debt,
        market.liquidation_threshold_bps,
    );
    assert!(hf.value_bps < BPS_BASE, ENotLiquidatable);

    // 限制最大还款金额
    let max_repay = debt * close_factor_bps / BPS_BASE;
    assert!(repay_amount <= max_repay, EInvalidAmount);

    // 计算没收的抵押品
    let seized = repay_amount * (BPS_BASE + market.liquidation_bonus_bps) / BPS_BASE;
    // ... 更新状态
}
```

## 总结

```
全额清算:
  一次性还清全部债务
  → 实现简单，清理彻底
  → 对借款人惩罚重
  → lending_market 使用此模式

部分清算:
  每次最多偿还 close_factor 比例的债务
  → 对借款人友好
  → 清算门槛低
  → 生产级协议使用此模式

关键参数:
  close_factor: 单次最大清算比例（通常 50%）
  liquidation_bonus: 清算奖励（通常 5-10%）
```
