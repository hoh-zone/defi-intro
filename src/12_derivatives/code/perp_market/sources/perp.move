module perp_market::perp;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ============================================================
// Error codes
// ============================================================
#[error]
const EInvalidAmount: vector<u8> = b"Invalid Amount";
#[error]
const EInsufficientMargin: vector<u8> = b"Insufficient Margin";
#[error]
const ENotLiquidatable: vector<u8> = b"Not Liquidatable";
#[error]
const EUnauthorized: vector<u8> = b"Unauthorized";
#[error]
const EMktPaused: vector<u8> = b"Mkt Paused";
#[error]
const EPositionMismatch: vector<u8> = b"Position Mismatch";
#[error]
const EInsufficientReserve: vector<u8> = b"Insufficient Reserve";
#[error]
const EInvalidPrice: vector<u8> = b"Invalid Price";

// ============================================================
// Constants
// ============================================================
const BPS_BASE: u64 = 10000;

// ============================================================
// Events
// ============================================================
public struct PositionOpenedEvent has copy, drop {
    trader: address,
    size: u64,
    entry_price: u64,
    is_long: bool,
    margin: u64,
}

public struct PositionClosedEvent has copy, drop {
    trader: address,
    size: u64,
    pnl_abs: u64,
    pnl_is_profit: bool,
    margin_returned: u64,
}

public struct MarginAddedEvent has copy, drop {
    trader: address,
    amount: u64,
}

public struct MarginRemovedEvent has copy, drop {
    trader: address,
    amount: u64,
}

public struct LiquidationEvent has copy, drop {
    liquidator: address,
    trader: address,
    size: u64,
    penalty: u64,
}

public struct FundingUpdatedEvent has copy, drop {
    funding_rate_bps: u64,
    funding_positive: bool,
    mark_price: u64,
    index_price: u64,
}

// ============================================================
// Structs
// ============================================================

/// Shared perpetual futures market for a BASE/QUOTE pair.
/// Prices are quoted as "quote per base" (e.g. 50000 means 1 base = 50000 quote).
public struct PerpMarket<phantom Base, phantom Quote> has key {
    id: UID,
    /// Reserve of base tokens (used for backing positions).
    base_reserve: Balance<Base>,
    /// Reserve of quote tokens (margin deposits and PnL settlements).
    quote_reserve: Balance<Quote>,
    /// Insurance fund to cover bad debt.
    insurance_fund: Balance<Quote>,
    /// Total outstanding long size in base units.
    total_long_size: u64,
    /// Total outstanding short size in base units.
    total_short_size: u64,
    /// Index price (oracle-like, set by admin for this educational model).
    index_price: u64,
    /// Mark price (used for PnL and margin calculations).
    mark_price: u64,
    /// Current funding rate in basis points (absolute value).
    funding_rate_bps: u64,
    /// Whether funding rate is positive (longs pay shorts). false = shorts pay longs.
    funding_positive: bool,
    /// Timestamp of last funding payment.
    last_funding_time: u64,
    /// Interval between funding payments in milliseconds.
    funding_interval_ms: u64,
    /// Maintenance margin ratio in basis points (e.g. 500 = 5%).
    maintenance_margin_bps: u64,
    /// Taker fee in basis points (e.g. 10 = 0.1%).
    taker_fee_bps: u64,
    /// Whether the market is paused.
    paused: bool,
}

/// A trader's position in the market. Owned by the trader.
public struct Position<phantom Base, phantom Quote> has key, store {
    id: UID,
    /// ID of the market this position belongs to.
    market_id: ID,
    /// Owner address (redundant with ownership, useful for queries).
    owner: address,
    /// Position size in base units.
    size: u64,
    /// Entry price at which the position was opened.
    entry_price: u64,
    /// Margin deposited (in quote token).
    margin: u64,
    /// Whether this is a long position.
    is_long: bool,
    /// Cached unrealized PnL (absolute value, in quote units).
    unrealized_pnl_abs: u64,
    /// Whether unrealized PnL is positive (profit). false = loss.
    unrealized_pnl_is_profit: bool,
}

/// Admin capability for managing the market.
public struct AdminCap<phantom Base, phantom Quote> has key, store {
    id: UID,
    market_id: ID,
}

