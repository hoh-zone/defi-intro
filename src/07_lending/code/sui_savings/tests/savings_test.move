#[test_only]
module sui_savings::test_coin {
    public struct TESTCOIN has copy, drop, store {}
}
#[test_only]
module sui_savings::savings_test {
    use sui::coin::{Self, TreasuryCap};
    use sui::test_scenario;
    use sui_savings::savings::{Self, SavingsPool, SavingsReceipt, AdminCap};
    use sui_savings::test_coin::TESTCOIN;

    // Helper: create a test treasury cap
    fun setup_treasury(ctx: &mut sui::tx_context::TxContext): TreasuryCap<TESTCOIN> {
        coin::create_treasury_cap_for_testing<TESTCOIN>(ctx)
    }

    // Helper: mint coins
    fun mint_coins(
        cap: &mut TreasuryCap<TESTCOIN>,
        amount: u64,
        ctx: &mut sui::tx_context::TxContext,
    ): coin::Coin<TESTCOIN> {
        coin::mint(cap, amount, ctx)
    }

    // Helper: burn any coin (for cleanup)
    fun burn_coin(coin: coin::Coin<TESTCOIN>) {
        coin::burn_for_testing(coin);
    }

    // ============================================================
    // Test 1: Initialize savings pool
    // ============================================================
    #[test]
    fun test_init_pool() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();
        let mut treasury_cap = setup_treasury(ctx);
        savings::test_init<TESTCOIN>(500, ctx);

        // Move to next tx so shared/transferred objects are in the inventory
        scenario.next_tx(@0xA);

        // Verify pool was created and shared
        let pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        assert!(savings::total_shares(&pool) == 0);
        assert!(savings::principal_balance(&pool) == 0);
        assert!(savings::reward_balance(&pool) == 0);
        assert!(!savings::is_paused(&pool));
        test_scenario::return_shared(pool);

        // Verify AdminCap was transferred to sender
        let admin_cap = test_scenario::take_from_sender<AdminCap<TESTCOIN>>(&scenario);
        test_scenario::return_to_sender(&scenario, admin_cap);

        // Cleanup: transfer treasury_cap to sender for scenario cleanup
        sui::transfer::public_transfer(treasury_cap, @0xA);

