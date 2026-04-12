module lending_market::market;
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};

// ============================================================
// Error codes
// ============================================================
const EInvalidAmount: u64 = 0;
const EInsufficientLiquidity: u64 = 1;
const EHealthFactorTooLow: u64 = 2;
const ENotLiquidatable: u64 = 3;
const EReceiptMismatch: u64 = 4;
const EUnauthorized: u64 = 5;
const EInvalidCollateralFactor: u64 = 6;
const EInvalidThreshold: u64 = 7;
const EInsufficientCollateral: u64 = 8;

// ============================================================
// Constants
// ============================================================
const BPS_BASE: u64 = 10000;

// ============================================================
// Events
// ============================================================
public struct SupplyEvent has copy, drop {
    supplier: address,
    collateral_amount: u64,
}

public struct BorrowEvent has copy, drop {
    borrower: address,
    borrow_amount: u64,
}

public struct RepayEvent has copy, drop {
    repayer: address,
    repay_amount: u64,
}

public struct WithdrawEvent has copy, drop {
    withdrawer: address,
    collateral_amount: u64,
}

public struct LiquidationEvent has copy, drop {
    liquidator: address,
    repay_amount: u64,
    seized_collateral: u64,
}

// ============================================================
// Structs
// ============================================================

/// Shared lending market for a collateral/borrow pair.
public struct Market<phantom Collateral, phantom Borrow> has key {
    id: UID,
    /// Vault holding deposited collateral tokens.
    collateral_vault: Balance<Collateral>,
    /// Vault holding borrowable tokens (supplied by liquidity providers).
    borrow_vault: Balance<Borrow>,
    /// Total collateral recorded (tracks what depositors have put in).
    total_collateral: u64,
    /// Total debt outstanding (sum of all borrows).
    total_borrow: u64,
    /// Collateral factor in basis points (e.g. 7500 = 75%).
    /// Determines how much you can borrow against collateral.
    collateral_factor_bps: u64,
    /// Liquidation threshold in basis points (e.g. 8000 = 80%).
    /// Health factor drops below 1 when debt exceeds this fraction of collateral.
    liquidation_threshold_bps: u64,
    /// Liquidation bonus in basis points (e.g. 500 = 5% extra collateral for liquidator).
    liquidation_bonus_bps: u64,
    /// Interest rate model parameters.
    base_rate_bps: u64,
    kink_bps: u64,
    multiplier_bps: u64,
    /// Jump multiplier applied above the kink (e.g. 5x).
    jump_multiplier_bps: u64,
}

/// Receipt proving a user has deposited collateral into the market.
public struct DepositReceipt<phantom C, phantom B> has key, store {
    id: UID,
    market_id: ID,
    collateral_amount: u64,
}

/// Receipt tracking a user's outstanding debt.
public struct BorrowReceipt<phantom C, phantom B> has key, store {
    id: UID,
    market_id: ID,
    borrow_amount: u64,
}

/// Admin capability for managing risk parameters.
public struct AdminCap<phantom C, phantom B> has key, store {
    id: UID,
    market_id: ID,
}

// ============================================================
// Health factor helper (returned as a struct for readability)
// ============================================================

/// A simple wrapper so callers can inspect the health factor value.
public struct HealthFactor has copy, drop, store {
    value_bps: u64,
}

// ============================================================
// Init
// ============================================================