// ============================================================
// Create Market
// ============================================================

/// Create a new perpetual futures market.
///
/// @param maintenance_margin_bps  Maintenance margin ratio (e.g. 500 = 5%).
/// @param taker_fee_bps  Trading fee (e.g. 10 = 0.1%).
/// @param funding_interval_ms  Time between funding payments (e.g. 3600000 = 1 hour).
/// @param initial_mark_price  Starting mark/index price.
public fun create_market<Base, Quote>(
    maintenance_margin_bps: u64,
    taker_fee_bps: u64,
    funding_interval_ms: u64,
    initial_mark_price: u64,
    ctx: &mut TxContext,
) {
    assert!(initial_mark_price > 0, EInvalidPrice);
    assert!(maintenance_margin_bps > 0, EInvalidAmount);
    assert!(maintenance_margin_bps < BPS_BASE, EInvalidAmount);

    let market = PerpMarket<Base, Quote> {
        id: object::new(ctx),
        base_reserve: balance::zero(),
        quote_reserve: balance::zero(),
        insurance_fund: balance::zero(),
        total_long_size: 0,
        total_short_size: 0,
        index_price: initial_mark_price,
        mark_price: initial_mark_price,
        funding_rate_bps: 0,
        funding_positive: true,
        last_funding_time: 0,
        funding_interval_ms,
        maintenance_margin_bps,
        taker_fee_bps,
        paused: false,
    };

    let market_id = object::id(&market);

    let cap = AdminCap<Base, Quote> {
        id: object::new(ctx),
        market_id,
    };

    transfer::share_object(market);
    transfer::transfer(cap, ctx.sender());
}

// ============================================================
// Core: Open Position
// ============================================================

/// Open a new long or short position.
///
/// The trader deposits `margin_coin` (Quote tokens) as margin and
/// specifies the desired `size` (in base units) and direction.
///
/// Margin requirement: margin >= size * mark_price * initial_margin_bps / BPS_BASE
/// For simplicity, initial_margin_bps = maintenance_margin_bps * 2.
///
/// A taker fee is charged from the deposited amount. The fee stays in
/// the quote reserve as protocol revenue. The position tracks the
/// remaining effective margin after fee deduction.
public fun open_position<Base, Quote>(
    market: &mut PerpMarket<Base, Quote>,
    margin_coin: Coin<Quote>,
    size: u64,
    is_long: bool,
    ctx: &mut TxContext,
): Position<Base, Quote> {
    assert!(!market.paused, EMktPaused);
    assert!(size > 0, EInvalidAmount);

    let margin_amount = coin::value(&margin_coin);
    assert!(margin_amount > 0, EInvalidAmount);

    // Calculate fee: fee = size * mark_price * taker_fee_bps / BPS_BASE
    let fee = size * market.mark_price * market.taker_fee_bps / BPS_BASE;

    // Deposit full amount (margin + fee) into quote reserve.
    balance::join(&mut market.quote_reserve, coin::into_balance(margin_coin));

    // Effective margin after fee.
    let effective_margin = margin_amount - fee;

    // Initial margin requirement: effective_margin >= size * mark_price * (2 * maintenance_margin_bps) / BPS_BASE
    let initial_margin_required =
        size * market.mark_price * (2 * market.maintenance_margin_bps) / BPS_BASE;
    assert!(effective_margin >= initial_margin_required, EInsufficientMargin);

    // Update open interest.
    if (is_long) {
        market.total_long_size = market.total_long_size + size;
    } else {
        market.total_short_size = market.total_short_size + size;
    };

    let position = Position<Base, Quote> {
        id: object::new(ctx),
        market_id: object::id(market),
        owner: ctx.sender(),
        size,
        entry_price: market.mark_price,
        margin: effective_margin,
        is_long,
        unrealized_pnl_abs: 0,
        unrealized_pnl_is_profit: true,
    };

    sui::event::emit(PositionOpenedEvent {
        trader: ctx.sender(),
        size,
        entry_price: market.mark_price,
        is_long,
        margin: effective_margin,
    });

    position
}

// ============================================================
// Core: Add Margin
// ============================================================

