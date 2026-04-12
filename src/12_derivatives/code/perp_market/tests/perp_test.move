#[test_only]
module perp_market::test_coins {
    public struct BASE has copy, drop, store {}
    public struct QUOTE has copy, drop, store {}
}

#[test_only]
module perp_market::perp_test {
    use perp_market::perp;

    // ============================================================
    // Test: PnL calculation pure function tests
    // ============================================================
    #[test]
    fun test_pnl_calculation() {
        // Long profit: price goes from 10000 to 12000, size 10.
        // pnl = (12000 - 10000) * 10 = 20000
        let (pnl_abs, is_profit) = perp::calculate_pnl(10000, 12000, 10, true);
        assert!(pnl_abs == 20000);
        assert!(is_profit == true);

        // Long loss: price goes from 10000 to 8000, size 10.
        // pnl = (8000 - 10000) * 10 = -20000
        let (pnl_abs, is_profit) = perp::calculate_pnl(10000, 8000, 10, true);
        assert!(pnl_abs == 20000);
        assert!(is_profit == false);

        // Short profit: price goes from 10000 to 8000, size 10.
        // pnl = (10000 - 8000) * 10 = 20000
        let (pnl_abs, is_profit) = perp::calculate_pnl(10000, 8000, 10, false);
        assert!(pnl_abs == 20000);
        assert!(is_profit == true);

        // Short loss: price goes from 10000 to 12000, size 10.
        // pnl = (10000 - 12000) * 10 = -20000
        let (pnl_abs, is_profit) = perp::calculate_pnl(10000, 12000, 10, false);
        assert!(pnl_abs == 20000);
        assert!(is_profit == false);

        // Zero PnL: price unchanged.
        let (pnl_abs, is_profit) = perp::calculate_pnl(10000, 10000, 10, true);
        assert!(pnl_abs == 0);
        assert!(is_profit == true);

        // Long profit with larger size: price 10000 -> 15000, size 100.
        // pnl = (15000 - 10000) * 100 = 500000
        let (pnl_abs, is_profit) = perp::calculate_pnl(10000, 15000, 100, true);
        assert!(pnl_abs == 500000);
        assert!(is_profit == true);
    }

    // ============================================================
    // Test: Signed add unsigned helper
    // ============================================================
    #[test]
    fun test_signed_add_unsigned() {
        // Profit + margin: 2000 (profit) + 10000 = 12000
        let (result, is_pos) = perp::signed_add_unsigned(2000, true, 10000);
        assert!(result == 12000);
        assert!(is_pos == true);

        // Loss larger than margin: 15000 (loss) + 10000 = 5000 (negative)
        let (result, is_pos) = perp::signed_add_unsigned(15000, false, 10000);
        assert!(result == 5000);
        assert!(is_pos == false);

        // Loss smaller than margin: 5000 (loss) + 10000 = 5000 (positive)
        let (result, is_pos) = perp::signed_add_unsigned(5000, false, 10000);
        assert!(result == 5000);
        assert!(is_pos == true);

        // Zero PnL + margin
        let (result, is_pos) = perp::signed_add_unsigned(0, true, 10000);
        assert!(result == 10000);
        assert!(is_pos == true);

        // Exact zero: loss == margin
        let (result, is_pos) = perp::signed_add_unsigned(10000, false, 10000);
        assert!(result == 0);
        assert!(is_pos == false);
    }
}
