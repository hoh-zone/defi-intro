#[test_only]
module mock_oracle::oracle_test;

use mock_oracle::aggregator;
use mock_oracle::price_oracle;
use std::unit_test::assert_eq;
use sui::test_scenario;

const ADMIN: address = @0xAD;

// ===== price_oracle tests =====

#[test]
/// Verify that create_for_test creates an Oracle (shared) and an AdminCap owned by sender.
fun oracle_init() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    price_oracle::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let oracle = test_scenario::take_shared<price_oracle::Oracle>(&scenario);
        let feed = price_oracle::price(&oracle);
        assert_eq!(price_oracle::feed_price(&feed), 0);
        assert_eq!(price_oracle::feed_confidence(&feed), 0);
        test_scenario::return_shared(oracle);
    };
    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<price_oracle::AdminCap>();
        price_oracle::delete_admin_cap(cap);
    };
    scenario.end();
}

#[test]
/// Update price and read it back.
fun price_update_and_get() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Use create_for_test to create oracle objects that can be taken together.
    let ctx = scenario.ctx();
    price_oracle::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<price_oracle::AdminCap>();
        let mut oracle = test_scenario::take_shared<price_oracle::Oracle>(&scenario);

        price_oracle::update_price(&cap, &mut oracle, 1_000, 100, 1000);

        let feed = price_oracle::price(&oracle);
        assert_eq!(price_oracle::feed_price(&feed), 1_000);
        assert_eq!(price_oracle::feed_confidence(&feed), 100);
        assert_eq!(price_oracle::feed_timestamp(&feed), 1000);

        test_scenario::return_shared(oracle);
        price_oracle::delete_admin_cap(cap);
    };
    scenario.end();
}

#[test]
/// Update price multiple times and verify TWAP.
fun twap_calculation() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    price_oracle::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<price_oracle::AdminCap>();
        let mut oracle = test_scenario::take_shared<price_oracle::Oracle>(&scenario);

        // First update at t=1000.
        price_oracle::update_price(&cap, &mut oracle, 1_000, 100, 1000);
        // Second update at t=2000.
        price_oracle::update_price(&cap, &mut oracle, 2_000, 100, 2000);
        // Third update at t=3000.
        price_oracle::update_price(&cap, &mut oracle, 3_000, 100, 3000);

        // TWAP over 2000 ms ending at t=3000.
        let twap = price_oracle::twap(&oracle, 2000, 3000);
        assert!(twap == 1_500, twap);

        test_scenario::return_shared(oracle);
        price_oracle::delete_admin_cap(cap);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = price_oracle::EStalePrice)]
/// Reject a price that is too stale.
fun stale_price_rejection() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    price_oracle::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<price_oracle::AdminCap>();
        let mut oracle = test_scenario::take_shared<price_oracle::Oracle>(&scenario);

        // Set price at t=1000.
        price_oracle::update_price(&cap, &mut oracle, 1_000, 100, 1000);

        // Try to read at t=5000 with max staleness 1000ms => age=4000 > 1000 => abort.
        price_oracle::safe_read_price(
            &oracle,
            1000, // max_staleness_ms
            10_000, // max_deviation_bps (very loose)
            1_000, // reference_price
            5000, // current_ms
        );

        test_scenario::return_shared(oracle);
        price_oracle::delete_admin_cap(cap);
    };
    scenario.end();
}

#[test, expected_failure(abort_code = price_oracle::EPriceDeviation)]
/// Reject a price that deviates too much from the reference.
fun price_deviation_rejection() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    price_oracle::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<price_oracle::AdminCap>();
        let mut oracle = test_scenario::take_shared<price_oracle::Oracle>(&scenario);

        // Set price at t=1000.
        price_oracle::update_price(&cap, &mut oracle, 1_000, 100, 1000);

        // Read at t=1500; age=500 <= 1000 ok, but price=1000 vs reference=800
        // diff=200, bps = 200*10000/800 = 2500 > 1000 bps => abort.
        price_oracle::safe_read_price(
            &oracle,
            1000, // max_staleness_ms
            1000, // max_deviation_bps = 10%
            800, // reference_price
            1500, // current_ms
        );

        test_scenario::return_shared(oracle);
        price_oracle::delete_admin_cap(cap);
    };
    scenario.end();
}