/// Add more margin to an existing position.
public fun add_margin<Base, Quote>(
    market: &mut PerpMarket<Base, Quote>,
    position: &mut Position<Base, Quote>,
    margin_coin: Coin<Quote>,
) {
    assert!(object::id(market) == position.market_id, EPositionMismatch);

    let amount = coin::value(&margin_coin);
    assert!(amount > 0, EInvalidAmount);

    position.margin = position.margin + amount;
    balance::join(&mut market.quote_reserve, coin::into_balance(margin_coin));

    sui::event::emit(MarginAddedEvent {
        trader: position.owner,
        amount,
    });
}

// ============================================================
// Core: Remove Margin
// ============================================================

/// Remove margin from a position if it remains healthy after removal.
public fun remove_margin<Base, Quote>(
    market: &mut PerpMarket<Base, Quote>,
    position: &mut Position<Base, Quote>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(!market.paused, EMktPaused);
    assert!(object::id(market) == position.market_id, EPositionMismatch);
    assert!(amount > 0, EInvalidAmount);
    assert!(amount <= position.margin, EInsufficientMargin);

    // Recalculate unrealized PnL at current mark price.
    let (pnl_abs, pnl_is_profit) = calculate_pnl(
        position.entry_price,
        market.mark_price,
        position.size,
        position.is_long,
    );
    position.unrealized_pnl_abs = pnl_abs;
    position.unrealized_pnl_is_profit = pnl_is_profit;

    // Check health after removal.
    let new_margin = position.margin - amount;
    // effective_margin = new_margin + pnl (with sign)
    let (effective_margin, effective_is_positive) = signed_add_unsigned(
        pnl_abs,
        pnl_is_profit,
        new_margin,
    );
    // effective_margin must be positive.
    assert!(effective_is_positive, EInsufficientMargin);

    // Must still satisfy initial margin: effective_margin >= size * mark_price * (2 * maintenance_bps) / BPS_BASE
    let initial_required =
        position.size * market.mark_price * (2 * market.maintenance_margin_bps) / BPS_BASE;
    assert!(effective_margin >= initial_required, EInsufficientMargin);

    assert!(balance::value(&market.quote_reserve) >= amount, EInsufficientReserve);

    position.margin = new_margin;

    sui::event::emit(MarginRemovedEvent {
        trader: position.owner,
        amount,
    });

    coin::take(&mut market.quote_reserve, amount, ctx)
}

// ============================================================
// Core: Close Position
// ============================================================

/// Close an entire position. Returns the margin plus realized PnL.
/// If PnL is negative and exceeds margin, the returned amount may be zero.
/// The quote reserve must have enough to cover the return; otherwise the
/// insurance fund is tapped (if available) or the return is capped.
public fun close_position<Base, Quote>(
    market: &mut PerpMarket<Base, Quote>,
    position: Position<Base, Quote>,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(!market.paused, EMktPaused);
    assert!(object::id(market) == position.market_id, EPositionMismatch);

    let Position {
        id,
        market_id: _,
        owner: _,
        size,
        entry_price,
        margin,
        is_long,
        unrealized_pnl_abs: _,
        unrealized_pnl_is_profit: _,
    } = position;

    // Calculate PnL at current mark price.
    let (pnl_abs, pnl_is_profit) = calculate_pnl(entry_price, market.mark_price, size, is_long);

    // Update open interest.
    if (is_long) {
        market.total_long_size = market.total_long_size - size;
    } else {
        market.total_short_size = market.total_short_size - size;
    };

    // Calculate amount to return: margin + pnl (with sign).
    let return_amount = if (pnl_is_profit) {
        margin + pnl_abs
    } else {
        if (pnl_abs >= margin) {
            // Trader loses all margin. Deficit is socialized or covered by insurance.
            0
        } else {
            margin - pnl_abs
        }
    };

    // Try to cover from quote reserve first.
    let reserve_bal = balance::value(&market.quote_reserve);
    if (return_amount <= reserve_bal) {
        // Quote reserve covers the full amount.
        id.delete();

        sui::event::emit(PositionClosedEvent {
            trader: tx_context::sender(ctx),
            size,
            pnl_abs,
            pnl_is_profit,
            margin_returned: return_amount,
        });

        coin::take(&mut market.quote_reserve, return_amount, ctx)
    } else {
        // Not enough in quote reserve. Tap insurance fund for the deficit.
        let deficit = return_amount - reserve_bal;
        let insurance_bal = balance::value(&market.insurance_fund);

        let actual_return = if (deficit <= insurance_bal) {
            // Insurance covers the gap.
            let insurance_coin = coin::take(&mut market.insurance_fund, deficit, ctx);
            balance::join(&mut market.quote_reserve, coin::into_balance(insurance_coin));
            return_amount
        } else {
            // Even insurance can't cover it fully. Return what we can.
            if (insurance_bal > 0) {
                let insurance_coin = coin::take(&mut market.insurance_fund, insurance_bal, ctx);
                balance::join(&mut market.quote_reserve, coin::into_balance(insurance_coin));
            };
            balance::value(&market.quote_reserve)
        };

        id.delete();

        sui::event::emit(PositionClosedEvent {
            trader: tx_context::sender(ctx),
            size,
            pnl_abs,
            pnl_is_profit,
            margin_returned: actual_return,
        });

        coin::take(&mut market.quote_reserve, actual_return, ctx)
    }
}

