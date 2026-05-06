/// 教学级现货杠杆实现
/// 展示杠杆借贷的核心机制：
/// - 抵押存入与借出
/// - 健康因子计算
/// - 杠杆循环（存入→借出→买入→再存入）
/// - 清算触发
///
/// 注意：本实现为教学原型，省略了预言机集成、利率计算等生产级功能。
#[allow(duplicate_alias, unused_const)]
module spot_leverage::spot_leverage;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID};
use sui::sui::SUI;
use sui::transfer;
use sui::tx_context::TxContext;

// ============ Constants ============

const PRECISION: u64 = 1_000_000_000; // 9 位精度，用于比率计算
const BPS: u64 = 10000;               // 基点分母

// ============ Errors ============

const EZeroAmount: u64 = 0;
const EInsufficientCollateral: u64 = 1;
const EInsufficientLiquidity: u64 = 2;
const EPositionUnhealthy: u64 = 3;
const ENotOwner: u64 = 4;
const ELiquidationNotAllowed: u64 = 5;
const EInvalidRepay: u64 = 6;

// ============ Structs ============

/// 杠杆协议的全局状态（共享对象）
public struct LeveragePool has key {
    id: UID,
    /// 可借出的 SUI 流动性
    available: Balance<SUI>,
    /// 累积的利息（教学简化）
    interest_reserve: Balance<SUI>,
    /// 借贷利率（年化，基点）
    borrow_rate_bps: u64,
    /// 最低抵押率（基点，如 15000 = 150%）
    min_collateral_ratio_bps: u64,
    /// 清算阈值（基点，如 13000 = 130%）
    liquidation_threshold_bps: u64,
    /// 清算罚金（基点，如 500 = 5%）
    liquidation_penalty_bps: u64,
}

/// 用户的杠杆仓位（owned 对象）
public struct LeveragePosition has key, store {
    id: UID,
    /// 存入的 SUI 抵押品
    collateral: Balance<SUI>,
    /// 借出的 SUI 数量（债务）
    debt: u64,
    /// 仓位所有者
    owner: address,
}

// ============ Events ============

public struct PositionOpened has copy, drop {
    user: address,
    collateral: u64,
}

public struct Borrowed has copy, drop {
    user: address,
    amount: u64,
    new_debt: u64,
    health_factor_bps: u64,
}

public struct Repaid has copy, drop {
    user: address,
    amount: u64,
    remaining_debt: u64,
}

public struct CollateralAdded has copy, drop {
    user: address,
    amount: u64,
    new_health_factor_bps: u64,
}

public struct Liquidated has copy, drop {
    user: address,
    liquidator: address,
    collateral_seized: u64,
    debt_repaid: u64,
    penalty: u64,
}

public struct PositionClosed has copy, drop {
    user: address,
    collateral_returned: u64,
    debt_repaid: u64,
}

// ============ Pool Management ============

/// 创建杠杆池
public fun create_pool(
    initial_liquidity: Coin<SUI>,
    borrow_rate_bps: u64,
    min_collateral_ratio_bps: u64,
    liquidation_threshold_bps: u64,
    liquidation_penalty_bps: u64,
    ctx: &mut TxContext,
) {
    let pool = LeveragePool {
        id: object::new(ctx),
        available: coin::into_balance(initial_liquidity),
        interest_reserve: balance::zero(),
        borrow_rate_bps,
        min_collateral_ratio_bps,
        liquidation_threshold_bps,
        liquidation_penalty_bps,
    };
    transfer::share_object(pool);
}

// ============ Health Factor ============

/// 计算健康因子（基点表示）
/// health_factor = collateral_value / debt_value * BPS
/// > liquidation_threshold_bps → 安全
/// <= liquidation_threshold_bps → 可清算
public fun health_factor_bps(
    _pool: &LeveragePool,
    position: &LeveragePosition,
    sui_price_bps: u64, // SUI 相对自身为 10000（教学简化）
): u64 {
    if (position.debt == 0) {
        return 999_999_999 // 无债务时健康因子极高
    };
    // collateral * price / debt * BPS
    // 教学简化：sui_price_bps 始终为 10000（SUI 用 SUI 计价）
    let collateral_value = balance::value(&position.collateral) * sui_price_bps / BPS;
    collateral_value * BPS / position.debt
}

/// 检查仓位是否健康（不可清算）
public fun is_healthy(
    pool: &LeveragePool,
    position: &LeveragePosition,
    sui_price_bps: u64,
): bool {
    let hf = health_factor_bps(pool, position, sui_price_bps);
    hf > pool.liquidation_threshold_bps
}

// ============ Open Position ============

