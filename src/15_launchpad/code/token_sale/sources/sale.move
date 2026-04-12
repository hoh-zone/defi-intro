module token_sale::sale;

use sui::coin::{Self, Coin, TreasuryCap};
use sui::balance::{Self, Balance};
use sui::object::{Self, UID, ID};
use sui::bag;
use sui::transfer;
use sui::event;
use sui::tx_context::TxContext;
use std::option;

// States
const STATE_CREATED: u8 = 0;
const STATE_WHITELIST: u8 = 1;
const STATE_PUBLIC: u8 = 2;
const STATE_ENDED: u8 = 3;
const STATE_DISTRIBUTED: u8 = 4;

// Errors
const EWrongState: u64 = 100;
const ENotWhitelisted: u64 = 101;
const EBelowMin: u64 = 102;
const EAboveMax: u64 = 103;
const EHardCapExceeded: u64 = 104;
const EAlreadyClaimed: u64 = 105;
const EUnauthorized: u64 = 106;
const EInvalidAmount: u64 = 107;

// Sale token type (one-time witness)
public struct SALE has drop {}

public struct SaleRound has key {
    id: UID,
    treasury_cap: TreasuryCap<SALE>,
    payment_collected: Balance<sui::sui::SUI>,
    state: u8,
    price: u64,              // payment per sale token
    min_purchase: u64,
    max_purchase: u64,
    hard_cap: u64,
    total_sold: u64,
    whitelisted: sui::bag::Bag,        // address -> bool
    purchases: sui::bag::Bag,          // address -> PurchaseRecord
}

public struct PurchaseRecord has store {
    amount: u64,
    claimed: bool,
}

public struct AdminCap has key, store {
    id: UID,
    sale_id: ID,
}

// Events
public struct Purchased has copy, drop { buyer: address, amount: u64, payment: u64 }
public struct Claimed has copy, drop { buyer: address, amount: u64 }

fun init(witness: SALE, ctx: &mut TxContext) {
    // Default sale with placeholder values
    let (treasury_cap, metadata) = coin::create_currency<SALE>(
        witness,
        9,
        b"SALE",
        b"Sale Token",
        b"Token for sale",
        option::none(),
        ctx,
    );
    let price = 1;
    let min_purchase = 1;
    let max_purchase = 1_000_000_000_000;
    let hard_cap = 10_000_000_000_000;
    let sale = SaleRound {
        id: object::new(ctx),
        treasury_cap,
        payment_collected: balance::zero(),
        state: STATE_CREATED,
        price,
        min_purchase,
        max_purchase,
        hard_cap,
        total_sold: 0,
        whitelisted: bag::new(ctx),
        purchases: bag::new(ctx),
    };
    let sale_id = object::id(&sale);
    transfer::share_object(sale);
    transfer::public_transfer(AdminCap { id: object::new(ctx), sale_id }, ctx.sender());
    // CoinMetadata is a key+store object; transfer it to sender (can't destructure outside its module)
    transfer::public_transfer(metadata, ctx.sender());
}

/// Create a sale round with custom parameters for testing.
#[test_only]
public fun create_for_testing(
    treasury_cap: TreasuryCap<SALE>,
    price: u64,
    min_purchase: u64,
    max_purchase: u64,
    hard_cap: u64,
    ctx: &mut TxContext,
) {
    let sale = SaleRound {
        id: object::new(ctx),
        treasury_cap,
        payment_collected: balance::zero(),
        state: STATE_CREATED,
        price,
        min_purchase,
        max_purchase,
        hard_cap,
        total_sold: 0,
        whitelisted: bag::new(ctx),
        purchases: bag::new(ctx),
    };
    let sale_id = object::id(&sale);
    transfer::share_object(sale);
    transfer::public_transfer(AdminCap { id: object::new(ctx), sale_id }, ctx.sender());
}

// --- State Transitions ---

public fun start_whitelist(cap: &AdminCap, sale: &mut SaleRound) {
    assert!(object::id(sale) == cap.sale_id, EUnauthorized);
    assert!(sale.state == STATE_CREATED, EWrongState);
    sale.state = STATE_WHITELIST;
}

