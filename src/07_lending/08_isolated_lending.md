# 7.8 隔离市场借贷：Euler / Silo 风格

## 多抵押品模型的系统性风险

Aave 和 Compound 的资金池模型有一个根本问题：**所有资产的风险被混在一起。**

```
Aave 市场：
  抵押品池: ETH + WBTC + LINK + UNI + AAVE + ...
  
  如果 LINK 暴跌 80%：
  - LINK 仓位被清算
  - 清算产生的卖压进一步压低 LINK
  - 如果清算不及时，产生坏账
  - 坏账由整个市场承担（所有存款人受损）
```

一个风险资产的崩溃可以影响所有存款人——即使他们从未接触过那个资产。

## 隔离市场：每个交易对独立

Euler 和 Silo 的解决方案：**每个交易对是独立的借贷市场，风险不跨市场传播。**

```
ETH/USDC 市场（独立）
  抵押品: ETH
  借出: USDC
  → ETH 暴跌只影响这个市场的参与者

LINK/USDC 市场（独立）
  抵押品: LINK
  借出: USDC
  → LINK 暴跌只影响这个市场

SOL/USDC 市场（独立）
  抵押品: SOL
  借出: USDC
  → SOL 暴跌只影响这个市场
```

## Move 实现

```move
module isolated_lending {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientLiquidity: u64 = 900;
    const EHealthFactorTooLow: u64 = 901;
    const EUnauthorized: u64 = 902;

    struct IsolatedPair<phantom Collateral, phantom Borrow> has key {
        id: UID,
        collateral_balance: Balance<Collateral>,
        borrow_balance: Balance<Borrow>,
        total_collateral: u64,
        total_borrows: u64,
        interest_model: KinkedModel,
        collateral_threshold_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_penalty_bps: u64,
        borrow_cap: u64,
        supply_cap: u64,
    }

    struct UserPosition<phantom Collateral, phantom Borrow> has key, store {
        id: UID,
        pair_id: ID,
        owner: address,
        collateral_amount: u64,
        borrow_amount: u64,
    }

    public fun create_pair<Collateral, Borrow>(
        interest_model: KinkedModel,
        collateral_threshold_bps: u64,
        liquidation_threshold_bps: u64,
        ctx: &mut TxContext,
    ): IsolatedPair<Collateral, Borrow> {
        IsolatedPair<Collateral, Borrow> {
            id: object::new(ctx),
            collateral_balance: balance::zero<Collateral>(),
            borrow_balance: balance::zero<Borrow>(),
            total_collateral: 0,
            total_borrows: 0,
            interest_model,
            collateral_threshold_bps,
            liquidation_threshold_bps,
            liquidation_penalty_bps: 800,
            borrow_cap: 0,
            supply_cap: 0,
        }
    }

    public fun supply<Collateral, Borrow>(
        pair: &mut IsolatedPair<Collateral, Borrow>,
        collateral: Coin<Collateral>,
        position: Option<&mut UserPosition<Collateral, Borrow>>,
        ctx: &mut TxContext,
    ): UserPosition<Collateral, Borrow> {
        let amount = coin::value(&collateral);
        if (option::is_some(&position)) {
            let pos = option::borrow_mut(&mut position);
            pos.collateral_amount = pos.collateral_amount + amount;
        };
        pair.total_collateral = pair.total_collateral + amount;
        balance::join(&mut pair.collateral_balance, coin::into_balance(collateral));
        if (option::is_none(&position)) {
            UserPosition<Collateral, Borrow> {
                id: object::new(ctx),
                pair_id: object::id(pair),
                owner: tx_context::sender(ctx),
                collateral_amount: amount,
                borrow_amount: 0,
            }
        } else { option::destroy_none(position) }
    }

    public fun borrow<Collateral, Borrow>(
        pair: &mut IsolatedPair<Collateral, Borrow>,
        position: &mut UserPosition<Collateral, Borrow>,
        amount: u64,
        collateral_price: u64,
        borrow_price: u64,
        ctx: &mut TxContext,
    ): Coin<Borrow> {
        assert!(pair.borrow_cap == 0 || pair.total_borrows + amount <= pair.borrow_cap, EInsufficientLiquidity);
        assert!(balance::value(&pair.borrow_balance) >= amount, EInsufficientLiquidity);

        let collateral_value = (position.collateral_amount as u128) * (collateral_price as u128) / 1000000;
        let borrow_value = ((position.borrow_amount + amount) as u128) * (borrow_price as u128) / 1000000;
        let max_borrow = collateral_value * (pair.collateral_threshold_bps as u128) / 10000;
        assert!(borrow_value <= max_borrow, EHealthFactorTooLow);

        position.borrow_amount = position.borrow_amount + amount;
        pair.total_borrows = pair.total_borrows + amount;
        coin::take(&mut pair.borrow_balance, amount, ctx)
    }

    public fun repay<Collateral, Borrow>(
        pair: &mut IsolatedPair<Collateral, Borrow>,
        position: &mut UserPosition<Collateral, Borrow>,
        repayment: Coin<Borrow>,
    ) {
        let amount = coin::value(&repayment);
        assert!(amount <= position.borrow_amount, EInsufficientLiquidity);
        position.borrow_amount = position.borrow_amount - amount;
        pair.total_borrows = pair.total_borrows - amount;
        balance::join(&mut pair.borrow_balance, coin::into_balance(repayment));
    }

    public fun withdraw<Collateral, Borrow>(
        pair: &mut IsolatedPair<Collateral, Borrow>,
        position: &mut UserPosition<Collateral, Borrow>,
        amount: u64,
        collateral_price: u64,
        borrow_price: u64,
        ctx: &mut TxContext,
    ): Coin<Collateral> {
        assert!(amount <= position.collateral_amount, EInsufficientLiquidity);
        position.collateral_amount = position.collateral_amount - amount;
        pair.total_collateral = pair.total_collateral - amount;

        if (position.borrow_amount > 0) {
            let remaining_collateral_value = (position.collateral_amount as u128) * (collateral_price as u128) / 1000000;
            let debt_value = (position.borrow_amount as u128) * (borrow_price as u128) / 1000000;
            let max_debt = remaining_collateral_value * (pair.liquidation_threshold_bps as u128) / 10000;
            assert!(debt_value <= max_debt, EHealthFactorTooLow);
        };

        coin::take(&mut pair.collateral_balance, amount, ctx)
    }
}
```

## 隔离市场 vs 资金池 对比

| 维度 | 资金池（Aave/Compound） | 隔离市场（Euler/Silo） |
|------|------------------------|----------------------|
| 风险传播 | 跨资产传播 | 每个交易对独立 |
| 资本效率 | 高（跨市场共享抵押品） | 较低（每个市场独立） |
| 新资产上架 | 需治理审核 | 任何人可创建市场 |
| 清算影响 | 影响所有存款人 | 只影响该市场的参与者 |
| 适合资产 | 主流资产（ETH, WBTC, USDC） | 任意资产（包括长尾资产） |
| 复杂度 | 中 | 高（需要管理多个市场） |

## 在 Sui 上的实现考量

Sui 的对象模型对隔离市场有天然支持：
- 每个交易对是一个独立的 `IsolatedPair` 共享对象
- 用户在每个交易对中有独立的 `UserPosition` 拥有对象
- 不同交易对的交易可以并行执行，不竞争共享对象

Sui 上暂无成熟的隔离借贷协议，但 Navi 的 e-Mode（高效模式）是一种折中方案——在特定资产组内使用更高的 LTV，类似于局部的隔离市场。
