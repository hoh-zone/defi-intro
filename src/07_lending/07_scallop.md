# 7.7 Scallop：Sui 原生零利率借贷

## Scallop 的定位

Scallop 是另一个 Sui 原生借贷协议。与 Navi 不同，Scallop 的核心差异在于**零利率市场**和**保险库（Vault）**机制。

## 核心创新

### 1. 零利率市场（0% Interest Market）

Scallop 支持创建零利率的借贷市场。这看起来反直觉——如果借款不付利息，谁愿意存款？

答案：**零利率市场用于稳定币对稳定币的借贷，目的是提供流动性而非赚取利息。**

```
场景：USDC/USDT 零利率市场
- 用户存入 USDC（不赚利息，但获得流动性）
- 其他用户借出 USDC（不付利息，只需要抵押）
- 用途：MEV 搜索者的短期资金周转、跨协议套利
```

### 2. 保险库（Vault）

Scallop 引入了 Vault 机制，将存款人的资金分层管理：

```move
module scallop {
    public struct Vault<phantom T> has key {
        id: UID,
        total_deposits: u64,
        available: u64,
        lent_out: u64,
        fee_bps: u64,
        strategy_id: ID,
    }

    public struct VaultReceipt<phantom T> has key, store {
        id: UID,
        vault_id: ID,
        shares: u64,
    }
}
```

Vault 的资金管理策略：
- `available`：随时可以取出的资金
- `lent_out`：借给借款人的资金
- 保持一定比例的 `available` 确保存款人流动性

### 3. 预言机安全优先

Scallop 在预言机集成上特别保守：
- 使用多源价格
- 严格的时间校验
- 偏差校验阈值设得更紧

## Scallop 对象设计

```move
module scallop_lending {
    public struct LendingMarket has key {
        id: UID,
        reserves: vector<Reserve>,
        zero_rate_markets: vector<u8>,
        vaults: vector<ID>,
        paused: bool,
    }

    public struct Reserve has store {
        coin_type: u8,
        total_deposits: u64,
        total_borrows: u64,
        is_zero_rate: bool,
        interest_model: Option<KinkedModel>,
        risk_config: ReserveRiskConfig,
    }

    public struct UserAccount has key, store {
        id: UID,
        market_id: ID,
        owner: address,
        deposit_positions: vector<DepositPosition>,
        borrow_positions: vector<BorrowPosition>,
    }

    public struct DepositPosition has store {
        reserve_index: u8,
        amount: u64,
        is_collateral: bool,
        vault_shares: u64,
    }

    public struct BorrowPosition has store {
        reserve_index: u8,
        amount: u64,
        is_zero_rate: bool,
    }
}
```

## Scallop vs Navi 对比

| 维度 | Navi | Scallop |
|------|------|---------|
| 利率模型 | 拐点模型 | 拐点模型 + 零利率市场 |
| 资金管理 | 直接池子 | Vault 分层 |
| 自动杠杆 | 内置 | 需外部组合 |
| 零利率市场 | 无 | 有（稳定币对） |
| 预言机策略 | 标准 | 更保守 |
| 保险库 | 无 | 有 |
| Sui 原生 | 是 | 是 |

## 零利率市场的经济学

为什么有人愿意在零利率市场存款？

1. **LP 对冲**：在 DEX 做 USDC/USDT LP 的用户，可以在 Scallop 借出 USDC 或 USDT 来调整仓位
2. **套利资金周转**：MEV 搜索者需要短期借用稳定币执行套利
3. **跨协议组合**：其他协议可以将资金存入 Scallop 零利率市场作为流动性后端

零利率市场降低了特定场景的资金成本，但存款人没有利息收入——适合对"成本"敏感但对"收益"不敏感的用户。
