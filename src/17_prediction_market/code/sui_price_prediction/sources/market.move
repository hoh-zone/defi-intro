/// SUI/USD 10 分钟涨跌预测（教学示例 · Sui Testnet + Pyth）
/// - 创建回合时向涨跌两侧各注入 10 SUI 种子流动性
/// - 用户押注 UP 或 DOWN
/// - 结算用 Pyth SUI/USD 现价对比开盘价；涨跌幅度小于 flat_bps 视为「平盘」不结算（全额退款）
/// - 有胜负时：胜方按押注比例分配两侧池子全部余额（含种子与用户押注）
#[allow(lint(self_transfer), lint(public_entry), duplicate_alias, implicit_const_copy)]
module sui_price_prediction::market;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, ID, UID};
use sui::sui::SUI;
use sui::table::{Self, Table};

use pyth::i64::{Self as pyth_i64, I64};
use pyth::price::{Self as pyth_price, Price};
use pyth::price_identifier;
use pyth::price_info::{Self as price_info};
use pyth::pyth;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MIST_PER_SUI: u64 = 1_000_000_000;
const SEED_PER_SIDE_MIST: u64 = 10 * MIST_PER_SUI;
const SEED_TOTAL_MIST: u64 = 20 * MIST_PER_SUI;
const DEFAULT_DURATION_MS: u64 = 600_000;
const MAX_PRICE_AGE_SECS: u64 = 60;

/// Sui **Testnet** SUI/USD price feed id（32 bytes）
const SUI_USD_PRICE_ID: vector<u8> =
    x"50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266";

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[error]
const E_BAD_SEED: vector<u8> = b"_BAD_SEED";
#[error]
const E_BETTING_CLOSED: vector<u8> = b"_BETTING_CLOSED";
#[error]
const E_ALREADY_SETTLED: vector<u8> = b"_ALREADY_SETTLED";
#[error]
const E_ZERO_BET: vector<u8> = b"_ZERO_BET";
#[error]
const E_INVALID_FEED: vector<u8> = b"_INVALID_FEED";
#[error]
const E_NEGATIVE_PRICE: vector<u8> = b"_NEGATIVE_PRICE";
#[error]
const E_EXPO_MISMATCH: vector<u8> = b"_EXPO_MISMATCH";
#[error]
const E_NOTHING_TO_CLAIM: vector<u8> = b"_NOTHING_TO_CLAIM";
#[error]
const E_NOT_SETTLED: vector<u8> = b"_NOT_SETTLED";
#[error]
const E_TOO_SHORT: vector<u8> = b"_TOO_SHORT";
#[error]
const E_TOO_LONG: vector<u8> = b"_TOO_LONG";
#[error]
const E_NOT_WINNER: vector<u8> = b"_NOT_WINNER";
#[error]
const E_BAD_OUTCOME: vector<u8> = b"_BAD_OUTCOME";

// ---------------------------------------------------------------------------
// Outcome
// ---------------------------------------------------------------------------

const OUTCOME_PENDING: u8 = 0;
const OUTCOME_VOID: u8 = 1;
const OUTCOME_UP: u8 = 2;
const OUTCOME_DOWN: u8 = 3;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

public struct Round has key, store {
    id: UID,
    betting_ends_ms: u64,
    open_mag: u64,
    open_expo: I64,
    flat_bps: u64,
    settled: bool,
    outcome: u8,
    sum_winner_snapshot: u64,
    total_snapshot: u64,
    up_pool: Balance<SUI>,
    down_pool: Balance<SUI>,
    sum_up: u64,
    sum_down: u64,
    stakes_up: Table<address, u64>,
    stakes_down: Table<address, u64>,
}

public struct RoundCreated has copy, drop {
    round_id: ID,
    betting_ends_ms: u64,
    open_mag: u64,
}

