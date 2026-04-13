# 7.25 Cross Collateral 模型

Cross Collateral（交叉抵押）模型允许用户在一个账户中使用多种资产作为抵押品借款。

## 核心概念

```
Cross Collateral:
  一个账户，多种抵押品，统一计算 HF

  Alice 的账户:
    存入: 10 ETH ($30000) + 5000 SUI ($10000)
    借出: 25000 USDC

  总加权抵押品:
    = 30000 × 82% (ETH threshold) + 10000 × 75% (SUI threshold)
    = 24600 + 7500 = 32100

  HF = 32100 / 25000 = 1.284 → 安全
```

## Move 架构设计

```move
public struct Account has key {
    id: UID,
    deposits: Bag,  // TypeName → DepositInfo
    borrows: Bag,   // TypeName → BorrowInfo
}

public struct DepositInfo has store {
    amount: u64,
    share_amount: u64,
}

public struct BorrowInfo has store {
    amount: u64,
    debt_shares: u64,
}
```

```
Account 是综合对象:
  → deposits: 所有存入的资产（Bag 存储）
  → borrows: 所有借出的资产
  → TypeName 作为 key 区分不同资产
```

## 聚合 Health Factor

```
总加权抵押品 = Σ (collateral_i × price_i × threshold_i)
总债务 = Σ (debt_j × price_j)

aggregate_HF = 总加权抵押品 / 总债务

实现:
  1. 遍历 Account.deposits，查询预言机价格 × threshold
  2. 遍历 Account.borrows，查询预言机价格
  3. HF = 总抵押品 / 总债务
```

## Navi Protocol（Sui 代表）

```
Navi 是 Sui 上 Cross Collateral 借贷的代表:

特点:
  → 多资产存款池
  → 统一账户管理
  → 自动杠杆功能
  → Sui 原生设计

资产: SUI, USDC, USDT, WETH, CETUS 等
  → 每种资产有独立 risk 参数
  → 统一计算聚合 HF
```

## 优劣分析

```
优势:
  ✅ 资本效率高（多资产组合抵押）
  ✅ 用户体验好（一个账户管理）
  ✅ 风险分散（资产间可能不相关）

风险:
  ⚠️ 关联性风险（所有抵押品同时下跌）
  ⚠️ 复杂度高（多资产 HF 计算）
  ⚠️ 预言机依赖（需要多种价格）
  ⚠️ 级联清算（一个资产暴跌拖垮整个账户）
```

## 总结

```
Cross Collateral: 资本效率最高，用户体验最好，复杂度最高
适用: 主流资产市场，用户量大
Sui 代表: Navi Protocol
```
