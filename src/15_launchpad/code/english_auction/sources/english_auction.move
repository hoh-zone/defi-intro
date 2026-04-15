module english_auction::english_auction;

use std::option;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::TxContext;

// States
const STATE_CREATED: u8 = 0;
const STATE_ACTIVE: u8 = 1;
const STATE_ENDED: u8 = 2;
const STATE_CANCELLED: u8 = 3;

// Errors
#[error]
const EWrongState: vector<u8> = b"Wrong State";
#[error]
const EUnauthorized: vector<u8> = b"Unauthorized";
#[error]
const EBidTooLow: vector<u8> = b"Bid Too Low";
#[error]
const ENoBidPlaced: vector<u8> = b"No Bid Placed";
#[error]
const ENotWinner: vector<u8> = b"Not Winner";
#[error]
const EAlreadyClaimed: vector<u8> = b"Already Claimed";
#[error]
const ECannotOutbidSelf: vector<u8> = b"Cannot Outbid Self";
#[error]
const EInvalidParams: vector<u8> = b"Invalid Params";

// One-time witness
public struct ENGLISH_AUCTION has drop {}

public struct EnglishAuctionRound has key {
    id: UID,
    treasury_cap: TreasuryCap<ENGLISH_AUCTION>,
    state: u8,
    reserve_price: u64, // minimum starting bid (MIST)
    min_bid_increment: u64, // minimum raise over current bid (MIST)
    token_amount: u64, // how many tokens being auctioned
    start_time: u64, // auction start timestamp_ms
    duration_ms: u64, // auction duration
    highest_bid: u64, // current highest bid amount (MIST)
    highest_bidder: address, // current highest bidder
    bid_count: u64, // total number of bids
    winner_claimed: bool, // whether winner has claimed tokens
    // Track all bidders' deposits: address -> deposited amount
    deposits: sui::table::Table<address, u64>,
    // Collected balance (winner's payment)
    payment_collected: Balance<sui::sui::SUI>,
}

public struct AdminCap has key, store {
    id: UID,
    auction_id: ID,
}

// Events
public struct AuctionStarted has copy, drop {
    auction_id: ID,
    reserve_price: u64,
    token_amount: u64,
}
public struct BidPlaced has copy, drop { bidder: address, amount: u64, bid_count: u64 }
public struct Outbid has copy, drop {
    previous_bidder: address,
    new_bidder: address,
    new_amount: u64,
}
public struct AuctionEnded has copy, drop { auction_id: ID, winner: address, winning_bid: u64 }
public struct Claimed has copy, drop { winner: address, token_amount: u64 }

fun init(witness: ENGLISH_AUCTION, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency<ENGLISH_AUCTION>(
        witness,
        9,
        b"EAUC",
        b"English Auction Token",
        b"Token for English auction",
        option::none(),
        ctx,
    );
    let auction = EnglishAuctionRound {
        id: object::new(ctx),
        treasury_cap,
        state: STATE_CREATED,
        reserve_price: 1_000_000_000, // 1 SUI minimum
        min_bid_increment: 500_000_000, // 0.5 SUI minimum raise
        token_amount: 1_000_000_000_000, // 1M tokens
        start_time: 0,
        duration_ms: 3_600_000, // 1 hour
        highest_bid: 0,
        highest_bidder: @0x0,
        bid_count: 0,
        winner_claimed: false,
        deposits: sui::table::new(ctx),
        payment_collected: balance::zero(),
    };
    let auction_id = object::id(&auction);
    transfer::share_object(auction);
    transfer::public_transfer(
        AdminCap { id: object::new(ctx), auction_id },
        ctx.sender(),
    );
    transfer::public_transfer(metadata, ctx.sender());
}

// --- Admin: start auction ---

public fun start_auction(
    cap: &AdminCap,
    auction: &mut EnglishAuctionRound,
    reserve_price: u64,
    min_bid_increment: u64,
    token_amount: u64,
    duration_ms: u64,
    clock: &Clock,
) {
    assert!(object::id(auction) == cap.auction_id, EUnauthorized);
    assert!(auction.state == STATE_CREATED, EWrongState);
    assert!(reserve_price > 0, EInvalidParams);
    assert!(min_bid_increment > 0, EInvalidParams);
    assert!(duration_ms > 0, EInvalidParams);

    auction.reserve_price = reserve_price;
    auction.min_bid_increment = min_bid_increment;
    auction.token_amount = token_amount;
    auction.duration_ms = duration_ms;
    auction.start_time = clock.timestamp_ms();
    auction.state = STATE_ACTIVE;

    event::emit(AuctionStarted {
        auction_id: object::id(auction),
        reserve_price,
        token_amount,
    });
}

// --- Core: place bid ---

