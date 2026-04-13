module dutch_auction::dutch_auction;

use sui::coin::{Self, Coin, TreasuryCap};
use sui::balance::{Self, Balance};
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::event;
use sui::tx_context::TxContext;
use sui::clock::{Self, Clock};
use std::option;

// States
const STATE_CREATED: u8 = 0;
const STATE_ACTIVE: u8 = 1;
const STATE_SETTLED: u8 = 2;
const STATE_CANCELLED: u8 = 3;

// Errors
const EWrongState: u64 = 100;
const EUnauthorized: u64 = 101;
const EAuctionNotActive: u64 = 102;
const EBelowFloorPrice: u64 = 103;
const EInsufficientPayment: u64 = 104;
const ENoTokensToClaim: u64 = 105;
const EAlreadyClaimed: u64 = 106;
const EInvalidPrice: u64 = 107;
const EInvalidDuration: u64 = 108;
const ESoldOut: u64 = 109;

// One-time witness for sale token
public struct DUTCH_AUCTION has drop {}

public struct DutchAuctionRound has key {
    id: UID,
    treasury_cap: TreasuryCap<DUTCH_AUCTION>,
    payment_collected: Balance<sui::sui::SUI>,
    state: u8,
    start_price: u64,       // price per token at start (in MIST)
    end_price: u64,         // floor price per token (in MIST)
    start_time: u64,        // auction start timestamp_ms
    duration_ms: u64,       // auction duration in milliseconds
    total_supply: u64,      // total tokens for sale
    remaining: u64,         // tokens remaining
    // Per-buyer records: address -> PurchaseRecord
    purchases: sui::table::Table<address, PurchaseRecord>,
}

public struct PurchaseRecord has store {
    token_amount: u64,
    total_payment: u64,     // total SUI paid
    claimed: bool,
}

public struct AdminCap has key, store {
    id: UID,
    auction_id: ID,
}

// Events
public struct AuctionStarted has copy, drop { auction_id: ID, start_price: u64, end_price: u64, duration_ms: u64 }
public struct Purchased has copy, drop { buyer: address, price_per_token: u64, token_amount: u64, payment: u64 }
public struct Claimed has copy, drop { buyer: address, token_amount: u64 }
public struct AuctionSettled has copy, drop { auction_id: ID, total_sold: u64, total_payment: u64 }

fun init(witness: DUTCH_AUCTION, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency<DUTCH_AUCTION>(
        witness,
        9,
        b"DAUC",
        b"Dutch Auction Token",
        b"Token for Dutch auction",
        option::none(),
        ctx,
    );
    let auction = DutchAuctionRound {
        id: object::new(ctx),
        treasury_cap,
        payment_collected: balance::zero(),
        state: STATE_CREATED,
        start_price: 10_000_000_000,     // 10 SUI per token
        end_price: 2_000_000_000,        // 2 SUI per token
        start_time: 0,
        duration_ms: 3_600_000,          // 1 hour
        total_supply: 1_000_000_000_000,  // 1M tokens
        remaining: 1_000_000_000_000,
        purchases: sui::table::new(ctx),
    };
    let auction_id = object::id(&auction);
    transfer::share_object(auction);
    transfer::public_transfer(
        AdminCap { id: object::new(ctx), auction_id },
        ctx.sender(),
    );
    transfer::public_transfer(metadata, ctx.sender());
}

// --- Admin: configure and start auction ---

public fun start_auction(
    cap: &AdminCap,
    auction: &mut DutchAuctionRound,
    start_price: u64,
    end_price: u64,
    duration_ms: u64,
    clock: &Clock,
) {
    assert!(object::id(auction) == cap.auction_id, EUnauthorized);
    assert!(auction.state == STATE_CREATED, EWrongState);
    assert!(start_price > end_price, EInvalidPrice);
    assert!(duration_ms > 0, EInvalidDuration);

    auction.start_price = start_price;
    auction.end_price = end_price;
    auction.duration_ms = duration_ms;
    auction.start_time = clock.timestamp_ms();
    auction.state = STATE_ACTIVE;

    event::emit(AuctionStarted {
        auction_id: object::id(auction),
        start_price,
        end_price,
        duration_ms,
    });
}

// --- Core: calculate current price ---

/// Returns the current price per token based on elapsed time.
/// Price linearly decays from start_price to end_price over duration_ms.
public fun current_price(auction: &DutchAuctionRound, clock: &Clock): u64 {
    assert!(auction.state == STATE_ACTIVE, EAuctionNotActive);
    let now = clock.timestamp_ms();
    let elapsed = now - auction.start_time;
    if (elapsed >= auction.duration_ms) {
        auction.end_price
    } else {
        auction.start_price - (auction.start_price - auction.end_price) * elapsed / auction.duration_ms
    }
}

// --- Purchase ---