/// 开仓：存入初始抵押品
public fun open_position(
    _pool: &mut LeveragePool,
    collateral: Coin<SUI>,
    ctx: &mut TxContext,
): LeveragePosition {
    let amount = coin::value(&collateral);
    assert!(amount > 0, EZeroAmount);

    let position = LeveragePosition {
        id: object::new(ctx),
        collateral: coin::into_balance(collateral),
        debt: 0,
        owner: ctx.sender(),
    };

    event::emit(PositionOpened {
        user: ctx.sender(),
        collateral: amount,
    });

    position
}

// ============ Add Collateral ============

/// 追加抵押品
public fun add_collateral(
    pool: &mut LeveragePool,
    position: &mut LeveragePosition,
    collateral: Coin<SUI>,
    sui_price_bps: u64,
    ctx: &TxContext,
) {
    let amount = coin::value(&collateral);
    assert!(amount > 0, EZeroAmount);
    assert!(ctx.sender() == position.owner, ENotOwner);

    balance::join(&mut position.collateral, coin::into_balance(collateral));

    let hf = health_factor_bps(pool, position, sui_price_bps);
    event::emit(CollateralAdded {
        user: ctx.sender(),
        amount,
        new_health_factor_bps: hf,
    });
}

// ============ Borrow ============

/// 借出 SUI（增加杠杆）
/// 借出后健康因子必须仍高于最低抵押率
public fun borrow(
    pool: &mut LeveragePool,
    position: &mut LeveragePosition,
    amount: u64,
    sui_price_bps: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(amount > 0, EZeroAmount);
    assert!(ctx.sender() == position.owner, ENotOwner);
    assert!(balance::value(&pool.available) >= amount, EInsufficientLiquidity);

    // 模拟借出后的健康因子
    let new_debt = position.debt + amount;
    let collateral_value = balance::value(&position.collateral) * sui_price_bps / BPS;
    let new_hf = collateral_value * BPS / new_debt;

    // 检查是否满足最低抵押率
    assert!(new_hf >= pool.min_collateral_ratio_bps, EInsufficientCollateral);

    position.debt = new_debt;
    let borrowed = coin::take(&mut pool.available, amount, ctx);

    event::emit(Borrowed {
        user: ctx.sender(),
        amount,
        new_debt,
        health_factor_bps: new_hf,
    });

    borrowed
}

// ============ Repay ============

/// 偿还债务
public fun repay(
    pool: &mut LeveragePool,
    position: &mut LeveragePosition,
    payment: Coin<SUI>,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == position.owner, ENotOwner);
    let pay_amount = coin::value(&payment);
    assert!(pay_amount > 0, EZeroAmount);
    assert!(pay_amount <= position.debt, EInvalidRepay);

    position.debt = position.debt - pay_amount;
    balance::join(&mut pool.available, coin::into_balance(payment));

    event::emit(Repaid {
        user: ctx.sender(),
        amount: pay_amount,
        remaining_debt: position.debt,
    });
}

// ============ Close Position ============

/// 平仓：偿还所有债务，取回剩余抵押品
public fun close_position(
    pool: &mut LeveragePool,
    position: LeveragePosition,
    payment: Coin<SUI>,
    ctx: &mut TxContext,
) {
    let LeveragePosition { id, collateral, debt, owner } = position;
    assert!(ctx.sender() == owner, ENotOwner);

    let pay_amount = coin::value(&payment);
    assert!(pay_amount >= debt, EInvalidRepay);

    // 偿还债务
    balance::join(&mut pool.available, coin::into_balance(payment));

    // 返回剩余抵押品
    let collateral_amount = balance::value(&collateral);
    let returned = coin::from_balance(collateral, ctx);

    event::emit(PositionClosed {
        user: owner,
        collateral_returned: collateral_amount,
        debt_repaid: debt,
    });

    transfer::public_transfer(returned, owner);
    object::delete(id);
}

// ============ Liquidate ============

