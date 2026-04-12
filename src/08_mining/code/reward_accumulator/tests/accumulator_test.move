#[test_only]
module reward_accumulator::test_stake_coin {
    public struct STAKE has drop {}

}
#[test_only]
module reward_accumulator::test_reward_coin {
    public struct REWARD has drop {}

}
#[test_only]
module reward_accumulator::accumulator_test {
    use sui::coin::{Self, TreasuryCap};
    use sui::test_scenario;
    use sui::transfer;
    use sui::tx_context;
    use reward_accumulator::accumulator;
    use reward_accumulator::accumulator::{RewardPool};
    use reward_accumulator::test_stake_coin::STAKE;
    use reward_accumulator::test_reward_coin::REWARD;

    // ========== Error codes (mirrored from accumulator) ==========
    const EZeroDuration: u64 = 4;

    // ========== Helpers ==========

    fun setup_treasuries(ctx: &mut sui::tx_context::TxContext): (
        TreasuryCap<STAKE>, TreasuryCap<REWARD>,
    ) {
        (
            coin::create_treasury_cap_for_testing<STAKE>(ctx),
            coin::create_treasury_cap_for_testing<REWARD>(ctx),
        )
    }

    fun mint_stake(cap: &mut TreasuryCap<STAKE>, amount: u64, ctx: &mut sui::tx_context::TxContext): coin::Coin<STAKE> {
        coin::mint(cap, amount, ctx)
    }

    fun mint_reward(cap: &mut TreasuryCap<REWARD>, amount: u64, ctx: &mut sui::tx_context::TxContext): coin::Coin<REWARD> {
        coin::mint(cap, amount, ctx)
    }

    fun cleanup_treasury<T>(treasury: TreasuryCap<T>, ctx: &mut sui::tx_context::TxContext) {
        transfer::public_transfer(treasury, tx_context::sender(ctx));
    }

    fun teardown_treasuries(
        treasury_stake: TreasuryCap<STAKE>,
        treasury_reward: TreasuryCap<REWARD>,
        ctx: &mut sui::tx_context::TxContext,
    ) {
        cleanup_treasury(treasury_stake, ctx);
        cleanup_treasury(treasury_reward, ctx);
    }

    fun destroy_empty_pool<StakeCoin, RewardCoin>(
        pool: RewardPool<StakeCoin, RewardCoin>,
    ) {
        accumulator::destroy_pool(pool);
    }

    // ============================================================
    // Test 1: Create reward pool with initial rewards
    // ============================================================

    #[test]
    fun test_create_pool() {
        let mut scenario = test_scenario::begin(@0xA);

        // Tx 1: Create currencies and pool
        let (mut treasury_stake, mut treasury_reward) = {
            let ctx = scenario.ctx();
            let (ts, mut tr) = setup_treasuries(ctx);
            let reward_coin = mint_reward(&mut tr, 10000, ctx);
            accumulator::create_pool<STAKE, REWARD>(reward_coin, 1000, 100, ctx);
            (ts, tr)
        };

        // Tx 2: Verify pool state
        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let (total_stake, rate, last_update, end_ms, remaining) = accumulator::pool_info(&pool);
            assert!(total_stake == 0);
            assert!(rate == 10);
            assert!(last_update == 100);
            assert!(end_ms == 1100);
            assert!(remaining == 10000);
            test_scenario::return_shared(pool);
        };

