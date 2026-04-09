# 6.2 常规借贷市场设计与实现

## 从储蓄到借贷

Sui Savings 只有存款人，没有借款人。利息来自管理员注入，不是来自借款人支付。

借贷市场的核心变化：**引入借款人。** 存款人的利息来自借款人支付的利率。协议不再是"管理员发利息"，而是"借款人付利息给存款人"。

## 对象设计

```move
module lending {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientLiquidity: u64 = 100;
    const EInvalidAmount: u64 = 101;
    const EHealthFactorTooLow: u64 = 102;
    const ENotCollateral: u64 = 103;
    const EPoolPaused: u64 = 104;
    const EUnauthorized: u64 = 105;

    struct Market has key {
        id: UID,
        reserves: vector<Reserve>,
        paused: bool,
    }

    struct Reserve has store {
        coin_type: u8,
        total_deposits: u64,
        total_borrows: u64,
        base_rate_bps: u64,
        slope1_bps: u64,
        slope2_bps: u64,
        optimal_utilization_bps: u64,
        reserve_factor_bps: u64,
        collateral_threshold_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_penalty_bps: u64,
    }

    struct DepositPosition has key, store {
        id: UID,
        market_id: ID,
        reserve_index: u8,
        amount: u64,
        use_as_collateral: bool,
        index_at_deposit: u128,
    }

    struct BorrowPosition has key, store {
        id: UID,
        market_id: ID,
        reserve_index: u8,
        amount: u64,
        index_at_borrow: u128,
    }

    struct LiquidationCap has key, store {
        id: UID,
        market_id: ID,
    }
}
```

关键设计：
- `Market` — 一个共享对象，包含所有储备池
- `Reserve` — 每种代币的储备状态（存款总额、借款总额、利率参数）
- `DepositPosition` — 用户的存款凭证，标记是否用作抵押
- `BorrowPosition` — 用户的借款凭证

## 存入

```move
public fun supply(
    market: &mut Market,
    reserve_idx: u8,
    coin: Coin<phantom T>,
    ctx: &mut TxContext,
): DepositPosition {
    assert!(!market.paused, EPoolPaused);
    let reserve = vector::borrow_mut(&mut market.reserves, (reserve_idx as u64));
    let amount = coin::value(&coin);
    assert!(amount > 0, EInvalidAmount);

    let deposit_index = calculate_deposit_index(reserve);
    reserve.total_deposits = reserve.total_deposits + amount;

    DepositPosition {
        id: object::new(ctx),
        market_id: object::id(market),
        reserve_index: reserve_idx,
        amount,
        use_as_collateral: false,
        index_at_deposit: deposit_index,
    }
}
```

## 借款

```move
public fun borrow(
    market: &mut Market,
    reserve_idx: u8,
    amount: u64,
    collateral_positions: &vector<&DepositPosition>,
    ctx: &mut TxContext,
): BorrowPosition {
    assert!(!market.paused, EPoolPaused);

    let reserve = vector::borrow_mut(&mut market.reserves, (reserve_idx as u64));
    assert!(reserve.total_deposits - reserve.total_borrows >= amount, EInsufficientLiquidity);

    let health_factor = calculate_health_factor(market, collateral_positions, amount, reserve_idx);
    assert!(health_factor >= 10000, EHealthFactorTooLow);

    reserve.total_borrows = reserve.total_borrows + amount;
    let borrow_index = calculate_borrow_index(reserve);

    BorrowPosition {
        id: object::new(ctx),
        market_id: object::id(market),
        reserve_index: reserve_idx,
        amount,
        index_at_borrow: borrow_index,
    }
}
```

借款前检查健康因子。健康因子 < 1.0（10000 bps）意味着抵押品价值不足以覆盖借款。

## 偿还

```move
public fun repay(
    market: &mut Market,
    borrow_position: BorrowPosition,
    coin: Coin<phantom T>,
    ctx: &mut TxContext,
) {
    assert!(object::id(market) == borrow_position.market_id, EInvalidAmount);
    let reserve = vector::borrow_mut(&mut market.reserves, (borrow_position.reserve_index as u64));
    let repay_amount = coin::value(&coin);
    assert!(repay_amount >= borrow_position.amount, EInvalidAmount);

    reserve.total_borrows = reserve.total_borrows - borrow_position.amount;
    object::delete(borrow_position);
}
```

偿还时销毁借款凭证。简洁且安全——凭证不存在了，债务就不存在。

## 启用/禁用抵押

```move
public fun enable_collateral(position: &mut DepositPosition) {
    position.use_as_collateral = true;
}

public fun disable_collateral(
    position: &mut DepositPosition,
    market: &Market,
    borrow_positions: &vector<&BorrowPosition>,
) {
    position.use_as_collateral = false;
    let health = calculate_health_factor_existing(market, position, borrow_positions);
    assert!(health >= 10000, EHealthFactorTooLow);
}
```

禁用抵押前检查健康因子——防止用户在已有借款的情况下移除抵押品。

## 健康因子计算

```move
public fun calculate_health_factor(
    market: &Market,
    collateral_positions: &vector<&DepositPosition>,
    new_borrow_amount: u64,
    new_borrow_reserve: u8,
): u64 {
    let mut total_collateral_value = 0u128;
    let mut i = 0;
    while (i < vector::length(collateral_positions)) {
        let pos = vector::borrow(collateral_positions, i);
        if (pos.use_as_collateral) {
            let reserve = vector::borrow(&market.reserves, (pos.reserve_index as u64));
            let value = (pos.amount as u128) * (reserve.collateral_threshold_bps as u128) / 10000;
            total_collateral_value = total_collateral_value + value;
        };
        i = i + 1;
    };
    let borrow_reserve = vector::borrow(&market.reserves, (new_borrow_reserve as u64));
    let borrow_value = (new_borrow_amount as u128) * 10000 / 10000;
    if (borrow_value == 0) { return 0xFFFFFFFFFFFFFFFF };
    let hf = total_collateral_value * 10000 / borrow_value;
    (hf as u64)
}
```

健康因子 = 总抵押品价值（含折扣）/ 总借款价值
- HF > 1.0：安全
- HF < 1.0：可被清算
- HF 越高，越安全
