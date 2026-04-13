# 9.2 CDP 完整实现：抵押、铸造、偿还、清算

## 对象设计

```move
module cdp;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    #[error]
    const ECollateralRatioTooLow: vector<u8> = b"Collateral Ratio Too Low";
    #[error]
    const EInvalidAmount: vector<u8> = b"Invalid Amount";
    #[error]
    const ENotOwner: vector<u8> = b"Not Owner";
    #[error]
    const EPositionNotLiquidatable: vector<u8> = b"Position Not Liquidatable";
    #[error]
    const EDebtCeiling: vector<u8> = b"Debt Ceiling";
    #[error]
    const ESystemPaused: vector<u8> = b"System Paused";

    public struct STABLE has copy, drop {}

    public struct CDPSystem has key {
        id: UID,
        treasury_cap: TreasuryCap<STABLE>,
        collateral_balance: Balance<SUI>,
        total_debt: u64,
        debt_ceiling: u64,
        collateral_ratio_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_penalty_bps: u64,
        stability_fee_bps: u64,
        paused: bool,
    }

    public struct CDPPosition has key, store {
        id: UID,
        system_id: ID,
        owner: address,
        collateral_amount: u64,
        debt_amount: u64,
        created_at: u64,
    }

    public struct GovernanceCap has key, store {
        id: UID,
        system_id: ID,
    }
```

三个核心对象：
- `CDPSystem` — 全局共享对象，管理所有抵押品和稳定币供给
- `CDPPosition` — 用户的 CDP 仓位（Owned Object）
- `GovernanceCap` — 治理权限凭证

## 初始化

```move
public fun init(
    ctx: &mut TxContext,
) {
    let (treasury_cap, coin_metadata) = coin::create_currency<STABLE>(
        b"USDs",
        6,
        b"USDs",
        b"Sui CDP Stablecoin",
        option::none(),
        ctx,
    );
    let system = CDPSystem {
        id: object::new(ctx),
        treasury_cap,
        collateral_balance: balance::zero<SUI>(),
        total_debt: 0,
        debt_ceiling: 100_000_000_000000,
        collateral_ratio_bps: 15000,
        liquidation_threshold_bps: 13000,
        liquidation_penalty_bps: 1000,
        stability_fee_bps: 200,
        paused: false,
    };
    let gov_cap = GovernanceCap {
        id: object::new(ctx),
        system_id: object::id(&system),
    };
    transfer::share_object(system);
    transfer::transfer(gov_cap, ctx.sender());
    coin::update_currency_metadata(coin_metadata, ctx);
}
```

参数说明：
- `collateral_ratio_bps: 15000` → 最低抵押率 150%（抵押 $1.5 才能借出 $1）
- `liquidation_threshold_bps: 13000` → 抵押率低于 130% 时可被清算
- `liquidation_penalty_bps: 1000` → 清算罚金 10%
- `stability_fee_bps: 200` → 年化稳定费 2%

## 开仓：存入抵押品 + 铸造稳定币

```move
public fun open_position(
    system: &mut CDPSystem,
    collateral: Coin<SUI>,
    mint_amount: u64,
    ctx: &mut TxContext,
): CDPPosition {
    assert!(!system.paused, ESystemPaused);
    assert!(mint_amount > 0, EInvalidAmount);
    let collateral_amount = coin::value(&collateral);
    let collateral_value = collateral_amount * get_sui_price();
    let max_debt = collateral_value * system.collateral_ratio_bps / 10000;
    assert!(mint_amount <= max_debt, ECollateralRatioTooLow);
    assert!(system.total_debt + mint_amount <= system.debt_ceiling, EDebtCeiling);

    balance::join(&mut system.collateral_balance, coin::into_balance(collateral));
    system.total_debt = system.total_debt + mint_amount;

    let stable_coin = coin::mint(&mut system.treasury_cap, mint_amount, ctx);
    transfer::transfer(stable_coin, ctx.sender());

    CDPPosition {
        id: object::new(ctx),
        system_id: object::id(system),
        owner: ctx.sender(),
        collateral_amount,
        debt_amount: mint_amount,
        created_at: sui::clock::timestamp_ms(sui::clock::create(ctx)),
    }
}
```