/// Place a bid. The bid amount must be:
/// 1. >= reserve_price (if no bids yet)
/// 2. >= current_highest_bid + min_bid_increment (if bids exist)
/// 3. Not from the current highest bidder
///
/// When a new highest bid is placed, the previous highest bidder's deposit
/// is available for withdrawal via `withdraw_losing_bid`.
public fun bid(
    auction: &mut EnglishAuctionRound,
    payment: Coin<sui::sui::SUI>,
    ctx: &mut TxContext,
) {
    assert!(auction.state == STATE_ACTIVE, EWrongState);
    let bidder = ctx.sender();
    let bid_amount = coin::value(&payment);

    // Cannot outbid yourself
    assert!(bidder != auction.highest_bidder, ECannotOutbidSelf);

    if (auction.bid_count == 0) {
        // First bid must meet reserve price
        assert!(bid_amount >= auction.reserve_price, EBidTooLow);
    } else {
        // Subsequent bids must exceed current highest by min_bid_increment
        assert!(bid_amount >= auction.highest_bid + auction.min_bid_increment, EBidTooLow);
    };

    // Record previous highest bidder (for outbid event)
    let previous_bidder = auction.highest_bidder;

    // Track this bidder's total deposit
    if (auction.deposits.contains(bidder)) {
        let existing: &mut u64 = auction.deposits.borrow_mut(bidder);
        *existing = *existing + bid_amount;
    } else {
        auction.deposits.add(bidder, bid_amount);
    };

    // Update auction state
    auction.highest_bid = bid_amount;
    auction.highest_bidder = bidder;
    auction.bid_count = auction.bid_count + 1;

    // Absorb payment into contract balance
    balance::join(&mut auction.payment_collected, coin::into_balance(payment));

    event::emit(BidPlaced {
        bidder,
        amount: bid_amount,
        bid_count: auction.bid_count,
    });

    if (auction.bid_count > 1) {
        event::emit(Outbid {
            previous_bidder,
            new_bidder: bidder,
            new_amount: bid_amount,
        });
    };
}

// --- End auction ---

public fun end_auction(cap: &AdminCap, auction: &mut EnglishAuctionRound, clock: &Clock) {
    assert!(object::id(auction) == cap.auction_id, EUnauthorized);
    assert!(auction.state == STATE_ACTIVE, EWrongState);
    let now = clock.timestamp_ms();
    assert!(now >= auction.start_time + auction.duration_ms, EWrongState);
    assert!(auction.bid_count > 0, ENoBidPlaced);

    auction.state = STATE_ENDED;

    event::emit(AuctionEnded {
        auction_id: object::id(auction),
        winner: auction.highest_bidder,
        winning_bid: auction.highest_bid,
    });
}

// --- Winner claims tokens ---

public fun claim(auction: &mut EnglishAuctionRound, ctx: &mut TxContext): Coin<ENGLISH_AUCTION> {
    assert!(auction.state == STATE_ENDED, EWrongState);
    let claimer = ctx.sender();
    assert!(claimer == auction.highest_bidder, ENotWinner);
    assert!(!auction.winner_claimed, EAlreadyClaimed);

    auction.winner_claimed = true;
    let token = coin::mint(&mut auction.treasury_cap, auction.token_amount, ctx);
    event::emit(Claimed { winner: claimer, token_amount: auction.token_amount });
    token
}

// --- Losing bidders withdraw their deposits ---

public fun withdraw_losing_bid(
    auction: &mut EnglishAuctionRound,
    ctx: &mut TxContext,
): Coin<sui::sui::SUI> {
    assert!(auction.state == STATE_ENDED || auction.state == STATE_CANCELLED, EWrongState);
    let claimer = ctx.sender();
    assert!(auction.deposits.contains(claimer), ENotWinner);

    // Winner cannot withdraw (they pay for the tokens)
    assert!(claimer != auction.highest_bidder || auction.state == STATE_CANCELLED, ENotWinner);

    let deposit = auction.deposits.borrow_mut(claimer);
    let amount = *deposit;
    assert!(amount > 0, EAlreadyClaimed);
    // Remove the entry to prevent re-withdrawal
    auction.deposits.remove(claimer);

    coin::take(&mut auction.payment_collected, amount, ctx)
}

// --- Cancel ---

public fun cancel(cap: &AdminCap, auction: &mut EnglishAuctionRound) {
    assert!(object::id(auction) == cap.auction_id, EUnauthorized);
    assert!(auction.state == STATE_CREATED || auction.state == STATE_ACTIVE, EWrongState);
    auction.state = STATE_CANCELLED;
}

// --- Admin: withdraw winning payment ---

public fun withdraw_winning_payment(
    cap: &AdminCap,
    auction: &mut EnglishAuctionRound,
    ctx: &mut TxContext,
): Coin<sui::sui::SUI> {
    assert!(object::id(auction) == cap.auction_id, EUnauthorized);
    assert!(auction.state == STATE_ENDED, EWrongState);
    assert!(auction.winner_claimed, ENotWinner);
    let amount = balance::value(&auction.payment_collected);
    coin::take(&mut auction.payment_collected, amount, ctx)
}

// --- View helpers ---

public fun state(auction: &EnglishAuctionRound): u8 { auction.state }

public fun highest_bid(auction: &EnglishAuctionRound): u64 { auction.highest_bid }

public fun highest_bidder(auction: &EnglishAuctionRound): address { auction.highest_bidder }

public fun bid_count(auction: &EnglishAuctionRound): u64 { auction.bid_count }

public fun reserve_price(auction: &EnglishAuctionRound): u64 { auction.reserve_price }

public fun token_amount(auction: &EnglishAuctionRound): u64 { auction.token_amount }

// --- Test helpers ---

#[test_only]
public fun create_for_testing(treasury_cap: TreasuryCap<ENGLISH_AUCTION>, ctx: &mut TxContext) {
    let auction = EnglishAuctionRound {
        id: object::new(ctx),
        treasury_cap,
        state: STATE_CREATED,
        reserve_price: 1_000_000_000,
        min_bid_increment: 500_000_000,
        token_amount: 1_000_000_000_000,
        start_time: 0,
        duration_ms: 3_600_000,
        highest_bid: 0,
        highest_bidder: @0x0,
        bid_count: 0,
        winner_claimed: false,
        deposits: sui::table::new(ctx),
        payment_collected: balance::zero(),
    };
    let auction_id = object::id(&auction);
    transfer::share_object(auction);
    transfer::public_transfer(
        AdminCap { id: object::new(ctx), auction_id },
        ctx.sender(),
    );
}
