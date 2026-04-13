# 7.8 Debt Token 设计

借款需要记账——记录谁欠了多少钱。Debt Token 是借款的凭证，它的价值随时间增长（对你不利）。

## 借款如何记账

```
存款记账:
  你存入 1000 SUI → 获得 Share Token
  Share Token 价值增长 → 你赚了

借款记账:
  你借出 1000 USDC → 获得 Debt Token
  Debt Token 价值增长 → 你欠更多了

关键区别:
  Share Token: 利息帮你赚钱
  Debt Token: 利息让你欠更多
```

## Debt Token 的两种模式

### 模式 1: 固定金额 + 利息指数（lending_market 使用）

```move
// code/lending_market/sources/market.move

public struct BorrowReceipt<phantom C, phantom B> has key, store {
    id: UID,
    market_id: ID,
    borrow_amount: u64,     // 借款时的固定金额
}
```

```
简化模型:
  borrow_amount 记录借款时的金额
  利息通过全局 index 追踪
  实际债务 = borrow_amount × borrow_index / initial_index

优点: 简单，容易理解
缺点: 需要额外的 index 计算才能知道实际债务
```

### 模式 2: 递增 Debt Token（生产级）

```
实际债务:
  debt_token_value 初始 = 1.0
  随时间增长: debt_token_value = 1.0 × (1 + rate × dt)

  你借出 1000 USDC:
  获得 1000 debt_tokens

  一年后（利率 5%）:
  debt_token_value = 1.05
  你的债务 = 1000 × 1.05 = 1050 USDC

  不需要额外的 index 查询
  → debt_tokens × exchange_rate = 实际债务
```

## 两种记账对比

```
维度         │ Share Token (存款)    │ Debt Token (借款)
────────────┼──────────────────────┼─────────────────────
持有者       │ 存款人               │ 借款人
价值方向     │ 上涨（对你有利）     │ 上涨（对你不利）
利息来源     │ 借款人支付的利息     │ 自己支付的利息
可以转让?    │ 是（生产级）         │ 否（债务不可转让）
可以交易?    │ 可以（如 cToken）    │ 不可以

为什么 Debt Token 不能交易:
  → 如果 Alice 把债务转给 Bob
  → Bob 没有提供抵押品
  → 违反超额抵押原则

例外:
  某些协议支持"信用委托"
  → 但需要被委托人有足够的信用额度
```

## BorrowReceipt 在 lending_market 中的角色

```move
// 创建借款凭证
let borrow_receipt = BorrowReceipt<Collateral, Borrow> {
    id: object::new(ctx),
    market_id: object::id(market),
    borrow_amount: amount,     // 借款金额
};

// 清算时销毁
let BorrowReceipt { id, market_id: _, borrow_amount: _ } = borrow_receipt;
id.delete();
```

```
BorrowReceipt 的生命周期:
  borrow() → 创建 BorrowReceipt
  repay()  → 销毁 BorrowReceipt
  liquidate() → 销毁 BorrowReceipt（清算人代还）

Receipt 是债务的"凭证":
  → 只有持有 Receipt 才能被清算
  → 销毁 Receipt 表示债务已清偿
  → Receipt 的 borrow_amount 用于计算 HF 和清算
```

## 债务增长示例

```
Alice 借入 1000 USDC（利率 5%）

Day 0:   debt = 1000.00
Day 30:  debt = 1004.11
Day 60:  debt = 1008.27
Day 90:  debt = 1012.47
Day 180: debt = 1025.32
Day 365: debt = 1051.27

注意:
  → 债务持续增长（即使你不操作）
  → 如果利率上升（如利用率高），增长更快
  → 必须确保抵押品价值始终覆盖债务
```

## 多笔借款的管理

```
lending_market: 每次借款创建新的 BorrowReceipt
  borrow(500) → BorrowReceipt { amount: 500 }
  borrow(300) → BorrowReceipt { amount: 300 }

  → 两张 Receipt，分别追踪
  → 还款时需要指定哪张 Receipt
  → 清算时每张 Receipt 独立处理

生产级: 合并为单一债务
  → 所有借款合并为总债务
  → 单一的 debt index 追踪
  → 更高效，但更复杂
```

## 总结

```
Debt Token 核心概念:
  记录借款人的债务
  债务随时间增长（利息累积）
  借款人必须维持超额抵押

与 Share Token 对称:
  Share Token 价值增长 → 对持有者有利
  Debt Token 价值增长 → 对持有者不利
```
