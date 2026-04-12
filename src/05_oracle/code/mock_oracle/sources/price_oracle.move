/// Module: mock_oracle::price_oracle
/// A self-contained mock oracle for DeFi educational purposes (Chapter 5).
/// Supports single-price feeds, TWAP history, and safe price reads.
module mock_oracle::price_oracle {

    // ===== Error codes =====

    /// The stored price is older than the caller's maximum allowed staleness.
    const EStalePrice: u64 = 0;
    /// The price deviates from the reference by more than the allowed basis points.
    const EPriceDeviation: u64 = 1;
    /// Caller does not hold the required AdminCap.
    const EUnauthorized: u64 = 2;
    /// The provided price or confidence is zero.
    const EInvalidPrice: u64 = 3;

    // ===== Constants =====

    /// Maximum number of TWAP observations retained.
    const MAX_OBSERVATIONS: u64 = 100;
    /// Basis-points denominator (10 000).
    const BPS_DENOMINATOR: u64 = 10_000;

    // ===== Structs =====

    /// Admin capability -- only the holder may update the oracle price.
    public struct AdminCap has key, store {
        id: UID,
    }

    /// A single price snapshot stored inside the Oracle.
    public struct PriceFeed has copy, drop, store {
        price: u64,
        confidence: u64,
        timestamp_ms: u64,
    }

    /// One observation used for TWAP computation.
    public struct TwapObservation has copy, drop, store {
        timestamp_ms: u64,
        price: u64,
        cumulative_price: u64,
    }

    /// Shared oracle object containing the current price feed and TWAP history.
    public struct Oracle has key {
        id: UID,
        feed: PriceFeed,
        observations: vector<TwapObservation>,
        last_update_ms: u64,
    }

    // ===== Init =====

