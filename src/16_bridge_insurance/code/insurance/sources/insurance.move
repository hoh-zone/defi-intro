/// Module: insurance
/// On-chain insurance contract for DeFi risk coverage.
/// Users purchase policies by paying premiums; liquidity providers supply coverage capital.
/// Claims are simplified (no oracle) for educational purposes.
module insurance::insurance;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;

// ===== Constants =====

/// Basis points divisor (100 bps = 1%).
const BPS_DIVISOR: u64 = 10000;
/// Milliseconds in one year (365 * 24 * 3600 * 1000).
const MS_PER_YEAR: u64 = 365 * 24 * 3600 * 1000;

// ===== Objects =====

/// Shared insurance pool holding premium and coverage balances.
public struct InsurancePool<phantom Token> has key, store {
    id: UID,
    /// Collected premiums (revenue for liquidity providers).
    premium_pool: Balance<Token>,
    /// Capital reserved for paying out claims.
    coverage_pool: Balance<Token>,
    /// Total active coverage across all policies.
    total_coverage: u64,
    /// Premium rate in basis points per year (e.g. 300 = 3% annual rate).
    premium_rate_bps: u64,
    /// Maximum coverage amount a single user can purchase.
    max_coverage_per_user: u64,
    /// Whether the pool is currently paused.
    paused: bool,
}

/// Owned policy object representing a user's insurance coverage.
public struct Policy<phantom Token> has key, store {
    id: UID,
    /// Amount of coverage (max claim payout).
    coverage_amount: u64,
    /// Total premium paid for this policy.
    premium_paid: u64,
    /// Timestamp (ms) when the policy becomes active.
    start_time: u64,
    /// Duration of coverage in milliseconds.
    duration_ms: u64,
    /// Whether the policy is still active.
    active: bool,
}

/// Owned capability granting admin privileges.
public struct AdminCap has key, store {
    id: UID,
}

// ===== Events =====

/// Emitted when coverage capital is added to the pool.
public struct CoverageProvided has copy, drop {
    pool_id: ID,
    amount: u64,
}

/// Emitted when a user purchases an insurance policy.
public struct PolicyPurchased has copy, drop {
    pool_id: ID,
    policy_id: ID,
    coverage_amount: u64,
    premium_paid: u64,
    duration_ms: u64,
}

/// Emitted when a claim is paid out.
public struct ClaimPaid has copy, drop {
    pool_id: ID,
    policy_id: ID,
    claim_amount: u64,
}

/// Emitted when a policy expires.
public struct PolicyExpired has copy, drop {
    pool_id: ID,
    policy_id: ID,
}

/// Emitted when an admin withdraws collected premiums.
public struct PremiumsWithdrawn has copy, drop {
    pool_id: ID,
    amount: u64,
    recipient: address,
}

// ===== Pool creation =====

/// Create the insurance pool and AdminCap.
/// `premium_rate_bps` is the annual premium rate in basis points.
/// `max_coverage_per_user` is the cap on coverage per policy.
/// This is a separate function (not module init) because it takes config parameters.
public fun create_pool<Token>(
    premium_rate_bps: u64,
    max_coverage_per_user: u64,
    ctx: &mut TxContext,
) {
    assert!(premium_rate_bps > 0 && premium_rate_bps <= BPS_DIVISOR, EInvalidRate);
    assert!(max_coverage_per_user > 0, EZeroAmount);

    let pool = InsurancePool<Token> {
        id: object::new(ctx),
        premium_pool: balance::zero(),
        coverage_pool: balance::zero(),
        total_coverage: 0,
        premium_rate_bps,
        max_coverage_per_user,
        paused: false,
    };
    transfer::public_share_object(pool);

    let cap = AdminCap { id: object::new(ctx) };
    transfer::public_transfer(cap, ctx.sender());
}

// ===== Admin / LP functions =====

/// Add coverage capital to the pool. Only the AdminCap holder can call this.
public fun provide_coverage<Token>(
    _cap: &AdminCap,
    pool: &mut InsurancePool<Token>,
    coverage_coin: Coin<Token>,
) {
    assert!(!pool.paused, EPoolPaused);

    let amount = coin::value(&coverage_coin);
    assert!(amount > 0, EZeroAmount);

    let coin_balance = coin::into_balance(coverage_coin);
    balance::join(&mut pool.coverage_pool, coin_balance);

    event::emit(CoverageProvided {
        pool_id: object::id(pool),
        amount,
    });
}

