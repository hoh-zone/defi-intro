#[test_only]
module attack_defense::attack_test {
    use attack_defense::unsafe_oracle;
    use attack_defense::safe_oracle;
    use sui::coin;
    use sui::tx_context;

    public struct COIN_A has copy, drop, store {}
    public struct COIN_B has copy, drop, store {}

    fun mint_a(amount: u64, ctx: &mut tx_context::TxContext): coin::Coin<COIN_A> {
        coin::mint_for_testing<COIN_A>(amount, ctx)
    }

    fun mint_b(amount: u64, ctx: &mut tx_context::TxContext): coin::Coin<COIN_B> {
        coin::mint_for_testing<COIN_B>(amount, ctx)
    }

    #[test]
    fun unsafe_price_is_spot_price() {
        let mut ctx = tx_context::dummy();
        let pool = unsafe_oracle::create_pool_for_testing<COIN_A, COIN_B>(
            mint_a(1_000_000, &mut ctx),
            mint_b(2_000_000, &mut ctx),
            &mut ctx,
        );
        // Price = reserve_b / reserve_a = 2.0
        let price = unsafe_oracle::get_price_unsafe(&pool);
        assert!(price == 2_000_000); // 2.0 * 1_000_000
        // VULNERABILITY: a large swap changes price immediately
        unsafe_oracle::destroy_pool_for_testing(pool, &mut ctx);
    }

    #[test]
    fun safe_twap_resists_manipulation() {
        let mut ctx = tx_context::dummy();

        let mut pool = safe_oracle::create_pool_for_testing<COIN_A, COIN_B>(
            mint_a(1_000_000, &mut ctx),
            mint_b(2_000_000, &mut ctx),
            &mut ctx,
        );

        // Initial TWAP at time 1000
        let twap_before = safe_oracle::get_twap_price<COIN_A, COIN_B>(&pool, 1000, 1000);
        assert!(twap_before == 2_000_000);

        // Simulate: swap at time 1001 changes spot price
        let swapped = safe_oracle::swap_safe<COIN_A, COIN_B>(
            &mut pool, mint_a(500_000, &mut ctx), 0, 1000, 5000, 1001, &mut ctx,
        );
        coin::burn_for_testing(swapped);

        // TWAP over 1000ms window still close to original
        let twap_after = safe_oracle::get_twap_price<COIN_A, COIN_B>(&pool, 1000, 1002);
        // TWAP should be between the new spot price and the original price
        assert!(twap_after >= 800_000);
        assert!(twap_after <= 2_200_000);

        // Drain pool and destroy
        safe_oracle::destroy_pool_for_testing(pool, &mut ctx);
    }

    #[test]
    fun price_deviation_check() {
        // No deviation
        assert!(safe_oracle::validate_price_deviation(100, 100, 500));
        // 5% deviation, within 10% limit
        assert!(safe_oracle::validate_price_deviation(100, 105, 1000));
        // 20% deviation, exceeds 10% limit
        assert!(!safe_oracle::validate_price_deviation(100, 120, 1000));
    }
}