// ============================================================
// Core: Liquidate
// ============================================================

/// Liquidate an undercollateralized position.
///
/// A position is liquidatable when:
///   effective_margin = margin + unrealized_pnl
///   margin_ratio = effective_margin * BPS_BASE / (size * mark_price)
///   margin_ratio < maintenance_margin_bps
///
/// The liquidator receives a reward, and a penalty goes to the insurance fund.
public fun liquidate<Base, Quote>(
    market: &mut PerpMarket<Base, Quote>,
    position: Position<Base, Quote>,
    ctx: &mut TxContext,
): Coin<Quote> {
    assert!(object::id(market) == position.market_id, EPositionMismatch);

    let Position {
        id,
        market_id: _,
        owner,
        size,
        entry_price,
        margin,
        is_long,
        unrealized_pnl_abs: _,
        unrealized_pnl_is_profit: _,
    } = position;

    // Calculate current PnL.
    let (pnl_abs, pnl_is_profit) = calculate_pnl(entry_price, market.mark_price, size, is_long);

    // Calculate effective margin.
    let (effective_margin, effective_is_positive) = signed_add_unsigned(
        pnl_abs,
        pnl_is_profit,
        margin,
    );

    // Calculate margin ratio.
    // position_value = size * mark_price
    let position_value = size * market.mark_price;
    assert!(position_value > 0, EInvalidAmount);

    // margin_ratio_bps = effective_margin * BPS_BASE / position_value
    // Only liquidate if effective_margin is positive but too low (or negative).
    let liquidatable = if (!effective_is_positive) {
        true
    } else {
        let margin_ratio_bps = effective_margin * BPS_BASE / position_value;
        margin_ratio_bps < market.maintenance_margin_bps
    };

    assert!(liquidatable, ENotLiquidatable);

    // Update open interest.
    if (is_long) {
        market.total_long_size = market.total_long_size - size;
    } else {
        market.total_short_size = market.total_short_size - size;
    };

    // Liquidation penalty: 10% of margin goes to insurance fund.
    let penalty = margin / 10;
    let liquidator_reward = if (penalty > margin) {
        0
    } else {
        margin - penalty
    };

    // Transfer penalty to insurance fund from quote reserve.
    if (penalty > 0 && penalty <= balance::value(&market.quote_reserve)) {
        let penalty_balance = coin::take(&mut market.quote_reserve, penalty, ctx);
        balance::join(&mut market.insurance_fund, coin::into_balance(penalty_balance));
    };

    id.delete();

    sui::event::emit(LiquidationEvent {
        liquidator: tx_context::sender(ctx),
        trader: owner,
        size,
        penalty,
    });

    // Return liquidator reward from quote reserve.
    if (liquidator_reward > 0 && liquidator_reward <= balance::value(&market.quote_reserve)) {
        coin::take(&mut market.quote_reserve, liquidator_reward, ctx)
    } else {
        coin::take(&mut market.quote_reserve, 0, ctx)
    }
}

// ============================================================
// Admin: Set Price (mock oracle)
// ============================================================