        scenario.end();
    }

    // ============================================================
    // Test 2: Deposit and check shares (first depositor gets 1:1)
    // ============================================================
    #[test]
    fun test_first_deposit() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();
        let mut treasury_cap = setup_treasury(ctx);
        savings::test_init<TESTCOIN>(500, ctx);

        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let coin = mint_coins(&mut treasury_cap, 1000, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let receipt = savings::deposit<TESTCOIN>(&mut pool, coin, scenario.ctx());

        // First depositor: 1:1 ratio, so 1000 tokens = 1000 shares
        assert!(savings::total_shares(&pool) == 1000);
        assert!(savings::principal_balance(&pool) == 1000);

        test_scenario::return_shared(pool);
        sui::transfer::public_transfer(receipt, @0xA);
        sui::transfer::public_transfer(treasury_cap, @0xA);

        scenario.end();
    }

    // ============================================================
    // Test 3: Second depositor gets correct shares based on exchange rate
    // ============================================================
    #[test]
    fun test_second_deposit_exchange_rate() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();
        let mut treasury_cap = setup_treasury(ctx);
        savings::test_init<TESTCOIN>(500, ctx);

        // --- First deposit: 1000 tokens ---
        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let coin1 = mint_coins(&mut treasury_cap, 1000, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let receipt1 = savings::deposit<TESTCOIN>(&mut pool, coin1, scenario.ctx());
        test_scenario::return_shared(pool);
        sui::transfer::public_transfer(receipt1, @0xA);

        // --- Second deposit: 500 tokens ---
        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let coin2 = mint_coins(&mut treasury_cap, 500, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);

        assert!(savings::principal_balance(&pool) == 1000);
        assert!(savings::total_shares(&pool) == 1000);

        let receipt2 = savings::deposit<TESTCOIN>(&mut pool, coin2, scenario.ctx());

        assert!(savings::total_shares(&pool) == 1500);
        assert!(savings::principal_balance(&pool) == 1500);

        test_scenario::return_shared(pool);
        sui::transfer::public_transfer(receipt2, @0xA);

        // Cleanup: withdraw both receipts
        scenario.next_tx(@0xA);
        let receipt1 = test_scenario::take_from_sender<SavingsReceipt<TESTCOIN>>(&scenario);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let withdrawn1 = savings::withdraw<TESTCOIN>(&mut pool, receipt1, scenario.ctx());
        burn_coin(withdrawn1);
        test_scenario::return_shared(pool);

        scenario.next_tx(@0xA);
        let receipt2 = test_scenario::take_from_sender<SavingsReceipt<TESTCOIN>>(&scenario);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let withdrawn2 = savings::withdraw<TESTCOIN>(&mut pool, receipt2, scenario.ctx());
        burn_coin(withdrawn2);
        test_scenario::return_shared(pool);

        sui::transfer::public_transfer(treasury_cap, @0xA);

        scenario.end();
    }

    // ============================================================
    // Test 4: Withdraw returns correct amount
    // ============================================================
    #[test]
    fun test_withdraw() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();
        let mut treasury_cap = setup_treasury(ctx);
        savings::test_init<TESTCOIN>(500, ctx);

        // --- Deposit 2000 tokens ---
        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let coin = mint_coins(&mut treasury_cap, 2000, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let receipt = savings::deposit<TESTCOIN>(&mut pool, coin, scenario.ctx());
        test_scenario::return_shared(pool);
        sui::transfer::public_transfer(receipt, @0xA);

        // --- Withdraw ---
        scenario.next_tx(@0xA);
        let receipt = test_scenario::take_from_sender<SavingsReceipt<TESTCOIN>>(&scenario);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let withdrawn = savings::withdraw<TESTCOIN>(&mut pool, receipt, scenario.ctx());

        // Should get back exactly 2000 (1:1 since no rewards were added)
        assert!(coin::value(&withdrawn) == 2000);
        assert!(savings::total_shares(&pool) == 0);
        assert!(savings::principal_balance(&pool) == 0);

        test_scenario::return_shared(pool);
        burn_coin(withdrawn);

        sui::transfer::public_transfer(treasury_cap, @0xA);

        scenario.end();
    }

    // ============================================================
    // Test 5: Admin can add rewards
    // ============================================================
    #[test]
    fun test_add_rewards() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();
        let mut treasury_cap = setup_treasury(ctx);
        savings::test_init<TESTCOIN>(500, ctx);

        // Deposit some tokens first
        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let deposit_coin = mint_coins(&mut treasury_cap, 10000, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let receipt = savings::deposit<TESTCOIN>(&mut pool, deposit_coin, scenario.ctx());
        test_scenario::return_shared(pool);
        sui::transfer::public_transfer(receipt, @0xA);

        // Admin adds 500 reward tokens
        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let reward_coin = mint_coins(&mut treasury_cap, 500, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let admin_cap = test_scenario::take_from_sender<AdminCap<TESTCOIN>>(&scenario);

        assert!(savings::reward_balance(&pool) == 0);

        savings::add_rewards<TESTCOIN>(&admin_cap, &mut pool, reward_coin);

        assert!(savings::reward_balance(&pool) == 500);
        assert!(savings::principal_balance(&pool) == 10000);

        test_scenario::return_shared(pool);
        test_scenario::return_to_sender(&scenario, admin_cap);

        // Cleanup: claim reward then withdraw to drain pool
        scenario.next_tx(@0xA);
        let receipt = test_scenario::take_from_sender<SavingsReceipt<TESTCOIN>>(&scenario);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let interest = savings::claim_interest<TESTCOIN>(&mut pool, &receipt, scenario.ctx());
        burn_coin(interest);
        test_scenario::return_shared(pool);
        test_scenario::return_to_sender(&scenario, receipt);

        scenario.next_tx(@0xA);
        let receipt = test_scenario::take_from_sender<SavingsReceipt<TESTCOIN>>(&scenario);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let withdrawn = savings::withdraw<TESTCOIN>(&mut pool, receipt, scenario.ctx());
        burn_coin(withdrawn);
        test_scenario::return_shared(pool);

        sui::transfer::public_transfer(treasury_cap, @0xA);

        scenario.end();
    }

    // ============================================================
    // Test 6: User can claim interest proportional to shares
    // ============================================================
    #[test]
    fun test_claim_interest() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();
        let mut treasury_cap = setup_treasury(ctx);
        savings::test_init<TESTCOIN>(500, ctx);

        // --- First deposit: 8000 tokens ---
        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let coin_a = mint_coins(&mut treasury_cap, 8000, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let receipt_a = savings::deposit<TESTCOIN>(&mut pool, coin_a, scenario.ctx());
        test_scenario::return_shared(pool);
        sui::transfer::public_transfer(receipt_a, @0xA);

        // --- Second deposit: 2000 tokens ---
        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let coin_b = mint_coins(&mut treasury_cap, 2000, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let receipt_b = savings::deposit<TESTCOIN>(&mut pool, coin_b, scenario.ctx());
        assert!(savings::total_shares(&pool) == 10000);
        test_scenario::return_shared(pool);
        sui::transfer::public_transfer(receipt_b, @0xA);

        // --- Admin adds 1000 reward tokens ---
        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let reward_coin = mint_coins(&mut treasury_cap, 1000, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let admin_cap = test_scenario::take_from_sender<AdminCap<TESTCOIN>>(&scenario);
        savings::add_rewards<TESTCOIN>(&admin_cap, &mut pool, reward_coin);
        assert!(savings::reward_balance(&pool) == 1000);
        test_scenario::return_shared(pool);
        test_scenario::return_to_sender(&scenario, admin_cap);

        // --- First claim: LIFO order, so receipt_b (2000 shares) is taken first ---
        // 2000 shares out of 10000 = 20%. 20% of 1000 reward = 200.
        scenario.next_tx(@0xA);
        let receipt = test_scenario::take_from_sender<SavingsReceipt<TESTCOIN>>(&scenario);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let interest = savings::claim_interest<TESTCOIN>(&mut pool, &receipt, scenario.ctx());
        assert!(coin::value(&interest) == 200);
        burn_coin(interest);
        test_scenario::return_shared(pool);
        savings::destroy_receipt(receipt);

        // --- Second claim: receipt_a (8000 shares) is now the only one left ---
        // 8000 shares out of 10000 = 80%. 80% of remaining 800 = 640.
        scenario.next_tx(@0xA);
        let receipt = test_scenario::take_from_sender<SavingsReceipt<TESTCOIN>>(&scenario);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let interest_b = savings::claim_interest<TESTCOIN>(&mut pool, &receipt, scenario.ctx());
        assert!(coin::value(&interest_b) == 640);
        burn_coin(interest_b);
        test_scenario::return_shared(pool);
        test_scenario::return_to_sender(&scenario, receipt);

        // Cleanup: withdraw the remaining receipt
        scenario.next_tx(@0xA);
        let receipt = test_scenario::take_from_sender<SavingsReceipt<TESTCOIN>>(&scenario);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let withdrawn = savings::withdraw<TESTCOIN>(&mut pool, receipt, scenario.ctx());
        burn_coin(withdrawn);
        test_scenario::return_shared(pool);

        sui::transfer::public_transfer(treasury_cap, @0xA);

        scenario.end();
    }

    // ============================================================
    // Test 7: Pool can be paused and unpaused
    // ============================================================
    #[test]
    fun test_pause_unpause() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();
        let mut treasury_cap = setup_treasury(ctx);
        savings::test_init<TESTCOIN>(500, ctx);

        // --- Pause the pool ---
        scenario.next_tx(@0xA);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let admin_cap = test_scenario::take_from_sender<AdminCap<TESTCOIN>>(&scenario);

        assert!(!savings::is_paused(&pool));
        savings::pause<TESTCOIN>(&admin_cap, &mut pool);
        assert!(savings::is_paused(&pool));

        test_scenario::return_shared(pool);
        test_scenario::return_to_sender(&scenario, admin_cap);

        // --- Unpause the pool ---
        scenario.next_tx(@0xA);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let admin_cap = test_scenario::take_from_sender<AdminCap<TESTCOIN>>(&scenario);

        assert!(savings::is_paused(&pool));
        savings::unpause<TESTCOIN>(&admin_cap, &mut pool);
        assert!(!savings::is_paused(&pool));

        test_scenario::return_shared(pool);
        test_scenario::return_to_sender(&scenario, admin_cap);

        sui::transfer::public_transfer(treasury_cap, @0xA);

        scenario.end();
    }

    // ============================================================
    // Test 8: Cannot deposit when paused
    // ============================================================
    #[test]
    #[expected_failure(abort_code = savings::EPoolPaused)]
    fun test_cannot_deposit_when_paused() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();
        let mut treasury_cap = setup_treasury(ctx);
        savings::test_init<TESTCOIN>(500, ctx);

        // --- Pause the pool ---
        scenario.next_tx(@0xA);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let admin_cap = test_scenario::take_from_sender<AdminCap<TESTCOIN>>(&scenario);
        savings::pause<TESTCOIN>(&admin_cap, &mut pool);
        test_scenario::return_shared(pool);
        test_scenario::return_to_sender(&scenario, admin_cap);

        // --- Try to deposit while paused (should fail) ---
        scenario.next_tx(@0xA);
        let ctx = scenario.ctx();
        let coin = mint_coins(&mut treasury_cap, 1000, ctx);
        let mut pool = test_scenario::take_shared<SavingsPool<TESTCOIN>>(&scenario);
        let receipt = savings::deposit<TESTCOIN>(&mut pool, coin, scenario.ctx());
        // These lines should not be reached (abort at deposit above)
        savings::destroy_receipt(receipt);
        test_scenario::return_shared(pool);

        sui::transfer::public_transfer(treasury_cap, @0xA);

        scenario.end();
    }
}
