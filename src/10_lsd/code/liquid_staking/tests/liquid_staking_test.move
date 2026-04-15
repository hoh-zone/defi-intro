#[test_only]
module liquid_staking::liquid_staking_test;

use liquid_staking::liquid_staking;
use std::unit_test::{Self, assert_eq};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario;
use sui::transfer;

const ADMIN: address = @0xAD;

// Helper: mint SUI coins for testing
fun mint_sui(amount: u64, ctx: &mut sui::tx_context::TxContext): Coin<SUI> {
    let mut treasury = coin::create_treasury_cap_for_testing<SUI>(ctx);
    let coin = coin::mint(&mut treasury, amount, ctx);
    transfer::public_transfer(treasury, @0x0);
    coin
}

// Helper: destroy a coin using burn_for_testing
fun destroy_coin<T>(c: Coin<T>) {
    coin::burn_for_testing(c);
}

#[test]
fun init_and_stake() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = test_scenario::ctx(&mut scenario);
    liquid_staking::create_for_testing(ctx);
    test_scenario::next_tx(&mut scenario, ADMIN);

    let mut pool = test_scenario::take_shared<liquid_staking::StakingPool>(&scenario);

    // First stake: 10 SUI -> 10 LST (1:1)
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let sui_coin = mint_sui(10_000_000_000, ctx); // 10 SUI
        let lst = liquid_staking::stake(&mut pool, sui_coin, ctx);

        assert_eq!(liquid_staking::total_lst_supply(&pool), 10_000_000_000);
        assert_eq!(coin::value(&lst), 10_000_000_000);
        assert_eq!(liquid_staking::exchange_rate(&pool), 1_000_000_000); // PRECISION = 1:1

        unit_test::destroy(lst);
    };

    test_scenario::return_shared(pool);
    scenario.end();
}

#[test]
fun second_stake_exchange_rate() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = test_scenario::ctx(&mut scenario);
    liquid_staking::create_for_testing(ctx);
    test_scenario::next_tx(&mut scenario, ADMIN);

    let mut pool = test_scenario::take_shared<liquid_staking::StakingPool>(&scenario);

    // User1 stakes 10 SUI
    let lst1;
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let sui1 = mint_sui(10_000_000_000, ctx);
        lst1 = liquid_staking::stake(&mut pool, sui1, ctx);
        assert_eq!(coin::value(&lst1), 10_000_000_000); // 1:1
    };

    // Admin adds 1 SUI rewards (no new LST minted)
    test_scenario::return_shared(pool);
    test_scenario::next_tx(&mut scenario, ADMIN);
    let mut pool = test_scenario::take_shared<liquid_staking::StakingPool>(&scenario);
    {
        let cap = test_scenario::take_from_sender<liquid_staking::AdminCap>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        let reward = mint_sui(1_000_000_000, ctx); // 1 SUI
        liquid_staking::add_rewards(&cap, &mut pool, reward);
        test_scenario::return_to_sender(&scenario, cap);
    };

    // Now total_sui = 11, total_lst = 10, rate = 1.1
    assert_eq!(liquid_staking::exchange_rate(&pool), 1_100_000_000);

    // User2 stakes 11 SUI at rate 1.1 -> gets 10 LST
    let lst2;
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let sui2 = mint_sui(11_000_000_000, ctx);
        lst2 = liquid_staking::stake(&mut pool, sui2, ctx);
        assert_eq!(coin::value(&lst2), 10_000_000_000); // 11 / 1.1 = 10
    };

    test_scenario::return_shared(pool);
    unit_test::destroy(lst1);
    unit_test::destroy(lst2);
    scenario.end();
}

#[test]
fun unstake_with_rewards() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = test_scenario::ctx(&mut scenario);
    liquid_staking::create_for_testing(ctx);
    test_scenario::next_tx(&mut scenario, ADMIN);

    let mut pool = test_scenario::take_shared<liquid_staking::StakingPool>(&scenario);

    // Stake 10 SUI
    let lst;
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let sui_in = mint_sui(10_000_000_000, ctx);
        lst = liquid_staking::stake(&mut pool, sui_in, ctx);
    };

    // Add 1 SUI rewards
    test_scenario::return_shared(pool);
    test_scenario::next_tx(&mut scenario, ADMIN);
    let mut pool = test_scenario::take_shared<liquid_staking::StakingPool>(&scenario);
    {
        let cap = test_scenario::take_from_sender<liquid_staking::AdminCap>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        let reward = mint_sui(1_000_000_000, ctx);
        liquid_staking::add_rewards(&cap, &mut pool, reward);
        test_scenario::return_to_sender(&scenario, cap);
    };

    // Unstake: should get 11 SUI (10 + 1 reward)
    let sui_out;
    {
        let ctx = test_scenario::ctx(&mut scenario);
        sui_out = liquid_staking::unstake(&mut pool, lst, ctx);
        assert_eq!(coin::value(&sui_out), 11_000_000_000); // 11 SUI
    };

    test_scenario::return_shared(pool);
    destroy_coin(sui_out);
    scenario.end();
}

#[test]
fun preview_functions() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = test_scenario::ctx(&mut scenario);
    liquid_staking::create_for_testing(ctx);
    test_scenario::next_tx(&mut scenario, ADMIN);

    let mut pool = test_scenario::take_shared<liquid_staking::StakingPool>(&scenario);

    // Stake 10 SUI
    let lst1;
    {
        let ctx = test_scenario::ctx(&mut scenario);
        let sui1 = mint_sui(10_000_000_000, ctx);
        lst1 = liquid_staking::stake(&mut pool, sui1, ctx);
    };

    // Preview should match actual
    let preview_lst = liquid_staking::preview_stake(&pool, 10_000_000_000);
    assert_eq!(preview_lst, 10_000_000_000);

    // Add 2 SUI rewards
    test_scenario::return_shared(pool);
    test_scenario::next_tx(&mut scenario, ADMIN);
    let mut pool = test_scenario::take_shared<liquid_staking::StakingPool>(&scenario);
    {
        let cap = test_scenario::take_from_sender<liquid_staking::AdminCap>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        let reward = mint_sui(2_000_000_000, ctx);
        liquid_staking::add_rewards(&cap, &mut pool, reward);
        test_scenario::return_to_sender(&scenario, cap);
    };

    // Preview unstake: 10 LST should get 12 SUI
    // total_sui=12, total_lst=10: 10 * 12 / 10 = 12
    let preview_sui = liquid_staking::preview_unstake(&pool, 10_000_000_000);
    assert_eq!(preview_sui, 12_000_000_000);

    test_scenario::return_shared(pool);
    unit_test::destroy(lst1);
    scenario.end();
}

#[test]
fun pause_prevents_staking() {
    let mut scenario = test_scenario::begin(ADMIN);
    let ctx = test_scenario::ctx(&mut scenario);
    liquid_staking::create_for_testing(ctx);
    test_scenario::next_tx(&mut scenario, ADMIN);

    let mut pool = test_scenario::take_shared<liquid_staking::StakingPool>(&scenario);
    let cap = test_scenario::take_from_sender<liquid_staking::AdminCap>(&scenario);

    // Pause
    liquid_staking::pause(&cap, &mut pool);
    assert!(liquid_staking::is_paused(&pool));

    // Unpause
    liquid_staking::unpause(&cap, &mut pool);
    assert!(!liquid_staking::is_paused(&pool));

    test_scenario::return_to_sender(&scenario, cap);
    test_scenario::return_shared(pool);
    scenario.end();
}
