/// Tests for the insurance module.
#[test_only]
module insurance::insurance_test {
    use insurance::insurance;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario;

    // Test parameters
    const ADMIN: address = @0xAD;
    const USER: address = @0xB0B;

    // 3% annual premium rate = 300 bps, max 100_000 SUI coverage per user
    const PREMIUM_RATE_BPS: u64 = 300;
    const MAX_COVERAGE: u64 = 100_000;

    // ===== Helpers =====

    fun setup(): test_scenario::Scenario {
        test_scenario::begin(ADMIN)
    }

    /// Manually initialize the insurance pool (since create_pool takes parameters).
    fun init_pool(ctx: &mut TxContext) {
        insurance::create_pool<SUI>(PREMIUM_RATE_BPS, MAX_COVERAGE, ctx);
    }

    fun mint_sui(ctx: &mut TxContext, amount: u64): Coin<SUI> {
        let mut cap = coin::create_treasury_cap_for_testing<SUI>(ctx);
        let minted = coin::mint(&mut cap, amount, ctx);
        transfer::public_freeze_object(cap);
        minted
    }

    /// Consume a coin by freezing it (for cleanup in tests).
    fun destroy_coin(c: Coin<SUI>) {
        transfer::public_freeze_object(c);
    }

    // ===== Tests =====

    #[test]
    /// Verify create_pool creates the InsurancePool (shared) and AdminCap (owned).
    fun test_init_creates_objects() {
        let mut scenario = setup();

        // Manually initialize the pool
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Verify AdminCap is owned by ADMIN
        scenario.next_tx(ADMIN);
        {
            let _cap = scenario.take_from_sender<insurance::AdminCap>();
            scenario.return_to_sender(_cap);
        };

        // Verify InsurancePool<SUI> exists as shared object
        scenario.next_tx(ADMIN);
        {
            let pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            assert!(insurance::total_coverage(&pool) == 0);
            assert!(insurance::coverage_pool_value(&pool) == 0);
            assert!(insurance::premium_pool_value(&pool) == 0);
            assert!(!insurance::is_paused(&pool));
            test_scenario::return_shared(pool);
        };

        scenario.end();
    }

    #[test]
    /// Provide coverage capital and verify it appears in the pool.
    fun test_provide_coverage() {
        let mut scenario = setup();

        // Init
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Admin provides 50_000 SUI of coverage capital
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 50_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            assert!(insurance::coverage_pool_value(&pool) == 50_000);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        // Provide additional coverage from another tx
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 30_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            assert!(insurance::coverage_pool_value(&pool) == 80_000);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        scenario.end();
    }

    #[test]
    /// Purchase a policy and verify premium calculation and policy fields.
    fun test_purchase_policy() {
        let mut scenario = setup();

        // Init
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Admin provides coverage capital first
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 50_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        // User purchases a policy: 10_000 SUI coverage for half a year
        // Premium = 10_000 * 300 / 10000 * (MS_PER_YEAR/2) / MS_PER_YEAR = 300 * 0.5 = 150
        let coverage = 10_000;
        let duration_ms = 365 * 24 * 3600 * 1000 / 2; // half year
        let expected_premium = insurance::calculate_premium(coverage, PREMIUM_RATE_BPS, duration_ms);

        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let premium_coin = mint_sui(scenario.ctx(), expected_premium);
            insurance::purchase_policy(
                &mut pool,
                coverage,
                premium_coin,
                duration_ms,
                1000, // current_ms
                scenario.ctx(),
            );
            assert!(insurance::total_coverage(&pool) == coverage);
            assert!(insurance::premium_pool_value(&pool) == expected_premium);
            test_scenario::return_shared(pool);
        };

        // Verify policy was transferred to USER
        scenario.next_tx(USER);
        {
            let policy = scenario.take_from_sender<insurance::Policy<SUI>>();
            assert!(insurance::policy_coverage_amount(&policy) == coverage);
            assert!(insurance::policy_active(&policy));
            assert!(insurance::policy_start_time(&policy) == 1000);
            scenario.return_to_sender(policy);
        };

