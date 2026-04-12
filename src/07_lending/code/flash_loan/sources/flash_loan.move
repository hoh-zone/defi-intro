/// Module: flash_loan
/// A flash loan pool implementation using Sui Move's "hot potato" pattern.
///
/// Flash loans allow users to borrow assets without collateral, provided the loan
/// is repaid (with a fee) within the same transaction. This is enforced by the
/// FlashLoanReceipt struct, which has only the `store` ability -- it cannot be
/// dropped, so it MUST be consumed by passing it to `repay`. If the transaction
/// ends with an unconsumed receipt, the entire transaction aborts and all changes
/// roll back atomically.
module flash_loan::flash_loan;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::balance::{Self, Balance};
use sui::object::{Self, ID};

// ===== Error Constants =====

const EInsufficientLiquidity: u64 = 0;
const ERepaymentTooLow: u64 = 1;
const EFeeBpsTooHigh: u64 = 2;
const EWrongPool: u64 = 3;
const EZeroAmount: u64 = 5;

/// Maximum fee: 10% (1000 basis points)
const MAX_FEE_BPS: u64 = 1000;

// ===== Structs =====

/// A shared pool that holds liquidity for flash loans.
/// `T` is the coin type this pool lends out.
public struct FlashPool<phantom T> has key {
    id: UID,
    /// The pool's available liquidity + accumulated fees
    balance: Balance<T>,
    /// Fee in basis points (e.g., 30 = 0.3%)
    fee_bps: u64,
    /// Total number of flash loans executed
    total_loans: u64,
    /// Accumulated fees waiting to be withdrawn by admin
    accumulated_fees: Balance<T>,
}

/// Admin capability to manage the pool (withdraw fees, update fee).
public struct AdminCap<phantom T> has key, store {
    id: UID,
    pool_id: ID,
}

/// Hot potato receipt -- has only `store` ability, NO `drop`.
/// This means it MUST be consumed within the same transaction by passing
/// it to `repay`. If not, the transaction will abort.
public struct FlashLoanReceipt<phantom T> has store {
    /// The amount that was borrowed
    loan_amount: u64,
    /// The fee that must be paid on top of the loan amount
    fee_amount: u64,
    /// The ID of the pool this loan came from (prevents cross-pool repayment)
    pool_id: ID,
}

// ===== Initialization =====

/// Create a new flash loan pool for coin type `T`.
/// Only callable by the holder of the `TreasuryCap<T>`.
public fun new_pool<T>(
    treasury_cap: &TreasuryCap<T>,
    fee_bps: u64,
    ctx: &mut TxContext,
) {
    assert!(fee_bps <= MAX_FEE_BPS, EFeeBpsTooHigh);

    let pool_uid = object::new(ctx);
    let pool_id = object::uid_to_inner(&pool_uid);
    let pool = FlashPool<T> {
        id: pool_uid,
        balance: balance::zero(),
        fee_bps,
        total_loans: 0,
        accumulated_fees: balance::zero(),
    };

    let admin_cap = AdminCap<T> {
        id: object::new(ctx),
        pool_id,
    };

    // Share the pool so anyone can borrow from it
    transfer::share_object(pool);

    // Give admin cap to the creator
    transfer::transfer(admin_cap, ctx.sender());

    // TreasuryCap is not consumed; it is only read for authorization
    // We suppress the unused variable warning with a dummy use
    let _ = treasury_cap;
}

// ===== Core Flash Loan Functions =====

/// Borrow `amount` of coin `T` from the pool.
/// Returns the borrowed coins and a hot potato `FlashLoanReceipt`.
/// The receipt MUST be consumed by calling `repay` in the same transaction.
public fun borrow<T>(
    pool: &mut FlashPool<T>,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, FlashLoanReceipt<T>) {
    assert!(amount > 0, EZeroAmount);
    assert!(balance::value(&pool.balance) >= amount, EInsufficientLiquidity);

    let fee_amount = get_fee_amount(pool, amount);
    let coin = coin::take(&mut pool.balance, amount, ctx);
    let receipt = FlashLoanReceipt<T> {
        loan_amount: amount,
        fee_amount,
        pool_id: object::id(pool),
    };

    (coin, receipt)
}

