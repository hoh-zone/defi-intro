/// CDP (Collateralized Debt Position) Stablecoin Implementation
///
/// A simplified CDP system where users deposit collateral to mint a
/// stablecoin (USDs). The system enforces a minimum collateral ratio and
/// liquidates positions that fall below the liquidation threshold.
///
/// For educational purposes, the collateral price is passed as a parameter
/// rather than read from an oracle. In production you would integrate
/// with a price oracle (see Chapter 5).
module cdp_stablecoin::cdp;

use std::option;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::object::{Self, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ============================================================
// Error codes
// ============================================================
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
#[error]
const EPositionMismatch: vector<u8> = b"Position Mismatch";
#[error]
const EInsufficientRepayment: vector<u8> = b"Insufficient Repayment";
#[error]
const EInvalidParameters: vector<u8> = b"Invalid Parameters";

// ============================================================
// Constants
// ============================================================
const BPS_BASE: u64 = 10000;

// ============================================================
// One-Time Witness for this module.
// Also serves as the phantom type for the USDs stablecoin:
// Coin<CDP> is the USDs stablecoin.
// ============================================================
public struct CDP has drop {}

// ============================================================
// Shared treasury object (holds TreasuryCap<CDP>)
// ============================================================
/// Shared object that holds the treasury capability for the USDs
/// stablecoin. Created once in init.
public struct StableTreasury has key {
    id: UID,
    treasury_cap: TreasuryCap<CDP>,
}

// ============================================================
// Shared system object
// ============================================================
/// The global CDP system for a given collateral type. Tracks
/// aggregate state and holds the collateral balance.
public struct CDPSystem<phantom Collateral> has key {
    id: UID,
    treasury_id: ID,
    collateral_balance: Balance<Collateral>,
    total_debt: u64,
    debt_ceiling: u64,
    collateral_ratio_bps: u64,
    liquidation_threshold_bps: u64,
    liquidation_penalty_bps: u64,
    paused: bool,
}

// ============================================================
// User position (owned object)
// ============================================================
/// A user's individual CDP position, tracking their collateral deposit
/// and outstanding debt.
public struct CDPPosition<phantom Collateral> has key, store {
    id: UID,
    system_id: ID,
    owner: address,
    collateral_amount: u64,
    debt_amount: u64,
}

// ============================================================
// Governance capability (owned object)
// ============================================================
/// Capability object that authorises governance actions such as
/// parameter updates and emergency pauses.
public struct GovernanceCap<phantom Collateral> has key, store {
    id: UID,
    system_id: ID,
}

// ============================================================
// Events
// ============================================================
public struct PositionOpened has copy, drop {
    owner: address,
    collateral_amount: u64,
    mint_amount: u64,
}

public struct CollateralAdded has copy, drop {
    owner: address,
    amount: u64,
}

public struct DebtRepaid has copy, drop {
    owner: address,
    amount: u64,
}

public struct PositionClosed has copy, drop {
    owner: address,
    collateral_returned: u64,
    debt_repaid: u64,
}

public struct PositionLiquidated has copy, drop {
    owner: address,
    collateral_seized: u64,
    debt_repaid: u64,
}

public struct ParametersUpdated has copy, drop {
    collateral_ratio_bps: u64,
    liquidation_threshold_bps: u64,
    debt_ceiling: u64,
}

public struct SystemPaused has copy, drop {}
public struct SystemUnpaused has copy, drop {}

// ============================================================
// Init
// ============================================================
/// Create the USDs stablecoin currency and publish the treasury
/// as a shared object. Governance caps and CDP systems are created
/// per-collateral-type via `create_system`.
fun init(witness: CDP, ctx: &mut TxContext) {
    let (treasury_cap, coin_metadata) = coin::create_currency<CDP>(
        witness,
        6,
        b"USDs",
        b"USDs",
        b"Sui CDP Stablecoin",
        option::none(),
        ctx,
    );
    transfer::share_object(StableTreasury {
        id: object::new(ctx),
        treasury_cap,
    });
    // Publish CoinMetadata as an immutable shared object
    transfer::public_freeze_object(coin_metadata);
}

// ============================================================
// Create CDP system for a collateral type
// ============================================================
/// Create a new CDP system for the given collateral type, sharing
/// the treasury with other CDP systems. A governance cap is
/// transferred to the caller.
public fun create_system<Collateral>(
    treasury: &mut StableTreasury,
    debt_ceiling: u64,
    collateral_ratio_bps: u64,
    liquidation_threshold_bps: u64,
    liquidation_penalty_bps: u64,
    ctx: &mut TxContext,
) {
    let system = CDPSystem<Collateral> {
        id: object::new(ctx),
        treasury_id: object::id(treasury),
        collateral_balance: balance::zero<Collateral>(),
        total_debt: 0,
        debt_ceiling,
        collateral_ratio_bps,
        liquidation_threshold_bps,
        liquidation_penalty_bps,
        paused: false,
    };
    let gov_cap = GovernanceCap<Collateral> {
        id: object::new(ctx),
        system_id: object::id(&system),
    };
    transfer::share_object(system);
    transfer::public_transfer(gov_cap, ctx.sender());
}

// ============================================================
// Open position
// ============================================================
/// Deposit collateral and mint stablecoins.
public fun open_position<Collateral>(
    treasury: &mut StableTreasury,
    system: &mut CDPSystem<Collateral>,
    collateral: Coin<Collateral>,
    mint_amount: u64,
    price: u64,
    ctx: &mut TxContext,
): CDPPosition<Collateral> {
    assert!(!system.paused, ESystemPaused);
    assert!(mint_amount > 0, EInvalidAmount);

    let collateral_amount = coin::value(&collateral);

    // max_debt = collateral_amount * price * collateral_ratio_bps / (1_000_000_000 * 10000)
    let max_debt =
        (
            (collateral_amount as u128)
            * (price as u128)
            * (system.collateral_ratio_bps as u128)
            / ((1_000_000_000u128) * (BPS_BASE as u128)),
        ) as u64;
    assert!(mint_amount <= max_debt, ECollateralRatioTooLow);
    assert!(system.total_debt + mint_amount <= system.debt_ceiling, EDebtCeiling);

    // Absorb collateral
    balance::join(&mut system.collateral_balance, coin::into_balance(collateral));
    system.total_debt = system.total_debt + mint_amount;

    // Mint stablecoin to the caller
    let stable_coin = coin::mint(&mut treasury.treasury_cap, mint_amount, ctx);
    transfer::public_transfer(stable_coin, ctx.sender());

    sui::event::emit(PositionOpened {
        owner: ctx.sender(),
        collateral_amount,
        mint_amount,
    });

    CDPPosition<Collateral> {
        id: object::new(ctx),
        system_id: object::id(system),
        owner: ctx.sender(),
        collateral_amount,
        debt_amount: mint_amount,
    }
}

// ============================================================
// Add collateral
// ============================================================
/// Add more collateral to an existing position.
public fun add_collateral<Collateral>(
    system: &mut CDPSystem<Collateral>,
    position: &mut CDPPosition<Collateral>,
    collateral: Coin<Collateral>,
) {
    assert!(object::id(system) == position.system_id, EPositionMismatch);

    let amount = coin::value(&collateral);
    balance::join(&mut system.collateral_balance, coin::into_balance(collateral));
    position.collateral_amount = position.collateral_amount + amount;

    sui::event::emit(CollateralAdded {
        owner: position.owner,
        amount,
    });
}

// ============================================================
// Repay partial debt
// ============================================================
/// Repay some debt without closing the position.
public fun repay_partial<Collateral>(
    treasury: &mut StableTreasury,
    system: &mut CDPSystem<Collateral>,
    position: &mut CDPPosition<Collateral>,
    repayment: Coin<CDP>,
    ctx: &TxContext,
) {
    assert!(object::id(system) == position.system_id, EPositionMismatch);
    assert!(position.owner == ctx.sender(), ENotOwner);

    let repay_amount = coin::value(&repayment);
    assert!(repay_amount > 0, EInvalidAmount);
    assert!(repay_amount <= position.debt_amount, EInsufficientRepayment);

    coin::burn(&mut treasury.treasury_cap, repayment);
    system.total_debt = system.total_debt - repay_amount;
    position.debt_amount = position.debt_amount - repay_amount;

    sui::event::emit(DebtRepaid {
        owner: position.owner,
        amount: repay_amount,
    });
}

// ============================================================
// Repay and close position
// ============================================================
/// Repay all outstanding debt, return the collateral, and destroy
/// the CDP position.
public fun repay_and_close<Collateral>(
    treasury: &mut StableTreasury,
    system: &mut CDPSystem<Collateral>,
    position: CDPPosition<Collateral>,
    repayment: Coin<CDP>,
    ctx: &mut TxContext,
): Coin<Collateral> {
    assert!(object::id(system) == position.system_id, EPositionMismatch);
    assert!(position.owner == ctx.sender(), ENotOwner);

    let repay_amount = coin::value(&repayment);
    assert!(repay_amount >= position.debt_amount, EInsufficientRepayment);

    coin::burn(&mut treasury.treasury_cap, repayment);
    system.total_debt = system.total_debt - position.debt_amount;

    let collateral_return = coin::take(
        &mut system.collateral_balance,
        position.collateral_amount,
        ctx,
    );

    let debt_repaid = position.debt_amount;
    let collateral_returned = position.collateral_amount;

    // Destroy the position object
    let CDPPosition { id, system_id: _, owner: _, collateral_amount: _, debt_amount: _ } = position;
    id.delete();

    sui::event::emit(PositionClosed {
        owner: ctx.sender(),
        collateral_returned,
        debt_repaid,
    });

    collateral_return
}

// ============================================================
// Liquidation
// ============================================================
/// Liquidate an undercollateralized position.
public fun liquidate<Collateral>(
    treasury: &mut StableTreasury,
    system: &mut CDPSystem<Collateral>,
    position: CDPPosition<Collateral>,
    repayment: Coin<CDP>,
    price: u64,
    ctx: &mut TxContext,
): Coin<Collateral> {
    assert!(object::id(system) == position.system_id, EPositionMismatch);

    // Check that the position is actually liquidatable
    let current_ratio_bps =
        (
            (position.collateral_amount as u128)
            * (price as u128)
            * (BPS_BASE as u128)
            / ((position.debt_amount as u128) * 1_000_000_000u128),
        ) as u64;
    assert!(current_ratio_bps < system.liquidation_threshold_bps, EPositionNotLiquidatable);

    let repay_amount = coin::value(&repayment);
    assert!(repay_amount >= position.debt_amount, EInsufficientRepayment);

    // Burn the repaid stablecoin
    coin::burn(&mut treasury.treasury_cap, repayment);
    system.total_debt = system.total_debt - position.debt_amount;

    // Calculate collateral to seize
    let debt_value_collateral =
        (
            (position.debt_amount as u128)
            * 1_000_000_000u128
            / (price as u128),
        ) as u64;
    let penalty = position.collateral_amount * system.liquidation_penalty_bps / BPS_BASE;
    let collateral_to_seize = debt_value_collateral + penalty;
    let seize_amount = if (collateral_to_seize > position.collateral_amount) {
        position.collateral_amount
    } else {
        collateral_to_seize
    };

    let owner = position.owner;
    let debt_repaid = position.debt_amount;
    let seized = seize_amount;

    // Destroy the position object
    let CDPPosition { id, system_id: _, owner: _, collateral_amount: _, debt_amount: _ } = position;
    id.delete();

    sui::event::emit(PositionLiquidated {
        owner,
        collateral_seized: seized,
        debt_repaid,
    });

    coin::take(&mut system.collateral_balance, seize_amount, ctx)
}

// ============================================================
// Health factor
// ============================================================
/// Compute the health factor for a position in basis points.
public fun health_factor<Collateral>(position: &CDPPosition<Collateral>, price: u64): u64 {
    if (position.debt_amount == 0) {
        return 0xFFFFFFFFFFFFFFFF
    };
    (
        ((position.collateral_amount as u128)
            * (price as u128)
            * (BPS_BASE as u128))
            / ((position.debt_amount as u128) * 1_000_000_000u128),
    ) as u64
}

// ============================================================
// Governance: update parameters
// ============================================================
public fun update_parameters<Collateral>(
    _cap: &GovernanceCap<Collateral>,
    system: &mut CDPSystem<Collateral>,
    new_collateral_ratio_bps: u64,
    new_liquidation_threshold_bps: u64,
    new_debt_ceiling: u64,
    new_liquidation_penalty_bps: u64,
) {
    assert!(new_collateral_ratio_bps > new_liquidation_threshold_bps, EInvalidParameters);
    system.collateral_ratio_bps = new_collateral_ratio_bps;
    system.liquidation_threshold_bps = new_liquidation_threshold_bps;
    system.debt_ceiling = new_debt_ceiling;
    system.liquidation_penalty_bps = new_liquidation_penalty_bps;

    sui::event::emit(ParametersUpdated {
        collateral_ratio_bps: new_collateral_ratio_bps,
        liquidation_threshold_bps: new_liquidation_threshold_bps,
        debt_ceiling: new_debt_ceiling,
    });
}

// ============================================================
// Governance: emergency pause / unpause
// ============================================================
public fun emergency_pause<Collateral>(
    _cap: &GovernanceCap<Collateral>,
    system: &mut CDPSystem<Collateral>,
) {
    system.paused = true;
    sui::event::emit(SystemPaused {});
}

public fun emergency_unpause<Collateral>(
    _cap: &GovernanceCap<Collateral>,
    system: &mut CDPSystem<Collateral>,
) {
    system.paused = false;
    sui::event::emit(SystemUnpaused {});
}

// ============================================================
// View functions
// ============================================================
public fun total_debt<Collateral>(system: &CDPSystem<Collateral>): u64 {
    system.total_debt
}

public fun debt_ceiling<Collateral>(system: &CDPSystem<Collateral>): u64 {
    system.debt_ceiling
}

public fun collateral_ratio_bps<Collateral>(system: &CDPSystem<Collateral>): u64 {
    system.collateral_ratio_bps
}

public fun liquidation_threshold_bps<Collateral>(system: &CDPSystem<Collateral>): u64 {
    system.liquidation_threshold_bps
}

public fun liquidation_penalty_bps<Collateral>(system: &CDPSystem<Collateral>): u64 {
    system.liquidation_penalty_bps
}

public fun is_paused<Collateral>(system: &CDPSystem<Collateral>): bool {
    system.paused
}

public fun collateral_balance<Collateral>(system: &CDPSystem<Collateral>): u64 {
    balance::value(&system.collateral_balance)
}

public fun position_collateral<Collateral>(position: &CDPPosition<Collateral>): u64 {
    position.collateral_amount
}

public fun position_debt<Collateral>(position: &CDPPosition<Collateral>): u64 {
    position.debt_amount
}

public fun position_owner<Collateral>(position: &CDPPosition<Collateral>): address {
    position.owner
}

// ============================================================
// Test helpers
// ============================================================
/// Create and share a StableTreasury for testing, bypassing init.
/// Call this in the first transaction, then use next_tx before take_shared.
#[test_only]
public fun create_treasury_for_testing(ctx: &mut TxContext) {
    let treasury_cap = coin::create_treasury_cap_for_testing<CDP>(ctx);
    let treasury = StableTreasury {
        id: object::new(ctx),
        treasury_cap,
    };
    transfer::share_object(treasury);
}

/// Test-only: create treasury and CDP system in one call.
/// Use this instead of create_treasury_for_testing + create_system
/// to avoid needing take_shared in the same transaction.
#[test_only]
public fun create_system_for_testing<Collateral>(
    debt_ceiling: u64,
    collateral_ratio_bps: u64,
    liquidation_threshold_bps: u64,
    liquidation_penalty_bps: u64,
    ctx: &mut TxContext,
) {
    let treasury_cap = coin::create_treasury_cap_for_testing<CDP>(ctx);
    let treasury = StableTreasury {
        id: object::new(ctx),
        treasury_cap,
    };
    let treasury_id = object::id(&treasury);
    transfer::share_object(treasury);

    let system = CDPSystem<Collateral> {
        id: object::new(ctx),
        treasury_id,
        collateral_balance: balance::zero<Collateral>(),
        total_debt: 0,
        debt_ceiling,
        collateral_ratio_bps,
        liquidation_threshold_bps,
        liquidation_penalty_bps,
        paused: false,
    };
    let gov_cap = GovernanceCap<Collateral> {
        id: object::new(ctx),
        system_id: object::id(&system),
    };
    transfer::share_object(system);
    transfer::public_transfer(gov_cap, ctx.sender());
}

#[test_only]
public fun destroy_treasury(treasury: StableTreasury) {
    let StableTreasury { id, treasury_cap } = treasury;
    transfer::public_transfer(treasury_cap, @0x0);
    id.delete();
}

#[test_only]
public fun destroy_system<Collateral>(system: CDPSystem<Collateral>) {
    let CDPSystem {
        id,
        treasury_id: _,
        collateral_balance,
        total_debt: _,
        debt_ceiling: _,
        collateral_ratio_bps: _,
        liquidation_threshold_bps: _,
        liquidation_penalty_bps: _,
        paused: _,
    } = system;
    balance::destroy_zero(collateral_balance);
    id.delete();
}

#[test_only]
public fun destroy_position<Collateral>(position: CDPPosition<Collateral>) {
    let CDPPosition { id, system_id: _, owner: _, collateral_amount: _, debt_amount: _ } = position;
    id.delete();
}

#[test_only]
public fun destroy_gov_cap<Collateral>(cap: GovernanceCap<Collateral>) {
    let GovernanceCap { id, system_id: _ } = cap;
    id.delete();
}
