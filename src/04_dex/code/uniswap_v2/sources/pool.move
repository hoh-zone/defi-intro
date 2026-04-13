/// Uniswap V2 Constant-Product AMM Implementation for Sui
///
/// This module implements the core logic of a Uniswap V2-style automated
/// market maker using the constant-product invariant: x * y = k.
module uniswap_v2::pool;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;

    // ========== Error Codes ==========

    #[error]
    const EInsufficientLiquidity: vector<u8> = b"Insufficient Liquidity";
    #[error]
    const EInvalidAmount: vector<u8> = b"Invalid Amount";
    #[error]
    const EPoolPaused: vector<u8> = b"Pool Paused";
    #[error]
    const EInvalidRatio: vector<u8> = b"Invalid Ratio";
    #[error]
    const EInsufficientOutput: vector<u8> = b"Insufficient Output";
    #[error]
    const EUnauthorized: vector<u8> = b"Unauthorized";
    #[error]
    const EKLastMismatch: vector<u8> = b"K Last Mismatch";

    // ========== Structs ==========

    /// Shared pool object holding reserves for two token types.
    public struct Pool<phantom A, phantom B> has key {
        id: UID,
        /// Balance reserves for token A
        balance_a: Balance<A>,
        /// Balance reserves for token B
        balance_b: Balance<B>,
        /// Tracked reserve of token A (may lag actual balance for protocol fee)
        reserve_a: u64,
        /// Tracked reserve of token B
        reserve_b: u64,
        /// Total LP shares outstanding
        total_supply: u64,
        /// Product of reserves at last fee-mint: reserve_a * reserve_b
        k_last: u128,
        /// Swap fee in basis points (e.g. 30 = 0.3%)
        fee_bps: u64,
        /// Protocol fee fraction of swap fee in basis points (e.g. 500 = 5% of swap fee)
        protocol_fee_bps: u64,
        /// Whether the pool is paused
        paused: bool,
    }

    /// LP token representing a share of the pool.
    public struct LP<phantom A, phantom B> has key, store {
        id: UID,
        /// ID of the pool this LP token belongs to
        pool_id: ID,
        /// Number of shares represented by this LP token
        shares: u64,
    }

    /// Admin capability for managing protocol fee parameters.
    public struct AdminCap has key, store {
        id: UID,
        /// ID of the pool this admin cap controls
        pool_id: ID,
    }

    // ========== Pool Creation ==========

    /// Create a new trading pool for token pair (A, B).
    /// The creator receives an `AdminCap` for protocol fee management.
    public fun create_pool<A, B>(
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        fee_bps: u64,
        ctx: &mut TxContext,
    ) {
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, EInvalidAmount);
        assert!(fee_bps <= 1000, EInvalidAmount); // max 10% fee

        let pool_id = object::new(ctx);
        let pool = Pool<A, B> {
            id: pool_id,
            balance_a: coin::into_balance(coin_a),
            balance_b: coin::into_balance(coin_b),
            reserve_a: amount_a,
            reserve_b: amount_b,
            total_supply: 0,
            k_last: (amount_a as u128) * (amount_b as u128),
            fee_bps,
            protocol_fee_bps: 500, // default: 5% of swap fee goes to protocol
            paused: false,
        };

        let admin_cap = AdminCap {
            id: object::new(ctx),
            pool_id: object::id(&pool),
        };

        transfer::share_object(pool);
        transfer::transfer(admin_cap, ctx.sender());
    }

    // ========== Liquidity Provision ==========

    /// Add liquidity to the pool. The first LP receives sqrt(a*b) shares.
    /// Subsequent LPs receive min(shares_a, shares_b) shares.
    /// Slippage protection via `min_lp` parameter.
    public fun add_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        min_lp: u64,
        ctx: &mut TxContext,
    ) {
        assert!(!pool.paused, EPoolPaused);

        // Mint protocol fee based on k growth since last mint
        mint_protocol_fee(pool);

        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        assert!(amount_a > 0 && amount_b > 0, EInvalidAmount);

        let shares = if (pool.total_supply == 0) {
            // First LP: geometric mean = sqrt(a * b)
            let product = (amount_a as u128) * (amount_b as u128);
            (sqrt(product) as u64)
        } else {
            // Subsequent LPs: min of proportional shares
            let shares_a = ((amount_a as u128) * (pool.total_supply as u128)
                / (pool.reserve_a as u128)) as u64;
            let shares_b = ((amount_b as u128) * (pool.total_supply as u128)
                / (pool.reserve_b as u128)) as u64;
            let min_shares = if (shares_a < shares_b) { shares_a } else { shares_b };
            assert!(min_shares > 0, EInvalidRatio);
            min_shares
        };

        assert!(shares >= min_lp, EInsufficientOutput);

        // Update pool state
        pool.reserve_a = pool.reserve_a + amount_a;
        pool.reserve_b = pool.reserve_b + amount_b;
        pool.total_supply = pool.total_supply + shares;
        pool.k_last = (pool.reserve_a as u128) * (pool.reserve_b as u128);

        // Deposit balances
        balance::join(&mut pool.balance_a, coin::into_balance(coin_a));
        balance::join(&mut pool.balance_b, coin::into_balance(coin_b));

        // Mint LP token to sender
        let lp = LP<A, B> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            shares,
        };
        transfer::transfer(lp, ctx.sender());
    }

    /// Remove liquidity from the pool. Burns the LP token and returns
    /// proportional amounts of both tokens. Slippage protection via
    /// `min_a` and `min_b` parameters.
    public fun remove_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        lp: LP<A, B>,
        min_a: u64,
        min_b: u64,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        assert!(!pool.paused, EPoolPaused);
        assert!(object::id(pool) == lp.pool_id, EUnauthorized);

        // Mint protocol fee before withdrawal
        mint_protocol_fee(pool);

        let shares = lp.shares;
        assert!(shares > 0, EInsufficientLiquidity);
        assert!(pool.total_supply > 0, EInsufficientLiquidity);

        // Proportional withdrawal
        let amount_a = ((shares as u128) * (pool.reserve_a as u128)
            / (pool.total_supply as u128)) as u64;
        let amount_b = ((shares as u128) * (pool.reserve_b as u128)
            / (pool.total_supply as u128)) as u64;

        assert!(amount_a >= min_a, EInsufficientOutput);
        assert!(amount_b >= min_b, EInsufficientOutput);
        assert!(amount_a <= pool.reserve_a, EInsufficientLiquidity);
        assert!(amount_b <= pool.reserve_b, EInsufficientLiquidity);

        // Update pool state
        pool.reserve_a = pool.reserve_a - amount_a;
        pool.reserve_b = pool.reserve_b - amount_b;
        pool.total_supply = pool.total_supply - shares;
        pool.k_last = (pool.reserve_a as u128) * (pool.reserve_b as u128);

        // Withdraw balances
        let coin_a = coin::take(&mut pool.balance_a, amount_a, ctx);
        let coin_b = coin::take(&mut pool.balance_b, amount_b, ctx);

        // Burn LP token
        let LP { id, pool_id: _, shares: _ } = lp;
        id.delete();

        (coin_a, coin_b)
    }

    // ========== Swaps ==========

    /// Swap token A for token B using the constant-product formula.
    /// The caller receives output coins; input coins are deposited into the pool.
    /// Slippage protection via `min_output`.
    public fun swap_a_to_b<A, B>(
        pool: &mut Pool<A, B>,
        input: Coin<A>,
        min_output: u64,
        ctx: &mut TxContext,
    ): Coin<B> {
        assert!(!pool.paused, EPoolPaused);

        let amount_in = coin::value(&input);
        assert!(amount_in > 0, EInvalidAmount);

        let output_amount = amount_out(
            amount_in,
            pool.reserve_a,
            pool.reserve_b,
            pool.fee_bps,
        );
        assert!(output_amount >= min_output, EInsufficientOutput);
        assert!(output_amount <= pool.reserve_b, EInsufficientLiquidity);

        // Update reserves
        pool.reserve_a = pool.reserve_a + amount_in;
        pool.reserve_b = pool.reserve_b - output_amount;

        // Deposit input, withdraw output
        balance::join(&mut pool.balance_a, coin::into_balance(input));
        let output = coin::take(&mut pool.balance_b, output_amount, ctx);

        output
    }

    /// Swap token B for token A using the constant-product formula.
    public fun swap_b_to_a<A, B>(
        pool: &mut Pool<A, B>,
        input: Coin<B>,
        min_output: u64,
        ctx: &mut TxContext,
    ): Coin<A> {
        assert!(!pool.paused, EPoolPaused);

        let amount_in = coin::value(&input);
        assert!(amount_in > 0, EInvalidAmount);

        let output_amount = amount_out(
            amount_in,
            pool.reserve_b,
            pool.reserve_a,
            pool.fee_bps,
        );
        assert!(output_amount >= min_output, EInsufficientOutput);
        assert!(output_amount <= pool.reserve_a, EInsufficientLiquidity);

        // Update reserves
        pool.reserve_b = pool.reserve_b + amount_in;
        pool.reserve_a = pool.reserve_a - output_amount;

        // Deposit input, withdraw output
        balance::join(&mut pool.balance_b, coin::into_balance(input));
        let output = coin::take(&mut pool.balance_a, output_amount, ctx);

        output
    }

    // ========== View / Pure Functions ==========

    /// Calculate the output amount for a swap given input amount and reserves.
    /// Formula: output = (amount_in * (10000 - fee_bps) * reserve_out) / (reserve_in * 10000 + amount_in * (10000 - fee_bps))
    public fun amount_out(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        fee_bps: u64,
    ): u64 {
        assert!(amount_in > 0, EInvalidAmount);
        assert!(reserve_in > 0 && reserve_out > 0, EInsufficientLiquidity);

        let amount_in_128 = amount_in as u128;
        let reserve_in_128 = reserve_in as u128;
        let reserve_out_128 = reserve_out as u128;
        let fee_bps_128 = fee_bps as u128;

        // Apply fee: amount_in * (10000 - fee_bps) / 10000
        let amount_in_with_fee = amount_in_128 * (10000 - fee_bps_128);
        let numerator = amount_in_with_fee * reserve_out_128;
        let denominator = reserve_in_128 * 10000 + amount_in_with_fee;

        ((numerator / denominator) as u64)
    }

    /// Given an amount of A and the reserves, calculate the equivalent amount of B.
    public fun quote(amount_a: u64, reserve_a: u64, reserve_b: u64): u64 {
        assert!(amount_a > 0, EInvalidAmount);
        assert!(reserve_a > 0 && reserve_b > 0, EInsufficientLiquidity);

        (((amount_a as u128) * (reserve_b as u128) / (reserve_a as u128)) as u64)
    }

    /// Get the number of shares in an LP token.
    public fun lp_shares<A, B>(lp: &LP<A, B>): u64 {
        lp.shares
    }

    /// Get the current price of A in terms of B (reserve_b / reserve_a).
    public fun price<A, B>(pool: &Pool<A, B>): u64 {
        assert!(pool.reserve_a > 0, EInsufficientLiquidity);
        ((pool.reserve_b as u128) * 1000000 / (pool.reserve_a as u128)) as u64
    }

    /// Calculate the integer square root of a u128 using Newton's method.
    public fun sqrt(n: u128): u128 {
        if (n == 0) { return 0 };
        if (n == 1) { return 1 };

        let mut x = n;
        let mut y = (x + 1) / 2;

        while (y < x) {
            x = y;
            y = (x + n / x) / 2;
        };

        x
    }

    // ========== Internal: Protocol Fee ==========

    /// Mint LP shares to the pool itself as protocol fee, based on growth
    /// of the constant product k since the last mint.
    fun mint_protocol_fee<A, B>(pool: &mut Pool<A, B>) {
        if (pool.k_last == 0 || pool.total_supply == 0) {
            return
        };

        let k_current = (pool.reserve_a as u128) * (pool.reserve_b as u128);
        if (k_current <= pool.k_last) {
            return
        };

        // Sanity check: k_last should always be <= k_current
        assert!(pool.k_last <= k_current, EKLastMismatch);

        // Protocol fee: fraction of the growth in k
        // fee_shares = total_supply * (sqrt(k_current/k_last) - 1) * protocol_fee_bps / 10000
        let root_k_current = sqrt(k_current);
        let root_k_last = sqrt(pool.k_last);
        if (root_k_current <= root_k_last) {
            return
        };

        let numerator = (pool.total_supply as u128) * (root_k_current - root_k_last)
            * (pool.protocol_fee_bps as u128);
        let denominator = root_k_current * (10000 - (pool.protocol_fee_bps as u128));

        if (denominator == 0) {
            return
        };

        let fee_shares = (numerator / denominator) as u64;
        if (fee_shares > 0) {
            pool.total_supply = pool.total_supply + fee_shares;
            // The fee shares stay in the pool (no transfer needed);
            // they dilute all LP holders proportionally.
        };
    }

    // ========== Admin Functions ==========

    /// Set the protocol fee basis points. Only the holder of the AdminCap
    /// can call this (enforced by requiring the cap as a witness).
    public fun set_protocol_fee<A, B>(
        _cap: &AdminCap,
        pool: &mut Pool<A, B>,
        protocol_fee_bps: u64,
    ) {
        assert!(protocol_fee_bps <= 10000, EInvalidAmount);
        pool.protocol_fee_bps = protocol_fee_bps;
    }

    /// Pause or unpause the pool.
    public fun set_paused<A, B>(
        _cap: &AdminCap,
        pool: &mut Pool<A, B>,
        paused: bool,
    ) {
        pool.paused = paused;
    }
