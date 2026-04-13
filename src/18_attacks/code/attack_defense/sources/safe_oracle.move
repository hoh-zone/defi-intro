/// SAFE oracle — uses TWAP and deviation checks to resist manipulation
module attack_defense::safe_oracle;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

#[error]
const EInsufficientLiquidity: vector<u8> = b"Insufficient Liquidity";
#[error]
const EInvalidAmount: vector<u8> = b"Invalid Amount";
#[error]
const EPoolPaused: vector<u8> = b"Pool Paused";
#[error]
const EPriceDeviation: vector<u8> = b"Price Deviation";

public struct Observation has copy, drop, store {
    timestamp: u64,
    price: u64,
    cumulative_price: u128,
}

public struct SafePool<phantom A, phantom B> has key {
    id: UID,
    reserve_a: Balance<A>,
    reserve_b: Balance<B>,
    observations: vector<Observation>,
    paused: bool,
}

public fun create_pool<A, B>(coin_a: Coin<A>, coin_b: Coin<B>, ctx: &mut TxContext) {
    let price = coin::value(&coin_b) * 1_000_000 / coin::value(&coin_a);
    let pool = SafePool {
        id: object::new(ctx),
        reserve_a: coin::into_balance(coin_a),
        reserve_b: coin::into_balance(coin_b),
        observations: vector[Observation { timestamp: 0, price, cumulative_price: 0 }],
        paused: false,
    };
    transfer::share_object(pool);
}

/// Record a price observation (call after each swap)
fun record_observation<A, B>(pool: &mut SafePool<A, B>, timestamp: u64) {
    let reserve_a = balance::value(&pool.reserve_a);
    let reserve_b = balance::value(&pool.reserve_b);
    let spot_price = if (reserve_a == 0) { 0u64 } else { reserve_b * 1_000_000 / reserve_a };

    let last = pool.observations[pool.observations.length() - 1];
    let elapsed = if (timestamp > last.timestamp) { timestamp - last.timestamp } else { 0 };
    let new_cum = last.cumulative_price + (spot_price as u128) * (elapsed as u128);

    pool.observations.push_back(Observation {
        timestamp,
        price: spot_price,
        cumulative_price: new_cum,
    });

    // Keep only last 100 observations
    if (pool.observations.length() > 100) {
        pool.observations.swap_remove(0);
    };
}

/// TWAP: time-weighted average price over period
/// Resistant to flash loan manipulation (single-block price spike has minimal impact)
public fun get_twap_price<A, B>(pool: &SafePool<A, B>, period_ms: u64, current_ms: u64): u64 {
    let cutoff = if (current_ms > period_ms) { current_ms - period_ms } else { 0 };
    let len = pool.observations.length();
    if (len == 0) { return 0 };

    // Find first observation at or after cutoff
    let mut idx = 0;
    while (idx < len && pool.observations[idx].timestamp < cutoff) {
        idx = idx + 1;
    };
    if (idx >= len) { return pool.observations[len - 1].price };

    let cum_start = pool.observations[idx].cumulative_price;
    let cum_end = pool.observations[len - 1].cumulative_price;
    let ts_start = pool.observations[idx].timestamp;
    let ts_end = pool.observations[len - 1].timestamp;

    let dt = ts_end - ts_start;
    if (dt == 0) { return pool.observations[len - 1].price };
    ((cum_end - cum_start) / (dt as u128)) as u64
}

/// Validate that spot price doesn't deviate too much from TWAP
public fun validate_price_deviation(twap_price: u64, spot_price: u64, max_deviation_bps: u64): bool {
    if (twap_price == 0) { return true };
    let diff = if (spot_price > twap_price) { spot_price - twap_price } else { twap_price - spot_price };
    let deviation_bps = diff * 10000 / twap_price;
    deviation_bps <= max_deviation_bps
}

/// SAFE swap: validates against TWAP before executing
public fun swap_safe<A, B>(
    pool: &mut SafePool<A, B>,
    coin_in: Coin<A>,
    min_out: u64,
    twap_period_ms: u64,
    max_deviation_bps: u64,
    current_ms: u64,
    ctx: &mut TxContext,
): Coin<B> {
    assert!(!pool.paused, EPoolPaused);
    let amount_in = coin::value(&coin_in);
    assert!(amount_in > 0, EInvalidAmount);

    let reserve_a = balance::value(&pool.reserve_a);
    let reserve_b = balance::value(&pool.reserve_b);
    let spot_price = reserve_b * 1_000_000 / reserve_a;
    let twap = get_twap_price(pool, twap_period_ms, current_ms);

    // Verify price hasn't been manipulated
    assert!(validate_price_deviation(twap, spot_price, max_deviation_bps), EPriceDeviation);

    let amount_out = amount_in * reserve_b / (reserve_a + amount_in);
    assert!(amount_out >= min_out, EInsufficientLiquidity);

    balance::join(&mut pool.reserve_a, coin::into_balance(coin_in));
    let result = coin::take(&mut pool.reserve_b, amount_out, ctx);
    record_observation(pool, current_ms);
    result
}

public fun spot_price<A, B>(pool: &SafePool<A, B>): u64 {
    let ra = balance::value(&pool.reserve_a);
    let rb = balance::value(&pool.reserve_b);
    if (ra == 0) { return 0 };
    rb * 1_000_000 / ra
}

#[test_only]
public fun create_pool_for_testing<A, B>(coin_a: Coin<A>, coin_b: Coin<B>, ctx: &mut TxContext): SafePool<A, B> {
    let price = coin::value(&coin_b) * 1_000_000 / coin::value(&coin_a);
    SafePool {
        id: object::new(ctx),
        reserve_a: coin::into_balance(coin_a),
        reserve_b: coin::into_balance(coin_b),
        observations: vector[Observation { timestamp: 0, price, cumulative_price: 0 }],
        paused: false,
    }
}

#[test_only]
public fun destroy_pool_for_testing<A, B>(pool: SafePool<A, B>, ctx: &mut TxContext) {
    let SafePool { id, mut reserve_a, mut reserve_b, observations: _, paused: _ } = pool;
    let val_a = balance::value(&reserve_a);
    let val_b = balance::value(&reserve_b);
    if (val_a > 0) {
        let _ca = coin::take(&mut reserve_a, val_a, ctx);
        coin::burn_for_testing(_ca);
    };
    if (val_b > 0) {
        let _cb = coin::take(&mut reserve_b, val_b, ctx);
        coin::burn_for_testing(_cb);
    };
    balance::destroy_zero(reserve_a);
    balance::destroy_zero(reserve_b);
    id.delete();
}