/// Update the mark price and index price (admin-only).
/// In production this would come from a price oracle.
public fun set_price<Base, Quote>(
    _cap: &AdminCap<Base, Quote>,
    market: &mut PerpMarket<Base, Quote>,
    new_mark_price: u64,
    new_index_price: u64,
) {
    assert!(new_mark_price > 0, EInvalidPrice);
    assert!(new_index_price > 0, EInvalidPrice);
    market.mark_price = new_mark_price;
    market.index_price = new_index_price;
}

// ============================================================
// Funding Rate
// ============================================================

/// Update the funding rate based on the spread between mark and index price.
///
/// funding_rate_bps = |mark_price - index_price| * BPS_BASE / index_price
/// Positive (funding_positive=true) = longs pay shorts.
/// Negative (funding_positive=false) = shorts pay longs.
public fun update_funding<Base, Quote>(market: &mut PerpMarket<Base, Quote>) {
    let mark = market.mark_price;
    let index = market.index_price;

    if (mark >= index) {
        // Longs pay shorts.
        let spread = mark - index;
        market.funding_rate_bps = spread * BPS_BASE / index;
        market.funding_positive = true;
    } else {
        // Shorts pay longs.
        let spread = index - mark;
        market.funding_rate_bps = spread * BPS_BASE / index;
        market.funding_positive = false;
    };

    sui::event::emit(FundingUpdatedEvent {
        funding_rate_bps: market.funding_rate_bps,
        funding_positive: market.funding_positive,
        mark_price: market.mark_price,
        index_price: market.index_price,
    });
}

// ============================================================
// Pure: PnL Calculation
// ============================================================

/// Calculate profit/loss for a position.
///
/// Long:  pnl = (exit_price - entry_price) * size
/// Short: pnl = (entry_price - exit_price) * size
///
/// Returns (pnl_abs, pnl_is_profit) where pnl_abs is the absolute
/// value of the PnL in quote units, and pnl_is_profit indicates profit.
public fun calculate_pnl(entry_price: u64, exit_price: u64, size: u64, is_long: bool): (u64, bool) {
    if (is_long) {
        if (exit_price >= entry_price) {
            let pnl = (exit_price - entry_price) * size;
            (pnl, true)
        } else {
            let pnl = (entry_price - exit_price) * size;
            (pnl, false)
        }
    } else {
        if (entry_price >= exit_price) {
            let pnl = (entry_price - exit_price) * size;
            (pnl, true)
        } else {
            let pnl = (exit_price - entry_price) * size;
            (pnl, false)
        }
    }
}

// ============================================================
// Pure: Signed arithmetic helper
// ============================================================

/// Add an unsigned value to a signed value represented as (abs, is_positive).
/// Returns (result_abs, result_is_positive).
/// Computes: result = (pnl_abs if pnl_is_profit else -pnl_abs) + unsigned_val
public fun signed_add_unsigned(pnl_abs: u64, pnl_is_profit: bool, unsigned_val: u64): (u64, bool) {
    if (pnl_is_profit) {
        // Both positive: result = pnl_abs + unsigned_val
        (pnl_abs + unsigned_val, true)
    } else {
        // pnl is negative: result = unsigned_val - pnl_abs
        if (pnl_abs >= unsigned_val) {
            (pnl_abs - unsigned_val, false)
        } else {
            (unsigned_val - pnl_abs, true)
        }
    }
}

// ============================================================
// View: Health Factor
// ============================================================

/// Calculate the health factor of a position.
///
/// health_factor_bps = (margin + unrealized_pnl) * BPS_BASE / (size * mark_price)
///
/// Returns the health factor in basis points. A value below maintenance_margin_bps
/// means the position is liquidatable. A value above 10000 means well-collateralized.
public fun health_factor<Base, Quote>(
    market: &PerpMarket<Base, Quote>,
    position: &Position<Base, Quote>,
): u64 {
    let (pnl_abs, pnl_is_profit) = calculate_pnl(
        position.entry_price,
        market.mark_price,
        position.size,
        position.is_long,
    );

    let (effective_margin, effective_is_positive) = signed_add_unsigned(
        pnl_abs,
        pnl_is_profit,
        position.margin,
    );

    if (!effective_is_positive) {
        return 0
    };

    let position_value = position.size * market.mark_price;
    if (position_value == 0) {
        return BPS_BASE
    };

    (effective_margin * BPS_BASE) / position_value
}

// ============================================================
// Admin: Fund Insurance
// ============================================================

