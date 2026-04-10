# 13.2 Cetus 杠杆借贷实现

## Cetus 的杠杆产品

Cetus 除了 CLMM DEX 之外，还提供了借贷市场和杠杆功能。Cetus 的杠杆实现路径：

```
存入抵押品 → 借出代币 → 在 Cetus DEX 买入 → 再次存入 → 循环
```

## Cetus 借贷模块

```move
module cetus_lending {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientLiquidity: u64 = 800;
    const EHealthFactorTooLow: u64 = 801;
    const EPoolPaused: u64 = 802;

    struct LendingMarket has key {
        id: UID,
        reserves: vector<Reserve>,
        paused: bool,
    }

    struct Reserve has store {
        coin_type: u8,
        total_deposits: u64,
        total_borrows: u64,
        available: Balance,
        deposit_index: u128,
        borrow_index: u128,
        interest_model: InterestModel,
        risk_config: ReserveRiskConfig,
    }

    struct ReserveRiskConfig has store {
        ltv_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_penalty_bps: u64,
        borrow_cap: u64,
        supply_cap: u64,
    }

    struct InterestModel has store {
        base_rate_bps: u64,
        slope1_bps: u64,
        slope2_bps: u64,
        optimal_utilization_bps: u64,
    }

    struct DepositReceipt has key, store {
        id: UID,
        market_id: ID,
        reserve_index: u8,
        amount: u64,
        use_as_collateral: bool,
        index_at_deposit: u128,
    }

    struct BorrowReceipt has key, store {
        id: UID,
        market_id: ID,
        reserve_index: u8,
        amount: u64,
        index_at_borrow: u128,
    }
}
```

## 杠杆开仓流程

Cetus 的杠杆开仓在单笔交易中完成（通过 PTB）：

```typescript
async function openCetusLeverageLong(params: {
    collateralAmount: number;
    collateralType: string;
    targetLeverage: number;
    targetAsset: string;
}) {
    const ptb = new TransactionBlock();

    let depositAmount = params.collateralAmount;
    let totalBorrowed = 0;
    const leverage = params.targetLeverage;

    for (let i = 0; i < Math.ceil(leverage) - 1; i++) {
        const borrowAmount = calculateBorrowForLeverage(
            depositAmount,
            leverage,
            i,
            params.collateralType,
            params.targetAsset
        );

        const borrowCoin = ptb.moveCall({
            target: `${CETUS_LENDING}::market::borrow`,
            arguments: [
                ptb.object(MARKET_ID),
                ptb.pure(borrowAmount),
                ptb.object(DEPOSIT_RECEIPT),
            ],
            typeArguments: [params.collateralType],
        });

        const [swapOutput] = ptb.moveCall({
            target: `${CETUS_ROUTER}::swap::swap_exact_input`,
            arguments: [
                ptb.object(POOL_ID),
                borrowCoin,
                ptb.pure(0),
            ],
            typeArguments: [params.targetAsset, params.collateralType],
        });

        const newDeposit = ptb.moveCall({
            target: `${CETUS_LENDING}::market::supply`,
            arguments: [
                ptb.object(MARKET_ID),
                swapOutput,
            ],
            typeArguments: [params.targetAsset],
        });

        depositAmount = borrowAmount;
        totalBorrowed += borrowAmount;
    }

    return ptb;
}
```

## Move 实现：杠杆循环

```move
module cetus_leverage {
    use cetus_lending::{Self, LendingMarket, DepositReceipt, BorrowReceipt};
    use cetus_clmm::{Self, Pool};
    use sui::coin::{Self, Coin};
    use sui::tx_context::{Self, TxContext};

    public fun open_leverage_long<Base, Quote>(
        market: &mut LendingMarket,
        pool: &mut Pool<Base, Quote>,
        initial_deposit: Coin<Base>,
        target_leverage_bps: u64,
        ctx: &mut TxContext,
    ): (DepositReceipt, BorrowReceipt) {
        let deposit_amount = coin::value(&initial_deposit);
        let deposit = cetus_lending::supply(market, initial_deposit, ctx);
        cetus_lending::enable_collateral(&mut deposit);

        let mut total_debt = 0u64;
        let mut loop_count = target_leverage_bps / 10000;
        let borrow_receipt: Option<BorrowReceipt> = option::none();

        let mut i = 0;
        while (i < loop_count) {
            let max_borrow = cetus_lending::get_max_borrow(market, &deposit);
            let borrow_amount = if (i == loop_count - 1) {
                max_borrow
            } else {
                max_borrow * 10000 / target_leverage_bps
            };
            assert!(borrow_amount > 0, 800);

            let borrowed = cetus_lending::borrow(market, borrow_amount, &deposit, ctx);
            let swapped = cetus_clmm::swap(pool, borrowed, ctx);
            let extra_deposit = cetus_lending::supply(market, swapped, ctx);
            cetus_lending::merge_deposits(&mut deposit, extra_deposit);

            total_debt = total_debt + borrow_amount;
            i = i + 1;
        };

        (deposit, option::extract(&mut borrow_receipt))
    }

    public fun close_leverage_position<Base, Quote>(
        market: &mut LendingMarket,
        pool: &mut Pool<Base, Quote>,
        deposit: DepositReceipt,
        borrow: BorrowReceipt,
        ctx: &mut TxContext,
    ) {
        let debt_amount = cetus_lending::get_debt_amount(&borrow);
        let collateral_withdrawn = cetus_lending::withdraw(market, deposit, ctx);
        let repayment_coin = cetus_clmm::swap(pool, collateral_withdrawn, ctx);
        cetus_lending::repay(market, borrow, repayment_coin, ctx);
    }
}
```

## Cetus 杠杆的风险参数

| 参数 | 典型值 | 说明 |
|------|--------|------|
| 最大杠杆 | 3x | 单一资产的最高杠杆倍数 |
| LTV（贷款价值比） | 75% | 最大可借金额 = 抵押品 × LTV |
| 清算阈值 | 80% | 抵押率低于此值触发清算 |
| 清算罚金 | 5-8% | 清算时从抵押品中扣除的罚金 |

## 与传统杠杆的区别

| 维度 | CeFi 杠杆 | Cetus 链上杠杆 |
|------|-----------|---------------|
| 资金来源 | 交易所自有资金 | 其他用户的存款 |
| 清算方式 | 中心化引擎 | 链上智能合约 |
| 透明度 | 不透明 | 全链上可验证 |
| 利率 | 固定或浮动 | 动态利率模型 |
| 杠杆来源 | 借款 | 借款 + DEX swap 循环 |
