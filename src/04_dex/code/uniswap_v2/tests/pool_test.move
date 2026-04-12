#[test_only]
module uniswap_v2::test_coin_a {
    public struct COINA has copy, drop, store {}

}
#[test_only]
module uniswap_v2::test_coin_b {
    public struct COINB has copy, drop, store {}

}
#[test_only]
module uniswap_v2::pool_test {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use uniswap_v2::pool;
    use uniswap_v2::test_coin_a::COINA;
    use uniswap_v2::test_coin_b::COINB;

    // ========== Helpers ==========

    /// Transfer a coin to sender for cleanup.
    fun discard<T>(c: Coin<T>, ctx: &mut TxContext) {
        transfer::public_transfer(c, tx_context::sender(ctx));
    }

    /// Transfer an LP token to sender for cleanup.
    fun discard_lp(lp: pool::LP<COINA, COINB>, ctx: &mut TxContext) {
        transfer::public_transfer(lp, tx_context::sender(ctx));
    }

    /// Transfer TreasuryCap to sender for cleanup.
    fun cleanup_treasury<T>(treasury: TreasuryCap<T>, ctx: &mut TxContext) {
        transfer::public_transfer(treasury, tx_context::sender(ctx));
    }

    /// Setup: create treasury caps for both test currencies.
    fun setup_currencies(ctx: &mut TxContext): (TreasuryCap<COINA>, TreasuryCap<COINB>) {
        let ta = coin::create_treasury_cap_for_testing<COINA>(ctx);
        let tb = coin::create_treasury_cap_for_testing<COINB>(ctx);
        (ta, tb)
    }

    /// Cleanup: transfer treasury caps to sender.
    fun teardown(
        treasury_a: TreasuryCap<COINA>, treasury_b: TreasuryCap<COINB>,
        ctx: &mut TxContext
    ) {
        cleanup_treasury(treasury_a, ctx);
        cleanup_treasury(treasury_b, ctx);
    }

    // ========== Test: Create Pool ==========

    #[test]
    fun test_create_pool() {
        use sui::test_scenario;

        let mut scenario = test_scenario::begin(@0xA);

        {
            let ctx = scenario.ctx();
            let (mut treasury_a, mut treasury_b) = setup_currencies(ctx);

            let coin_a = coin::mint(&mut treasury_a, 1000000, ctx);
            let coin_b = coin::mint(&mut treasury_b, 2000000, ctx);
            pool::create_pool(coin_a, coin_b, 30, ctx);

            teardown(treasury_a, treasury_b, ctx);
        };

        scenario.end();
    }

    // ========== Test: Add Liquidity (First LP) ==========

    #[test]
    fun test_add_liquidity_first_lp() {
        use sui::test_scenario;

        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_a, mut treasury_b) = {
            let ctx = scenario.ctx();
            let (mut ta, mut tb) = setup_currencies(ctx);
            let coin_a = coin::mint(&mut ta, 1000000, ctx);
            let coin_b = coin::mint(&mut tb, 2000000, ctx);
            pool::create_pool(coin_a, coin_b, 30, ctx);
            (ta, tb)
        };

