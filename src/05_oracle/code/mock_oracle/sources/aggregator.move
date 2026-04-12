/// Module: mock_oracle::aggregator
/// Multi-source oracle aggregator for DeFi educational purposes (Chapter 5).
/// Collects prices from N independent sources and returns the median.
module mock_oracle::aggregator;
use mock_oracle::price_oracle::aggregate_prices;

// ===== Error codes =====

const EUnauthorized: u64 = 100;
const ESourceExists: u64 = 101;
const ENoSources: u64 = 102;
const ESourceNotFound: u64 = 103;
const EInvalidPrice: u64 = 104;

// ===== Structs =====

/// Admin capability for the aggregator.
public struct AggregatorAdminCap has key, store {
    id: UID,
}

/// One registered price source.
public struct Source has copy, drop, store {
    source_id: u64,
    price: u64,
    timestamp_ms: u64,
}

/// Shared aggregator object holding multiple price sources.
public struct Aggregator has key {
    id: UID,
    sources: vector<Source>,
    next_source_id: u64,
}

// ===== Init =====

fun init(ctx: &mut tx_context::TxContext) {
    let aggregator = Aggregator {
        id: object::new(ctx),
        sources: vector::empty(),
        next_source_id: 0,
    };
    transfer::share_object(aggregator);

    let cap = AggregatorAdminCap { id: object::new(ctx) };
    transfer::transfer(cap, tx_context::sender(ctx));
}

/// Test helper: manually create the Aggregator and AdminCap (same logic as init).
#[test_only]
public fun create_for_test(ctx: &mut tx_context::TxContext) {
    let aggregator = Aggregator {
        id: object::new(ctx),
        sources: vector::empty(),
        next_source_id: 0,
    };
    transfer::share_object(aggregator);

    let cap = AggregatorAdminCap { id: object::new(ctx) };
    transfer::transfer(cap, tx_context::sender(ctx));
}

// ===== Admin: manage sources =====

/// Register a new price source. Returns the assigned source_id.
public fun add_source(
    _cap: &AggregatorAdminCap,
    aggregator: &mut Aggregator,
    ctx: &mut tx_context::TxContext,
): u64 {
    let sid = aggregator.next_source_id;
    let source = Source {
        source_id: sid,
        price: 0,
        timestamp_ms: 0,
    };
    vector::push_back(&mut aggregator.sources, source);
    aggregator.next_source_id = sid + 1;
    sid
}

/// Update the price for a previously registered source.
public fun update_source_price(
    _cap: &AggregatorAdminCap,
    aggregator: &mut Aggregator,
    source_id: u64,
    price: u64,
    timestamp_ms: u64,
) {
    assert!(price > 0, EInvalidPrice);
    let len = vector::length(&aggregator.sources);
    let mut i: u64 = 0;
    let mut found = false;
    while (i < len) {
        let src = vector::borrow_mut(&mut aggregator.sources, i);
        if (src.source_id == source_id) {
            src.price = price;
            src.timestamp_ms = timestamp_ms;
            found = true;
            break
        };
        i = i + 1;
    };
    assert!(found, ESourceNotFound);
}

// ===== Reads =====

/// Return the median price across all active sources.
/// Active = source with a non-zero price.
public fun get_aggregated_price(aggregator: &Aggregator): u64 {
    let len = vector::length(&aggregator.sources);
    assert!(len > 0, ENoSources);

    // Collect non-zero prices.
    let mut prices: vector<u64> = vector::empty();
    let mut i: u64 = 0;
    while (i < len) {
        let src = vector::borrow(&aggregator.sources, i);
        if (src.price > 0) {
            vector::push_back(&mut prices, src.price);
        };
        i = i + 1;
    };

    assert!(vector::length(&prices) > 0, ENoSources);
    aggregate_prices(&mut prices)
}

/// Return the number of registered sources (including inactive ones).
public fun get_source_count(aggregator: &Aggregator): u64 {
    vector::length(&aggregator.sources)
}

/// Return the number of active (non-zero price) sources.
public fun get_active_source_count(aggregator: &Aggregator): u64 {
    let mut count: u64 = 0;
    let len = vector::length(&aggregator.sources);
    let mut i: u64 = 0;
    while (i < len) {
        let src = vector::borrow(&aggregator.sources, i);
        if (src.price > 0) {
            count = count + 1;
        };
        i = i + 1;
    };
    count
}

// ===== Accessors =====

public fun source_id(src: &Source): u64 { src.source_id }
public fun source_price(src: &Source): u64 { src.price }
public fun source_timestamp(src: &Source): u64 { src.timestamp_ms }

// ===== Cleanup for tests =====

public fun delete_aggregator_admin_cap(cap: AggregatorAdminCap) {
    let AggregatorAdminCap { id } = cap;
    id.delete();
}

public fun delete_aggregator(aggregator: Aggregator) {
    let Aggregator { id, sources: _, next_source_id: _ } = aggregator;
    id.delete();
}