        // Tx 3: Cleanup
        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            destroy_empty_pool(pool);
            let ctx = scenario.ctx();
            teardown_treasuries(treasury_stake, treasury_reward, ctx);
        };

        scenario.end();
    }

    // ============================================================
    // Test 2: User stakes tokens
    // ============================================================

    #[test]
    fun test_stake() {
        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_stake, mut treasury_reward) = {
            let ctx = scenario.ctx();
            let (ts, mut tr) = setup_treasuries(ctx);
            let reward_coin = mint_reward(&mut tr, 10000, ctx);
            accumulator::create_pool<STAKE, REWARD>(reward_coin, 1000, 100, ctx);
            (ts, tr)
        };

        // Tx 2: User stakes 5000 tokens at t=200
        scenario.next_tx(@0xA);
        {
            let stake_coin = mint_stake(&mut treasury_stake, 5000, scenario.ctx());
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::stake(&mut pool, stake_coin, @0xA, 200);
            test_scenario::return_shared(pool);
        };

        // Tx 3: Verify stake info
        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let (amount, reward_debt) = accumulator::user_stake_info(&pool, @0xA);
            assert!(amount == 5000);
            assert!(reward_debt == 0);

            let (total_stake, _rate, _last_update, _end_ms, remaining) = accumulator::pool_info(&pool);
            assert!(total_stake == 5000);
            assert!(remaining == 10000);
            test_scenario::return_shared(pool);
        };

        // Cleanup: unstake everything then destroy pool
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 5000, @0xA, 200, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let returned_stake: coin::Coin<STAKE> = scenario.take_from_sender();
            coin::burn_for_testing(returned_stake);
        };

        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            destroy_empty_pool(pool);
            let ctx = scenario.ctx();
            teardown_treasuries(treasury_stake, treasury_reward, ctx);
        };

        scenario.end();
    }

    // ============================================================
    // Test 3: User unstakes tokens
    // ============================================================

    #[test]
    fun test_unstake() {
        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_stake, mut treasury_reward) = {
            let ctx = scenario.ctx();
            let (ts, mut tr) = setup_treasuries(ctx);
            let reward_coin = mint_reward(&mut tr, 10000, ctx);
            accumulator::create_pool<STAKE, REWARD>(reward_coin, 1000, 100, ctx);
            (ts, tr)
        };

        // Tx 2: Stake 10000 tokens at t=200
        scenario.next_tx(@0xA);
        {
            let stake_coin = mint_stake(&mut treasury_stake, 10000, scenario.ctx());
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::stake(&mut pool, stake_coin, @0xA, 200);
            test_scenario::return_shared(pool);
        };

        // Tx 3: Unstake 4000 tokens at t=300
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 4000, @0xA, 300, ctx);
            test_scenario::return_shared(pool);
        };

        // Tx 4: Verify returned coins and remaining stake
        scenario.next_tx(@0xA);
        {
            let returned_coin: coin::Coin<STAKE> = scenario.take_from_sender();
            assert!(coin::value(&returned_coin) == 4000);
            coin::burn_for_testing(returned_coin);
        };

        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let (amount, _reward_debt) = accumulator::user_stake_info(&pool, @0xA);
            assert!(amount == 6000);

            let (total_stake, _rate, _last_update, _end_ms, _remaining) = accumulator::pool_info(&pool);
            assert!(total_stake == 6000);
            test_scenario::return_shared(pool);
        };

        // Cleanup: unstake remaining
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 6000, @0xA, 300, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let returned_coin: coin::Coin<STAKE> = scenario.take_from_sender();
            coin::burn_for_testing(returned_coin);
        };

        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            destroy_empty_pool(pool);
            let ctx = scenario.ctx();
            teardown_treasuries(treasury_stake, treasury_reward, ctx);
        };

        scenario.end();
    }

    // ============================================================
    // Test 4: User claims rewards
    // ============================================================

    #[test]
    fun test_claim_rewards() {
        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_stake, mut treasury_reward) = {
            let ctx = scenario.ctx();
            let (ts, mut tr) = setup_treasuries(ctx);
            let reward_coin = mint_reward(&mut tr, 10000, ctx);
            accumulator::create_pool<STAKE, REWARD>(reward_coin, 1000, 0, ctx);
            (ts, tr)
        };

        // Tx 2: Stake 10000 tokens at t=0
        scenario.next_tx(@0xA);
        {
            let stake_coin = mint_stake(&mut treasury_stake, 10000, scenario.ctx());
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::stake(&mut pool, stake_coin, @0xA, 0);
            test_scenario::return_shared(pool);
        };

        // Tx 3: Wait 100 ms then claim at t=100
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::claim(&mut pool, @0xA, 100, ctx);
            test_scenario::return_shared(pool);
        };

        // Tx 4: Verify reward coins received
        scenario.next_tx(@0xA);
        {
            let reward_coin: coin::Coin<REWARD> = scenario.take_from_sender();
            assert!(coin::value(&reward_coin) == 1000);
            coin::burn_for_testing(reward_coin);
        };

        // Cleanup: unstake and destroy
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 10000, @0xA, 100, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let returned_stake: coin::Coin<STAKE> = scenario.take_from_sender();
            coin::burn_for_testing(returned_stake);
        };

        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            destroy_empty_pool(pool);
            let ctx = scenario.ctx();
            teardown_treasuries(treasury_stake, treasury_reward, ctx);
        };

        scenario.end();
    }

    // ============================================================
    // Test 5: Reward accumulation math is correct
    // ============================================================

    #[test]
    fun test_reward_accumulation_math() {
        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_stake, mut treasury_reward) = {
            let ctx = scenario.ctx();
            let (ts, mut tr) = setup_treasuries(ctx);
            let reward_coin = mint_reward(&mut tr, 10000, ctx);
            accumulator::create_pool<STAKE, REWARD>(reward_coin, 1000, 0, ctx);
            (ts, tr)
        };

        // Tx 2: Stake 10000 at t=0
        scenario.next_tx(@0xA);
        {
            let stake_coin = mint_stake(&mut treasury_stake, 10000, scenario.ctx());
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::stake(&mut pool, stake_coin, @0xA, 0);
            test_scenario::return_shared(pool);
        };

        // Tx 3: Check pending reward at t=50
        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let pending = accumulator::pending_reward(&pool, @0xA, 50);
            assert!(pending == 500);
            test_scenario::return_shared(pool);
        };

        // Tx 4: Check pending at t=100
        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let pending = accumulator::pending_reward(&pool, @0xA, 100);
            assert!(pending == 1000);
            test_scenario::return_shared(pool);
        };

        // Tx 5: Claim at t=100
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::claim(&mut pool, @0xA, 100, ctx);
            test_scenario::return_shared(pool);
        };

        // Tx 6: Take reward coin
        scenario.next_tx(@0xA);
        {
            let reward_coin: coin::Coin<REWARD> = scenario.take_from_sender();
            assert!(coin::value(&reward_coin) == 1000);
            coin::burn_for_testing(reward_coin);
        };

        // Tx 7: Check remaining pool balance
        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let (_total_stake, _rate, _last_update, _end_ms, remaining) = accumulator::pool_info(&pool);
            assert!(remaining == 9000);
            let pending = accumulator::pending_reward(&pool, @0xA, 100);
            assert!(pending == 0);
            test_scenario::return_shared(pool);
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 10000, @0xA, 100, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let returned_stake: coin::Coin<STAKE> = scenario.take_from_sender();
            coin::burn_for_testing(returned_stake);
        };

        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            destroy_empty_pool(pool);
            let ctx = scenario.ctx();
            teardown_treasuries(treasury_stake, treasury_reward, ctx);
        };

        scenario.end();
    }

    // ============================================================
    // Test 6: Multiple users get proportional rewards
    // ============================================================

    #[test]
    fun test_multiple_users_proportional() {
        let admin = @0xA;
        let user1 = @0xB;
        let user2 = @0xC;

        let mut scenario = test_scenario::begin(admin);

        let (mut treasury_stake, mut treasury_reward) = {
            let ctx = scenario.ctx();
            let (ts, mut tr) = setup_treasuries(ctx);
            let reward_coin = mint_reward(&mut tr, 10000, ctx);
            accumulator::create_pool<STAKE, REWARD>(reward_coin, 1000, 0, ctx);
            (ts, tr)
        };

        // Tx 2: User1 stakes 3000 at t=0
        scenario.next_tx(user1);
        {
            let stake_coin = mint_stake(&mut treasury_stake, 3000, scenario.ctx());
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::stake(&mut pool, stake_coin, user1, 0);
            test_scenario::return_shared(pool);
        };

        // Tx 3: User2 stakes 7000 at t=0
        scenario.next_tx(user2);
        {
            let stake_coin = mint_stake(&mut treasury_stake, 7000, scenario.ctx());
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::stake(&mut pool, stake_coin, user2, 0);
            test_scenario::return_shared(pool);
        };

        // Tx 4: Claim for user1 at t=100
        scenario.next_tx(user1);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::claim(&mut pool, user1, 100, ctx);
            test_scenario::return_shared(pool);
        };

        // Tx 5: User1 receives 300 reward tokens
        scenario.next_tx(user1);
        {
            let reward_coin: coin::Coin<REWARD> = scenario.take_from_sender();
            assert!(coin::value(&reward_coin) == 300);
            coin::burn_for_testing(reward_coin);
        };

        // Tx 6: User2 claims at t=100
        scenario.next_tx(user2);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::claim(&mut pool, user2, 100, ctx);
            test_scenario::return_shared(pool);
        };

        // Tx 7: User2 receives 700 reward tokens
        scenario.next_tx(user2);
        {
            let reward_coin: coin::Coin<REWARD> = scenario.take_from_sender();
            assert!(coin::value(&reward_coin) == 700);
            coin::burn_for_testing(reward_coin);
        };

        // Cleanup: both users unstake
        scenario.next_tx(user1);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 3000, user1, 100, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(user1);
        {
            let returned: coin::Coin<STAKE> = scenario.take_from_sender();
            coin::burn_for_testing(returned);
        };

        scenario.next_tx(user2);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 7000, user2, 100, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(user2);
        {
            let returned: coin::Coin<STAKE> = scenario.take_from_sender();
            coin::burn_for_testing(returned);
        };

        // Final cleanup
        scenario.next_tx(admin);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            destroy_empty_pool(pool);
            let ctx = scenario.ctx();
            teardown_treasuries(treasury_stake, treasury_reward, ctx);
        };

        scenario.end();
    }

    // ============================================================
    // Test 7: Unstake with accumulated rewards preserves pending
    // ============================================================

    #[test]
    fun test_partial_unstake_preserves_pending() {
        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_stake, mut treasury_reward) = {
            let ctx = scenario.ctx();
            let (ts, mut tr) = setup_treasuries(ctx);
            let reward_coin = mint_reward(&mut tr, 10000, ctx);
            accumulator::create_pool<STAKE, REWARD>(reward_coin, 1000, 0, ctx);
            (ts, tr)
        };

        // Tx 2: Stake 10000 at t=0
        scenario.next_tx(@0xA);
        {
            let stake_coin = mint_stake(&mut treasury_stake, 10000, scenario.ctx());
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::stake(&mut pool, stake_coin, @0xA, 0);
            test_scenario::return_shared(pool);
        };

        // Tx 3: Partial unstake 4000 at t=100
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 4000, @0xA, 100, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let returned: coin::Coin<STAKE> = scenario.take_from_sender();
            assert!(coin::value(&returned) == 4000);
            coin::burn_for_testing(returned);
        };

        // Tx 4: At t=200, claim rewards
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::claim(&mut pool, @0xA, 200, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let reward_coin: coin::Coin<REWARD> = scenario.take_from_sender();
            assert!(coin::value(&reward_coin) == 999);
            coin::burn_for_testing(reward_coin);
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 6000, @0xA, 200, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let returned: coin::Coin<STAKE> = scenario.take_from_sender();
            coin::burn_for_testing(returned);
        };

        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            destroy_empty_pool(pool);
            let ctx = scenario.ctx();
            teardown_treasuries(treasury_stake, treasury_reward, ctx);
        };

        scenario.end();
    }

    // ============================================================
    // Test 8: Zero duration aborts
    // ============================================================

    #[test]
    #[expected_failure(abort_code = accumulator::EZeroDuration)]
    fun test_zero_duration_aborts() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (mut treasury_stake, mut treasury_reward) = setup_treasuries(ctx);

        let reward_coin = mint_reward(&mut treasury_reward, 10000, ctx);
        accumulator::create_pool<STAKE, REWARD>(reward_coin, 0, 100, ctx);

        teardown_treasuries(treasury_stake, treasury_reward, ctx);
        scenario.end();
    }

    // ============================================================
    // Test 9: Insufficient stake aborts on unstake
    // ============================================================

    #[test]
    #[expected_failure(abort_code = accumulator::EInsufficientStake)]
    fun test_insufficient_stake_aborts() {
        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_stake, mut treasury_reward) = {
            let ctx = scenario.ctx();
            let (ts, mut tr) = setup_treasuries(ctx);
            let reward_coin = mint_reward(&mut tr, 10000, ctx);
            accumulator::create_pool<STAKE, REWARD>(reward_coin, 1000, 0, ctx);
            (ts, tr)
        };

        // Tx 2: Stake 1000
        scenario.next_tx(@0xA);
        {
            let stake_coin = mint_stake(&mut treasury_stake, 1000, scenario.ctx());
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::stake(&mut pool, stake_coin, @0xA, 0);
            test_scenario::return_shared(pool);
        };

        // Tx 3: Try to unstake 2000
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 2000, @0xA, 0, ctx);
            test_scenario::return_shared(pool);
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let ctx = scenario.ctx();
            teardown_treasuries(treasury_stake, treasury_reward, ctx);
        };

        scenario.end();
    }

    // ============================================================
    // Test 10: Pool expires and stops emitting after end_ms
    // ============================================================

    #[test]
    fun test_pool_expires() {
        let mut scenario = test_scenario::begin(@0xA);

        let (mut treasury_stake, mut treasury_reward) = {
            let ctx = scenario.ctx();
            let (ts, mut tr) = setup_treasuries(ctx);
            let reward_coin = mint_reward(&mut tr, 1000, ctx);
            accumulator::create_pool<STAKE, REWARD>(reward_coin, 100, 0, ctx);
            (ts, tr)
        };

        // Tx 2: Stake 1000 at t=0
        scenario.next_tx(@0xA);
        {
            let stake_coin = mint_stake(&mut treasury_stake, 1000, scenario.ctx());
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::stake(&mut pool, stake_coin, @0xA, 0);
            test_scenario::return_shared(pool);
        };

        // Tx 3: Claim at t=50
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::claim(&mut pool, @0xA, 50, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let reward_coin: coin::Coin<REWARD> = scenario.take_from_sender();
            assert!(coin::value(&reward_coin) == 500);
            coin::burn_for_testing(reward_coin);
        };

        // Tx 4: Claim at t=200 (past end_ms=100)
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::claim(&mut pool, @0xA, 200, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let reward_coin: coin::Coin<REWARD> = scenario.take_from_sender();
            assert!(coin::value(&reward_coin) == 500);
            coin::burn_for_testing(reward_coin);
        };

        // Tx 5: Verify no more rewards remain
        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let (_total, _rate, _last_update, _end_ms, remaining) = accumulator::pool_info(&pool);
            assert!(remaining == 0);
            test_scenario::return_shared(pool);
        };

        // Cleanup
        scenario.next_tx(@0xA);
        {
            let mut pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            let ctx = scenario.ctx();
            accumulator::unstake(&mut pool, 1000, @0xA, 200, ctx);
            test_scenario::return_shared(pool);
        };

        scenario.next_tx(@0xA);
        {
            let returned: coin::Coin<STAKE> = scenario.take_from_sender();
            coin::burn_for_testing(returned);
        };

        scenario.next_tx(@0xA);
        {
            let pool = test_scenario::take_shared<RewardPool<STAKE, REWARD>>(&scenario);
            destroy_empty_pool(pool);
            let ctx = scenario.ctx();
            teardown_treasuries(treasury_stake, treasury_reward, ctx);
        };

        scenario.end();
    }

}