        // Transaction 2: Add liquidity as first LP
        scenario.next_tx(@0xA);
        {
            let coin_a = coin::mint(&mut treasury_a, 100000, scenario.ctx());
            let coin_b = coin::mint(&mut treasury_b, 200000, scenario.ctx());
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            pool::add_liquidity(&mut pool_obj, coin_a, coin_b, 0, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Transaction 3: Verify LP token
        scenario.next_tx(@0xA);
        {
            let lp: pool::LP<COINA, COINB> = test_scenario::take_from_sender(&scenario);
            // First LP shares = sqrt(100000 * 200000) = sqrt(20_000_000_000) = 141421
            assert!(pool::lp_shares(&lp) == 141421);
            discard_lp(lp, scenario.ctx());
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let ctx = scenario.ctx();
            teardown(treasury_a, treasury_b, ctx);
        };

        scenario.end();
    }

    // ========== Test: Add Liquidity (Subsequent LP) ==========

    #[test]
    fun test_add_liquidity_subsequent() {
        use sui::test_scenario;

        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_a, mut treasury_b) = {
            let ctx = scenario.ctx();
            let (mut ta, mut tb) = setup_currencies(ctx);
            let coin_a = coin::mint(&mut ta, 1000000, ctx);
            let coin_b = coin::mint(&mut tb, 2000000, ctx);
            pool::create_pool(coin_a, coin_b, 30, ctx);
            (ta, tb)
        };

        // Transaction 2: First LP adds liquidity
        scenario.next_tx(@0xA);
        {
            let coin_a = coin::mint(&mut treasury_a, 100000, scenario.ctx());
            let coin_b = coin::mint(&mut treasury_b, 200000, scenario.ctx());
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            pool::add_liquidity(&mut pool_obj, coin_a, coin_b, 0, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Transaction 3: Take first LP, second LP adds liquidity
        scenario.next_tx(@0xA);
        let lp1: pool::LP<COINA, COINB> = test_scenario::take_from_sender(&scenario);
        {
            let coin_a = coin::mint(&mut treasury_a, 50000, scenario.ctx());
            let coin_b = coin::mint(&mut treasury_b, 100000, scenario.ctx());
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            pool::add_liquidity(&mut pool_obj, coin_a, coin_b, 0, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Transaction 4: Verify second LP shares
        scenario.next_tx(@0xA);
        {
            let lp2: pool::LP<COINA, COINB> = test_scenario::take_from_sender(&scenario);
            // Reserves: 1_100_000 A, 2_200_000 B, total_supply = 141_421
            // shares = min(50000 * 141421 / 1100000, 100000 * 141421 / 2200000)
            //        = min(6428, 6428) = 6428
            assert!(pool::lp_shares(&lp2) == 6428);
            discard_lp(lp2, scenario.ctx());
            discard_lp(lp1, scenario.ctx());
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let ctx = scenario.ctx();
            teardown(treasury_a, treasury_b, ctx);
        };

        scenario.end();
    }

    // ========== Test: Swap A to B ==========

    #[test]
    fun test_swap_a_to_b() {
        use sui::test_scenario;

        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_a, mut treasury_b) = {
            let ctx = scenario.ctx();
            let (mut ta, mut tb) = setup_currencies(ctx);
            let coin_a = coin::mint(&mut ta, 1000, ctx);
            let coin_b = coin::mint(&mut tb, 2000, ctx);
            pool::create_pool(coin_a, coin_b, 30, ctx);
            (ta, tb)
        };

        // Transaction 2: Swap 100 A for B
        scenario.next_tx(@0xA);
        {
            let input_a = coin::mint(&mut treasury_a, 100, scenario.ctx());
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            let output_b = pool::swap_a_to_b(&mut pool_obj, input_a, 0, scenario.ctx());
            // get_amount_out(100, 1000, 2000, 30):
            // amount_in_with_fee = 100 * 9970 = 997000
            // numerator = 997000 * 2000 = 1994000000
            // denominator = 1000 * 10000 + 997000 = 10997000
            // output = 1994000000 / 10997000 = 181
            assert!(coin::value(&output_b) == 181);
            discard(output_b, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let ctx = scenario.ctx();
            teardown(treasury_a, treasury_b, ctx);
        };

        scenario.end();
    }

    // ========== Test: Swap B to A ==========

    #[test]
    fun test_swap_b_to_a() {
        use sui::test_scenario;

        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_a, mut treasury_b) = {
            let ctx = scenario.ctx();
            let (mut ta, mut tb) = setup_currencies(ctx);
            let coin_a = coin::mint(&mut ta, 1000, ctx);
            let coin_b = coin::mint(&mut tb, 2000, ctx);
            pool::create_pool(coin_a, coin_b, 30, ctx);
            (ta, tb)
        };

        // Transaction 2: Swap 200 B for A
        scenario.next_tx(@0xA);
        {
            let input_b = coin::mint(&mut treasury_b, 200, scenario.ctx());
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            let output_a = pool::swap_b_to_a(&mut pool_obj, input_b, 0, scenario.ctx());
            // get_amount_out(200, 2000, 1000, 30):
            // amount_in_with_fee = 200 * 9970 = 1994000
            // numerator = 1994000 * 1000 = 1994000000
            // denominator = 2000 * 10000 + 1994000 = 21994000
            // output = 1994000000 / 21994000 = 90
            assert!(coin::value(&output_a) == 90);
            discard(output_a, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let ctx = scenario.ctx();
            teardown(treasury_a, treasury_b, ctx);
        };

        scenario.end();
    }

    // ========== Test: Remove Liquidity ==========

    #[test]
    fun test_remove_liquidity() {
        use sui::test_scenario;

        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_a, mut treasury_b) = {
            let ctx = scenario.ctx();
            let (mut ta, mut tb) = setup_currencies(ctx);
            let coin_a = coin::mint(&mut ta, 1000, ctx);
            let coin_b = coin::mint(&mut tb, 2000, ctx);
            pool::create_pool(coin_a, coin_b, 30, ctx);
            (ta, tb)
        };

        // Transaction 2: Add liquidity
        scenario.next_tx(@0xA);
        {
            let coin_a = coin::mint(&mut treasury_a, 1000, scenario.ctx());
            let coin_b = coin::mint(&mut treasury_b, 2000, scenario.ctx());
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            pool::add_liquidity(&mut pool_obj, coin_a, coin_b, 0, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Transaction 3: Remove liquidity
        scenario.next_tx(@0xA);
        {
            let lp: pool::LP<COINA, COINB> = test_scenario::take_from_sender(&scenario);
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            let (coin_a, coin_b) = pool::remove_liquidity(&mut pool_obj, lp, 0, 0, scenario.ctx());

            // Pool created with 1000 A, 2000 B (total_supply=0).
            // add_liquidity(1000, 2000) -> shares = sqrt(2000000) = 1414
            // reserves become: 2000 A, 4000 B, total_supply = 1414
            // remove_liquidity: amount_a = 1414*2000/1414 = 2000
            //                   amount_b = 1414*4000/1414 = 4000
            assert!(coin::value(&coin_a) == 2000);
            assert!(coin::value(&coin_b) == 4000);

            discard(coin_a, scenario.ctx());
            discard(coin_b, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let ctx = scenario.ctx();
            teardown(treasury_a, treasury_b, ctx);
        };

        scenario.end();
    }

    // ========== Test: Slippage Protection (expected failure) ==========

    #[test]
    #[expected_failure(abort_code = pool::EInsufficientOutput)]
    fun test_slippage_protection_swap() {
        use sui::test_scenario;

        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_a, mut treasury_b) = {
            let ctx = scenario.ctx();
            let (mut ta, mut tb) = setup_currencies(ctx);
            let coin_a = coin::mint(&mut ta, 1000, ctx);
            let coin_b = coin::mint(&mut tb, 2000, ctx);
            pool::create_pool(coin_a, coin_b, 30, ctx);
            (ta, tb)
        };

        // Transaction 2: Swap with unrealistic min_output (should abort)
        scenario.next_tx(@0xA);
        {
            let input_a = coin::mint(&mut treasury_a, 100, scenario.ctx());
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            // Actual output is ~181, but we demand at least 200 => aborts
            let output = pool::swap_a_to_b(&mut pool_obj, input_a, 200, scenario.ctx());
            // Unreachable when abort happens, but needed for compile
            discard(output, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Unreachable on abort, but written for compile completeness
        scenario.next_tx(@0xA);
        {
            let ctx = scenario.ctx();
            teardown(treasury_a, treasury_b, ctx);
        };

        scenario.end();
    }

    // ========== Test: get_amount_out pure function ==========

    #[test]
    fun test_get_amount_out_basic() {
        // Symmetric pool: 1000 A, 1000 B, 0.3% fee (30 bps)
        let output = pool::get_amount_out(100, 1000, 1000, 30);
        // amount_in_with_fee = 100 * 9970 = 997000
        // numerator = 997000 * 1000 = 997000000
        // denominator = 1000 * 10000 + 997000 = 10997000
        // output = 997000000 / 10997000 = 90
        assert!(output == 90);

        // Asymmetric pool: 1000 A, 4000 B
        let output2 = pool::get_amount_out(100, 1000, 4000, 30);
        // amount_in_with_fee = 997000
        // numerator = 997000 * 4000 = 3988000000
        // denominator = 10997000
        // output = 3988000000 / 10997000 = 362
        assert!(output2 == 362);
    }

    #[test]
    fun test_get_amount_out_zero_fee() {
        let output = pool::get_amount_out(100, 1000, 1000, 0);
        // amount_in_with_fee = 100 * 10000 = 1000000
        // numerator = 1000000 * 1000 = 1000000000
        // denominator = 1000 * 10000 + 1000000 = 11000000
        // output = 1000000000 / 11000000 = 90
        assert!(output == 90);
    }

    #[test]
    fun test_get_amount_out_large_swap() {
        let output = pool::get_amount_out(500000, 1000000, 1000000, 30);
        // amount_in_with_fee = 500000 * 9970 = 4985000000
        // numerator = 4985000000 * 1000000 = 4985000000000000
        // denominator = 1000000 * 10000 + 4985000000 = 5098500000
        // output = 4985000000000000 / 14985000000 = 332665
        assert!(output == 332665);
    }

    // ========== Test: quote pure function ==========

    #[test]
    fun test_quote() {
        let q = pool::quote(100, 1000, 2000);
        assert!(q == 200);

        let q2 = pool::quote(500, 1000, 1000);
        assert!(q2 == 500);
    }

    // ========== Test: sqrt function ==========

    #[test]
    fun test_sqrt() {
        assert!(pool::sqrt(0) == 0);
        assert!(pool::sqrt(1) == 1);
        assert!(pool::sqrt(4) == 2);
        assert!(pool::sqrt(9) == 3);
        assert!(pool::sqrt(100) == 10);
        assert!(pool::sqrt(200) == 14);
        assert!(pool::sqrt(1000000000000) == 1000000);
        assert!(pool::sqrt(2) == 1);
        assert!(pool::sqrt(3) == 1);
        assert!(pool::sqrt(2000000) == 1414);
        assert!(pool::sqrt(20000000000) == 141421);
    }

    // ========== Test: get_price ==========

    #[test]
    fun test_get_price() {
        use sui::test_scenario;

        let mut scenario = test_scenario::begin(@0xA);

        let (treasury_a, treasury_b) = {
            let ctx = scenario.ctx();
            let (mut ta, mut tb) = setup_currencies(ctx);
            let coin_a = coin::mint(&mut ta, 1000, ctx);
            let coin_b = coin::mint(&mut tb, 2000, ctx);
            pool::create_pool(coin_a, coin_b, 30, ctx);
            (ta, tb)
        };

        // Transaction 2: Check price
        scenario.next_tx(@0xA);
        {
            let pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            let price = pool::get_price(&pool_obj);
            // price = 2000 * 1000000 / 1000 = 2000000
            assert!(price == 2000000);
            test_scenario::return_shared(pool_obj);
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let ctx = scenario.ctx();
            teardown(treasury_a, treasury_b, ctx);
        };

        scenario.end();
    }

    // ========== Test: Full Lifecycle ==========

    #[test]
    fun test_full_lifecycle() {
        use sui::test_scenario;

        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_a, mut treasury_b) = {
            let ctx = scenario.ctx();
            let (mut ta, mut tb) = setup_currencies(ctx);
            let coin_a = coin::mint(&mut ta, 10000, ctx);
            let coin_b = coin::mint(&mut tb, 20000, ctx);
            pool::create_pool(coin_a, coin_b, 30, ctx);
            (ta, tb)
        };

        // Transaction 2: Add liquidity
        scenario.next_tx(@0xA);
        {
            let coin_a = coin::mint(&mut treasury_a, 5000, scenario.ctx());
            let coin_b = coin::mint(&mut treasury_b, 10000, scenario.ctx());
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            pool::add_liquidity(&mut pool_obj, coin_a, coin_b, 0, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Transaction 3: Take LP, then swap
        scenario.next_tx(@0xA);
        let lp: pool::LP<COINA, COINB> = test_scenario::take_from_sender(&scenario);
        {
            let input_a = coin::mint(&mut treasury_a, 1000, scenario.ctx());
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            let output_b = pool::swap_a_to_b(&mut pool_obj, input_a, 0, scenario.ctx());
            assert!(coin::value(&output_b) > 0);
            discard(output_b, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Transaction 4: Remove liquidity
        scenario.next_tx(@0xA);
        {
            let mut pool_obj = test_scenario::take_shared<pool::Pool<COINA, COINB>>(&scenario);
            let (coin_a, coin_b) = pool::remove_liquidity(&mut pool_obj, lp, 0, 0, scenario.ctx());
            assert!(coin::value(&coin_a) > 0);
            assert!(coin::value(&coin_b) > 0);
            discard(coin_a, scenario.ctx());
            discard(coin_b, scenario.ctx());
            test_scenario::return_shared(pool_obj);
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let ctx = scenario.ctx();
            teardown(treasury_a, treasury_b, ctx);
        };

        scenario.end();
    }

}
