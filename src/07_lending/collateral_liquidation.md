# 6.5 抵押、健康因子与清算机制

## 为什么需要抵押

在传统金融中，信用基于身份和信用评分。在 DeFi 中，没有身份系统，协议只能要求用户**超额抵押**——存入价值高于借款的抵押品。

## 健康因子（Health Factor）

健康因子是衡量仓位安全性的核心指标：

$$HF = \frac{\sum (\text{抵押品价值}_i \times \text{清算阈值}_i)}{\sum \text{借款价值}_j}$$

- HF > 1.0：安全，不会被清算
- HF = 1.0：临界状态
- HF < 1.0：可被清算

```move
public fun calculate_health_factor(
    market: &Market,
    deposit_positions: &vector<&DepositPosition>,
    borrow_positions: &vector<&BorrowPosition>,
    price_feed: &PriceFeed,
): u64 {
    let mut total_collateral = 0u128;
    let mut i = 0;
    while (i < vector::length(deposit_positions)) {
        let pos = vector::borrow(deposit_positions, i);
        if (pos.use_as_collateral) {
            let reserve = vector::borrow(&market.reserves, (pos.reserve_index as u64));
            let price = get_price(price_feed, pos.reserve_index);
            let value = (pos.amount as u128) * (price as u128) / 1000000;
            let adjusted = value * (reserve.liquidation_threshold_bps as u128) / 10000;
            total_collateral = total_collateral + adjusted;
        };
        i = i + 1;
    };

    let mut total_debt = 0u128;
    let mut j = 0;
    while (j < vector::length(borrow_positions)) {
        let pos = vector::borrow(borrow_positions, j);
        let price = get_price(price_feed, pos.reserve_index);
        let value = (pos.amount as u128) * (price as u128) / 1000000;
        total_debt = total_debt + value;
        j = j + 1;
    };

    if (total_debt == 0) { return 0xFFFFFFFFFFFFFFFF };
    let hf = total_collateral * 10000 / total_debt;
    (hf as u64)
}
```

## 清算机制

当 HF < 1.0 时，任何人都可以触发清算。清算者替借款人偿还部分债务，获得等值（加罚金）的抵押品。

### 清算流程

```
1. 检查借款人 HF < 1.0
2. 清算者提供还款代币
3. 协议计算可清算金额（通常为债务的 50%）
4. 从借款人抵押品中扣除对应价值（+清算罚金）
5. 清算者获得抵押品
6. 重新计算 HF
```

```move
public fun liquidate(
    market: &mut Market,
    borrower_deposits: &mut vector<&mut DepositPosition>,
    borrower_borrows: &mut vector<&mut BorrowPosition>,
    repayment_coin: Coin<phantom T>,
    price_feed: &PriceFeed,
    ctx: &mut TxContext,
): Coin<phantom CollateralT> {
    let hf = calculate_health_factor(market, borrower_deposits, borrower_borrows, price_feed);
    assert!(hf < 10000, EHealthFactorTooLow);

    let repay_amount = coin::value(&repayment_coin);
    let max_repay = get_max_liquidation_amount(borrower_borrows);
    assert!(repay_amount <= max_repay, EInvalidAmount);

    let collateral_reserve_idx = find_collateral_reserve(borrower_deposits);
    let collateral_reserve = vector::borrow(&market.reserves, (collateral_reserve_idx as u64));
    let debt_price = get_price(price_feed, get_debt_reserve_index(borrower_borrows));
    let collateral_price = get_price(price_feed, collateral_reserve_idx);

    let penalty = collateral_reserve.liquidation_penalty_bps;
    let collateral_value = (repay_amount as u128)
        * (debt_price as u128)
        * (10000 + penalty as u128)
        / (collateral_price as u128)
        / 10000;
    let collateral_to_seize = (collateral_value as u64);

    let debt_pos = vector::borrow_mut(borrower_borrows, 0);
    debt_pos.amount = debt_pos.amount - repay_amount;

    let collateral_pos = vector::borrow_mut(borrower_deposits, 0);
    collateral_pos.amount = collateral_pos.amount - collateral_to_seize;

    let seized = coin::take(
        &mut get_reserve_balance_mut(market, collateral_reserve_idx),
        collateral_to_seize,
        ctx,
    );
    seized
}
```

### 为什么是部分清算

大多数协议限制单次清算金额为债务的 50%。原因：
1. 避免一次性清算导致借款人损失过大
2. 给借款人时间补充抵押品
3. 分散清算对市场的影响

### 清算者的经济激励

清算者只有在有利润时才会清算。利润来自清算罚金（liquidation penalty，通常 5-10%）。

如果清算罚金太低 → 无人清算 → 坏账累积
如果清算罚金太高 → 借款人损失过大 → 用户体验差

## Sui 借贷协议对比

| 维度 | Suilend | Scallop | Navi |
|------|---------|---------|------|
| 利率模型 | 拐点模型 | 拐点模型 | 拐点模型 |
| 清算机制 | 部分清算 | 部分清算 | 部分清算 |
| 闪电贷 | 支持 | 支持 | 支持 |
| 孤立风险 | 隔离市场 | 隔离市场 | 跨市场 |
| 特点 |利率市场灵活 | Sui原生优先 | 生态整合度高 |

## 从 Sui Savings 到生产级借贷的五个升级层

1. **利率模型**：固定利率 → 动态利率（拐点模型）
2. **借款功能**：只有存款 → 存款 + 借款
3. **抵押管理**：无 → 抵押品启用/禁用/健康因子
4. **清算机制**：无 → 自动清算 + 清算激励
5. **预言机集成**：无 → 实时价格喂价 + 安全校验
