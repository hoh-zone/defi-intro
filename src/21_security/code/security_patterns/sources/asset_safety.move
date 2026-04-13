module security_patterns::asset_safety;
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

#[error]
const EUnauthorized: vector<u8> = b"Unauthorized";
#[error]
const EInvariantViolated: vector<u8> = b"Invariant Violated";
#[error]
const EInsufficientBalance: vector<u8> = b"Insufficient Balance";

public struct SecurePool<phantom T> has key {
    id: UID,
    balance: Balance<T>,
    total_deposits: u64,
    total_withdrawals: u64,
}

public struct PoolCap has key, store {
    id: UID,
    pool_id: ID,
}

public fun create_pool<T>(ctx: &mut TxContext): PoolCap {
    let pool = SecurePool<T> {
        id: object::new(ctx),
        balance: balance::zero(),
        total_deposits: 0,
        total_withdrawals: 0,
    };
    let pool_id = object::id(&pool);
    transfer::share_object(pool);
    PoolCap { id: object::new(ctx), pool_id }
}

/// Deposit and track
public fun deposit<T>(pool: &mut SecurePool<T>, coin: Coin<T>) {
    let amount = coin::value(&coin);
    balance::join(&mut pool.balance, coin::into_balance(coin));
    pool.total_deposits = pool.total_deposits + amount;
}

/// Withdraw with invariant check
public fun withdraw<T>(cap: &PoolCap, pool: &mut SecurePool<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    assert!(object::id(pool) == cap.pool_id, EUnauthorized);
    check_invariant(pool);
    assert!(balance::value(&pool.balance) >= amount, EInsufficientBalance);
    pool.total_withdrawals = pool.total_withdrawals + amount;
    coin::take(&mut pool.balance, amount, ctx)
}

/// Check: actual balance == total_deposits - total_withdrawals
public fun check_invariant<T>(pool: &SecurePool<T>) {
    let expected = pool.total_deposits - pool.total_withdrawals;
    let actual = balance::value(&pool.balance);
    assert!(actual >= expected, EInvariantViolated);
}

/// Sweep any dust (tokens sent directly to pool object)
public fun sweep_dust<T>(cap: &PoolCap, pool: &mut SecurePool<T>, ctx: &mut TxContext): Coin<T> {
    assert!(object::id(pool) == cap.pool_id, EUnauthorized);
    let expected = pool.total_deposits - pool.total_withdrawals;
    let actual = balance::value(&pool.balance);
    let dust = actual - expected;
    assert!(dust > 0, EInsufficientBalance);
    // Adjust deposits so invariant holds after sweep
    pool.total_deposits = pool.total_deposits - dust;
    coin::take(&mut pool.balance, dust, ctx)
}

public fun balance<T>(pool: &SecurePool<T>): u64 { balance::value(&pool.balance) }
public fun total_deposits<T>(pool: &SecurePool<T>): u64 { pool.total_deposits }
public fun total_withdrawals<T>(pool: &SecurePool<T>): u64 { pool.total_withdrawals }
