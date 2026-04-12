#[test_only]
module security_patterns::security_test {
    use security_patterns::capability;
    use security_patterns::integer_safety;
    use security_patterns::asset_safety;
    use sui::coin;
    use sui::sui::SUI;
    use sui::test_scenario;
    use std::unit_test::assert_eq;

    const ADMIN: address = @0xAD;

    // === Capability Tests ===

    #[test]
    fun capability_deposit_and_withdraw() {
        let mut scenario = test_scenario::begin(ADMIN);
        let cap = capability::create_vault<SUI>(scenario.ctx());
        // Shared objects only become available after next_tx
        scenario.next_tx(ADMIN);
        let mut vault = scenario.take_shared<capability::ProtectedVault<SUI>>();

        // Deposit (no cap needed)
        let coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
        capability::deposit(&mut vault, coin);
        assert_eq!(capability::balance(&vault), 1000);

        // Withdraw (needs cap)
        let withdrawn = capability::withdraw(&cap, &mut vault, 500, scenario.ctx());
        assert_eq!(coin::value(&withdrawn), 500);
        assert_eq!(capability::balance(&vault), 500);

        test_scenario::return_shared(vault);
        transfer::public_transfer(cap, scenario.ctx().sender());
        coin::burn_for_testing(withdrawn);
        scenario.end();
    }

    #[test]
    fun integer_safe_operations() {
        // Normal operations
        assert_eq!(integer_safety::safe_mul(100, 200), 20000);
        assert_eq!(integer_safety::safe_add(100, 200), 300);
        assert_eq!(integer_safety::safe_sub(300, 100), 200);
        assert_eq!(integer_safety::safe_div(1000, 10), 100);
        assert_eq!(integer_safety::mul_div(1000, 2000, 3000), 666); // truncated
    }

    #[test, expected_failure(abort_code = integer_safety::EOverflow)]
    fun integer_mul_overflow() {
        integer_safety::safe_mul(0x100000000, 0x100000000);
    }

    #[test, expected_failure(abort_code = integer_safety::EOverflow)]
    fun integer_add_overflow() {
        integer_safety::safe_add(0xFFFFFFFFFFFFFFFF, 1);
    }

    #[test, expected_failure(abort_code = integer_safety::EUnderflow)]
    fun integer_sub_underflow() {
        integer_safety::safe_sub(100, 200);
    }

    #[test, expected_failure(abort_code = integer_safety::EDivisionByZero)]
    fun integer_div_by_zero() {
        integer_safety::safe_div(100, 0);
    }

    // === Asset Safety Tests ===

    #[test]
    fun asset_safety_deposit_withdraw_invariant() {
        let mut scenario = test_scenario::begin(ADMIN);
        let cap = asset_safety::create_pool<SUI>(scenario.ctx());
        // Shared objects only become available after next_tx
        scenario.next_tx(ADMIN);
        let mut pool = scenario.take_shared<asset_safety::SecurePool<SUI>>();

        // Deposit
        let c1 = coin::mint_for_testing<SUI>(1000, scenario.ctx());
        asset_safety::deposit(&mut pool, c1);
        assert_eq!(asset_safety::total_deposits(&pool), 1000);

        let c2 = coin::mint_for_testing<SUI>(500, scenario.ctx());
        asset_safety::deposit(&mut pool, c2);
        assert_eq!(asset_safety::total_deposits(&pool), 1500);
        assert_eq!(asset_safety::balance(&pool), 1500);

        // Withdraw
        let withdrawn = asset_safety::withdraw(&cap, &mut pool, 800, scenario.ctx());
        assert_eq!(coin::value(&withdrawn), 800);
        assert_eq!(asset_safety::total_withdrawals(&pool), 800);

        // Check invariant
        asset_safety::check_invariant(&pool);

        test_scenario::return_shared(pool);
        transfer::public_transfer(cap, scenario.ctx().sender());
        coin::burn_for_testing(withdrawn);
        scenario.end();
    }
}
