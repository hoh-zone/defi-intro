/// UNSAFE oracle — demonstrates vulnerability to price manipulation
/// DO NOT use this pattern in production!
module attack_defense::unsafe_oracle;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

const EInsufficientLiquidity: u64 = 0;
const EInvalidAmount: u64 = 1;
const EPoolPaused: u64 = 2;

public struct Pool<phantom A, phantom B> has key {
    id: UID,
    reserve_a: Balance<A>,
    reserve_b: Balance<B>,
    paused: bool,
}

/// Create pool — VULNERABLE: price is just reserve ratio
public fun create_pool<A, B>(coin_a: Coin<A>, coin_b: Coin<B>, ctx: &mut TxContext) {
    let pool = Pool {
        id: object::new(ctx),
        reserve_a: coin::into_balance(coin_a),
        reserve_b: coin::into_balance(coin_b),
        paused: false,
    };
    transfer::share_object(pool);
}

/// UNSAFE: reads price directly from reserve ratio
/// A flash loan attacker can drain one side, manipulate price, then exploit
public fun get_price_unsafe<A, B>(pool: &Pool<A, B>): u64 {
    let reserve_a = balance::value(&pool.reserve_a);
    let reserve_b = balance::value(&pool.reserve_b);
    if (reserve_a == 0) { return 0 };
    reserve_b * 1_000_000 / reserve_a
}

/// Swap without TWAP validation — vulnerable to sandwich attacks
public fun swap_a_to_b_unsafe<A, B>(pool: &mut Pool<A, B>, coin_in: Coin<A>, min_out: u64, ctx: &mut TxContext): Coin<B> {
    assert!(!pool.paused, EPoolPaused);
    let amount_in = coin::value(&coin_in);
    assert!(amount_in > 0, EInvalidAmount);

    let reserve_a = balance::value(&pool.reserve_a);
    let reserve_b = balance::value(&pool.reserve_b);
    let amount_out = amount_in * reserve_b / (reserve_a + amount_in);
    assert!(amount_out >= min_out, EInsufficientLiquidity);
    assert!(amount_out <= reserve_b, EInsufficientLiquidity);

    balance::join(&mut pool.reserve_a, coin::into_balance(coin_in));
    coin::take(&mut pool.reserve_b, amount_out, ctx)
}

public fun reserve_a<A, B>(pool: &Pool<A, B>): u64 { balance::value(&pool.reserve_a) }
public fun reserve_b<A, B>(pool: &Pool<A, B>): u64 { balance::value(&pool.reserve_b) }

#[test_only]
public fun create_pool_for_testing<A, B>(coin_a: Coin<A>, coin_b: Coin<B>, ctx: &mut TxContext): Pool<A, B> {
    Pool {
        id: object::new(ctx),
        reserve_a: coin::into_balance(coin_a),
        reserve_b: coin::into_balance(coin_b),
        paused: false,
    }
}

#[test_only]
public fun destroy_pool_for_testing<A, B>(pool: Pool<A, B>, ctx: &mut TxContext) {
    let Pool { id, mut reserve_a, mut reserve_b, paused: _ } = pool;
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