#[test]
/// Safe read passes when price is fresh and within deviation.
fun safe_read_ok() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    price_oracle::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<price_oracle::AdminCap>();
        let mut oracle = test_scenario::take_shared<price_oracle::Oracle>(&scenario);

        price_oracle::update_price(&cap, &mut oracle, 1_000, 100, 1000);

        let price = price_oracle::safe_read_price(
            &oracle,
            1000, // max_staleness_ms
            1000, // max_deviation_bps = 10%
            950, // reference_price (close enough)
            1500, // current_ms => age=500 <= 1000
        );
        assert!(price == 1_000, price);

        test_scenario::return_shared(oracle);
        price_oracle::delete_admin_cap(cap);
    };
    scenario.end();
}

#[test]
/// validate_price_range works correctly.
fun validate_price_range() {
    assert!(price_oracle::validate_price_range(500, 100, 1000), 0);
    assert!(price_oracle::validate_price_range(100, 100, 1000), 0);
    assert!(price_oracle::validate_price_range(1000, 100, 1000), 0);
    assert!(!price_oracle::validate_price_range(99, 100, 1000), 0);
    assert!(!price_oracle::validate_price_range(1001, 100, 1000), 0);
}

#[test]
/// aggregate_prices returns the median.
fun aggregate_median() {
    // Odd number of sources.
    let mut prices = vector::empty();
    vector::push_back(&mut prices, 300);
    vector::push_back(&mut prices, 100);
    vector::push_back(&mut prices, 200);
    let median = price_oracle::aggregate_prices(&mut prices);
    assert!(median == 200, median);

    // Even number of sources => average of two middle.
    let mut prices2 = vector::empty();
    vector::push_back(&mut prices2, 400);
    vector::push_back(&mut prices2, 100);
    vector::push_back(&mut prices2, 300);
    vector::push_back(&mut prices2, 200);
    let median2 = price_oracle::aggregate_prices(&mut prices2);
    // sorted: 100, 200, 300, 400 => (200+300)/2 = 250
    assert!(median2 == 250, median2);
}

#[test, expected_failure(abort_code = price_oracle::EInvalidPrice)]
/// aggregate_prices aborts on empty vector.
fun aggregate_empty() {
    let mut prices = vector::empty();
    price_oracle::aggregate_prices(&mut prices);
}

#[test, expected_failure(abort_code = price_oracle::EInvalidPrice)]
/// update_price rejects zero price.
fun update_price_zero() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    price_oracle::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<price_oracle::AdminCap>();
        let mut oracle = test_scenario::take_shared<price_oracle::Oracle>(&scenario);
        price_oracle::update_price(&cap, &mut oracle, 0, 100, 1000);
        test_scenario::return_shared(oracle);
        price_oracle::delete_admin_cap(cap);
    };
    scenario.end();
}

// ===== aggregator tests =====

#[test]
/// Aggregator init and source count.
fun aggregator_init() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    aggregator::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let agg = test_scenario::take_shared<aggregator::Aggregator>(&scenario);
        assert_eq!(aggregator::source_count(&agg), 0);
        test_scenario::return_shared(agg);
    };
    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<aggregator::AggregatorAdminCap>();
        aggregator::delete_aggregator_admin_cap(cap);
    };
    scenario.end();
}

#[test]
/// Single source aggregation.
fun single_source_aggregation() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    aggregator::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<aggregator::AggregatorAdminCap>();
        let mut agg = test_scenario::take_shared<aggregator::Aggregator>(&scenario);

        let sid = aggregator::add_source(&cap, &mut agg, scenario.ctx());
        aggregator::update_source_price(&cap, &mut agg, sid, 1_000, 1000);

        assert_eq!(aggregator::source_count(&agg), 1);
        assert_eq!(aggregator::active_source_count(&agg), 1);

        let price = aggregator::aggregated_price(&agg);
        assert!(price == 1_000, price);

        test_scenario::return_shared(agg);
        aggregator::delete_aggregator_admin_cap(cap);
    };
    scenario.end();
}

