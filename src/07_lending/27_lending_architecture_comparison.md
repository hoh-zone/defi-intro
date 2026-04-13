# 7.27 两种模型的 Move 架构实现

本节对比 Cross Collateral 和 Isolated Market 的 Move 架构设计。

## 架构对比

```
Isolated (lending_market):
┌───────────────┐ ┌───────────────┐
│Market<SUI,USDC>│ │Market<ETH,USDC>│
│独立 Receipt   │ │独立 Receipt   │
│独立参数       │ │独立参数       │
└───────────────┘ └───────────────┘

Cross (Navi style):
┌─────────────────────────────┐
│     Account (per user)      │
│  deposits: SUI, ETH, ...    │
│  borrows: USDC, ...         │
│  统一 HF 计算               │
└─────────────────────────────┘
```

## Isolated 代码结构

```move
// 每个市场独立，泛型参数隔离
public struct Market<phantom C, phantom B> has key {
    id: UID,
    collateral_vault: Balance<C>,
    borrow_vault: Balance<B>,
    collateral_factor_bps: u64,
    // ...
}

// 简单的双资产 HF
public fun health_factor(
    collateral: u64, debt: u64, factor_bps: u64
): HealthFactor {
    HealthFactor { value_bps: collateral * factor_bps / debt }
}
```

## Cross Collateral 代码结构

```move
// 全局风险引擎
public struct RiskEngine has key {
    id: UID,
    asset_configs: Bag,  // TypeName → AssetConfig
}

// 用户综合账户
public struct Account has key {
    id: UID,
    deposits: Bag,
    borrows: Bag,
}

// 聚合 HF: 遍历所有存款和借款
public fun aggregate_health_factor(
    account: &Account,
    risk_engine: &RiskEngine,
    oracle: &PriceOracle,
): u64 {
    // 遍历 deposits: Σ(amount × price × threshold)
    // 遍历 borrows: Σ(amount × price)
    // HF = 总抵押 / 总债务
}
```

## 决策框架

```
选 Isolated:
  → 新资产上线
  → 高波动资产
  → 小团队 / 简单协议

选 Cross Collateral:
  → 主流资产
  → 大用户量
  → 资本效率优先

混合: 主流用 Cross，长尾用 Isolated
```

## Sui 并行考量

```
Isolated:
  不同 Market 是不同 Shared Object → 天然并行

Cross:
  不同用户的 Account 是不同 Shared Object → 用户间并行
  但同一用户的操作需要串行（涉及同一 Account）
```

## 总结

```
Isolated: 泛型 Market<C,B>，简单 Receipt，独立 HF
Cross: Account + Bag，聚合 HF，统一管理

选择取决于资产类型、用户规模和团队资源
```