/// Buy tokens at the current auction price.
/// Payment must be >= current_price * token_amount.
/// Buyers can buy multiple times; each purchase records the amount.
public fun buy(
    auction: &mut DutchAuctionRound,
    payment: Coin<sui::sui::SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(auction.state == STATE_ACTIVE, EWrongState);
    let price = current_price(auction, clock);
    assert!(price >= auction.end_price, EBelowFloorPrice);

    let buyer = ctx.sender();
    let payment_amount = coin::value(&payment);
    let token_amount = payment_amount / price;
    assert!(token_amount > 0, EInsufficientPayment);
    assert!(token_amount <= auction.remaining, ESoldOut);

    // Update or create purchase record
    if (auction.purchases.contains(buyer)) {
        let record: &mut PurchaseRecord = auction.purchases.borrow_mut(buyer);
        record.token_amount = record.token_amount + token_amount;
        record.total_payment = record.total_payment + payment_amount;
    } else {
        auction.purchases.add(buyer, PurchaseRecord {
            token_amount,
            total_payment: payment_amount,
            claimed: false,
        });
    };

    auction.remaining = auction.remaining - token_amount;
    balance::join(&mut auction.payment_collected, coin::into_balance(payment));

    event::emit(Purchased {
        buyer,
        price_per_token: price,
        token_amount,
        payment: payment_amount,
    });

    // Auto-settle if sold out
    if (auction.remaining == 0) {
        auction.state = STATE_SETTLED;
        event::emit(AuctionSettled {
            auction_id: object::id(auction),
            total_sold: auction.total_supply,
            total_payment: balance::value(&auction.payment_collected),
        });
    };
}

// --- End auction manually ---

public fun end_auction(cap: &AdminCap, auction: &mut DutchAuctionRound, clock: &Clock) {
    assert!(object::id(auction) == cap.auction_id, EUnauthorized);
    assert!(auction.state == STATE_ACTIVE, EWrongState);
    let now = clock.timestamp_ms();
    // Allow ending only after duration has passed
    assert!(now >= auction.start_time + auction.duration_ms, EWrongState);
    auction.state = STATE_SETTLED;

    event::emit(AuctionSettled {
        auction_id: object::id(auction),
        total_sold: auction.total_supply - auction.remaining,
        total_payment: balance::value(&auction.payment_collected),
    });
}

// --- Cancel ---

public fun cancel(cap: &AdminCap, auction: &mut DutchAuctionRound) {
    assert!(object::id(auction) == cap.auction_id, EUnauthorized);
    assert!(auction.state == STATE_CREATED || auction.state == STATE_ACTIVE, EWrongState);
    auction.state = STATE_CANCELLED;
}

// --- Claim tokens ---

public fun claim(auction: &mut DutchAuctionRound, ctx: &mut TxContext): Coin<DUTCH_AUCTION> {
    assert!(auction.state == STATE_SETTLED, EWrongState);
    let buyer = ctx.sender();
    assert!(auction.purchases.contains(buyer), ENoTokensToClaim);

    let record: &mut PurchaseRecord = auction.purchases.borrow_mut(buyer);
    assert!(!record.claimed, EAlreadyClaimed);
    record.claimed = true;
    let amount = record.token_amount;

    let token = coin::mint(&mut auction.treasury_cap, amount, ctx);
    event::emit(Claimed { buyer, token_amount: amount });
    token
}

// --- Refund on cancel ---

public fun refund(auction: &mut DutchAuctionRound, ctx: &mut TxContext): Coin<sui::sui::SUI> {
    assert!(auction.state == STATE_CANCELLED, EWrongState);
    let buyer = ctx.sender();
    assert!(auction.purchases.contains(buyer), ENoTokensToClaim);

    let record: &mut PurchaseRecord = auction.purchases.borrow_mut(buyer);
    assert!(!record.claimed, EAlreadyClaimed);
    record.claimed = true;
    let refund_amount = record.total_payment;

    coin::take(&mut auction.payment_collected, refund_amount, ctx)
}

// --- Admin: withdraw payments after settlement ---

public fun withdraw_payments(
    cap: &AdminCap,
    auction: &mut DutchAuctionRound,
    ctx: &mut TxContext,
): Coin<sui::sui::SUI> {
    assert!(object::id(auction) == cap.auction_id, EUnauthorized);
    assert!(auction.state == STATE_SETTLED, EWrongState);
    let amount = balance::value(&auction.payment_collected);
    coin::take(&mut auction.payment_collected, amount, ctx)
}

// --- View helpers ---

public fun state(auction: &DutchAuctionRound): u8 { auction.state }
public fun remaining(auction: &DutchAuctionRound): u64 { auction.remaining }
public fun total_supply(auction: &DutchAuctionRound): u64 { auction.total_supply }
public fun start_price(auction: &DutchAuctionRound): u64 { auction.start_price }
public fun end_price(auction: &DutchAuctionRound): u64 { auction.end_price }
public fun duration_ms(auction: &DutchAuctionRound): u64 { auction.duration_ms }

public fun has_purchased(auction: &DutchAuctionRound, addr: address): bool {
    auction.purchases.contains(addr)
}

public fun purchase_amount(auction: &DutchAuctionRound, addr: address): u64 {
    if (auction.purchases.contains(addr)) {
        let record: &PurchaseRecord = auction.purchases.borrow(addr);
        record.token_amount
    } else {
        0
    }
}

// --- Test helpers ---

#[test_only]
public fun create_for_testing(
    treasury_cap: TreasuryCap<DUTCH_AUCTION>,
    start_price: u64,
    end_price: u64,
    duration_ms: u64,
    total_supply: u64,
    ctx: &mut TxContext,
) {
    let auction = DutchAuctionRound {
        id: object::new(ctx),
        treasury_cap,
        payment_collected: balance::zero(),
        state: STATE_CREATED,
        start_price,
        end_price,
        start_time: 0,
        duration_ms,
        total_supply,
        remaining: total_supply,
        purchases: sui::table::new(ctx),
    };
    let auction_id = object::id(&auction);
    transfer::share_object(auction);
    transfer::public_transfer(
        AdminCap { id: object::new(ctx), auction_id },
        ctx.sender(),
    );
}