/// Add quote tokens to the insurance fund (admin-only).
public fun fund_insurance<Base, Quote>(
    _cap: &AdminCap<Base, Quote>,
    market: &mut PerpMarket<Base, Quote>,
    fund: Coin<Quote>,
) {
    balance::join(&mut market.insurance_fund, coin::into_balance(fund));
}

// ============================================================
// Admin: Pause / Unpause
// ============================================================

/// Pause the market (no new positions or closes).
public fun pause<Base, Quote>(_cap: &AdminCap<Base, Quote>, market: &mut PerpMarket<Base, Quote>) {
    market.paused = true;
}

/// Unpause the market.
public fun unpause<Base, Quote>(
    _cap: &AdminCap<Base, Quote>,
    market: &mut PerpMarket<Base, Quote>,
) {
    market.paused = false;
}

// ============================================================
// View functions
// ============================================================

public fun mark_price<Base, Quote>(market: &PerpMarket<Base, Quote>): u64 {
    market.mark_price
}

public fun index_price<Base, Quote>(market: &PerpMarket<Base, Quote>): u64 {
    market.index_price
}

public fun total_long_size<Base, Quote>(market: &PerpMarket<Base, Quote>): u64 {
    market.total_long_size
}

public fun total_short_size<Base, Quote>(market: &PerpMarket<Base, Quote>): u64 {
    market.total_short_size
}

/// Returns (funding_rate_bps_abs, funding_positive).
/// funding_positive=true means longs pay shorts.
public fun funding_rate_bps<Base, Quote>(market: &PerpMarket<Base, Quote>): (u64, bool) {
    (market.funding_rate_bps, market.funding_positive)
}

public fun maintenance_margin_bps<Base, Quote>(market: &PerpMarket<Base, Quote>): u64 {
    market.maintenance_margin_bps
}

public fun is_paused<Base, Quote>(market: &PerpMarket<Base, Quote>): bool {
    market.paused
}

public fun quote_reserve_balance<Base, Quote>(market: &PerpMarket<Base, Quote>): u64 {
    balance::value(&market.quote_reserve)
}

public fun insurance_fund_balance<Base, Quote>(market: &PerpMarket<Base, Quote>): u64 {
    balance::value(&market.insurance_fund)
}

public fun position_size<Base, Quote>(position: &Position<Base, Quote>): u64 {
    position.size
}

public fun position_entry_price<Base, Quote>(position: &Position<Base, Quote>): u64 {
    position.entry_price
}

public fun position_margin<Base, Quote>(position: &Position<Base, Quote>): u64 {
    position.margin
}

public fun position_is_long<Base, Quote>(position: &Position<Base, Quote>): bool {
    position.is_long
}

public fun position_unrealized_pnl<Base, Quote>(position: &Position<Base, Quote>): (u64, bool) {
    (position.unrealized_pnl_abs, position.unrealized_pnl_is_profit)
}

// ============================================================
// Test helpers
// ============================================================

#[test_only]
public fun destroy_market<Base, Quote>(market: PerpMarket<Base, Quote>) {
    let PerpMarket {
        id,
        base_reserve,
        quote_reserve,
        insurance_fund,
        total_long_size: _,
        total_short_size: _,
        index_price: _,
        mark_price: _,
        funding_rate_bps: _,
        funding_positive: _,
        last_funding_time: _,
        funding_interval_ms: _,
        maintenance_margin_bps: _,
        taker_fee_bps: _,
        paused: _,
    } = market;
    balance::destroy_zero(base_reserve);
    balance::destroy_zero(quote_reserve);
    balance::destroy_zero(insurance_fund);
    id.delete();
}

#[test_only]
public fun destroy_position<Base, Quote>(position: Position<Base, Quote>) {
    let Position {
        id,
        market_id: _,
        owner: _,
        size: _,
        entry_price: _,
        margin: _,
        is_long: _,
        unrealized_pnl_abs: _,
        unrealized_pnl_is_profit: _,
    } = position;
    id.delete();
}

/// Test helper: directly set the mark price without admin cap.
#[test_only]
public fun set_mark_price_test<Base, Quote>(market: &mut PerpMarket<Base, Quote>, new_price: u64) {
    market.mark_price = new_price;
}
