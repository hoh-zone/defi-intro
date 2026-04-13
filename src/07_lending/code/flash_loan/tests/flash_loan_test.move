#[test_only]
module flash_loan::test_coin {
    /// A simple coin type used only in tests.
    public struct LOANCOIN has copy, drop, store {}

}
#[test_only]
module flash_loan::flash_loan_test {
    use sui::test_scenario;
    use sui::coin;
    use sui::transfer;
    use flash_loan::flash_loan;
    use flash_loan::test_coin::LOANCOIN;

    // ===== Constants =====
    const FEE_BPS: u64 = 30; // 0.3%

    // ===== Helper: Create TreasuryCap and Coin =====

    fun init_test_coin(ctx: &mut TxContext): (coin::TreasuryCap<LOANCOIN>, coin::Coin<LOANCOIN>) {
        let mut treasury_cap = coin::create_treasury_cap_for_testing<LOANCOIN>(ctx);
        let coins = coin::mint<LOANCOIN>(&mut treasury_cap, 100_000_000_000, ctx);
        (treasury_cap, coins)
    }

    // ===== Test 1: Initialize Pool =====

    #[test]
    fun test_init_pool() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (mut treasury_cap, coins) = init_test_coin(ctx);
        flash_loan::new_pool<LOANCOIN>(&treasury_cap, FEE_BPS, ctx);

        scenario.next_tx(@0xA);

        let pool = scenario.take_shared<flash_loan::FlashPool<LOANCOIN>>();
        assert!(flash_loan::pool_balance(&pool) == 0);
        assert!(flash_loan::fee_bps(&pool) == FEE_BPS);
        assert!(flash_loan::total_loans(&pool) == 0);
        test_scenario::return_shared(pool);