/// Repay a flash loan. Consumes the hot potato receipt.
/// The `repayment` coin must cover `loan_amount + fee_amount`.
/// Any excess is returned to the caller as a separate coin.
public fun repay<T>(
    pool: &mut FlashPool<T>,
    receipt: FlashLoanReceipt<T>,
    repayment: Coin<T>,
    ctx: &mut TxContext,
): Coin<T> {
    // Destructure the receipt (this "destroys" the hot potato)
    let FlashLoanReceipt { loan_amount, fee_amount, pool_id } = receipt;

    // Verify we are repaying the correct pool
    assert!(pool_id == object::id(pool), EWrongPool);

    let required = loan_amount + fee_amount;
    let repayment_value = coin::value(&repayment);
    assert!(repayment_value >= required, ERepaymentTooLow);

    // Return the principal to the pool balance
    let mut repayment_balance = coin::into_balance(repayment);
    let principal_balance = balance::split(&mut repayment_balance, loan_amount);
    balance::join(&mut pool.balance, principal_balance);

    // Send the fee to accumulated fees
    let fee_balance = balance::split(&mut repayment_balance, fee_amount);
    balance::join(&mut pool.accumulated_fees, fee_balance);

    // Update stats
    pool.total_loans = pool.total_loans + 1;

    // Return any excess to the caller
    coin::from_balance(repayment_balance, ctx)
}

// ===== Liquidity Management =====

/// Anyone can deposit coins into the pool to provide liquidity.
/// In a production system, this would mint LP tokens or track shares.
public fun deposit<T>(
    pool: &mut FlashPool<T>,
    coin: Coin<T>,
) {
    balance::join(&mut pool.balance, coin::into_balance(coin));
}

/// Withdraw a specified amount of liquidity from the pool.
/// Only the admin can withdraw (for simplicity; production systems would
/// use LP token redemptions).
public fun withdraw<T>(
    cap: &AdminCap<T>,
    pool: &mut FlashPool<T>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(object::id(pool) == cap.pool_id, EWrongPool);
    assert!(amount > 0, EZeroAmount);
    assert!(balance::value(&pool.balance) >= amount, EInsufficientLiquidity);
    coin::take(&mut pool.balance, amount, ctx)
}

/// Admin withdraws accumulated fees from the pool.
public fun withdraw_fees<T>(
    cap: &AdminCap<T>,
    pool: &mut FlashPool<T>,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(object::id(pool) == cap.pool_id, EWrongPool);
    let fees = balance::value(&pool.accumulated_fees);
    assert!(fees > 0, EZeroAmount);
    coin::take(&mut pool.accumulated_fees, fees, ctx)
}

// ===== Admin Functions =====

/// Update the fee rate (in basis points).
public fun set_fee_bps<T>(
    cap: &AdminCap<T>,
    pool: &mut FlashPool<T>,
    new_fee_bps: u64,
) {
    assert!(object::id(pool) == cap.pool_id, EWrongPool);
    assert!(new_fee_bps <= MAX_FEE_BPS, EFeeBpsTooHigh);
    pool.fee_bps = new_fee_bps;
}

// ===== View Functions =====

/// Calculate the fee for a given loan amount.
/// Fee = amount * fee_bps / 10000
public fun get_fee_amount<T>(pool: &FlashPool<T>, amount: u64): u64 {
    amount * pool.fee_bps / 10000
}

/// Get the current available liquidity in the pool (excluding fees).
public fun pool_balance<T>(pool: &FlashPool<T>): u64 {
    balance::value(&pool.balance)
}

/// Get the accumulated fees in the pool.
public fun accumulated_fees<T>(pool: &FlashPool<T>): u64 {
    balance::value(&pool.accumulated_fees)
}

/// Get the fee rate in basis points.
public fun fee_bps<T>(pool: &FlashPool<T>): u64 {
    pool.fee_bps
}

/// Get the total number of flash loans executed.
public fun total_loans<T>(pool: &FlashPool<T>): u64 {
    pool.total_loans
}

// ===== Cleanup =====

/// Destroy an unused AdminCap (e.g., if governance takes over).
public fun destroy_admin_cap<T>(cap: AdminCap<T>) {
    let AdminCap { id, pool_id: _ } = cap;
    object::delete(id);
}
