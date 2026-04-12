#[test_only]
module lending_market::test_coins {
    public struct COLLATERAL has copy, drop, store {}
    public struct BORROW has copy, drop, store {}

}
#[test_only]
module lending_market::market_test {
    use sui::coin;
    use sui::coin::{TreasuryCap, Coin};
    use sui::test_scenario;
    use lending_market::market;
    use lending_market::market::{Market, DepositReceipt, BorrowReceipt, AdminCap};
    use lending_market::test_coins::{COLLATERAL, BORROW};

    const ADMIN: address = @0xA;
    const USER_B: address = @0xB;

    // ============================================================
    // Helpers
    // ============================================================

    fun setup_collateral(
        ctx: &mut sui::tx_context::TxContext,
    ): TreasuryCap<COLLATERAL> {
        coin::create_treasury_cap_for_testing<COLLATERAL>(ctx)
    }

    fun setup_borrow(
        ctx: &mut sui::tx_context::TxContext,
    ): TreasuryCap<BORROW> {
        coin::create_treasury_cap_for_testing<BORROW>(ctx)
    }

    /// Initialize a market with standard parameters:
    /// - collateral_factor: 75%
    /// - liquidation_threshold: 80%
    /// - liquidation_bonus: 5%
    /// - base_rate: 2%
    /// - kink: 80% utilization
    /// - multiplier: 10% (slope below kink)
    /// - jump_multiplier: 5x (slope above kink)
    fun init_market(ctx: &mut sui::tx_context::TxContext) {
        market::create_market<COLLATERAL, BORROW>(
            7500,  // collateral_factor_bps
            8000,  // liquidation_threshold_bps
            500,   // liquidation_bonus_bps
            200,   // base_rate_bps
            8000,  // kink_bps
            1000,  // multiplier_bps
            500,   // jump_multiplier_bps
            ctx,
        );
    }

    // ============================================================
    // Test 1: Initialize market
    // ============================================================
    #[test]
    fun test_init_market() {
        let mut scenario = test_scenario::begin(ADMIN);
        // All initial setup in the first transaction context
        let coll_cap = setup_collateral(scenario.ctx());
        let borrow_cap = setup_borrow(scenario.ctx());
        init_market(scenario.ctx());

        // Move past the first tx so shared/owned objects are available
        scenario.next_tx(ADMIN);

        // Verify Market was shared
        let market = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        assert!(market::total_collateral(&market) == 0);
        assert!(market::total_borrow(&market) == 0);
        assert!(market::collateral_factor_bps(&market) == 7500);
        assert!(market::liquidation_threshold_bps(&market) == 8000);
        assert!(market::liquidation_bonus_bps(&market) == 500);
        test_scenario::return_shared(market);

        // Verify AdminCap was transferred to sender
        let admin_cap = scenario.take_from_sender<AdminCap<COLLATERAL, BORROW>>();
        scenario.return_to_sender(admin_cap);

        // Cleanup - transfer caps to sender to keep them alive
        sui::transfer::public_transfer(coll_cap, scenario.sender());
        sui::transfer::public_transfer(borrow_cap, scenario.sender());

        scenario.end();
    }

    // ============================================================
    // Test 2: Supply collateral
    // ============================================================
    #[test]
    fun test_supply_collateral() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut coll_cap = setup_collateral(scenario.ctx());
        let borrow_cap = setup_borrow(scenario.ctx());
        init_market(scenario.ctx());

        // Supply 1000 collateral tokens
        scenario.next_tx(ADMIN);
        // Scope ctx usage so scenario is free for take_shared
        let collateral_coin = coin::mint(&mut coll_cap, 1000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let deposit_receipt = market::supply_collateral(&mut market_obj, collateral_coin, scenario.ctx());

        assert!(market::total_collateral(&market_obj) == 1000);
        assert!(market::collateral_vault_balance(&market_obj) == 1000);
        assert!(market::deposit_amount(&deposit_receipt) == 1000);

        test_scenario::return_shared(market_obj);
        // deposit_receipt was newly created, transfer to sender
        sui::transfer::public_transfer(deposit_receipt, scenario.sender());

        sui::transfer::public_transfer(coll_cap, scenario.sender());
        sui::transfer::public_transfer(borrow_cap, scenario.sender());

        scenario.end();
    }