        coin::burn(&mut treasury_cap, coins);
        transfer::public_transfer(treasury_cap, @0x0);
        scenario.end();
    }

    // ===== Test 2: Deposit Liquidity =====

    #[test]
    fun test_deposit_liquidity() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (mut treasury_cap, coins) = init_test_coin(ctx);
        flash_loan::new_pool<LOANCOIN>(&treasury_cap, FEE_BPS, ctx);

        scenario.next_tx(@0xA);

        let deposit_coin = coin::mint<LOANCOIN>(&mut treasury_cap, 50_000_000_000, scenario.ctx());
        let mut pool = scenario.take_shared<flash_loan::FlashPool<LOANCOIN>>();
        flash_loan::deposit<LOANCOIN>(&mut pool, deposit_coin);

        assert!(flash_loan::pool_balance(&pool) == 50_000_000_000);
        test_scenario::return_shared(pool);

        coin::burn(&mut treasury_cap, coins);
        transfer::public_transfer(treasury_cap, @0x0);
        scenario.end();
    }

    // ===== Test 3: Flash Borrow and Repay =====

    #[test]
    fun test_flash_borrow_and_repay() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (mut treasury_cap, coins) = init_test_coin(ctx);
        flash_loan::new_pool<LOANCOIN>(&treasury_cap, FEE_BPS, ctx);

        scenario.next_tx(@0xA);

        // Deposit liquidity: 100_000 LOANCOIN
        let deposit_coin = coin::mint<LOANCOIN>(&mut treasury_cap, 100_000_000_000, scenario.ctx());
        let mut pool = scenario.take_shared<flash_loan::FlashPool<LOANCOIN>>();
        flash_loan::deposit<LOANCOIN>(&mut pool, deposit_coin);
        assert!(flash_loan::pool_balance(&pool) == 100_000_000_000);

        // Borrow 10_000 LOANCOIN
        let (mut borrowed_coin, receipt) = flash_loan::borrow<LOANCOIN>(&mut pool, 10_000_000_000, scenario.ctx());
        assert!(coin::value(&borrowed_coin) == 10_000_000_000);
        assert!(flash_loan::pool_balance(&pool) == 90_000_000_000);

        let expected_fee = 10_000_000_000 * FEE_BPS / 10000;
        assert!(expected_fee == 30_000_000);

        // Simulate profit by minting extra coins
        let profit = coin::mint<LOANCOIN>(&mut treasury_cap, 100_000_000, scenario.ctx());
        coin::join(&mut borrowed_coin, profit);

        // Repay with borrowed + fee
        let repayment = borrowed_coin;
        let excess = flash_loan::repay<LOANCOIN>(&mut pool, receipt, repayment, scenario.ctx());

        assert!(coin::value(&excess) == 70_000_000);
        assert!(flash_loan::pool_balance(&pool) == 100_000_000_000);
        assert!(flash_loan::accumulated_fees(&pool) == 30_000_000);
        assert!(flash_loan::total_loans(&pool) == 1);

        test_scenario::return_shared(pool);

        coin::burn(&mut treasury_cap, excess);
        coin::burn(&mut treasury_cap, coins);
        transfer::public_transfer(treasury_cap, @0x0);
        scenario.end();
    }

    // ===== Test 4: Fee Calculation =====

    #[test]
    fun test_fee_calculation() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (mut treasury_cap, coins) = init_test_coin(ctx);
        flash_loan::new_pool<LOANCOIN>(&treasury_cap, FEE_BPS, ctx);

        scenario.next_tx(@0xA);

        let deposit_coin = coin::mint<LOANCOIN>(&mut treasury_cap, 1_000_000_000_000, scenario.ctx());
        let mut pool = scenario.take_shared<flash_loan::FlashPool<LOANCOIN>>();
        flash_loan::deposit<LOANCOIN>(&mut pool, deposit_coin);

        // Test various amounts -- all within one take_shared block
        assert!(flash_loan::fee_amount(&pool, 1_000) == 3);
        assert!(flash_loan::fee_amount(&pool, 10_000) == 30);
        assert!(flash_loan::fee_amount(&pool, 1_000_000) == 3_000);
        assert!(flash_loan::fee_amount(&pool, 1_000_000_000) == 3_000_000);
        assert!(flash_loan::fee_amount(&pool, 1_000_000_000_000) == 3_000_000_000);
        test_scenario::return_shared(pool);

        coin::burn(&mut treasury_cap, coins);
        transfer::public_transfer(treasury_cap, @0x0);
        scenario.end();
    }

    // ===== Test 5: Repay Less Than Required Should Fail =====

    #[test]
    #[expected_failure(abort_code = flash_loan::ERepaymentTooLow)]
    fun test_repay_insufficient_fails() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (mut treasury_cap, coins) = init_test_coin(ctx);
        flash_loan::new_pool<LOANCOIN>(&treasury_cap, FEE_BPS, ctx);

        scenario.next_tx(@0xA);

        let deposit_coin = coin::mint<LOANCOIN>(&mut treasury_cap, 100_000_000_000, scenario.ctx());
        let mut pool = scenario.take_shared<flash_loan::FlashPool<LOANCOIN>>();
        flash_loan::deposit<LOANCOIN>(&mut pool, deposit_coin);

        let (borrowed_coin, receipt) = flash_loan::borrow<LOANCOIN>(&mut pool, 10_000_000_000, scenario.ctx());

        // Attempt to repay with ONLY the principal (no fee) -- should abort
        let excess = flash_loan::repay<LOANCOIN>(&mut pool, receipt, borrowed_coin, scenario.ctx());

        test_scenario::return_shared(pool);

        coin::burn(&mut treasury_cap, coins);
        coin::burn(&mut treasury_cap, excess);
        transfer::public_transfer(treasury_cap, @0x0);
        scenario.end();
    }

    // ===== Test 6: Admin Withdraw Fees =====

    #[test]
    fun test_admin_withdraw_fees() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (mut treasury_cap, coins) = init_test_coin(ctx);
        flash_loan::new_pool<LOANCOIN>(&treasury_cap, FEE_BPS, ctx);

        scenario.next_tx(@0xA);

        // AdminCap was transferred to @0xA
        let admin_cap = scenario.take_from_sender<flash_loan::AdminCap<LOANCOIN>>();

        // Deposit liquidity
        let deposit_coin = coin::mint<LOANCOIN>(&mut treasury_cap, 100_000_000_000, scenario.ctx());
        let mut pool = scenario.take_shared<flash_loan::FlashPool<LOANCOIN>>();
        flash_loan::deposit<LOANCOIN>(&mut pool, deposit_coin);

        // Flash loan to generate fees
        let (mut borrowed_coin, receipt) = flash_loan::borrow<LOANCOIN>(&mut pool, 10_000_000_000, scenario.ctx());
        let fee_coin = coin::mint<LOANCOIN>(&mut treasury_cap, 30_000_000, scenario.ctx());
        coin::join(&mut borrowed_coin, fee_coin);

        let excess = flash_loan::repay<LOANCOIN>(&mut pool, receipt, borrowed_coin, scenario.ctx());
        assert!(flash_loan::accumulated_fees(&pool) == 30_000_000);

        // Admin withdraws fees -- same take_shared block
        let fees = flash_loan::withdraw_fees<LOANCOIN>(&admin_cap, &mut pool, scenario.ctx());
        assert!(coin::value(&fees) == 30_000_000);
        assert!(flash_loan::accumulated_fees(&pool) == 0);

        test_scenario::return_shared(pool);

        coin::burn(&mut treasury_cap, fees);
        coin::burn(&mut treasury_cap, excess);
        coin::burn(&mut treasury_cap, coins);
        transfer::public_transfer(treasury_cap, @0x0);
        transfer::public_transfer(admin_cap, @0x0);
        scenario.end();
    }

    // ===== Test 7: Multiple Sequential Flash Loans =====

    #[test]
    fun test_multiple_flash_loans() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (mut treasury_cap, coins) = init_test_coin(ctx);
        flash_loan::new_pool<LOANCOIN>(&treasury_cap, FEE_BPS, ctx);

        scenario.next_tx(@0xA);

        let deposit_coin = coin::mint<LOANCOIN>(&mut treasury_cap, 1_000_000_000_000, scenario.ctx());
        let mut pool = scenario.take_shared<flash_loan::FlashPool<LOANCOIN>>();
        flash_loan::deposit<LOANCOIN>(&mut pool, deposit_coin);

        // Flash loan #1
        let (mut borrowed1, receipt1) = flash_loan::borrow<LOANCOIN>(&mut pool, 10_000_000_000, scenario.ctx());
        let fee1 = coin::mint<LOANCOIN>(&mut treasury_cap, 30_000_000, scenario.ctx());
        coin::join(&mut borrowed1, fee1);
        let excess1 = flash_loan::repay<LOANCOIN>(&mut pool, receipt1, borrowed1, scenario.ctx());

        // Flash loan #2
        let (mut borrowed2, receipt2) = flash_loan::borrow<LOANCOIN>(&mut pool, 50_000_000_000, scenario.ctx());
        let fee2 = coin::mint<LOANCOIN>(&mut treasury_cap, 150_000_000, scenario.ctx());
        coin::join(&mut borrowed2, fee2);
        let excess2 = flash_loan::repay<LOANCOIN>(&mut pool, receipt2, borrowed2, scenario.ctx());

        // Flash loan #3
        let (mut borrowed3, receipt3) = flash_loan::borrow<LOANCOIN>(&mut pool, 100_000_000_000, scenario.ctx());
        let fee3 = coin::mint<LOANCOIN>(&mut treasury_cap, 300_000_000, scenario.ctx());
        coin::join(&mut borrowed3, fee3);
        let excess3 = flash_loan::repay<LOANCOIN>(&mut pool, receipt3, borrowed3, scenario.ctx());

        assert!(flash_loan::total_loans(&pool) == 3);
        assert!(flash_loan::accumulated_fees(&pool) == 480_000_000);
        assert!(flash_loan::pool_balance(&pool) == 1_000_000_000_000);
        test_scenario::return_shared(pool);

        coin::burn(&mut treasury_cap, excess1);
        coin::burn(&mut treasury_cap, excess2);
        coin::burn(&mut treasury_cap, excess3);
        coin::burn(&mut treasury_cap, coins);
        transfer::public_transfer(treasury_cap, @0x0);
        scenario.end();
    }

    // ===== Test 8: Fee BPS Too High Should Fail =====

    #[test]
    #[expected_failure(abort_code = flash_loan::EFeeBpsTooHigh)]
    fun test_fee_too_high_fails() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (treasury_cap, coins) = init_test_coin(ctx);

        // Try to create pool with 20% fee (2000 bps > 1000 max)
        flash_loan::new_pool<LOANCOIN>(&treasury_cap, 2000, ctx);

        transfer::public_freeze_object(coins);
        transfer::public_transfer(treasury_cap, @0x0);
        scenario.end();
    }

    // ===== Test 9: Borrow More Than Pool Has Should Fail =====

    #[test]
    #[expected_failure(abort_code = flash_loan::EInsufficientLiquidity)]
    fun test_borrow_more_than_pool_fails() {
        let mut scenario = test_scenario::begin(@0xA);
        let ctx = scenario.ctx();

        let (mut treasury_cap, coins) = init_test_coin(ctx);
        flash_loan::new_pool<LOANCOIN>(&treasury_cap, FEE_BPS, ctx);

        scenario.next_tx(@0xA);

        let deposit_coin = coin::mint<LOANCOIN>(&mut treasury_cap, 1_000_000_000, scenario.ctx());
        let mut pool = scenario.take_shared<flash_loan::FlashPool<LOANCOIN>>();
        flash_loan::deposit<LOANCOIN>(&mut pool, deposit_coin);

        // Try to borrow 10_000 (more than pool has)
        let (borrowed, receipt) = flash_loan::borrow<LOANCOIN>(&mut pool, 10_000_000_000, scenario.ctx());

        // Consume for compilation (won't reach here)
        let excess = flash_loan::repay<LOANCOIN>(&mut pool, receipt, borrowed, scenario.ctx());
        test_scenario::return_shared(pool);

        coin::burn(&mut treasury_cap, coins);
        coin::burn(&mut treasury_cap, excess);
        transfer::public_transfer(treasury_cap, @0x0);
        scenario.end();
    }

}