/// 清算：当健康因子低于清算阈值时，清算人代为偿还债务并获取抵押品
public fun liquidate(
    pool: &mut LeveragePool,
    position: &mut LeveragePosition,
    mut payment: Coin<SUI>,
    sui_price_bps: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    let pay_amount = coin::value(&payment);

    // 检查仓位是否可清算
    let hf = health_factor_bps(pool, position, sui_price_bps);
    assert!(hf <= pool.liquidation_threshold_bps, ELiquidationNotAllowed);

    // 最多偿还 50% 的债务（部分清算）
    let max_repay = position.debt / 2;
    let actual_repay = if (pay_amount > max_repay) { max_repay } else { pay_amount };

    // 计算可获取的抵押品（按比例 + 罚金）
    let collateral_to_seize = actual_repay * BPS / hf;
    let penalty = collateral_to_seize * pool.liquidation_penalty_bps / BPS;
    let mut total_seize = collateral_to_seize + penalty;

    // 不能超过实际抵押品
    let total_collateral = balance::value(&position.collateral);
    if (total_seize > total_collateral) {
        total_seize = total_collateral;
    };

    // 更新状态
    position.debt = position.debt - actual_repay;
    let mut seized = balance::split(&mut position.collateral, total_seize);

    // 剩余的 payment 返还给清算人
    if (pay_amount > actual_repay) {
        let excess = coin::split(&mut payment, pay_amount - actual_repay, ctx);
        // 简化：将 excess 合并到 seized
        balance::join(&mut seized, coin::into_balance(excess));
    };

    // 将实际偿还的部分放入池子
    balance::join(&mut pool.available, coin::into_balance(payment));

    event::emit(Liquidated {
        user: position.owner,
        liquidator: ctx.sender(),
        collateral_seized: total_seize,
        debt_repaid: actual_repay,
        penalty,
    });

    coin::from_balance(seized, ctx)
}

// ============ View Functions ============

/// 获取池子可用流动性
public fun pool_available(pool: &LeveragePool): u64 {
    balance::value(&pool.available)
}

/// 获取仓位抵押品数量
public fun position_collateral(position: &LeveragePosition): u64 {
    balance::value(&position.collateral)
}

/// 获取仓位债务数量
public fun position_debt(position: &LeveragePosition): u64 {
    position.debt
}

/// 计算杠杆倍数（基点表示）
/// leverage = total_assets / (total_assets - debt)
/// 如果 debt == 0，返回 BPS（1x 杠杆）
public fun leverage_bps(position: &LeveragePosition): u64 {
    if (position.debt == 0) { return BPS };
    let collateral = balance::value(&position.collateral);
    if (collateral <= position.debt) { return 999_999_999 }; // 资不抵债
    collateral * BPS / (collateral - position.debt)
}

// ============ Tests ============

#[test_only]
fun create_pool_for_testing(
    initial_liquidity: Coin<SUI>,
    borrow_rate_bps: u64,
    min_collateral_ratio_bps: u64,
    liquidation_threshold_bps: u64,
    liquidation_penalty_bps: u64,
    ctx: &mut TxContext,
): LeveragePool {
    LeveragePool {
        id: object::new(ctx),
        available: coin::into_balance(initial_liquidity),
        interest_reserve: balance::zero(),
        borrow_rate_bps,
        min_collateral_ratio_bps,
        liquidation_threshold_bps,
        liquidation_penalty_bps,
    }
}

#[test]
fun open_position_and_borrow() {
    use std::unit_test::destroy;
    use sui::tx_context;

    let mut ctx = tx_context::dummy();
    let liquidity = coin::mint_for_testing<SUI>(100_000_000_000_000, &mut ctx);
    let mut pool = create_pool_for_testing(liquidity, 500, 15000, 13000, 500, &mut ctx);

    let collateral = coin::mint_for_testing<SUI>(10_000_000_000_000, &mut ctx);
    let mut position = open_position(&mut pool, collateral, &mut ctx);

    assert!(position_collateral(&position) == 10_000_000_000_000);
    assert!(position_debt(&position) == 0);

    let borrowed = borrow(&mut pool, &mut position, 6_000_000_000_000, 10000, &mut ctx);

    assert!(coin::value(&borrowed) == 6_000_000_000_000);
    assert!(position_debt(&position) == 6_000_000_000_000);

    let hf = health_factor_bps(&pool, &position, 10000);
    assert!(hf >= 15000);
    assert!(leverage_bps(&position) == 25000);

    destroy(borrowed);
    destroy(position);
    destroy(pool);
}

#[test]
fun partial_liquidation_after_price_drop() {
    use std::unit_test::destroy;
    use sui::tx_context;

    let mut ctx = tx_context::dummy();
    let liquidity = coin::mint_for_testing<SUI>(100_000_000_000_000, &mut ctx);
    let mut pool = create_pool_for_testing(liquidity, 500, 15000, 13000, 500, &mut ctx);

    let collateral = coin::mint_for_testing<SUI>(10_000_000_000_000, &mut ctx);
    let mut position = open_position(&mut pool, collateral, &mut ctx);
    let borrowed = borrow(&mut pool, &mut position, 6_500_000_000_000, 10000, &mut ctx);
    destroy(borrowed);

    let payment = coin::mint_for_testing<SUI>(3_250_000_000_000, &mut ctx);
    let seized = liquidate(&mut pool, &mut position, payment, 8000, &mut ctx);

    assert!(position_debt(&position) == 3_250_000_000_000);
    assert!(coin::value(&seized) > 0);

    destroy(seized);
    destroy(position);
    destroy(pool);
}