        scenario.end();
    }

    #[test]
    /// Verify premium calculation formula produces correct results.
    fun test_premium_calculation() {
        // 3% annual rate on 10_000 for a full year => 300
        let full_year_ms = 365 * 24 * 3600 * 1000;
        let premium = insurance::calculate_premium(10_000, 300, full_year_ms);
        assert!(premium == 300);

        // Half year => 150
        let half = insurance::calculate_premium(10_000, 300, full_year_ms / 2);
        assert!(half == 150);

        // Quarter year => 75
        let quarter = insurance::calculate_premium(10_000, 300, full_year_ms / 4);
        assert!(quarter == 75);

        // 1% rate (100 bps) on 100_000 for a full year => 1000
        let one_pct = insurance::calculate_premium(100_000, 100, full_year_ms);
        assert!(one_pct == 1000);
    }

    #[test]
    /// Purchase a policy, then file a claim and verify payout.
    fun test_claim_payout() {
        let mut scenario = setup();

        // Init
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Admin provides coverage capital
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 50_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        // User purchases policy
        let coverage = 10_000;
        let duration_ms = 365 * 24 * 3600 * 1000;
        let expected_premium = insurance::calculate_premium(coverage, PREMIUM_RATE_BPS, duration_ms);

        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let premium_coin = mint_sui(scenario.ctx(), expected_premium);
            insurance::purchase_policy(&mut pool, coverage, premium_coin, duration_ms, 1000, scenario.ctx());
            test_scenario::return_shared(pool);
        };

        // User claims 4_000 SUI
        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let mut policy = scenario.take_from_sender<insurance::Policy<SUI>>();
            insurance::claim(&mut pool, &mut policy, 4_000, scenario.ctx());

            // Policy should still be active with 6_000 remaining
            assert!(insurance::policy_coverage_amount(&policy) == 6_000);
            assert!(insurance::policy_active(&policy));

            test_scenario::return_shared(pool);
            scenario.return_to_sender(policy);
        };

        // User should have received the claim payout
        scenario.next_tx(USER);
        {
            let payout = scenario.take_from_sender<Coin<SUI>>();
            assert!(coin::value(&payout) == 4_000);
            destroy_coin(payout);
        };

        // Verify pool state: coverage reduced by 4_000
        scenario.next_tx(ADMIN);
        {
            let pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            assert!(insurance::total_coverage(&pool) == 6_000);
            assert!(insurance::coverage_pool_value(&pool) == 46_000);
            test_scenario::return_shared(pool);
        };

        scenario.end();
    }

    #[test]
    /// File a full claim which should deactivate the policy.
    fun test_full_claim_deactivates_policy() {
        let mut scenario = setup();

        // Init
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Setup coverage
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 50_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        let coverage = 5_000;
        let duration_ms = 365 * 24 * 3600 * 1000;
        let expected_premium = insurance::calculate_premium(coverage, PREMIUM_RATE_BPS, duration_ms);

        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let premium_coin = mint_sui(scenario.ctx(), expected_premium);
            insurance::purchase_policy(&mut pool, coverage, premium_coin, duration_ms, 1000, scenario.ctx());
            test_scenario::return_shared(pool);
        };

        // Claim full amount
        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let mut policy = scenario.take_from_sender<insurance::Policy<SUI>>();
            insurance::claim(&mut pool, &mut policy, 5_000, scenario.ctx());

            // Policy should be deactivated
            assert!(!insurance::policy_active(&policy));
            assert!(insurance::policy_coverage_amount(&policy) == 0);

            test_scenario::return_shared(pool);
            scenario.return_to_sender(policy);
        };

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = insurance::EInsufficientPremium)]
    /// Cannot purchase a policy without paying sufficient premium.
    fun test_insufficient_premium_rejected() {
        let mut scenario = setup();

        // Init
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Setup coverage
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 50_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        // User tries to purchase with too little premium (only 1 SUI instead of ~300)
        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let premium_coin = mint_sui(scenario.ctx(), 1);
            insurance::purchase_policy(
                &mut pool,
                10_000,
                premium_coin,
                365 * 24 * 3600 * 1000,
                1000,
                scenario.ctx(),
            );
            test_scenario::return_shared(pool);
        };

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = insurance::EClaimExceedsCoverage)]
    /// Cannot claim more than the policy's coverage amount.
    fun test_claim_exceeds_coverage() {
        let mut scenario = setup();

        // Init
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Setup coverage
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 50_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        let coverage = 5_000;
        let duration_ms = 365 * 24 * 3600 * 1000;
        let expected_premium = insurance::calculate_premium(coverage, PREMIUM_RATE_BPS, duration_ms);

        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let premium_coin = mint_sui(scenario.ctx(), expected_premium);
            insurance::purchase_policy(&mut pool, coverage, premium_coin, duration_ms, 1000, scenario.ctx());
            test_scenario::return_shared(pool);
        };

        // Try to claim more than coverage
        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let mut policy = scenario.take_from_sender<insurance::Policy<SUI>>();
            insurance::claim(&mut pool, &mut policy, 10_000, scenario.ctx());
            test_scenario::return_shared(pool);
            scenario.return_to_sender(policy);
        };

        scenario.end();
    }

    #[test]
    /// Admin can withdraw collected premiums.
    fun test_withdraw_premiums() {
        let mut scenario = setup();

        // Init
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Provide coverage
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 50_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        // User buys policy
        let coverage = 10_000;
        let duration_ms = 365 * 24 * 3600 * 1000;
        let expected_premium = insurance::calculate_premium(coverage, PREMIUM_RATE_BPS, duration_ms);

        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let premium_coin = mint_sui(scenario.ctx(), expected_premium);
            insurance::purchase_policy(&mut pool, coverage, premium_coin, duration_ms, 1000, scenario.ctx());
            test_scenario::return_shared(pool);
        };

        // Admin withdraws all premiums
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            insurance::withdraw_premiums(&cap, &mut pool, expected_premium, scenario.ctx());
            assert!(insurance::premium_pool_value(&pool) == 0);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        // Admin should have received the withdrawn premiums
        scenario.next_tx(ADMIN);
        {
            let withdrawn = scenario.take_from_sender<Coin<SUI>>();
            assert!(coin::value(&withdrawn) == expected_premium);
            destroy_coin(withdrawn);
        };

        scenario.end();
    }

    #[test]
    /// Test policy expiry flow.
    fun test_policy_expiry() {
        let mut scenario = setup();

        // Init
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Provide coverage
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 50_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        // User purchases policy starting at time 1000, duration 1 year
        let coverage = 10_000;
        let duration_ms = 365 * 24 * 3600 * 1000;
        let expected_premium = insurance::calculate_premium(coverage, PREMIUM_RATE_BPS, duration_ms);

        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let premium_coin = mint_sui(scenario.ctx(), expected_premium);
            insurance::purchase_policy(&mut pool, coverage, premium_coin, duration_ms, 1000, scenario.ctx());
            assert!(insurance::total_coverage(&pool) == coverage);
            test_scenario::return_shared(pool);
        };

        // Expire the policy: current time well past start + duration
        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let mut policy = scenario.take_from_sender<insurance::Policy<SUI>>();
            // Expiry = 1000 + duration_ms, so current_ms must be >= that
            let current_ms = 1000 + duration_ms;
            insurance::expire_policy(&mut pool, &mut policy, current_ms);

            assert!(!insurance::policy_active(&policy));
            assert!(insurance::policy_coverage_amount(&policy) == 0);
            assert!(insurance::total_coverage(&pool) == 0);

            test_scenario::return_shared(pool);
            scenario.return_to_sender(policy);
        };

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = insurance::EPolicyNotExpired)]
    /// Cannot expire a policy before its duration has elapsed.
    fun test_cannot_expire_before_duration() {
        let mut scenario = setup();

        // Init
        scenario.next_tx(ADMIN);
        {
            init_pool(scenario.ctx());
        };

        // Provide coverage
        scenario.next_tx(ADMIN);
        {
            let cap = scenario.take_from_sender<insurance::AdminCap>();
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let coin = mint_sui(scenario.ctx(), 50_000);
            insurance::provide_coverage(&cap, &mut pool, coin);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(cap);
        };

        let coverage = 10_000;
        let duration_ms = 365 * 24 * 3600 * 1000;
        let expected_premium = insurance::calculate_premium(coverage, PREMIUM_RATE_BPS, duration_ms);

        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let premium_coin = mint_sui(scenario.ctx(), expected_premium);
            insurance::purchase_policy(&mut pool, coverage, premium_coin, duration_ms, 1000, scenario.ctx());
            test_scenario::return_shared(pool);
        };

        // Try to expire too early (current_ms = 2000, but expiry = 1000 + duration_ms >> 2000)
        scenario.next_tx(USER);
        {
            let mut pool = test_scenario::take_shared<insurance::InsurancePool<SUI>>(&scenario);
            let mut policy = scenario.take_from_sender<insurance::Policy<SUI>>();
            insurance::expire_policy(&mut pool, &mut policy, 2000);
            test_scenario::return_shared(pool);
            scenario.return_to_sender(policy);
        };

        scenario.end();
    }
}