/// Create a new lending market.
///
/// @param collateral_factor_bps  How much of collateral value can be borrowed (e.g. 7500 = 75%).
/// @param liquidation_threshold_bps  Threshold at which position becomes liquidatable (e.g. 8000 = 80%).
/// @param liquidation_bonus_bps  Bonus collateral liquidator receives (e.g. 500 = 5%).
/// @param base_rate_bps  Base interest rate when utilization is 0 (e.g. 200 = 2%).
/// @param kink_bps  Utilization point where the rate jumps (e.g. 8000 = 80%).
/// @param multiplier_bps  Rate slope multiplier below kink (e.g. 1000 = 10% at 100% util).
/// @param jump_multiplier_bps  Rate slope multiplier above kink (e.g. 5000 = 50% extra).
public fun create_market<Collateral, Borrow>(
    collateral_factor_bps: u64,
    liquidation_threshold_bps: u64,
    liquidation_bonus_bps: u64,
    base_rate_bps: u64,
    kink_bps: u64,
    multiplier_bps: u64,
    jump_multiplier_bps: u64,
    ctx: &mut TxContext,
) {
    assert!(collateral_factor_bps <= BPS_BASE, EInvalidCollateralFactor);
    assert!(liquidation_threshold_bps <= BPS_BASE, EInvalidThreshold);
    assert!(liquidation_threshold_bps >= collateral_factor_bps, EInvalidThreshold);

    let market = Market<Collateral, Borrow> {
        id: object::new(ctx),
        collateral_vault: balance::zero(),
        borrow_vault: balance::zero(),
        total_collateral: 0,
        total_borrow: 0,
        collateral_factor_bps,
        liquidation_threshold_bps,
        liquidation_bonus_bps,
        base_rate_bps,
        kink_bps,
        multiplier_bps,
        jump_multiplier_bps,
    };

    let cap = AdminCap<Collateral, Borrow> {
        id: object::new(ctx),
        market_id: object::id(&market),
    };

    transfer::share_object(market);
    transfer::transfer(cap, ctx.sender());
}

// ============================================================
// Core functions
// ============================================================

/// Supply collateral tokens to the market and receive a DepositReceipt.
public fun supply_collateral<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    coin: Coin<Collateral>,
    ctx: &mut TxContext,
): DepositReceipt<Collateral, Borrow> {
    let amount = coin::value(&coin);
    assert!(amount > 0, EInvalidAmount);

    market.total_collateral = market.total_collateral + amount;
    balance::join(&mut market.collateral_vault, coin::into_balance(coin));

    sui::event::emit(SupplyEvent {
        supplier: ctx.sender(),
        collateral_amount: amount,
    });

    DepositReceipt<Collateral, Borrow> {
        id: object::new(ctx),
        market_id: object::id(market),
        collateral_amount: amount,
    }
}

/// Borrow tokens against deposited collateral.
/// Health factor must remain > 1 (i.e., > 10000 bps) after borrowing.
public fun borrow<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    deposit_receipt: &DepositReceipt<Collateral, Borrow>,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<Borrow>, BorrowReceipt<Collateral, Borrow>) {
    assert!(amount > 0, EInvalidAmount);
    assert!(object::id(market) == deposit_receipt.market_id, EReceiptMismatch);

    // Check there is enough liquidity in the borrow vault.
    assert!(balance::value(&market.borrow_vault) >= amount, EInsufficientLiquidity);

    // Compute health factor for this user's position.
    // In this simplified model, each borrow creates a new receipt.
    // The user's debt after this borrow is `amount`.
    // Their collateral is tracked in the deposit receipt.
    let hf = health_factor(
        deposit_receipt.collateral_amount,
        amount,
        market.collateral_factor_bps,
    );
    // Health factor must be strictly greater than 1 (> 10000 bps).
    assert!(hf.value_bps > BPS_BASE, EHealthFactorTooLow);

    // Update state.
    market.total_borrow = market.total_borrow + amount;

    sui::event::emit(BorrowEvent {
        borrower: ctx.sender(),
        borrow_amount: amount,
    });

    let borrow_coin = coin::take(&mut market.borrow_vault, amount, ctx);

    let borrow_receipt = BorrowReceipt<Collateral, Borrow> {
        id: object::new(ctx),
        market_id: object::id(market),
        borrow_amount: amount,
    };

    (borrow_coin, borrow_receipt)
}

