# 7.23 原子交易安全模型

闪电贷的安全性来自区块链交易的原子性。本节分析 Sui Move 如何通过"热土豆"模式保证安全。

## 原子性保证

```
一笔 Sui 交易的所有操作:
  → 要么全部成功
  → 要么全部回滚

  不存在"部分成功"的中间状态

例:
  PTB:
    1. 闪电借入 1000 USDC
    2. 在 DEX swap 为 SUI
    3. 在借贷协议存入 SUI
    4. 借出 950 USDC
    5. 归还 1000 USDC + 手续费

  如果步骤 5 失败（金额不够）:
    → 整个交易回滚
    → 步骤 1-4 的效果全部撤销
    → 好像什么都没发生

这就是原子性
```

## 热土豆模式（Hot Potato）

```
热土豆:
  一个结构体只有 `store` 能力，没有 `drop`

  有 `drop` → 可以被丢弃
  没有 `drop` → 必须被显式处理

  如果交易结束时还有未处理的"热土豆":
  → 编译器/运行时报错
  → 交易失败
  → 所有变更回滚
```

### FlashLoanReceipt 就是热土豆

```move
// code/flash_loan/sources/flash_loan.move

public struct FlashLoanReceipt<phantom T> has store {
    loan_amount: u64,
    fee_amount: u64,
    pool_id: ID,
}
```

```
注意: 只有 `store`，没有 `drop`，没有 `key`

这意味着:
  → 不能丢弃（没有 drop）
  → 不能作为顶层对象（没有 key）
  → 只能被存入其他对象或被函数消耗

生命周期:
  borrow() → 创建 FlashLoanReceipt
  repay()  → 消耗 FlashLoanReceipt（解构）

  如果用户忘记调用 repay():
  → Receipt 无法被丢弃
  → 交易无法结束
  → 自动回滚
```

## 与 Ethereum 的对比

```
Ethereum 的闪电贷安全:
  使用回调函数:
  function flashLoan(amount) {
    transfer(amount to user);
    user.onFlashLoanReceived(amount);  // ← 用户必须在这里归还
    assert(balance >= amount + fee);
  }

  问题:
  → 依赖回调模式
  → 重入风险
  → 合约必须实现回调接口

Sui Move 的闪电贷安全:
  使用热土豆:
  borrow() → (Coin, Receipt)
  // 用户在这里操作 Coin
  repay(Receipt, Coin) → 消耗 Receipt

  优势:
  → 不需要回调
  → 没有重入风险
  → 类型系统保证 Receipt 被消耗
  → 更安全、更简洁
```

## PTB 中的闪电贷

```
Sui PTB 使得闪电贷操作非常自然:

PTB:
  1. flash_loan::borrow(pool, 10000)
     → 得到 (Coin, Receipt)

  2. DEX::swap(coin, ...)          // 用借来的钱套利
     → 得到更多钱

  3. flash_loan::repay(pool, Receipt, repayment_coin)
     → 消耗 Receipt，归还本金+手续费
     → 返回多余的钱（利润）

全部在一个 PTB 中完成:
  → 原子性保证
  → 如果任何步骤失败，全部回滚
  → 不需要编写复杂的合约逻辑
```

## 安全性分析

```
攻击向量 1: 借了不还
  → Receipt 未消耗 → 交易回滚 → 安全

攻击向量 2: 还的金额不够
  → repay() 中 assert!(value >= required) → 交易回滚 → 安全

攻击向量 3: 还到错误的池子
  → repay() 中 assert!(pool_id == pool.id) → 交易回滚 → 安全

攻击向量 4: 伪造 Receipt
  → Receipt 只能由 borrow() 创建（结构体字段私有）
  → 外部无法构造 → 安全

所有攻击都被 Move 的类型系统和运行时检查阻止
```

## 其他热土豆应用

```
热土豆模式不仅用于闪电贷:

1. Kiosk 模式:
   购买 NFT 时创建 Receipt
   确认购买后消耗 Receipt

2. 资产转移:
   创建 TransferReceipt
   目标确认后消耗

3. 任何需要"两步确认"的操作:
   第一步创建 Receipt
   第二步消耗 Receipt
   → 如果不完成第二步，整个操作回滚

这是 Sui Move 的核心安全模式之一
```

## 总结

```
原子安全模型:
  交易的原子性 + Move 的类型系统 = 完美安全

热土豆模式:
  struct 只有 store 能力
  → 不能丢弃
  → 必须显式消耗
  → 未消耗 → 交易回滚

对比 Ethereum 回调模式:
  → 更安全（无重入风险）
  → 更简洁（无需回调接口）
  → 类型系统保证（编译时检查）
```
