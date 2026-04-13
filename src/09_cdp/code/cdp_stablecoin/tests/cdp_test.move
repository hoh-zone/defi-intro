#[test_only]
module cdp_stablecoin::test_coins {
    /// A mock collateral token type used exclusively in tests.
    public struct MOCK_COLL has copy, drop, store {}

}
#[test_only]
module cdp_stablecoin::cdp_test {
    use sui::coin;
    use sui::coin::{TreasuryCap, Coin};
    use sui::test_scenario;
    use cdp_stablecoin::cdp;
    use cdp_stablecoin::cdp::{StableTreasury, CDPSystem, CDPPosition, GovernanceCap, create_system_for_testing};
    use cdp_stablecoin::test_coins::MOCK_COLL;
    use std::unit_test::assert_eq;

    const ADMIN: address = @0xA;
    const USER_B: address = @0xB;
    const MOCK_PRICE: u64 = 2_000_000_000;

    fun setup_collateral(
        ctx: &mut sui::tx_context::TxContext,
    ): TreasuryCap<MOCK_COLL> {
        coin::create_treasury_cap_for_testing<MOCK_COLL>(ctx)
    }

    #[test]
    fun init_system() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = scenario.ctx();
            create_system_for_testing<MOCK_COLL>(
                100_000_000_000000, 15000, 13000, 1000, ctx,
            );
            let coll_cap = setup_collateral(ctx);
            sui::transfer::public_transfer(coll_cap, scenario.sender());
        };

        scenario.next_tx(ADMIN);
        let system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);
        assert_eq!(cdp::total_debt(&system), 0);
        assert_eq!(cdp::collateral_ratio_bps(&system), 15000);
        assert_eq!(cdp::liquidation_threshold_bps(&system), 13000);
        assert_eq!(cdp::liquidation_penalty_bps(&system), 1000);
        assert_eq!(cdp::is_paused(&system), false);
        test_scenario::return_shared(system);

        let gov_cap = test_scenario::take_from_sender<GovernanceCap<MOCK_COLL>>(&scenario);
        cdp::destroy_gov_cap(gov_cap);

        scenario.end();
    }

    #[test]
    fun open_position() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = scenario.ctx();
            create_system_for_testing<MOCK_COLL>(
                100_000_000_000000, 15000, 13000, 1000, ctx,
            );
            let coll_cap = setup_collateral(ctx);
            sui::transfer::public_transfer(coll_cap, scenario.sender());
        };

        scenario.next_tx(ADMIN);
        let mut coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        let ctx = scenario.ctx();
        let collateral_coin = coin::mint(&mut coll_cap, 10_000_000_000, ctx);
        sui::transfer::public_transfer(coll_cap, scenario.sender());

        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);
        let ctx2 = scenario.ctx();
        let position = cdp::open_position<MOCK_COLL>(
            &mut treasury, &mut system, collateral_coin, 10_000_000_000, MOCK_PRICE, ctx2,
        );

        assert_eq!(cdp::position_collateral(&position), 10_000_000_000);
        assert_eq!(cdp::position_debt(&position), 10_000_000_000);
        assert_eq!(cdp::total_debt(&system), 10_000_000_000);
        assert_eq!(cdp::collateral_balance(&system), 10_000_000_000);

        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());

        scenario.end();
    }

    #[test, expected_failure(abort_code = cdp::ECollateralRatioTooLow)]
    fun cannot_open_position_insufficient_collateral() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = scenario.ctx();
            create_system_for_testing<MOCK_COLL>(
                100_000_000_000000, 15000, 13000, 1000, ctx,
            );
            let coll_cap = setup_collateral(ctx);
            sui::transfer::public_transfer(coll_cap, scenario.sender());
        };

        scenario.next_tx(ADMIN);
        let mut coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        let ctx = scenario.ctx();
        let collateral_coin = coin::mint(&mut coll_cap, 10_000_000_000, ctx);
        sui::transfer::public_transfer(coll_cap, scenario.sender());

        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);
        let ctx2 = scenario.ctx();
        let position = cdp::open_position<MOCK_COLL>(
            &mut treasury, &mut system, collateral_coin, 40_000_000_000, MOCK_PRICE, ctx2,
        );

        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());

        scenario.end();
    }

    #[test]
    fun add_collateral() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = scenario.ctx();
            create_system_for_testing<MOCK_COLL>(
                100_000_000_000000, 15000, 13000, 1000, ctx,
            );
            let coll_cap = setup_collateral(ctx);
            sui::transfer::public_transfer(coll_cap, scenario.sender());
        };

        scenario.next_tx(ADMIN);
        let mut coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        let ctx = scenario.ctx();
        let collateral_coin = coin::mint(&mut coll_cap, 10_000_000_000, ctx);
        sui::transfer::public_transfer(coll_cap, scenario.sender());

        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);
        let ctx2 = scenario.ctx();
        let position = cdp::open_position<MOCK_COLL>(
            &mut treasury, &mut system, collateral_coin, 5_000_000_000, MOCK_PRICE, ctx2,
        );
        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());

        scenario.next_tx(ADMIN);
        let mut coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        let ctx = scenario.ctx();
        let extra_collateral = coin::mint(&mut coll_cap, 5_000_000_000, ctx);
        sui::transfer::public_transfer(coll_cap, scenario.sender());

        let mut position = test_scenario::take_from_sender<CDPPosition<MOCK_COLL>>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);

        cdp::add_collateral(&mut system, &mut position, extra_collateral);

        assert_eq!(cdp::position_collateral(&position), 15_000_000_000);
        assert_eq!(cdp::collateral_balance(&system), 15_000_000_000);

        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());

        scenario.end();
    }

    #[test]
    fun repay_partial() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = scenario.ctx();
            create_system_for_testing<MOCK_COLL>(
                100_000_000_000000, 15000, 13000, 1000, ctx,
            );
            let coll_cap = setup_collateral(ctx);
            sui::transfer::public_transfer(coll_cap, scenario.sender());
        };

        scenario.next_tx(ADMIN);
        let mut coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        let ctx = scenario.ctx();
        let collateral_coin = coin::mint(&mut coll_cap, 10_000_000_000, ctx);
        sui::transfer::public_transfer(coll_cap, scenario.sender());

        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);
        let ctx2 = scenario.ctx();
        let position = cdp::open_position<MOCK_COLL>(
            &mut treasury, &mut system, collateral_coin, 10_000_000_000, MOCK_PRICE, ctx2,
        );
        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());

        scenario.next_tx(ADMIN);
        let mut position = test_scenario::take_from_sender<CDPPosition<MOCK_COLL>>(&scenario);
        let mut stable_coin = test_scenario::take_from_sender<Coin<cdp::CDP>>(&scenario);
        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);

        let ctx = scenario.ctx();
        let repayment = coin::split(&mut stable_coin, 4_000_000_000, ctx);
        let ctx2 = scenario.ctx();
        cdp::repay_partial(&mut treasury, &mut system, &mut position, repayment, ctx2);

        assert!(cdp::position_debt(&position) == 6_000_000_000);
        assert!(cdp::total_debt(&system) == 6_000_000_000);

        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());
        sui::transfer::public_transfer(stable_coin, scenario.sender());

        scenario.end();
    }

    #[test]
    fun test_repay_and_close() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = scenario.ctx();
            create_system_for_testing<MOCK_COLL>(
                100_000_000_000000, 15000, 13000, 1000, ctx,
            );
            let coll_cap = setup_collateral(ctx);
            sui::transfer::public_transfer(coll_cap, scenario.sender());
        };

        scenario.next_tx(ADMIN);
        let mut coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        let ctx = scenario.ctx();
        let collateral_coin = coin::mint(&mut coll_cap, 10_000_000_000, ctx);
        sui::transfer::public_transfer(coll_cap, scenario.sender());

        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);
        let ctx2 = scenario.ctx();
        let position = cdp::open_position<MOCK_COLL>(
            &mut treasury, &mut system, collateral_coin, 5_000_000_000, MOCK_PRICE, ctx2,
        );
        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());

        scenario.next_tx(ADMIN);
        let position = test_scenario::take_from_sender<CDPPosition<MOCK_COLL>>(&scenario);
        let repayment = test_scenario::take_from_sender<Coin<cdp::CDP>>(&scenario);
        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);

        let ctx = scenario.ctx();
        let returned_collateral = cdp::repay_and_close<MOCK_COLL>(
            &mut treasury, &mut system, position, repayment, ctx,
        );

        assert!(coin::value(&returned_collateral) == 10_000_000_000);
        assert!(cdp::total_debt(&system) == 0);
        assert!(cdp::collateral_balance(&system) == 0);

        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        // returned_collateral has value, can't destroy_zero. Transfer it.
        sui::transfer::public_transfer(returned_collateral, scenario.sender());

        scenario.end();
    }

    #[test]
    fun test_liquidate() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = scenario.ctx();
            create_system_for_testing<MOCK_COLL>(
                100_000_000_000000, 15000, 13000, 1000, ctx,
            );
            let coll_cap = setup_collateral(ctx);
            sui::transfer::public_transfer(coll_cap, scenario.sender());
        };

        let high_price: u64 = 2_000_000_000;
        let low_price: u64 = 1_200_000_000;

        // Transfer coll_cap from ADMIN to USER_B
        scenario.next_tx(ADMIN);
        let coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        sui::transfer::public_transfer(coll_cap, USER_B);

        scenario.next_tx(USER_B);
        let mut coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        let ctx = scenario.ctx();
        let collateral_coin = coin::mint(&mut coll_cap, 10_000_000_000, ctx);
        sui::transfer::public_transfer(coll_cap, scenario.sender());

        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);
        let ctx2 = scenario.ctx();
        let position = cdp::open_position<MOCK_COLL>(
            &mut treasury, &mut system, collateral_coin, 14_000_000_000, high_price, ctx2,
        );
        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());

        scenario.next_tx(USER_B);
        let position = test_scenario::take_from_sender<CDPPosition<MOCK_COLL>>(&scenario);
        let repayment = test_scenario::take_from_sender<Coin<cdp::CDP>>(&scenario);
        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);

        let ctx = scenario.ctx();
        let seized_collateral = cdp::liquidate<MOCK_COLL>(
            &mut treasury, &mut system, position, repayment, low_price, ctx,
        );

        assert!(coin::value(&seized_collateral) == 10_000_000_000);
        assert!(cdp::total_debt(&system) == 0);
        assert!(cdp::collateral_balance(&system) == 0);

        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        // seized_collateral has value, can't destroy_zero. Transfer it.
        sui::transfer::public_transfer(seized_collateral, scenario.sender());

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = cdp::EPositionNotLiquidatable)]
    fun test_cannot_liquidate_healthy_position() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = scenario.ctx();
            create_system_for_testing<MOCK_COLL>(
                100_000_000_000000, 15000, 13000, 1000, ctx,
            );
            let coll_cap = setup_collateral(ctx);
            sui::transfer::public_transfer(coll_cap, scenario.sender());
        };

        scenario.next_tx(ADMIN);
        let mut coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        let ctx = scenario.ctx();
        let collateral_coin = coin::mint(&mut coll_cap, 10_000_000_000, ctx);
        sui::transfer::public_transfer(coll_cap, scenario.sender());

        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);
        let ctx2 = scenario.ctx();
        let position = cdp::open_position<MOCK_COLL>(
            &mut treasury, &mut system, collateral_coin, 5_000_000_000, MOCK_PRICE, ctx2,
        );
        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());

        scenario.next_tx(ADMIN);
        let position = test_scenario::take_from_sender<CDPPosition<MOCK_COLL>>(&scenario);
        let repayment = test_scenario::take_from_sender<Coin<cdp::CDP>>(&scenario);
        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);

        let ctx = scenario.ctx();
        let seized = cdp::liquidate<MOCK_COLL>(
            &mut treasury, &mut system, position, repayment, MOCK_PRICE, ctx,
        );

        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        coin::destroy_zero(seized);

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = cdp::ESystemPaused)]
    fun test_emergency_pause_blocks_new_positions() {
        let mut scenario = test_scenario::begin(ADMIN);
        {
            let ctx = scenario.ctx();
            create_system_for_testing<MOCK_COLL>(
                100_000_000_000000, 15000, 13000, 1000, ctx,
            );
            let coll_cap = setup_collateral(ctx);
            sui::transfer::public_transfer(coll_cap, scenario.sender());
        };

        scenario.next_tx(ADMIN);
        let gov_cap = test_scenario::take_from_sender<GovernanceCap<MOCK_COLL>>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);
        cdp::emergency_pause(&gov_cap, &mut system);
        assert!(cdp::is_paused(&system) == true);
        test_scenario::return_shared(system);
        test_scenario::return_to_sender(&scenario, gov_cap);

        scenario.next_tx(ADMIN);
        let mut coll_cap = test_scenario::take_from_sender<TreasuryCap<MOCK_COLL>>(&scenario);
        let ctx = scenario.ctx();
        let collateral_coin = coin::mint(&mut coll_cap, 10_000_000_000, ctx);
        sui::transfer::public_transfer(coll_cap, scenario.sender());

        let mut treasury = test_scenario::take_shared<StableTreasury>(&scenario);
        let mut system = test_scenario::take_shared<CDPSystem<MOCK_COLL>>(&scenario);

        let ctx2 = scenario.ctx();
        let position = cdp::open_position<MOCK_COLL>(
            &mut treasury, &mut system, collateral_coin, 5_000_000_000, MOCK_PRICE, ctx2,
        );

        test_scenario::return_shared(treasury);
        test_scenario::return_shared(system);
        sui::transfer::public_transfer(position, scenario.sender());

        scenario.end();
    }

}
