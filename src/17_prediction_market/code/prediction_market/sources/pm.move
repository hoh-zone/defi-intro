/// Prediction market (binary YES/NO) with:
/// - Conditional-token style split/merge on a user `Position`
/// - LMSR cost for trading against the automated market maker
/// - Resolution + optional challenge window + claim
///
/// Collateral is generic `Coin<T>`. LMSR uses WAD-fixed math (1e9).
/// This is teaching-grade code: tune `b`, fee, and time windows before mainnet use.
#[allow(lint(self_transfer))]
module prediction_market::pm;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const WAD: u128 = 1_000_000_000;
const LN2_WAD: u128 = 693_147_180; // ln(2) * 1e9
const BPS_DENOM: u64 = 10_000;
const U64_MAX: u128 = 18446744073709551615;

const STATUS_TRADING: u8 = 0;
const STATUS_RESOLVED: u8 = 1;

const OUTCOME_NONE: u8 = 0;
const OUTCOME_YES: u8 = 1;
const OUTCOME_NO: u8 = 2;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[error]
const ENotResolved: vector<u8> = b"Not Resolved";

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

/// Shared market. `q_yes`/`q_no` are LMSR share units (same dimension as outcome inventory).
public struct Market<phantom T> has key, store {
    id: UID,
    /// LMSR liquidity parameter (same units as q); larger => deeper book, larger worst-case loss.
    b: u64,
    q_yes: u64,
    q_no: u64,
    vault: Balance<T>,
    fee_bps: u64,
    trading_closes_ms: u64,
    challenge_window_ms: u64,
    resolved: u8,
    winning_outcome: u8,
    proposed_outcome: u8,
    proposal_time_ms: u64,
    challenger: address,
    challenge_stake: Balance<T>,
}

