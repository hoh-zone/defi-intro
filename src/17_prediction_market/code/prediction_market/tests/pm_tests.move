#[test_only]
module prediction_market::test_coin {
    public struct TCOIN has drop {}
}

#[test_only]
module prediction_market::pm_tests {
    use sui::coin;
    use sui::test_scenario;
    use sui::clock;
    use sui::transfer;
    use prediction_market::pm::{Self, Market};
    use prediction_market::test_coin::TCOIN;

    #[test]
    fun cost_state_is_monotone_in_q_yes() {
        let b = 1_000_000_000u64;
        let c0 = pm::cost_for_test(0, 0, b);
        let c1 = pm::cost_for_test(5_000_000, 0, b);
        assert!(c1 > c0);
    }

    #[test]
    fun lmsr_cost_increases_when_buying_yes() {
        let mut s = test_scenario::begin(@0xA);
        let mut c = clock::create_for_testing(s.ctx());
        clock::set_for_testing(&mut c, 1_000_000);
        {
            let ctx = s.ctx();
            let mut treasury = coin::create_treasury_cap_for_testing<TCOIN>(ctx);
            let seed = coin::mint(&mut treasury, 1_000_000_000_000, ctx);
            pm::create_market<TCOIN>(
                1_000_000_000,
                seed,
                10,
                9_999_999_999_999_999,
                86_400_000,
                ctx,
            );
            transfer::public_transfer(treasury, @0xA);
        };
        s.next_tx(@0xA);
        {
            let mut market = test_scenario::take_shared<Market<TCOIN>>(&s);
            let mut treasury = test_scenario::take_from_sender<coin::TreasuryCap<TCOIN>>(&s);
            let pay = coin::mint(&mut treasury, 500_000_000, s.ctx());
            let q0 = pm::q_yes(&market);
            pm::buy_yes(&mut market, pay, 5_000_000, &c, s.ctx());
            assert!(pm::q_yes(&market) == q0 + 5_000_000);
            test_scenario::return_shared(market);
            transfer::public_transfer(treasury, @0xA);
        };
        clock::destroy_for_testing(c);
        s.end();
    }

    #[test]
    fun split_merge_roundtrip() {
        let mut s = test_scenario::begin(@0xB);
        let mut c = clock::create_for_testing(s.ctx());
        clock::set_for_testing(&mut c, 2_000_000);
        {
            let ctx = s.ctx();
            let mut treasury = coin::create_treasury_cap_for_testing<TCOIN>(ctx);
            let seed = coin::mint(&mut treasury, 10_000_000_000, ctx);
            pm::create_market<TCOIN>(
                500_000_000,
                seed,
                0,
                9_999_999_999_999_999,
                86_400_000,
                ctx,
            );
            transfer::public_transfer(treasury, @0xB);
        };
        s.next_tx(@0xB);
        {
            let mut market = test_scenario::take_shared<Market<TCOIN>>(&s);
            let mut pos = pm::new_position(&market, s.ctx());
            let mut treasury = test_scenario::take_from_sender<coin::TreasuryCap<TCOIN>>(&s);
            let coin_in = coin::mint(&mut treasury, 1000, s.ctx());
            pm::split(&mut market, &mut pos, coin_in, s.ctx());
            assert!(pm::position_yes(&pos) == 1000 && pm::position_no(&pos) == 1000);
            pm::merge(&mut market, &mut pos, 400, s.ctx());
            assert!(pm::position_yes(&pos) == 600);
            test_scenario::return_shared(market);
            transfer::public_transfer(pos, @0xB);
            transfer::public_transfer(treasury, @0xB);
        };
        clock::destroy_for_testing(c);
        s.end();
    }
}
