# 7.5 存款凭证设计（Share Token）

存款凭证（Share Token）是借贷协议的基础。它代表存款人在池子中的份额，随利息累积而增值。

## 为什么需要 Share Token

```
不用 Share Token:
  Alice 存入 1000 SUI
  Bob 存入 1000 SUI
  池中有 2000 SUI

  一个月后，利息 100 SUI
  池中有 2100 SUI
  Alice 和 Bob 各应得多少?

  → 需要知道每个人什么时候存入的
  → 需要逐笔计算利息
  → 复杂度 O(交易次数)

用 Share Token:
  Alice 存入时获得 1000 shares
  Bob 存入时获得 952.38 shares（因为池子已经增值）
  总 shares = 1952.38

  一个月后，池中有 2100 SUI
  每份 share 价值 = 2100 / 1952.38 = 1.0756 SUI

  Alice: 1000 × 1.0756 = 1075.6 SUI
  Bob: 952.38 × 1.0756 = 1024.4 SUI

  → 利息自动按份额分配
  → 不需要逐笔追踪
  → 复杂度 O(1)
```

## 份额计算公式

```
汇率: exchange_rate = total_assets / total_shares

存款时:
  new_shares = deposit_amount / exchange_rate
  或者: new_shares = deposit_amount × total_shares / total_assets

取款时:
  withdraw_amount = shares × exchange_rate
  或者: withdraw_amount = shares × total_assets / total_shares

首个存款人:
  total_shares = 0, total_assets = 0
  → exchange_rate 无定义
  → 特殊处理: new_shares = deposit_amount（1:1）
```

## 数值示例

### 初始状态

```
Pool: 0 SUI, 0 shares
```

### Alice 存入 1000 SUI

```
第一个存款人 → 1:1
shares = 1000
Pool: 1000 SUI, 1000 shares
exchange_rate = 1000 / 1000 = 1.0
```

### 利息累积

```
借款人支付利息，池子增值
假设利息 = 50 SUI
Pool: 1050 SUI, 1000 shares
exchange_rate = 1050 / 1000 = 1.05

Alice 的份额价值: 1000 × 1.05 = 1050 SUI ✅
```

### Bob 存入 1000 SUI

```
exchange_rate = 1.05
shares = 1000 / 1.05 = 952.38
Pool: 2050 SUI, 1952.38 shares
exchange_rate = 2050 / 1952.38 = 1.05（不变）
```

### 更多利息累积

```
更多利息 = 100 SUI
Pool: 2150 SUI, 1952.38 shares
exchange_rate = 2150 / 1952.38 = 1.1008

Alice: 1000 × 1.1008 = 1100.8 SUI（存入 1000，收益 100.8）
Bob: 952.38 × 1.1008 = 1048.2 SUI（存入 1000，收益 48.2）
```

## Share 膨胀攻击与防御

```
攻击场景:
  1. 攻击者先存入 1 wei，获得 1 share
  2. 直接转入大量代币到池子（不是通过 deposit）
  3. 池子突然有 1000000 代币 + 1 share
  4. exchange_rate = 1000000

  后续存款人存入 1000 代币:
  shares = 1000 × 1 / 1000000 ≈ 0（四舍五入为 0）

  攻击者现在拥有 100% 的份额
  可以取走所有人的存款

防御措施:
  → 在 deposit 时验证 shares > 0
  → 使用最小份额数量（MINIMUM_SHARES）
  → 首个存款人存入时销毁 MINIMUM_SHARES（如 1000）

sui_savings 的防御:
  assert!(shares > 0, EInvalidAmount);
  → 确保存款获得的 shares 不为零
```

## SavingsReceipt 作为 Share Token

```move
// src/07_lending/code/sui_savings/sources/savings.move

public struct SavingsReceipt<phantom T> has key, store {
    id: UID,
    pool_id: ID,
    shares: u64,       // ← 持有的份额
}
```

```
Receipt 的特性:
  → has key: 是独立对象
  → has store: 可以被其他对象包含
  → 记录 pool_id: 确保只能用于对应的池子
  → 记录 shares: 用户的份额

取款时:
  principal_value = shares × balance / total_shares
  → 按当前汇率换回代币
```

## Share Token 的扩展设计

```
生产级 Share Token（如 Compound 的 cToken）:
  → ERC-20 / Coin 标准（可转让、可交易）
  → 持续增值（不需要 claim，价值体现在汇率中）
  → 可用作其他协议的抵押品

简化版（我们的 SavingsReceipt）:
  → 不可转让的 Receipt 对象
  → 需要主动取回才能变现
  → 足够说明核心概念

区别:
  cToken: 可以在 DEX 上交易
  Receipt: 只能在原协议中取回
  → 功能不同，但数学原理相同
```

## 总结

```
Share Token 的核心思想:
  用份额（shares）代替固定金额追踪存款
  利息自动反映在 exchange_rate 的增长中

关键公式:
  存款: shares = amount × total_shares / total_assets
  取款: amount = shares × total_assets / total_shares

防御措施:
  确保 shares > 0（防膨胀攻击）
```