/// Withdraw collected premiums. Only the AdminCap holder can call this.
public fun withdraw_premiums<Token>(
    _cap: &AdminCap,
    pool: &mut InsurancePool<Token>,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(!pool.paused, EPoolPaused);

    let available = balance::value(&pool.premium_pool);
    assert!(available >= amount, EInsufficientPremiums);
    assert!(amount > 0, EZeroAmount);

    let withdrawn = balance::split(&mut pool.premium_pool, amount);
    let premium_coin = coin::from_balance(withdrawn, ctx);
    transfer::public_transfer(premium_coin, ctx.sender());

    event::emit(PremiumsWithdrawn {
        pool_id: object::id(pool),
        amount,
        recipient: ctx.sender(),
    });
}

// ===== User functions =====

/// Purchase an insurance policy by paying a premium.
/// `current_ms` is the current timestamp in milliseconds (from clock.timestamp_ms()).
/// The premium is calculated as:
///   premium = coverage_amount * premium_rate_bps / 10000 * duration_ms / ms_per_year
public fun purchase_policy<Token>(
    pool: &mut InsurancePool<Token>,
    coverage_amount: u64,
    premium_coin: Coin<Token>,
    duration_ms: u64,
    current_ms: u64,
    ctx: &mut TxContext,
) {
    assert!(!pool.paused, EPoolPaused);
    assert!(coverage_amount > 0, EZeroAmount);
    assert!(duration_ms > 0, EZeroDuration);
    assert!(coverage_amount <= pool.max_coverage_per_user, EExceedsMaxCoverage);

    // Calculate required premium
    let expected_premium = calculate_premium(coverage_amount, pool.premium_rate_bps, duration_ms);
    let paid = coin::value(&premium_coin);
    assert!(paid >= expected_premium, EInsufficientPremium);

    // Ensure coverage pool has enough capital to back this policy
    let coverage_available = balance::value(&pool.coverage_pool);
    assert!(coverage_available >= coverage_amount, EInsufficientCoverage);

    // Absorb the premium
    let premium_balance = coin::into_balance(premium_coin);
    balance::join(&mut pool.premium_pool, premium_balance);

    // Increase total coverage
    pool.total_coverage = pool.total_coverage + coverage_amount;

    // Create the policy object
    let policy = Policy<Token> {
        id: object::new(ctx),
        coverage_amount,
        premium_paid: paid,
        start_time: current_ms,
        duration_ms,
        active: true,
    };

    let policy_id = object::id(&policy);

    event::emit(PolicyPurchased {
        pool_id: object::id(pool),
        policy_id,
        coverage_amount,
        premium_paid: paid,
        duration_ms,
    });

    transfer::public_transfer(policy, ctx.sender());
}

/// File a claim against an active policy.
/// In production this would require oracle verification or governance approval.
/// Simplified: any active policy holder can claim up to their coverage amount.
public fun claim<Token>(
    pool: &mut InsurancePool<Token>,
    policy: &mut Policy<Token>,
    claim_amount: u64,
    ctx: &mut TxContext,
) {
    assert!(!pool.paused, EPoolPaused);
    assert!(policy.active, EPolicyNotActive);
    assert!(claim_amount > 0, EZeroAmount);
    assert!(claim_amount <= policy.coverage_amount, EClaimExceedsCoverage);

    // Ensure coverage pool has funds
    let coverage_available = balance::value(&pool.coverage_pool);
    assert!(coverage_available >= claim_amount, EInsufficientCoverage);

    // Pay out from coverage pool
    let withdrawn = balance::split(&mut pool.coverage_pool, claim_amount);
    let payout_coin = coin::from_balance(withdrawn, ctx);
    transfer::public_transfer(payout_coin, ctx.sender());

    // Reduce coverage amount and total coverage
    policy.coverage_amount = policy.coverage_amount - claim_amount;
    pool.total_coverage = pool.total_coverage - claim_amount;

    // If full coverage is claimed, deactivate the policy
    if (policy.coverage_amount == 0) {
        policy.active = false;
    };

    event::emit(ClaimPaid {
        pool_id: object::id(pool),
        policy_id: object::id(policy),
        claim_amount,
    });
}

