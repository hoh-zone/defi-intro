# 7.24 Move 实现 Flash Loan

本节逐行分析 flash_loan 代码包的实现。

## FlashPool 结构体

```move
public struct FlashPool<phantom T> has key {
    id: UID,
    balance: Balance<T>,           // 可借出的流动性
    fee_bps: u64,                  // 手续费（基点）
    total_loans: u64,              // 总闪电贷次数
    accumulated_fees: Balance<T>,  // 累积的手续费收入
}
```

```
字段说明:
  balance: LP 存入的流动性
  fee_bps: 手续费率（如 30 = 0.3%）
  total_loans: 统计用
  accumulated_fees: 手续费收入（管理员可提取）

注意:
  → has key: 是 Shared Object
  → 任何人都可以调用 borrow
  → 不需要权限控制（安全由热土豆保证）
```

## FlashLoanReceipt 热土豆

```move
public struct FlashLoanReceipt<phantom T> has store {
    loan_amount: u64,
    fee_amount: u64,
    pool_id: ID,
}
```

```
只有 store 能力:
  → 没有 drop: 不能被丢弃
  → 没有 key: 不是独立对象
  → 没有 copy: 不能复制

这意味着:
  → 必须被传递给 repay() 消耗
  → 不能被忽略、丢弃、或复制
  → 交易结束前必须处理
```

## borrow 函数

```move
public fun borrow<T>(
    pool: &mut FlashPool<T>,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, FlashLoanReceipt<T>) {
    assert!(amount > 0, EZeroAmount);
    assert!(balance::value(&pool.balance) >= amount, EInsufficientLiquidity);

    let fee_amount = fee_amount(pool, amount);
    let coin = coin::take(&mut pool.balance, amount, ctx);

    let receipt = FlashLoanReceipt<T> {
        loan_amount: amount,
        fee_amount,
        pool_id: object::id(pool),
    };

    (coin, receipt)
}
```

```
执行流程:
  1. 验证金额 > 0
  2. 验证池子有足够流动性
  3. 计算手续费
  4. 从池子取出代币
  5. 创建热土豆 Receipt
  6. 返回 (Coin, Receipt)

注意:
  → 代币被实际取出（不是记账）
  → Receipt 记录了借款金额和手续费
  → pool_id 确保只能归还原池子
```

## repay 函数

```move
public fun repay<T>(
    pool: &mut FlashPool<T>,
    receipt: FlashLoanReceipt<T>,
    repayment: Coin<T>,
    ctx: &mut TxContext,
): Coin<T> {
    let FlashLoanReceipt { loan_amount, fee_amount, pool_id } = receipt;
    assert!(pool_id == object::id(pool), EWrongPool);

    let required = loan_amount + fee_amount;
    let repayment_value = coin::value(&repayment);
    assert!(repayment_value >= required, ERepaymentTooLow);

    let mut repayment_balance = coin::into_balance(repayment);
    let principal_balance = balance::split(&mut repayment_balance, loan_amount);
    balance::join(&mut pool.balance, principal_balance);

    let fee_balance = balance::split(&mut repayment_balance, fee_amount);
    balance::join(&mut pool.accumulated_fees, fee_balance);

    pool.total_loans = pool.total_loans + 1;

    coin::from_balance(repayment_balance, ctx)
}
```

```
还款流程:
  1. 解构 Receipt（消耗热土豆）
  2. 验证归还到正确的池子
  3. 计算需要的还款（本金 + 手续费）
  4. 验证还款金额足够
  5. 分离本金和手续费
  6. 本金回到 pool.balance
  7. 手续费进入 accumulated_fees
  8. 更新统计
  9. 返回多余的钱（如果有）

关键:
  → Receipt 在解构时被消耗（不再是热土豆）
  → 如果还款不够，assert 失败 → 交易回滚
  → 多还的钱会返还给调用者
```

## 手续费计算

```move
public fun fee_amount<T>(pool: &FlashPool<T>, amount: u64): u64 {
    amount * pool.fee_bps / 10000
}
```

```
示例:
  fee_bps = 30 (0.3%)
  amount = 10000 USDC

  fee = 10000 × 30 / 10000 = 30 USDC

  归还: 10000 + 30 = 10030 USDC
```

## 流动性管理

```move
// 存入流动性（任何人）
public fun deposit<T>(
    pool: &mut FlashPool<T>,
    coin: Coin<T>,
) {
    balance::join(&mut pool.balance, coin::into_balance(coin));
}

// 提取流动性（仅管理员）
public fun withdraw<T>(
    cap: &AdminCap<T>,
    pool: &mut FlashPool<T>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(object::id(pool) == cap.pool_id, EWrongPool);
    assert!(amount > 0, EZeroAmount);
    assert!(balance::value(&pool.balance) >= amount, EInsufficientLiquidity);
    coin::take(&mut pool.balance, amount, ctx)
}
```

```
流动性提供:
  → deposit: 任何人都可以存入
  → withdraw: 只有管理员可以提取
  → 简化模型（生产级用 LP Token）

手续费提取:
  withdraw_fees: 管理员提取累积的手续费
```

## 完整使用示例

```
PTB: 闪电贷套利

步骤 1: borrow
  flash_loan::borrow(pool, 10000)
  → Coin<USDC>: 10000
  → Receipt: { loan: 10000, fee: 30, pool_id: ... }

步骤 2: DEX swap
  cetus::swap(coin, SUI/USDC pool)
  → Coin<SUI>: 约 5000（假设汇率好）

步骤 3: 另一个 DEX swap
  deepbook::swap(coin, SUI/USDC)
  → Coin<USDC>: 10050（有套利利润）

步骤 4: repay
  flash_loan::repay(pool, receipt, 10050 USDC)
  → 需要 10030，实际还 10050
  → 多余 20 USDC 返回 → 利润！

如果步骤 2 或 3 失败:
  → 整个 PTB 回滚
  → Receipt 未被消耗 → 交易失败
  → 资金安全
```

## 测试覆盖

```
flash_loan 的 9 个测试:
  1. 初始化池子
  2. 存入流动性
  3. 闪电借入并归还
  4. 手续费计算验证
  5. 归还金额不足应失败
  6. 管理员提取手续费
  7. 多次连续闪电贷
  8. 手续费率过高应失败
  9. 借出超过池子余额应失败

关键测试 - 归还不足:
  borrow(1000), fee=3
  repay with 1000 (need 1003)
  → assert fails → test expects failure ✅
```

## 总结

```
flash_loan 实现的核心:
  FlashPool: Shared Object，存储流动性
  FlashLoanReceipt: 热土豆，强制归还
  borrow: 取出代币 + 创建 Receipt
  repay: 归还代币 + 消耗 Receipt + 收取手续费

安全保障:
  热土豆模式 → 必须归还
  pool_id 检查 → 归还到正确的池子
  金额检查 → 归还足够的金额
  原子性 → 任何失败都回滚
```