/// Repay debt. Burns the BorrowReceipt.
public fun repay<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    borrow_receipt: BorrowReceipt<Collateral, Borrow>,
    coin: Coin<Borrow>,
    ctx: &TxContext,
) {
    assert!(object::id(market) == borrow_receipt.market_id, EReceiptMismatch);

    let repay_amount = coin::value(&coin);
    let debt = borrow_receipt.borrow_amount;
    assert!(repay_amount == debt, EInvalidAmount);

    market.total_borrow = market.total_borrow - debt;
    balance::join(&mut market.borrow_vault, coin::into_balance(coin));

    // Delete the BorrowReceipt.
    let BorrowReceipt { id, market_id: _, borrow_amount: _ } = borrow_receipt;
    id.delete();

    sui::event::emit(RepayEvent {
        repayer: tx_context::sender(ctx),
        repay_amount,
    });
}

/// Withdraw collateral. Only allowed if the user's health factor remains > 1.
/// Burns the DepositReceipt and returns the collateral coin.
public fun withdraw_collateral<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    deposit_receipt: DepositReceipt<Collateral, Borrow>,
    borrow_receipt: &BorrowReceipt<Collateral, Borrow>,
    ctx: &mut TxContext,
): Coin<Collateral> {
    assert!(object::id(market) == deposit_receipt.market_id, EReceiptMismatch);
    assert!(object::id(market) == borrow_receipt.market_id, EReceiptMismatch);

    let collateral_amount = deposit_receipt.collateral_amount;

    // Check that the user still has a healthy position after withdrawal.
    let hf = health_factor(
        collateral_amount,
        borrow_receipt.borrow_amount,
        market.collateral_factor_bps,
    );
    assert!(hf.value_bps > BPS_BASE, EHealthFactorTooLow);

    // Ensure enough collateral in vault.
    assert!(balance::value(&market.collateral_vault) >= collateral_amount, EInsufficientCollateral);

    market.total_collateral = market.total_collateral - collateral_amount;

    // Delete the DepositReceipt.
    let DepositReceipt { id, market_id: _, collateral_amount: _ } = deposit_receipt;
    id.delete();

    sui::event::emit(WithdrawEvent {
        withdrawer: ctx.sender(),
        collateral_amount,
    });

    coin::take(&mut market.collateral_vault, collateral_amount, ctx)
}

/// Liquidate an unhealthy position.
///
/// The liquidator repays the borrower's debt and seizes collateral
/// equal to debt_value * (1 + liquidation_bonus).
///
/// The borrower's DepositReceipt is updated (reduced) and their
/// BorrowReceipt is burned.
public fun liquidate<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    borrow_receipt: BorrowReceipt<Collateral, Borrow>,
    repay_coin: Coin<Borrow>,
    deposit_receipt: &mut DepositReceipt<Collateral, Borrow>,
    ctx: &mut TxContext,
): Coin<Collateral> {
    assert!(object::id(market) == borrow_receipt.market_id, EReceiptMismatch);
    assert!(object::id(market) == deposit_receipt.market_id, EReceiptMismatch);

    let repay_amount = coin::value(&repay_coin);
    let debt = borrow_receipt.borrow_amount;

    // Must repay exactly the outstanding debt (full liquidation for simplicity).
    assert!(repay_amount == debt, EInvalidAmount);

    // Verify the position is actually liquidatable.
    let hf = health_factor(
        deposit_receipt.collateral_amount,
        debt,
        market.liquidation_threshold_bps,
    );
    assert!(hf.value_bps < BPS_BASE, ENotLiquidatable);

    // Calculate collateral to seize:
    // seized = debt * (BPS_BASE + liquidation_bonus_bps) / BPS_BASE
    // Using 1:1 price assumption (both assets valued equally).
    let seized_amount = debt * (BPS_BASE + market.liquidation_bonus_bps) / BPS_BASE;

    // Cannot seize more collateral than the borrower deposited.
    let seized_amount = if (seized_amount > deposit_receipt.collateral_amount) {
        deposit_receipt.collateral_amount
    } else {
        seized_amount
    };

    assert!(balance::value(&market.collateral_vault) >= seized_amount, EInsufficientCollateral);

    // Update borrower's deposit receipt.
    deposit_receipt.collateral_amount = deposit_receipt.collateral_amount - seized_amount;

    // Update market state.
    market.total_borrow = market.total_borrow - debt;
    market.total_collateral = market.total_collateral - seized_amount;

    // Put repaid tokens back into borrow vault.
    balance::join(&mut market.borrow_vault, coin::into_balance(repay_coin));

    // Delete the BorrowReceipt (debt is cleared).
    let BorrowReceipt { id, market_id: _, borrow_amount: _ } = borrow_receipt;
    id.delete();

    sui::event::emit(LiquidationEvent {
        liquidator: ctx.sender(),
        repay_amount: debt,
        seized_collateral: seized_amount,
    });

    coin::take(&mut market.collateral_vault, seized_amount, ctx)
}