/// Mark a policy as expired after its duration has elapsed.
/// `current_ms` is the current timestamp (from clock.timestamp_ms()).
public fun expire_policy<Token>(
    pool: &mut InsurancePool<Token>,
    policy: &mut Policy<Token>,
    current_ms: u64,
) {
    assert!(policy.active, EPolicyNotActive);

    let expiry = policy.start_time + policy.duration_ms;
    assert!(current_ms >= expiry, EPolicyNotExpired);

    pool.total_coverage = pool.total_coverage - policy.coverage_amount;
    policy.coverage_amount = 0;
    policy.active = false;

    event::emit(PolicyExpired {
        pool_id: object::id(pool),
        policy_id: object::id(policy),
    });
}

// ===== View functions =====

/// Read the total coverage across all active policies.
public fun total_coverage<Token>(pool: &InsurancePool<Token>): u64 {
    pool.total_coverage
}

/// Read the available coverage pool balance.
public fun coverage_pool_value<Token>(pool: &InsurancePool<Token>): u64 {
    balance::value(&pool.coverage_pool)
}

/// Read the collected premiums balance.
public fun premium_pool_value<Token>(pool: &InsurancePool<Token>): u64 {
    balance::value(&pool.premium_pool)
}

/// Check if the pool is paused.
public fun is_paused<Token>(pool: &InsurancePool<Token>): bool {
    pool.paused
}

// ===== Policy view functions =====

/// Read the coverage amount of a policy.
public fun policy_coverage_amount<Token>(policy: &Policy<Token>): u64 {
    policy.coverage_amount
}

/// Check if a policy is still active.
public fun policy_active<Token>(policy: &Policy<Token>): bool {
    policy.active
}

/// Read the start time of a policy.
public fun policy_start_time<Token>(policy: &Policy<Token>): u64 {
    policy.start_time
}

/// Calculate the premium for a given coverage amount and duration.
/// Formula: coverage_amount * premium_rate_bps / BPS_DIVISOR * duration_ms / MS_PER_YEAR
public fun calculate_premium(coverage_amount: u64, premium_rate_bps: u64, duration_ms: u64): u64 {
    // Do multiplication first to avoid truncation, then divide
    // coverage_amount * premium_rate_bps / BPS_DIVISOR gives annual premium
    // then * duration_ms / MS_PER_YEAR prorates it
    let annual_premium = coverage_amount * premium_rate_bps / BPS_DIVISOR;
    annual_premium * duration_ms / MS_PER_YEAR
}

// ===== Pause controls =====

/// Pause the insurance pool.
public fun pause<Token>(_cap: &AdminCap, pool: &mut InsurancePool<Token>) {
    pool.paused = true;
}

/// Unpause the insurance pool.
public fun unpause<Token>(_cap: &AdminCap, pool: &mut InsurancePool<Token>) {
    pool.paused = false;
}

// ===== Error constants =====

#[error]
const EZeroAmount: vector<u8> = b"Zero Amount";
#[error]
const EZeroDuration: vector<u8> = b"Zero Duration";
#[error]
const EInvalidRate: vector<u8> = b"Invalid Rate";
#[error]
const EExceedsMaxCoverage: vector<u8> = b"Exceeds Max Coverage";
#[error]
const EInsufficientPremium: vector<u8> = b"Insufficient Premium";
#[error]
const EInsufficientCoverage: vector<u8> = b"Insufficient Coverage";
#[error]
const EInsufficientPremiums: vector<u8> = b"Insufficient Premiums";
#[error]
const EPolicyNotActive: vector<u8> = b"Policy Not Active";
#[error]
const EClaimExceedsCoverage: vector<u8> = b"Claim Exceeds Coverage";
#[error]
const EPolicyNotExpired: vector<u8> = b"Policy Not Expired";
#[error]
const EPoolPaused: vector<u8> = b"Pool Paused";