#[test]
/// Multiple sources, all same price.
fun all_sources_same_price() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    aggregator::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<aggregator::AggregatorAdminCap>();
        let mut agg = test_scenario::take_shared<aggregator::Aggregator>(&scenario);

        let s1 = aggregator::add_source(&cap, &mut agg, scenario.ctx());
        let s2 = aggregator::add_source(&cap, &mut agg, scenario.ctx());
        let s3 = aggregator::add_source(&cap, &mut agg, scenario.ctx());

        aggregator::update_source_price(&cap, &mut agg, s1, 2_000, 1000);
        aggregator::update_source_price(&cap, &mut agg, s2, 2_000, 1000);
        aggregator::update_source_price(&cap, &mut agg, s3, 2_000, 1000);

        let price = aggregator::aggregated_price(&agg);
        assert!(price == 2_000, price);

        test_scenario::return_shared(agg);
        aggregator::delete_aggregator_admin_cap(cap);
    };
    scenario.end();
}

#[test]
/// Multiple sources with different prices => median.
fun multi_source_median() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    aggregator::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<aggregator::AggregatorAdminCap>();
        let mut agg = test_scenario::take_shared<aggregator::Aggregator>(&scenario);

        let s1 = aggregator::add_source(&cap, &mut agg, scenario.ctx());
        let s2 = aggregator::add_source(&cap, &mut agg, scenario.ctx());
        let s3 = aggregator::add_source(&cap, &mut agg, scenario.ctx());
        let s4 = aggregator::add_source(&cap, &mut agg, scenario.ctx());
        let s5 = aggregator::add_source(&cap, &mut agg, scenario.ctx());

        aggregator::update_source_price(&cap, &mut agg, s1, 990, 1000);
        aggregator::update_source_price(&cap, &mut agg, s2, 1010, 1000);
        aggregator::update_source_price(&cap, &mut agg, s3, 1_000, 1000);
        aggregator::update_source_price(&cap, &mut agg, s4, 1_020, 1000);
        aggregator::update_source_price(&cap, &mut agg, s5, 980, 1000);

        // Sorted: 980, 990, 1000, 1010, 1020 => median = 1000
        let price = aggregator::aggregated_price(&agg);
        assert!(price == 1_000, price);

        test_scenario::return_shared(agg);
        aggregator::delete_aggregator_admin_cap(cap);
    };
    scenario.end();
}

#[test]
/// TWAP over full observation history.
fun twap_full_history() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    price_oracle::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        let cap = scenario.take_from_sender<price_oracle::AdminCap>();
        let mut oracle = test_scenario::take_shared<price_oracle::Oracle>(&scenario);

        // Price stays at 100 for 10 seconds.
        // First update at t=1000 (must be non-zero to accumulate).
        price_oracle::update_price(&cap, &mut oracle, 100, 10, 1000);
        // Second update at t=11000.
        price_oracle::update_price(&cap, &mut oracle, 100, 10, 11_000);

        // TWAP over full 10s period ending at t=11000.
        // cum at t=1000 = 0 (first obs, elapsed was 0 because last_update_ms was 0).
        // cum at t=11000 = 0 + 100 * (11000 - 1000) = 1_000_000.
        // twap = 1_000_000 / (11000 - 1000) = 100.
        let twap = price_oracle::twap(&oracle, 10_000, 11_000);
        assert!(twap == 100, twap);

        test_scenario::return_shared(oracle);
        price_oracle::delete_admin_cap(cap);
    };
    scenario.end();
}

#[test]
/// TWAP with no observations returns current price.
fun twap_no_observations() {
    let mut scenario = test_scenario::begin(ADMIN);

    let ctx = scenario.ctx();
    price_oracle::create_for_test(ctx);

    scenario.next_tx(ADMIN);
    {
        // Take the oracle but do NOT update price (observations empty).
        let oracle = test_scenario::take_shared<price_oracle::Oracle>(&scenario);
        let cap = scenario.take_from_sender<price_oracle::AdminCap>();

        // Current feed.price is 0 (init default), so TWAP returns 0.
        let twap = price_oracle::twap(&oracle, 5_000, 10_000);
        assert!(twap == 0, twap);

        test_scenario::return_shared(oracle);
        price_oracle::delete_admin_cap(cap);
    };
    scenario.end();
}