/// User position: conditional-token balances (full-set invariant maintained by split/merge).
public struct Position has key, store {
    id: UID,
    market_id: ID,
    yes: u64,
    no: u64,
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

public struct MarketCreated has copy, drop {
    market_id: ID,
    b: u64,
    trading_closes_ms: u64,
}

public struct Traded has copy, drop {
    market_id: ID,
    side_is_yes: bool,
    shares: u64,
    collateral_paid: u64,
}

public struct SplitEvent has copy, drop {
    market_id: ID,
    amount: u64,
}

public struct MergeEvent has copy, drop {
    market_id: ID,
    amount: u64,
}

public struct Resolved has copy, drop {
    market_id: ID,
    outcome: u8,
}

// ---------------------------------------------------------------------------
// LMSR math (WAD = 1e9)
// ---------------------------------------------------------------------------

/// e^(x/WAD) in WAD scale, x >= 0, x <= ~30*WAD for convergence.
fun exp_pos_wad(x: u128): u128 {
    let mut s = WAD;
    let mut t = WAD;
    let mut i = 1u64;
    while (i <= 30) {
        t = t * x / ((i as u128) * WAD);
        s = s + t;
        i = i + 1;
    };
    s
}

/// e^(-d/WAD) in WAD scale.
fun exp_neg_wad(d: u64): u128 {
    if (d == 0) {
        return WAD
    };
    let ex = exp_pos_wad(d as u128);
    WAD * WAD / ex
}

/// ln(1 + y/WAD) expressed as fixed-point: returns value R such that real ln(1+y/WAD) ≈ R/WAD.
fun ln1p_ratio_wad(y: u128): u128 {
    // Taylor: ln(1+u) = Σ (-1)^{k+1} u^k/k for u = y/WAD, u ∈ (0,1]
    let mut term = y;
    let mut acc = term;
    let mut k = 2u64;
    while (k <= 120) {
        term = term * y / WAD;
        if (k % 2 == 0) {
            acc = acc - term / (k as u128);
        } else {
            acc = acc + term / (k as u128);
        };
        k = k + 1;
    };
    acc
}

/// ln(1 + e^{-d}) where d = |a-b| in WAD units (a,b are q/b scaled).
fun log1p_exp_neg(diff_wad: u64): u128 {
    if (diff_wad == 0) {
        return LN2_WAD
    };
    if (diff_wad > 50_000_000_000) {
        return 0
    };
    let e = exp_neg_wad(diff_wad);
    ln1p_ratio_wad(e)
}

/// LSE = ln(e^{qy/b} + e^{qn/b}) in WAD (natural log scaled).
fun lse_wad(qy: u64, qn: u64, b: u64): u128 {
    assert!(b > 0);
    let ay = (qy as u128) * WAD / (b as u128);
    let an = (qn as u128) * WAD / (b as u128);
    let max_ac = if (ay >= an) { ay } else { an };
    let diff = if (ay >= an) { ay - an } else { an - ay };
    let d = if (diff > U64_MAX) {
        18446744073709551615u64
    } else {
        (diff as u64)
    };
    max_ac + log1p_exp_neg(d)
}

/// C(q) = b * LSE(q) — returns collateral cost in raw units (same scale as `b` and q).
fun cost_state(qy: u64, qn: u64, b: u64): u128 {
    let l = lse_wad(qy, qn, b);
    (b as u128) * l / WAD
}

fun fee_on(amount: u64, fee_bps: u64): u64 {
    ((amount as u128) * (fee_bps as u128) / (BPS_DENOM as u128)) as u64
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

public fun create_market<T>(
    b: u64,
    initial_seed: Coin<T>,
    fee_bps: u64,
    trading_closes_ms: u64,
    challenge_window_ms: u64,
    ctx: &mut TxContext,
) {
    assert!(b > 0);
    let id = object::new(ctx);
    let market_id = object::uid_to_inner(&id);
    let bal = coin::into_balance(initial_seed);
    let m = Market<T> {
        id,
        b,
        q_yes: 0,
        q_no: 0,
        vault: bal,
        fee_bps,
        trading_closes_ms,
        challenge_window_ms,
        resolved: STATUS_TRADING,
        winning_outcome: OUTCOME_NONE,
        proposed_outcome: OUTCOME_NONE,
        proposal_time_ms: 0,
        challenger: @0x0,
        challenge_stake: balance::zero(),
    };
    event::emit(MarketCreated { market_id, b, trading_closes_ms });
    transfer::public_share_object(m);
}

public fun new_position<T>(market: &Market<T>, ctx: &mut TxContext): Position {
    Position {
        id: object::new(ctx),
        market_id: object::id(market),
        yes: 0,
        no: 0,
    }
}

/// Split: 1 collateral -> 1 YES + 1 NO (full set).
public fun split<T>(
    market: &mut Market<T>,
    pos: &mut Position,
    coin_in: Coin<T>,
    _ctx: &mut TxContext,
) {
    assert!(object::id(market) == pos.market_id);
    let amt = coin::value(&coin_in);
    assert!(amt > 0);
    balance::join(&mut market.vault, coin::into_balance(coin_in));
    pos.yes = pos.yes + amt;
    pos.no = pos.no + amt;
    event::emit(SplitEvent { market_id: object::id(market), amount: amt });
}

/// Merge: 1 YES + 1 NO -> 1 collateral.
public fun merge<T>(
    market: &mut Market<T>,
    pos: &mut Position,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(object::id(market) == pos.market_id);
    assert!(amount > 0);
    assert!(pos.yes >= amount && pos.no >= amount);
    pos.yes = pos.yes - amount;
    pos.no = pos.no - amount;
    let out = balance::split(&mut market.vault, amount);
    let c = coin::from_balance(out, ctx);
    transfer::public_transfer(c, ctx.sender());
    event::emit(MergeEvent { market_id: object::id(market), amount });
}

/// Buy YES shares (increases `q_yes` by `shares` LMSR units).
public fun buy_yes<T>(
    market: &mut Market<T>,
    coin_in: Coin<T>,
    shares: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    buy_internal(market, coin_in, shares, true, clock, ctx);
}

/// Buy NO shares.
public fun buy_no<T>(
    market: &mut Market<T>,
    coin_in: Coin<T>,
    shares: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    buy_internal(market, coin_in, shares, false, clock, ctx);
}

fun buy_internal<T>(
    market: &mut Market<T>,
    mut coin_in: Coin<T>,
    shares: u64,
    yes_side: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(market.resolved == STATUS_TRADING);
    assert!(clock.timestamp_ms() <= market.trading_closes_ms);
    assert!(shares > 0);
    let old_c = cost_state(market.q_yes, market.q_no, market.b);
    let (qy2, qn2) = if (yes_side) {
        (market.q_yes + shares, market.q_no)
    } else {
        (market.q_yes, market.q_no + shares)
    };
    let new_c = cost_state(qy2, qn2, market.b);
    let raw = new_c - old_c;
    assert!(raw <= U64_MAX);
    let mut need = (raw as u64);
    let fee = fee_on(need, market.fee_bps);
    need = need + fee;
    assert!(coin::value(&coin_in) >= need);
    let pay = coin::split(&mut coin_in, need, ctx);
    balance::join(&mut market.vault, coin::into_balance(pay));
    // refund remainder
    if (coin::value(&coin_in) > 0) {
        transfer::public_transfer(coin_in, ctx.sender());
    } else {
        coin::destroy_zero(coin_in);
    };
    market.q_yes = qy2;
    market.q_no = qn2;
    event::emit(Traded {
        market_id: object::id(market),
        side_is_yes: yes_side,
        shares,
        collateral_paid: need,
    });
}

/// Sell YES shares (decrease q_yes; user receives collateral minus LMSR refund math).
public fun sell_yes<T>(
    market: &mut Market<T>,
    shares: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    sell_internal(market, shares, true, clock, ctx)
}

public fun sell_no<T>(
    market: &mut Market<T>,
    shares: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    sell_internal(market, shares, false, clock, ctx)
}

fun sell_internal<T>(
    market: &mut Market<T>,
    shares: u64,
    yes_side: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(market.resolved == STATUS_TRADING);
    assert!(clock.timestamp_ms() <= market.trading_closes_ms);
    assert!(shares > 0);
    let old_c = cost_state(market.q_yes, market.q_no, market.b);
    let (qy2, qn2) = if (yes_side) {
        assert!(market.q_yes >= shares);
        (market.q_yes - shares, market.q_no)
    } else {
        assert!(market.q_no >= shares);
        (market.q_yes, market.q_no - shares)
    };
    let new_c = cost_state(qy2, qn2, market.b);
    assert!(old_c >= new_c);
    let raw = old_c - new_c;
    assert!(raw <= U64_MAX);
    let mut credit = (raw as u64);
    let fee = fee_on(credit, market.fee_bps);
    assert!(credit >= fee);
    credit = credit - fee;
    market.q_yes = qy2;
    market.q_no = qn2;
    let out = balance::split(&mut market.vault, credit);
    coin::from_balance(out, ctx)
}

/// Propose off-chain verified result (simplified oracle). In production, replace with committee / UMA-style escalation.
public fun submit_result<T>(
    market: &mut Market<T>,
    outcome: u8,
    clock: &Clock,
) {
    assert!(market.resolved == STATUS_TRADING);
    assert!(outcome == OUTCOME_YES || outcome == OUTCOME_NO);
    market.proposed_outcome = outcome;
    market.proposal_time_ms = clock.timestamp_ms();
}

/// Challenge with stake; extends resolution (minimal stub — production needs bond accounting).
public fun challenge_result<T>(market: &mut Market<T>, stake: Coin<T>, clock: &Clock, ctx: &TxContext) {
    assert!(market.resolved == STATUS_TRADING);
    assert!(market.proposed_outcome != OUTCOME_NONE);
    assert!(clock.timestamp_ms() <= market.proposal_time_ms + market.challenge_window_ms);
    let v = coin::value(&stake);
    assert!(v > 0);
    market.challenger = ctx.sender();
    balance::join(&mut market.challenge_stake, coin::into_balance(stake));
}

/// Finalize proposed outcome after challenge window.
public fun finalize_result<T>(market: &mut Market<T>, clock: &Clock) {
    assert!(market.resolved == STATUS_TRADING);
    assert!(market.proposed_outcome != OUTCOME_NONE);
    assert!(clock.timestamp_ms() > market.proposal_time_ms + market.challenge_window_ms);
    market.resolved = STATUS_RESOLVED;
    market.winning_outcome = market.proposed_outcome;
    event::emit(Resolved { market_id: object::id(market), outcome: market.winning_outcome });
}

/// Claim: winning side redeems YES or NO token balance 1:1 against vault (simplified payout).
public fun claim<T>(market: &mut Market<T>, pos: &mut Position, ctx: &mut TxContext): Coin<T> {
    assert!(object::id(market) == pos.market_id);
    assert!(market.resolved == STATUS_RESOLVED);
    let w = market.winning_outcome;
    let amt = if (w == OUTCOME_YES) {
        assert!(pos.yes > 0);
        let a = pos.yes;
        pos.yes = 0;
        pos.no = 0;
        a
    } else if (w == OUTCOME_NO) {
        assert!(pos.no > 0);
        let a = pos.no;
        pos.yes = 0;
        pos.no = 0;
        a
    } else {
        abort ENotResolved
    };
    let out = balance::split(&mut market.vault, amt);
    coin::from_balance(out, ctx)
}

// ---------------------------------------------------------------------------
// Read helpers (for tests / frontends)
// ---------------------------------------------------------------------------

public fun q_yes<T>(m: &Market<T>): u64 { m.q_yes }
public fun q_no<T>(m: &Market<T>): u64 { m.q_no }
public fun b<T>(m: &Market<T>): u64 { m.b }
public fun vault_amount<T>(m: &Market<T>): u64 { balance::value(&m.vault) }
public fun position_yes(p: &Position): u64 { p.yes }
public fun position_no(p: &Position): u64 { p.no }

#[test_only]
public fun lse_wad_for_test(qy: u64, qn: u64, b: u64): u128 { lse_wad(qy, qn, b) }

#[test_only]
public fun cost_for_test(qy: u64, qn: u64, b: u64): u128 { cost_state(qy, qn, b) }