// ============================================================
// Interest rate model (kinked)
// ============================================================

/// Calculate the borrow rate in basis points based on current utilization.
///
/// utilization = total_borrow / total_supply
/// if utilization <= kink: rate = base_rate + utilization * multiplier
/// if utilization > kink: rate = base_rate + kink * multiplier + (utilization - kink) * multiplier * jump_multiplier
///
/// Returns rate in basis points.
public fun calculate_interest_rate<Collateral, Borrow>(
    market: &Market<Collateral, Borrow>,
): u64 {
    let total_supply = balance::value(&market.collateral_vault);
    if (total_supply == 0) {
        return market.base_rate_bps
    };

    let total_borrow = market.total_borrow;
    // utilization in bps = total_borrow * BPS_BASE / total_supply
    let utilization_bps = total_borrow * BPS_BASE / total_supply;

    if (utilization_bps <= market.kink_bps) {
        // rate = base_rate + (utilization * multiplier) / BPS_BASE
        market.base_rate_bps + (utilization_bps * market.multiplier_bps) / BPS_BASE
    } else {
        // rate = base_rate + (kink * multiplier) / BPS_BASE
        //      + ((utilization - kink) * multiplier * jump_multiplier) / (BPS_BASE * BPS_BASE)
        let rate_at_kink = market.base_rate_bps + (market.kink_bps * market.multiplier_bps) / BPS_BASE;
        let excess_utilization = utilization_bps - market.kink_bps;
        let jump_rate = excess_utilization * market.multiplier_bps * market.jump_multiplier_bps / (BPS_BASE * BPS_BASE);
        rate_at_kink + jump_rate
    }
}

// ============================================================
// Health factor
// ============================================================

/// Compute the health factor for a position.
///
/// hf_bps = (collateral_value * factor_bps) / (debt_value)
/// If debt_value is 0, the position is perfectly healthy (returns max).
///
/// Uses 1:1 price assumption (both assets priced equally).
/// hf > 10000 => healthy, hf < 10000 => liquidatable.
public fun health_factor(
    collateral_value: u64,
    debt_value: u64,
    factor_bps: u64,
): HealthFactor {
    if (debt_value == 0) {
        return HealthFactor { value_bps: 0xFFFFFFFFFFFFFFFF }
    };
    HealthFactor {
        value_bps: collateral_value * factor_bps / debt_value,
    }
}

// ============================================================
// Admin functions
// ============================================================

/// Update the collateral factor.
public fun set_collateral_factor<Collateral, Borrow>(
    _cap: &AdminCap<Collateral, Borrow>,
    market: &mut Market<Collateral, Borrow>,
    new_factor_bps: u64,
) {
    assert!(new_factor_bps <= BPS_BASE, EInvalidCollateralFactor);
    assert!(new_factor_bps <= market.liquidation_threshold_bps, EInvalidCollateralFactor);
    market.collateral_factor_bps = new_factor_bps;
}