    // ============================================================
    // Test 3: Borrow within health factor
    // ============================================================
    #[test]
    fun test_borrow_within_health_factor() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut coll_cap = setup_collateral(scenario.ctx());
        let mut borrow_cap = setup_borrow(scenario.ctx());
        init_market(scenario.ctx());

        // Add borrow liquidity (someone deposited borrow tokens).
        scenario.next_tx(ADMIN);
        let liquidity_coin = coin::mint(&mut borrow_cap, 10000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        market::add_liquidity(&mut market_obj, liquidity_coin);
        test_scenario::return_shared(market_obj);

        // Supply 1000 collateral.
        scenario.next_tx(ADMIN);
        let collateral_coin = coin::mint(&mut coll_cap, 1000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let deposit_receipt = market::supply_collateral(&mut market_obj, collateral_coin, scenario.ctx());
        test_scenario::return_shared(market_obj);
        sui::transfer::public_transfer(deposit_receipt, scenario.sender());

        // Borrow 500.
        // collateral_factor = 75%, so max borrow = 1000 * 75% = 750.
        // Borrowing 500 => hf = 1000 * 7500 / 500 = 15000 (> 10000, healthy).
        scenario.next_tx(ADMIN);
        let deposit_receipt = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let (borrow_coin, borrow_receipt) = market::borrow(&mut market_obj, &deposit_receipt, 500, scenario.ctx());

        assert!(coin::value(&borrow_coin) == 500);
        assert!(market::total_borrow(&market_obj) == 500);
        assert!(market::borrow_vault_balance(&market_obj) == 9500);

        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(deposit_receipt);
        sui::transfer::public_transfer(borrow_receipt, scenario.sender());
        sui::transfer::public_transfer(borrow_coin, scenario.sender());

        sui::transfer::public_transfer(coll_cap, scenario.sender());
        sui::transfer::public_transfer(borrow_cap, scenario.sender());

        scenario.end();
    }

    // ============================================================
    // Test 4: Cannot borrow beyond health factor
    // ============================================================
    #[test]
    #[expected_failure(abort_code = market::EHealthFactorTooLow)]
    fun test_cannot_borrow_beyond_health_factor() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut coll_cap = setup_collateral(scenario.ctx());
        let mut borrow_cap = setup_borrow(scenario.ctx());
        init_market(scenario.ctx());

        // Add borrow liquidity.
        scenario.next_tx(ADMIN);
        let liquidity_coin = coin::mint(&mut borrow_cap, 10000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        market::add_liquidity(&mut market_obj, liquidity_coin);
        test_scenario::return_shared(market_obj);

        // Supply 1000 collateral.
        scenario.next_tx(ADMIN);
        let collateral_coin = coin::mint(&mut coll_cap, 1000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let deposit_receipt = market::supply_collateral(&mut market_obj, collateral_coin, scenario.ctx());
        test_scenario::return_shared(market_obj);
        sui::transfer::public_transfer(deposit_receipt, scenario.sender());

        // Try to borrow 800. Max borrow = 1000 * 75% = 750.
        // hf = 1000 * 7500 / 800 = 9375 (< 10000). Should fail.
        scenario.next_tx(ADMIN);
        let deposit_receipt = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let (borrow_coin, borrow_receipt) = market::borrow(&mut market_obj, &deposit_receipt, 800, scenario.ctx());

        // Should not reach here.
        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(deposit_receipt);
        sui::transfer::public_transfer(borrow_receipt, scenario.sender());
        sui::transfer::public_transfer(borrow_coin, scenario.sender());

        sui::transfer::public_transfer(coll_cap, scenario.sender());
        sui::transfer::public_transfer(borrow_cap, scenario.sender());

        scenario.end();
    }

    // ============================================================
    // Test 5: Repay debt
    // ============================================================
    #[test]
    fun test_repay() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut coll_cap = setup_collateral(scenario.ctx());
        let mut borrow_cap = setup_borrow(scenario.ctx());
        init_market(scenario.ctx());

        // Add borrow liquidity.
        scenario.next_tx(ADMIN);
        let liquidity_coin = coin::mint(&mut borrow_cap, 10000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        market::add_liquidity(&mut market_obj, liquidity_coin);
        test_scenario::return_shared(market_obj);

        // Supply 1000 collateral.
        scenario.next_tx(ADMIN);
        let collateral_coin = coin::mint(&mut coll_cap, 1000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let deposit_receipt = market::supply_collateral(&mut market_obj, collateral_coin, scenario.ctx());
        test_scenario::return_shared(market_obj);
        sui::transfer::public_transfer(deposit_receipt, scenario.sender());

        // Borrow 500.
        scenario.next_tx(ADMIN);
        let deposit_receipt = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let (borrow_coin, borrow_receipt) = market::borrow(&mut market_obj, &deposit_receipt, 500, scenario.ctx());
        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(deposit_receipt);
        sui::transfer::public_transfer(borrow_receipt, scenario.sender());
        sui::transfer::public_transfer(borrow_coin, scenario.sender());

        // Repay 500 (the exact debt).
        scenario.next_tx(ADMIN);
        let borrow_receipt = scenario.take_from_sender<BorrowReceipt<COLLATERAL, BORROW>>();
        let repay_coin = scenario.take_from_sender<Coin<BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);

        market::repay(&mut market_obj, borrow_receipt, repay_coin, scenario.ctx());

        assert!(market::total_borrow(&market_obj) == 0);
        assert!(market::borrow_vault_balance(&market_obj) == 10000);

        test_scenario::return_shared(market_obj);

        sui::transfer::public_transfer(coll_cap, scenario.sender());
        sui::transfer::public_transfer(borrow_cap, scenario.sender());

        scenario.end();
    }

    // ============================================================
    // Test 6: Withdraw collateral
    //
    // The user has an active small borrow and withdraws collateral.
    // ============================================================
    #[test]
    fun test_withdraw_collateral() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut coll_cap = setup_collateral(scenario.ctx());
        let mut borrow_cap = setup_borrow(scenario.ctx());
        init_market(scenario.ctx());

        // Add borrow liquidity.
        scenario.next_tx(ADMIN);
        let liquidity_coin = coin::mint(&mut borrow_cap, 10000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        market::add_liquidity(&mut market_obj, liquidity_coin);
        test_scenario::return_shared(market_obj);

        // Supply 1000 collateral.
        scenario.next_tx(ADMIN);
        let collateral_coin = coin::mint(&mut coll_cap, 1000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let deposit_receipt = market::supply_collateral(&mut market_obj, collateral_coin, scenario.ctx());
        test_scenario::return_shared(market_obj);
        sui::transfer::public_transfer(deposit_receipt, scenario.sender());

        // Borrow 100 (very small, so position stays healthy).
        // hf = 1000 * 7500 / 100 = 75000 >> 10000.
        scenario.next_tx(ADMIN);
        let deposit_receipt = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let (borrow_coin, borrow_receipt) = market::borrow(&mut market_obj, &deposit_receipt, 100, scenario.ctx());
        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(deposit_receipt);
        sui::transfer::public_transfer(borrow_receipt, scenario.sender());
        sui::transfer::public_transfer(borrow_coin, scenario.sender());

        // Withdraw all collateral. The health check uses collateral_factor (75%).
        // hf = 1000 * 7500 / 100 = 75000 >> 10000. Healthy.
        scenario.next_tx(ADMIN);
        let deposit_receipt = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let borrow_receipt = scenario.take_from_sender<BorrowReceipt<COLLATERAL, BORROW>>();
        let borrow_coin = scenario.take_from_sender<Coin<BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);

        let withdrawn = market::withdraw_collateral(&mut market_obj, deposit_receipt, &borrow_receipt, scenario.ctx());

        assert!(coin::value(&withdrawn) == 1000);
        assert!(market::total_collateral(&market_obj) == 0);

        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(borrow_receipt);
        sui::transfer::public_transfer(withdrawn, scenario.sender());
        sui::transfer::public_transfer(borrow_coin, scenario.sender());

        sui::transfer::public_transfer(coll_cap, scenario.sender());
        sui::transfer::public_transfer(borrow_cap, scenario.sender());

        scenario.end();
    }

    // ============================================================
    // Test 7: Liquidation of unhealthy position
    // ============================================================
    #[test]
    fun test_liquidation() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut coll_cap = setup_collateral(scenario.ctx());
        let mut borrow_cap = setup_borrow(scenario.ctx());
        init_market(scenario.ctx());

        // Add borrow liquidity.
        scenario.next_tx(ADMIN);
        let liquidity_coin = coin::mint(&mut borrow_cap, 10000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        market::add_liquidity(&mut market_obj, liquidity_coin);
        test_scenario::return_shared(market_obj);

        // USER_B supplies 1000 collateral and borrows 500.
        // With collateral_factor = 75%: max borrow = 750. Borrowing 500 is fine.
        // hf = 1000 * 7500 / 500 = 15000 > 10000.
        scenario.next_tx(USER_B);
        let collateral_coin = coin::mint(&mut coll_cap, 1000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let deposit_receipt_b = market::supply_collateral(&mut market_obj, collateral_coin, scenario.ctx());
        test_scenario::return_shared(market_obj);
        sui::transfer::public_transfer(deposit_receipt_b, scenario.sender());

        scenario.next_tx(USER_B);
        let deposit_receipt_b = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let (borrow_coin, borrow_receipt_b) = market::borrow(&mut market_obj, &deposit_receipt_b, 500, scenario.ctx());
        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(deposit_receipt_b);
        sui::transfer::public_transfer(borrow_receipt_b, scenario.sender());
        sui::transfer::public_transfer(borrow_coin, scenario.sender());

        // Now make the position unhealthy by lowering the liquidation threshold.
        // Current: threshold=80%, hf_with_threshold=1000*8000/500=16000 > 10000 (healthy).
        // Lower threshold to 40%: hf_with_threshold=1000*4000/500=8000 < 10000 (liquidatable).
        scenario.next_tx(ADMIN);
        let admin_cap = scenario.take_from_sender<AdminCap<COLLATERAL, BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        market::set_liquidation_threshold_test(&mut market_obj, 4000);
        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(admin_cap);

        // USER_B self-liquidates (repays their debt, seizes their collateral).
        // Seized collateral = 500 * (10000 + 500) / 10000 = 525.
        scenario.next_tx(USER_B);
        let borrow_receipt_b = scenario.take_from_sender<BorrowReceipt<COLLATERAL, BORROW>>();
        let mut deposit_receipt_b = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let borrow_coin_b = scenario.take_from_sender<Coin<BORROW>>();
        let repay_coin = coin::mint(&mut borrow_cap, 500, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);

        let seized_collateral = market::liquidate(
            &mut market_obj,
            borrow_receipt_b,
            repay_coin,
            &mut deposit_receipt_b,
            scenario.ctx(),
        );

        // Seized = 500 * (10000 + 500) / 10000 = 525
        assert!(coin::value(&seized_collateral) == 525);
        // Borrower's remaining collateral = 1000 - 525 = 475
        assert!(market::deposit_amount(&deposit_receipt_b) == 475);
        // Total borrow should be 0
        assert!(market::total_borrow(&market_obj) == 0);

        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(deposit_receipt_b);
        sui::transfer::public_transfer(seized_collateral, scenario.sender());
        sui::transfer::public_transfer(borrow_coin_b, scenario.sender());

        sui::transfer::public_transfer(coll_cap, scenario.sender());
        sui::transfer::public_transfer(borrow_cap, scenario.sender());

        scenario.end();
    }

    // ============================================================
    // Test 8: Interest rate calculation at different utilization levels
    // ============================================================
    #[test]
    fun test_interest_rate_calculation() {
        let mut scenario = test_scenario::begin(ADMIN);
        let mut coll_cap = setup_collateral(scenario.ctx());
        let mut borrow_cap = setup_borrow(scenario.ctx());
        init_market(scenario.ctx());

        // Market params: base_rate=200, kink=8000, multiplier=1000, jump_multiplier=500

        // At 0% utilization (no borrows, no collateral): rate = base_rate = 200 bps (2%).
        scenario.next_tx(ADMIN);
        let market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        assert!(market::calculate_interest_rate(&market_obj) == 200);
        test_scenario::return_shared(market_obj);

        // Add liquidity and borrow to reach different utilization levels.
        // Add 10000 borrow tokens to the vault.
        scenario.next_tx(ADMIN);
        let liquidity_coin = coin::mint(&mut borrow_cap, 10000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        market::add_liquidity(&mut market_obj, liquidity_coin);
        test_scenario::return_shared(market_obj);

        // Supply 10000 collateral so total_collateral = 10000.
        scenario.next_tx(ADMIN);
        let collateral_coin = coin::mint(&mut coll_cap, 10000, scenario.ctx());
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let deposit_receipt = market::supply_collateral(&mut market_obj, collateral_coin, scenario.ctx());
        test_scenario::return_shared(market_obj);
        sui::transfer::public_transfer(deposit_receipt, scenario.sender());

        // Borrow 5000 => 50% utilization, below kink of 80%.
        // utilization_bps = 5000 * 10000 / 10000 = 5000.
        // rate = 200 + (5000 * 1000) / 10000 = 200 + 500 = 700 bps.
        scenario.next_tx(ADMIN);
        let deposit_receipt = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let (borrow_coin, borrow_receipt) = market::borrow(&mut market_obj, &deposit_receipt, 5000, scenario.ctx());

        let rate_at_50 = market::calculate_interest_rate(&market_obj);
        assert!(rate_at_50 == 700);

        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(deposit_receipt);
        sui::transfer::public_transfer(borrow_receipt, scenario.sender());
        sui::transfer::public_transfer(borrow_coin, scenario.sender());

        // Borrow 3000 more => 80% utilization (at the kink).
        // utilization_bps = 8000.
        // rate = 200 + (8000 * 1000) / 10000 = 1000 bps.
        scenario.next_tx(ADMIN);
        let deposit_receipt = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let borrow_receipt1 = scenario.take_from_sender<BorrowReceipt<COLLATERAL, BORROW>>();
        let borrow_coin1 = scenario.take_from_sender<Coin<BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let (borrow_coin2, borrow_receipt2) = market::borrow(&mut market_obj, &deposit_receipt, 3000, scenario.ctx());

        let rate_at_kink = market::calculate_interest_rate(&market_obj);
        assert!(rate_at_kink == 1000);

        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(deposit_receipt);
        scenario.return_to_sender(borrow_receipt1);
        sui::transfer::public_transfer(borrow_receipt2, scenario.sender());
        sui::transfer::public_transfer(borrow_coin1, scenario.sender());
        sui::transfer::public_transfer(borrow_coin2, scenario.sender());

        // Borrow 1000 more => 90% utilization (above the kink).
        // excess = 9000 - 8000 = 1000.
        // rate = 200 + (8000 * 1000) / 10000 + (1000 * 1000 * 500) / 100000000
        //      = 200 + 800 + 5 = 1005 bps.
        scenario.next_tx(ADMIN);
        let deposit_receipt = scenario.take_from_sender<DepositReceipt<COLLATERAL, BORROW>>();
        let borrow_receipt1 = scenario.take_from_sender<BorrowReceipt<COLLATERAL, BORROW>>();
        let borrow_receipt2 = scenario.take_from_sender<BorrowReceipt<COLLATERAL, BORROW>>();
        let borrow_coin1 = scenario.take_from_sender<Coin<BORROW>>();
        let borrow_coin2 = scenario.take_from_sender<Coin<BORROW>>();
        let mut market_obj = test_scenario::take_shared<Market<COLLATERAL, BORROW>>(&scenario);
        let (borrow_coin3, borrow_receipt3) = market::borrow(&mut market_obj, &deposit_receipt, 1000, scenario.ctx());

        let rate_above_kink = market::calculate_interest_rate(&market_obj);
        assert!(rate_above_kink == 1005);

        test_scenario::return_shared(market_obj);
        scenario.return_to_sender(deposit_receipt);
        scenario.return_to_sender(borrow_receipt1);
        scenario.return_to_sender(borrow_receipt2);
        sui::transfer::public_transfer(borrow_receipt3, scenario.sender());
        sui::transfer::public_transfer(borrow_coin1, scenario.sender());
        sui::transfer::public_transfer(borrow_coin2, scenario.sender());
        sui::transfer::public_transfer(borrow_coin3, scenario.sender());

        sui::transfer::public_transfer(coll_cap, scenario.sender());
        sui::transfer::public_transfer(borrow_cap, scenario.sender());

        scenario.end();
    }

}