public struct Settled has copy, drop {
    round_id: ID,
    outcome: u8,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fun assert_sui_usd_feed(price_info_obj: &price_info::PriceInfoObject) {
    let pinfo = price_info::get_price_info_from_price_info_object(price_info_obj);
    let pid = price_info::get_price_identifier(&pinfo);
    let got = price_identifier::get_bytes(&pid);
    let want = SUI_USD_PRICE_ID;
    assert!(vec_eq_bytes(&got, &want), E_INVALID_FEED);
}

fun vec_eq_bytes(a: &vector<u8>, b: &vector<u8>): bool {
    if (vector::length(a) != vector::length(b)) {
        return false
    };
    let len = vector::length(a);
    let mut i = 0u64;
    while (i < len) {
        if (*vector::borrow(a, i) != *vector::borrow(b, i)) {
            return false
        };
        i = i + 1;
    };
    true
}

fun price_mag(p: &Price): u64 {
    let px = pyth_price::get_price(p);
    assert!(!pyth_i64::get_is_negative(&px), E_NEGATIVE_PRICE);
    pyth_i64::get_magnitude_if_positive(&px)
}

fun i64_eq(a: &I64, b: &I64): bool {
    if (pyth_i64::get_is_negative(a) != pyth_i64::get_is_negative(b)) {
        return false
    };
    if (pyth_i64::get_is_negative(a)) {
        pyth_i64::get_magnitude_if_negative(a) == pyth_i64::get_magnitude_if_negative(b)
    } else {
        pyth_i64::get_magnitude_if_positive(a) == pyth_i64::get_magnitude_if_positive(b)
    }
}

fun open_price_from_round(r: &Round): Price {
    pyth_price::new(pyth_i64::new(r.open_mag, false), 0, r.open_expo, 0)
}

/// 返回 OUTCOME_VOID / OUTCOME_UP / OUTCOME_DOWN（用 u8 存）
fun classify(open_p: &Price, close_p: &Price, flat_bps: u64): u8 {
    let eo = pyth_price::get_expo(open_p);
    let ec = pyth_price::get_expo(close_p);
    assert!(i64_eq(&eo, &ec), E_EXPO_MISMATCH);
    let o = price_mag(open_p);
    let c = price_mag(close_p);
    if (c == o) {
        return OUTCOME_VOID
    };
    let diff = if (c > o) {
        c - o
    } else {
        o - c
    };
    let lhs = (diff as u128) * 10_000u128;
    let rhs = (o as u128) * (flat_bps as u128);
    if (lhs < rhs) {
        return OUTCOME_VOID
    };
    if (c > o) {
        OUTCOME_UP
    } else {
        OUTCOME_DOWN
    }
}

/// 从两侧金库取出 `amount` MIST（先 up 再 down）
fun take_from_pools(
    up: &mut Balance<SUI>,
    down: &mut Balance<SUI>,
    amount: u64,
    ctx: &mut tx_context::TxContext,
): Coin<SUI> {
    let vu = balance::value(up);
    if (vu >= amount) {
        return coin::from_balance(balance::split(up, amount), ctx)
    };
    let mut c = if (vu > 0) {
        coin::from_balance(balance::split(up, vu), ctx)
    } else {
        coin::zero<SUI>(ctx)
    };
    let need = amount - vu;
    let got = coin::from_balance(balance::split(down, need), ctx);
    coin::join(&mut c, got);
    c
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

public fun create_round(
    seed: Coin<SUI>,
    clock: &Clock,
    price_info_obj: &price_info::PriceInfoObject,
    flat_bps: u64,
    duration_ms: u64,
    ctx: &mut tx_context::TxContext,
) {
    assert!(coin::value(&seed) == SEED_TOTAL_MIST, E_BAD_SEED);
    assert!(duration_ms >= 60_000, E_TOO_SHORT);
    assert!(duration_ms <= 86_400_000, E_TOO_LONG);

    assert_sui_usd_feed(price_info_obj);
    let px = pyth::get_price_no_older_than(price_info_obj, clock, MAX_PRICE_AGE_SECS);
    let mag = price_mag(&px);
    let expo = pyth_price::get_expo(&px);

    let mut c = seed;
    let upc = coin::split(&mut c, SEED_PER_SIDE_MIST, ctx);
    let downc = coin::split(&mut c, SEED_PER_SIDE_MIST, ctx);
    assert!(coin::value(&c) == 0);
    coin::destroy_zero(c);

    let now = clock::timestamp_ms(clock);
    let id = object::new(ctx);
    let round_id = object::uid_to_inner(&id);
    let r = Round {
        id,
        betting_ends_ms: now + duration_ms,
        open_mag: mag,
        open_expo: expo,
        flat_bps,
        settled: false,
        outcome: OUTCOME_PENDING,
        sum_winner_snapshot: 0,
        total_snapshot: 0,
        up_pool: coin::into_balance(upc),
        down_pool: coin::into_balance(downc),
        sum_up: 0,
        sum_down: 0,
        stakes_up: table::new(ctx),
        stakes_down: table::new(ctx),
    };
    event::emit(RoundCreated {
        round_id,
        betting_ends_ms: r.betting_ends_ms,
        open_mag: mag,
    });
    transfer::public_share_object(r);
}

public fun create_round_default(
    seed: Coin<SUI>,
    clock: &Clock,
    price_info_obj: &price_info::PriceInfoObject,
    flat_bps: u64,
    ctx: &mut tx_context::TxContext,
) {
    create_round(seed, clock, price_info_obj, flat_bps, DEFAULT_DURATION_MS, ctx);
}

public fun bet_up(
    round: &mut Round,
    coin_in: Coin<SUI>,
    clock: &Clock,
    ctx: &tx_context::TxContext,
) {
    bet(round, coin_in, clock, ctx, true);
}

public fun bet_down(
    round: &mut Round,
    coin_in: Coin<SUI>,
    clock: &Clock,
    ctx: &tx_context::TxContext,
) {
    bet(round, coin_in, clock, ctx, false);
}

fun bet(
    round: &mut Round,
    coin_in: Coin<SUI>,
    clock: &Clock,
    ctx: &tx_context::TxContext,
    is_up: bool,
) {
    assert!(!round.settled, E_ALREADY_SETTLED);
    assert!(clock::timestamp_ms(clock) <= round.betting_ends_ms, E_BETTING_CLOSED);
    let v = coin::value(&coin_in);
    assert!(v > 0, E_ZERO_BET);
    let sender = tx_context::sender(ctx);
    if (is_up) {
        round.sum_up = round.sum_up + v;
        if (table::contains(&round.stakes_up, sender)) {
            let cur = *table::borrow(&round.stakes_up, sender);
            *table::borrow_mut(&mut round.stakes_up, sender) = cur + v;
        } else {
            table::add(&mut round.stakes_up, sender, v);
        };
        balance::join(&mut round.up_pool, coin::into_balance(coin_in));
    } else {
        round.sum_down = round.sum_down + v;
        if (table::contains(&round.stakes_down, sender)) {
            let cur = *table::borrow(&round.stakes_down, sender);
            *table::borrow_mut(&mut round.stakes_down, sender) = cur + v;
        } else {
            table::add(&mut round.stakes_down, sender, v);
        };
        balance::join(&mut round.down_pool, coin::into_balance(coin_in));
    };
}

public fun settle(round: &mut Round, clock: &Clock, price_info_obj: &price_info::PriceInfoObject) {
    assert!(!round.settled, E_ALREADY_SETTLED);
    assert!(clock::timestamp_ms(clock) > round.betting_ends_ms, E_BETTING_CLOSED);

    assert_sui_usd_feed(price_info_obj);
    let close_px = pyth::get_price_no_older_than(price_info_obj, clock, MAX_PRICE_AGE_SECS);

    let open_px = open_price_from_round(round);
    let mut ocode = classify(&open_px, &close_px, round.flat_bps);

    let tu = balance::value(&round.up_pool);
    let td = balance::value(&round.down_pool);
    let total = tu + td;

    round.settled = true;
    // 若判定涨/跌但胜方无人押注，改为平盘（全额退款），避免资金锁死
    if (ocode == OUTCOME_UP && round.sum_up == 0) {
        ocode = OUTCOME_VOID;
    };
    if (ocode == OUTCOME_DOWN && round.sum_down == 0) {
        ocode = OUTCOME_VOID;
    };

    if (ocode == OUTCOME_VOID) {
        round.outcome = OUTCOME_VOID;
        round.sum_winner_snapshot = 0;
        round.total_snapshot = 0;
    } else if (ocode == OUTCOME_UP) {
        round.outcome = OUTCOME_UP;
        round.sum_winner_snapshot = round.sum_up;
        round.total_snapshot = total;
    } else {
        round.outcome = OUTCOME_DOWN;
        round.sum_winner_snapshot = round.sum_down;
        round.total_snapshot = total;
    };

    event::emit(Settled {
        round_id: object::uid_to_inner(&round.id),
        outcome: round.outcome,
    });
}

/// 胜方领取：`stake * total_snapshot / sum_winner_snapshot`
public fun claim_winner(round: &mut Round, ctx: &mut tx_context::TxContext) {
    assert!(round.settled, E_NOT_SETTLED);
    let o = round.outcome;
    assert!(o == OUTCOME_UP || o == OUTCOME_DOWN, E_BAD_OUTCOME);

    let sender = tx_context::sender(ctx);
    let stake = if (o == OUTCOME_UP) {
        assert!(table::contains(&round.stakes_up, sender), E_NOT_WINNER);
        let s = *table::borrow(&round.stakes_up, sender);
        assert!(s > 0, E_NOTHING_TO_CLAIM);
        table::remove(&mut round.stakes_up, sender);
        s
    } else {
        assert!(table::contains(&round.stakes_down, sender), E_NOT_WINNER);
        let s = *table::borrow(&round.stakes_down, sender);
        assert!(s > 0, E_NOTHING_TO_CLAIM);
        table::remove(&mut round.stakes_down, sender);
        s
    };

    let sum = round.sum_winner_snapshot;
    let tot = round.total_snapshot;
    let pay = ((stake as u128) * (tot as u128) / (sum as u128)) as u64;

    let coin_out = take_from_pools(&mut round.up_pool, &mut round.down_pool, pay, ctx);
    transfer::public_transfer(coin_out, sender);
}

/// 平盘退款：分别退回用户在 UP/DOWN 的押注
public fun claim_void_refund(round: &mut Round, ctx: &mut tx_context::TxContext) {
    assert!(round.settled, E_NOT_SETTLED);
    assert!(round.outcome == OUTCOME_VOID, E_BAD_OUTCOME);
    let sender = tx_context::sender(ctx);
    let mut total = 0u64;
    if (table::contains(&round.stakes_up, sender)) {
        let su = table::remove(&mut round.stakes_up, sender);
        total = total + su;
    };
    if (table::contains(&round.stakes_down, sender)) {
        let sd = table::remove(&mut round.stakes_down, sender);
        total = total + sd;
    };
    assert!(total > 0, E_NOTHING_TO_CLAIM);

    let coin_out = take_from_pools(&mut round.up_pool, &mut round.down_pool, total, ctx);
    transfer::public_transfer(coin_out, sender);
}

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

public fun betting_ends_ms(r: &Round): u64 {
    r.betting_ends_ms
}

public fun settled(r: &Round): bool {
    r.settled
}

public fun outcome(r: &Round): u8 {
    r.outcome
}

public fun sum_up(r: &Round): u64 {
    r.sum_up
}

public fun sum_down(r: &Round): u64 {
    r.sum_down
}