    /// Create the Oracle (shared) and an AdminCap transferred to the publisher.
    fun init(ctx: &mut tx_context::TxContext) {
        let oracle = Oracle {
            id: object::new(ctx),
            feed: PriceFeed { price: 0, confidence: 0, timestamp_ms: 0 },
            observations: vector::empty(),
            last_update_ms: 0,
        };
        transfer::share_object(oracle);

        let cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    /// Test helper: manually create the Oracle and AdminCap (same logic as init).
    #[test_only]
    public fun create_for_test(ctx: &mut tx_context::TxContext) {
        let oracle = Oracle {
            id: object::new(ctx),
            feed: PriceFeed { price: 0, confidence: 0, timestamp_ms: 0 },
            observations: vector::empty(),
            last_update_ms: 0,
        };
        transfer::share_object(oracle);

        let cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    // ===== Admin: update price =====

    /// Update the oracle price. Only the AdminCap holder may call this.
    /// Also records a TWAP observation (capped at MAX_OBSERVATIONS).
    public fun update_price(
        _cap: &AdminCap,
        oracle: &mut Oracle,
        price: u64,
        confidence: u64,
        timestamp_ms: u64,
    ) {
        assert!(price > 0, EInvalidPrice);
        assert!(confidence > 0, EInvalidPrice);

        // Compute cumulative price for TWAP.
        let prev_cum = cumulative_end(oracle);
        let elapsed = if (oracle.last_update_ms == 0) {
            0
        } else {
            timestamp_ms - oracle.last_update_ms
        };
        let new_cum = prev_cum + (oracle.feed.price * elapsed);

        // Append observation.
        let obs = TwapObservation {
            timestamp_ms,
            price,
            cumulative_price: new_cum,
        };
        vector::push_back(&mut oracle.observations, obs);

        // Cap the observation vector.
        if (vector::length(&oracle.observations) > MAX_OBSERVATIONS) {
            vector::remove(&mut oracle.observations, 0);
        };

        // Persist the new feed.
        oracle.feed = PriceFeed { price, confidence, timestamp_ms };
        oracle.last_update_ms = timestamp_ms;
    }

    // ===== Read helpers =====

    /// Return the current price feed (price, confidence, timestamp).
    public fun get_price(oracle: &Oracle): PriceFeed {
        oracle.feed
    }

    /// Convenience: return just the price.
    public fun get_price_value(oracle: &Oracle): u64 {
        oracle.feed.price
    }

    // ===== TWAP =====

    /// Calculate the Time-Weighted Average Price over the last `period_ms`
    /// milliseconds relative to `current_ms`.
    ///
    /// Formula:  twap = (cum_end - cum_start) / (ts_end - ts_start)
    ///
    /// If there are no observations in the window, returns the current price.
    public fun get_twap(oracle: &Oracle, period_ms: u64, current_ms: u64): u64 {
        let obs = &oracle.observations;
        let len = vector::length(obs);

        // No history -- return current price.
        if (len == 0) {
            return oracle.feed.price;
        };

        // cum_end = last cumulative_price
        let cum_end = cumulative_end(oracle);
        let ts_end = current_ms;
        let cutoff = if (ts_end > period_ms) { ts_end - period_ms } else { 0 };

        // Walk backwards to find the first observation at or before cutoff.
        let mut idx: u64 = 0;
        let mut found = false;
        let mut cum_start: u64 = 0;
        let mut ts_start: u64 = 0;
        let mut i: u64 = 0;
        while (i < len) {
            let o = vector::borrow(obs, i);
            if (o.timestamp_ms >= cutoff) {
                idx = i;
                found = true;
                break
            };
            i = i + 1;
        };

        if (!found) {
            // Entire window is before any observation; use earliest.
            let first = vector::borrow(obs, 0);
            cum_start = first.cumulative_price;
            ts_start = first.timestamp_ms;
        } else if (idx == 0) {
            // Only one observation in window.
            let first = vector::borrow(obs, 0);
            cum_start = first.cumulative_price;
            ts_start = first.timestamp_ms;
        } else {
            // Use observation just before cutoff for continuity.
            let prev = vector::borrow(obs, idx - 1);
            cum_start = prev.cumulative_price;
            ts_start = prev.timestamp_ms;
        };

        let dt = ts_end - ts_start;
        if (dt == 0) {
            return oracle.feed.price;
        };
        (cum_end - cum_start) / dt
    }

    // ===== Safe price read =====

    /// Read the price with safety guards:
    /// 1. Staleness check: `current_ms - feed.timestamp_ms <= max_staleness_ms`
    /// 2. Deviation check: price within `max_deviation_bps` basis points of
    ///    `reference_price`.
    /// Aborts with EStalePrice or EPriceDeviation on failure.
    public fun safe_read_price(
        oracle: &Oracle,
        max_staleness_ms: u64,
        max_deviation_bps: u64,
        reference_price: u64,
        current_ms: u64,
    ): u64 {
        // Staleness check.
        let age = current_ms - oracle.feed.timestamp_ms;
        assert!(age <= max_staleness_ms, EStalePrice);

        // Deviation check.
        if (reference_price > 0) {
            let diff = if (oracle.feed.price > reference_price) {
                oracle.feed.price - reference_price
            } else {
                reference_price - oracle.feed.price
            };
            let deviation_bps = (diff * BPS_DENOMINATOR) / reference_price;
            assert!(deviation_bps <= max_deviation_bps, EPriceDeviation);
        };

        oracle.feed.price
    }

    // ===== Pure helpers =====

    /// Validate that `price` falls within `[min_price, max_price]`.
    /// Returns `true` if valid, `false` otherwise (does not abort).
    public fun validate_price_range(price: u64, min_price: u64, max_price: u64): bool {
        price >= min_price && price <= max_price
    }

    /// Return the median of a non-empty vector of prices.
    /// Sorts in-place then picks the middle element (or average of two
    /// middle elements for even-length vectors).
    public fun aggregate_prices(prices: &mut vector<u64>): u64 {
        let len = vector::length(prices);
        assert!(len > 0, EInvalidPrice);

        // Bubble sort -- fine for small N in a mock oracle.
        let mut i: u64 = 0;
        while (i < len) {
            let mut j: u64 = 0;
            while (j < len - 1 - i) {
                let a = *vector::borrow(prices, j);
                let b = *vector::borrow(prices, j + 1);
                if (a > b) {
                    vector::swap(prices, j, j + 1);
                };
                j = j + 1;
            };
            i = i + 1;
        };

        let mid = len / 2;
        if (len % 2 == 1) {
            *vector::borrow(prices, mid)
        } else {
            (*vector::borrow(prices, mid - 1) + *vector::borrow(prices, mid)) / 2
        }
    }

    // ===== Internal helpers =====

    /// Return the cumulative_price of the last observation, or 0 if none.
    fun cumulative_end(oracle: &Oracle): u64 {
        let obs = &oracle.observations;
        let len = vector::length(obs);
        if (len == 0) {
            0
        } else {
            vector::borrow(obs, len - 1).cumulative_price
        }
    }

    // ===== Accessors for tests / external modules =====

    public fun feed_price(feed: &PriceFeed): u64 { feed.price }
    public fun feed_confidence(feed: &PriceFeed): u64 { feed.confidence }
    public fun feed_timestamp(feed: &PriceFeed): u64 { feed.timestamp_ms }
    public fun observation_timestamp(o: &TwapObservation): u64 { o.timestamp_ms }
    public fun observation_price(o: &TwapObservation): u64 { o.price }
    public fun observation_cumulative(o: &TwapObservation): u64 { o.cumulative_price }

    // ===== AdminCap destructor (for test cleanup) =====

    public fun delete_admin_cap(cap: AdminCap) {
        let AdminCap { id } = cap;
        id.delete();
    }

    // ===== Oracle destructor (for test cleanup) =====

    public fun delete_oracle(oracle: Oracle) {
        let Oracle { id, feed: _, observations: _, last_update_ms: _ } = oracle;
        id.delete();
    }
}
