# 7.6 Navi Protocol：Sui 原生跨市场借贷

## Navi 的定位

Navi 是 Sui 上 TVL 最高的借贷协议之一。它的设计结合了 Aave 的资金池模型和 Sui 对象模型的特性。

## 核心机制

### 跨市场借贷

Navi 支持在一个市场中用一种资产做抵押，借出多种资产：

```
用户存入:
  - 1000 SUI 作为抵押
  - 500 USDC 作为抵押

用户借出:
  - 300 USDT
  - 200 ETH

所有仓位在同一个账户中管理
```

### Move 对象设计

```move
module navi {
    struct Market has key {
        id: UID,
        reserves: vector<Reserve>,
    }

    struct Reserve has store {
        coin_type: u8,
        total_deposits: u64,
        total_borrows: u64,
        kinked_model: KinkedModel,
        risk_config: ReserveRiskConfig,
    }

    struct ReserveRiskConfig has store {
        ltv_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_penalty_bps: u64,
        borrow_cap: u64,
        supply_cap: u64,
        base_borrow_index: u128,
    }

    struct AccountPosition has key, store {
        id: UID,
        market_id: ID,
        owner: address,
        deposits: vector<DepositEntry>,
        borrows: vector<BorrowEntry>,
    }

    struct DepositEntry has store {
        reserve_index: u8,
        amount: u64,
        use_as_collateral: bool,
        index_at_deposit: u128,
    }

    struct BorrowEntry has store {
        reserve_index: u8,
        amount: u64,
        index_at_borrow: u128,
    }
}
```

关键点：
- `AccountPosition` 是用户的拥有对象，包含所有存款和借款记录
- 每种资产有独立的风险参数（LTV、清算阈值等）
- 索引（index）用于追踪利息累积

## Navi 的特点

| 特点 | 说明 |
|------|------|
| 自动杠杆 | 用户可以在单笔交易中完成存入→借出→再存入的杠杆循环 |
| 跨保证金 | 所有仓位合并计算健康因子 |
| Sui 原生 | 充分利用对象模型，AccountPosition 是拥有对象 |
| 多资产市场 | 支持 SUI、USDC、USDT、ETH、CETUS 等多种资产 |
| 闪电贷 | 内置闪电贷功能 |

## 健康因子计算

```move
public fun calculate_health_factor(
    market: &Market,
    position: &AccountPosition,
    price_feed: &PriceFeed,
): u64 {
    let mut total_collateral = 0u128;
    let mut total_debt = 0u128;

    let mut i = 0;
    while (i < vector::length(&position.deposits)) {
        let deposit = vector::borrow(&position.deposits, i);
        if (deposit.use_as_collateral) {
            let reserve = vector::borrow(&market.reserves, (deposit.reserve_index as u64));
            let price = get_price(price_feed, deposit.reserve_index);
            let value = (deposit.amount as u128) * (price as u128) / 1000000;
            let adjusted = value * (reserve.risk_config.liquidation_threshold_bps as u128) / 10000;
            total_collateral = total_collateral + adjusted;
        };
        i = i + 1;
    };

    let mut j = 0;
    while (j < vector::length(&position.borrows)) {
        let borrow = vector::borrow(&position.borrows, j);
        let price = get_price(price_feed, borrow.reserve_index);
        let value = (borrow.amount as u128) * (price as u128) / 1000000;
        total_debt = total_debt + value;
        j = j + 1;
    };

    if (total_debt == 0) { return 0xFFFFFFFFFFFFFFFF };
    (total_collateral * 10000 / total_debt) as u64
}
```

## Navi vs Aave 设计对比

| 维度 | Aave V3 | Navi |
|------|---------|------|
| 部署链 | 多链（EVM 为主） | Sui 原生 |
| 账户模型 | 合约存储 mapping | Owned Object |
| 存款凭证 | aToken（ERC-20） | 内嵌在 AccountPosition |
| 债务凭证 | debtToken（ERC-20） | 内嵌在 AccountPosition |
| 清算 | 外部清算者 | 外部清算者 |
| 杠杆 | 需要外部合约 | 内置自动杠杆 |