/// Update the liquidation threshold.
public fun set_liquidation_threshold<Collateral, Borrow>(
    _cap: &AdminCap<Collateral, Borrow>,
    market: &mut Market<Collateral, Borrow>,
    new_threshold_bps: u64,
) {
    assert!(new_threshold_bps <= BPS_BASE, EInvalidThreshold);
    assert!(new_threshold_bps >= market.collateral_factor_bps, EInvalidThreshold);
    market.liquidation_threshold_bps = new_threshold_bps;
}

/// Supply borrowable tokens to the market (for liquidity providers).
public fun add_liquidity<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    coin: Coin<Borrow>,
) {
    balance::join(&mut market.borrow_vault, coin::into_balance(coin));
}

// ============================================================
// View functions
// ============================================================

public fun total_collateral<Collateral, Borrow>(market: &Market<Collateral, Borrow>): u64 {
    market.total_collateral
}

public fun total_borrow<Collateral, Borrow>(market: &Market<Collateral, Borrow>): u64 {
    market.total_borrow
}

public fun collateral_factor_bps<Collateral, Borrow>(market: &Market<Collateral, Borrow>): u64 {
    market.collateral_factor_bps
}

public fun liquidation_threshold_bps<Collateral, Borrow>(market: &Market<Collateral, Borrow>): u64 {
    market.liquidation_threshold_bps
}

public fun liquidation_bonus_bps<Collateral, Borrow>(market: &Market<Collateral, Borrow>): u64 {
    market.liquidation_bonus_bps
}

public fun collateral_vault_balance<Collateral, Borrow>(market: &Market<Collateral, Borrow>): u64 {
    balance::value(&market.collateral_vault)
}

public fun borrow_vault_balance<Collateral, Borrow>(market: &Market<Collateral, Borrow>): u64 {
    balance::value(&market.borrow_vault)
}

public fun deposit_amount<Collateral, Borrow>(receipt: &DepositReceipt<Collateral, Borrow>): u64 {
    receipt.collateral_amount
}

public fun borrow_amount<C, B>(receipt: &BorrowReceipt<C, B>): u64 {
    receipt.borrow_amount
}

public fun health_factor_value(hf: &HealthFactor): u64 {
    hf.value_bps
}

// ============================================================
// Test helpers
// ============================================================

#[test_only]
public fun destroy_market<Collateral, Borrow>(market: Market<Collateral, Borrow>) {
    let Market {
        id,
        collateral_vault,
        borrow_vault,
        total_collateral: _,
        total_borrow: _,
        collateral_factor_bps: _,
        liquidation_threshold_bps: _,
        liquidation_bonus_bps: _,
        base_rate_bps: _,
        kink_bps: _,
        multiplier_bps: _,
        jump_multiplier_bps: _,
    } = market;
    balance::destroy_zero(collateral_vault);
    balance::destroy_zero(borrow_vault);
    id.delete();
}

#[test_only]
public fun destroy_deposit_receipt<Collateral, Borrow>(receipt: DepositReceipt<Collateral, Borrow>) {
    let DepositReceipt { id, market_id: _, collateral_amount: _ } = receipt;
    id.delete();
}

#[test_only]
public fun destroy_borrow_receipt<Collateral, Borrow>(receipt: BorrowReceipt<Collateral, Borrow>) {
    let BorrowReceipt { id, market_id: _, borrow_amount: _ } = receipt;
    id.delete();
}

/// Admin function to force-set the liquidation threshold lower (for testing liquidation).
#[test_only]
public fun set_liquidation_threshold_test<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    new_threshold_bps: u64,
) {
    market.liquidation_threshold_bps = new_threshold_bps;
}

/// Admin function to force-set the collateral factor (for testing).
#[test_only]
public fun set_collateral_factor_test<Collateral, Borrow>(
    market: &mut Market<Collateral, Borrow>,
    new_factor_bps: u64,
) {
    market.collateral_factor_bps = new_factor_bps;
}