## 增加抵押品

```move
public fun add_collateral(
    system: &mut CDPSystem,
    position: &mut CDPPosition,
    collateral: Coin<SUI>,
) {
    assert!(object::id(system) == position.system_id, EInvalidAmount);
    let amount = coin::value(&collateral);
    balance::join(&mut system.collateral_balance, coin::into_balance(collateral));
    position.collateral_amount = position.collateral_amount + amount;
}
```

## 偿还稳定币 + 关闭仓位

```move
public fun repay_and_close(
    system: &mut CDPSystem,
    position: CDPPosition,
    repayment: Coin<STABLE>,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(object::id(system) == position.system_id, EInvalidAmount);
    let repay_amount = coin::value(&repayment);
    assert!(repay_amount >= position.debt_amount, EInvalidAmount);

    coin::burn(&mut system.treasury_cap, repayment);
    system.total_debt = system.total_debt - position.debt_amount;
    let collateral_return = coin::take(
        &mut system.collateral_balance,
        position.collateral_amount,
        ctx,
    );
    .delete()(position);
    collateral_return
}
```

## 清算

```move
public fun liquidate(
    system: &mut CDPSystem,
    position: CDPPosition,
    repayment: Coin<STABLE>,
    ctx: &mut TxContext,
): Coin<SUI> {
    let collateral_value = (position.collateral_amount as u128) * (get_sui_price() as u128) / 1000000;
    let debt_value = position.debt_amount as u128;
    let current_ratio = collateral_value * 10000 / debt_value;
    assert!(current_ratio < system.liquidation_threshold_bps as u128, EPositionNotLiquidatable);

    let repay_amount = coin::value(&repayment);
    assert!(repay_amount >= position.debt_amount, EInvalidAmount);

    coin::burn(&mut system.treasury_cap, repayment);
    system.total_debt = system.total_debt - position.debt_amount;

    let penalty = position.collateral_amount * system.liquidation_penalty_bps / 10000;
    let collateral_to_seize = position.debt_amount * 10000 / (get_sui_price() / 1000000) + penalty;
    let seize_amount = if (collateral_to_seize > position.collateral_amount) {
        position.collateral_amount
    } else {
        collateral_to_seize
    };

    .delete()(position);
    coin::take(&mut system.collateral_balance, seize_amount, ctx)
}
```

## 治理功能

```move
public fun update_parameters(
    _cap: &GovernanceCap,
    system: &mut CDPSystem,
    new_collateral_ratio_bps: u64,
    new_liquidation_threshold_bps: u64,
    new_debt_ceiling: u64,
    new_stability_fee_bps: u64,
) {
    assert!(new_collateral_ratio_bps > new_liquidation_threshold_bps, EInvalidAmount);
    system.collateral_ratio_bps = new_collateral_ratio_bps;
    system.liquidation_threshold_bps = new_liquidation_threshold_bps;
    system.debt_ceiling = new_debt_ceiling;
    system.stability_fee_bps = new_stability_fee_bps;
}

public fun emergency_pause(_cap: &GovernanceCap, system: &mut CDPSystem) {
    system.paused = true;
}
```

注意 `assert!(new_collateral_ratio_bps > new_liquidation_threshold_bps, ...)`——抵押率必须高于清算阈值，否则用户一开仓就被清算。

## 完整生命周期示例

```
1. 用户存入 1500 SUI（价格 $2/SUI，价值 $3000）
2. 抵押率 150%，最多借出 $2000
3. 用户借出 1500 USDs
4. 当前抵押率 = 3000/1500 = 200%，安全
5. SUI 跌到 $1.5/SUI
6. 抵押品价值 = 1500 * 1.5 = $2250
7. 当前抵押率 = 2250/1500 = 150%，刚好在安全线
8. SUI 继续跌到 $1.2/SUI
9. 抵押品价值 = 1500 * 1.2 = $1800
10. 当前抵押率 = 1800/1500 = 120% < 130%（清算阈值）
11. 清算者触发清算
12. 清算者偿还 1500 USDs，获得抵押品 + 10% 罚金
13. 清算者获得 ~1237 SUI（1500 * 1.1 / 1.2 ≈ 1375 SUI）
```