public fun start_public_sale(cap: &AdminCap, sale: &mut SaleRound) {
    assert!(object::id(sale) == cap.sale_id, EUnauthorized);
    assert!(sale.state == STATE_WHITELIST, EWrongState);
    sale.state = STATE_PUBLIC;
}

public fun end_sale(cap: &AdminCap, sale: &mut SaleRound) {
    assert!(object::id(sale) == cap.sale_id, EUnauthorized);
    assert!(sale.state == STATE_PUBLIC, EWrongState);
    sale.state = STATE_ENDED;
}

public fun start_distribution(cap: &AdminCap, sale: &mut SaleRound) {
    assert!(object::id(sale) == cap.sale_id, EUnauthorized);
    assert!(sale.state == STATE_ENDED, EWrongState);
    sale.state = STATE_DISTRIBUTED;
}

// --- Whitelist ---

public fun add_to_whitelist(cap: &AdminCap, sale: &mut SaleRound, addr: address) {
    assert!(object::id(sale) == cap.sale_id, EUnauthorized);
    bag::add(&mut sale.whitelisted, addr, true);
}

public fun add_batch_whitelist(cap: &AdminCap, sale: &mut SaleRound, addrs: vector<address>) {
    assert!(object::id(sale) == cap.sale_id, EUnauthorized);
    let mut i = 0;
    let len = addrs.length();
    while (i < len) {
        bag::add(&mut sale.whitelisted, addrs[i], true);
        i = i + 1;
    };
}

// --- Purchase ---

public fun purchase(sale: &mut SaleRound, payment: Coin<sui::sui::SUI>, ctx: &mut TxContext) {
    let buyer = ctx.sender();
    let payment_amount = coin::value(&payment);
    assert!(payment_amount > 0, EInvalidAmount);

    // Check state: either whitelist (must be whitelisted) or public
    let is_whitelist = sale.state == STATE_WHITELIST;
    let is_public = sale.state == STATE_PUBLIC;
    assert!(is_whitelist || is_public, EWrongState);

    if (is_whitelist) {
        assert!(bag::contains(&sale.whitelisted, buyer), ENotWhitelisted);
    };

    let purchase_amount = payment_amount / sale.price;
    assert!(purchase_amount >= sale.min_purchase, EBelowMin);
    assert!(purchase_amount <= sale.max_purchase, EAboveMax);
    assert!(sale.total_sold + purchase_amount <= sale.hard_cap, EHardCapExceeded);

    // Record purchase
    bag::add(&mut sale.purchases, buyer, PurchaseRecord { amount: purchase_amount, claimed: false });
    sale.total_sold = sale.total_sold + purchase_amount;

    balance::join(&mut sale.payment_collected, coin::into_balance(payment));
    event::emit(Purchased { buyer, amount: purchase_amount, payment: payment_amount });
}

// --- Claim ---

public fun claim(sale: &mut SaleRound, ctx: &mut TxContext): Coin<SALE> {
    assert!(sale.state == STATE_DISTRIBUTED, EWrongState);
    let buyer = ctx.sender();
    assert!(bag::contains(&sale.purchases, buyer), ENotWhitelisted);

    let record: &mut PurchaseRecord = bag::borrow_mut(&mut sale.purchases, buyer);
    assert!(!record.claimed, EAlreadyClaimed);
    let amount = record.amount;
    record.claimed = true;

    let token = coin::mint(&mut sale.treasury_cap, amount, ctx);
    event::emit(Claimed { buyer, amount });
    token
}

// --- Admin withdraw ---

public fun withdraw_payments(cap: &AdminCap, sale: &mut SaleRound, ctx: &mut TxContext): Coin<sui::sui::SUI> {
    assert!(object::id(sale) == cap.sale_id, EUnauthorized);
    assert!(sale.state == STATE_ENDED || sale.state == STATE_DISTRIBUTED, EWrongState);
    let amount = balance::value(&sale.payment_collected);
    coin::take(&mut sale.payment_collected, amount, ctx)
}

// --- View ---

public fun state(sale: &SaleRound): u8 { sale.state }
public fun total_sold(sale: &SaleRound): u64 { sale.total_sold }
public fun is_whitelisted(sale: &SaleRound, addr: address): bool {
    bag::contains(&sale.whitelisted, addr)
}
public fun has_purchased(sale: &SaleRound, addr: address): bool {
    bag::contains(&sale.purchases, addr)
}
