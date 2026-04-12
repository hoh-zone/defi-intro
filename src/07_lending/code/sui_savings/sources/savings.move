module sui_savings::savings {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    // Error codes
    const EInsufficientBalance: u64 = 0;
    const EUnauthorized: u64 = 1;
    const EPoolPaused: u64 = 2;
    const EInvalidAmount: u64 = 3;

    // Events
    public struct DepositEvent has copy, drop {
        amount: u64,
        shares: u64,
    }

    public struct WithdrawEvent has copy, drop {
        amount: u64,
        shares: u64,
    }

    public struct InterestAccruedEvent has copy, drop {
        interest: u64,
    }

    // Objects
    public struct SavingsPool<phantom T> has key {
        id: UID,
        principal: Balance<T>,
        reward_pool: Balance<T>,
        total_shares: u64,
        interest_rate_bps: u64,
        paused: bool,
    }

    public struct SavingsReceipt<phantom T> has key, store {
        id: UID,
        pool_id: ID,
        shares: u64,
    }

    public struct AdminCap<phantom T> has key, store {
        id: UID,
        pool_id: ID,
    }

    // One-Time Witness for module init
    public struct SAVINGS has drop {}

    // Init - creates pool and AdminCap for SUI
    fun init(witness: SAVINGS, ctx: &mut TxContext) {
        let pool = SavingsPool<SAVINGS> {
            id: object::new(ctx),
            principal: balance::zero(),
            reward_pool: balance::zero(),
            total_shares: 0,
            interest_rate_bps: 300, // 3% default
            paused: false,
        };
        let cap = AdminCap<SAVINGS> {
            id: object::new(ctx),
            pool_id: object::id(&pool),
        };
        transfer::share_object(pool);
        transfer::transfer(cap, ctx.sender());
    }

    // Deposit: converts coin to shares based on current exchange rate
    public fun deposit<T>(
        pool: &mut SavingsPool<T>,
        coin: Coin<T>,
        ctx: &mut TxContext,
    ): SavingsReceipt<T> {
        assert!(!pool.paused, EPoolPaused);
        let amount = coin::value(&coin);
        assert!(amount > 0, EInvalidAmount);

        let shares = if (pool.total_shares == 0) {
            amount
        } else {
            amount * pool.total_shares / balance::value(&pool.principal)
        };
        assert!(shares > 0, EInvalidAmount);

        pool.total_shares = pool.total_shares + shares;
        balance::join(&mut pool.principal, coin::into_balance(coin));

        sui::event::emit(DepositEvent { amount, shares });

        SavingsReceipt<T> {
            id: object::new(ctx),
            pool_id: object::id(pool),
            shares,
        }
    }

    // Withdraw: burn shares, return proportional principal
    public fun withdraw<T>(
        pool: &mut SavingsPool<T>,
        receipt: SavingsReceipt<T>,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(object::id(pool) == receipt.pool_id, EInvalidAmount);
        let principal_value = if (pool.total_shares == 0) {
            receipt.shares
        } else {
            receipt.shares * balance::value(&pool.principal) / pool.total_shares
        };
        assert!(balance::value(&pool.principal) >= principal_value, EInsufficientBalance);

        pool.total_shares = pool.total_shares - receipt.shares;

        let shares = receipt.shares;
        let SavingsReceipt { id, pool_id: _, shares: _ } = receipt;
        id.delete();

        sui::event::emit(WithdrawEvent { amount: principal_value, shares });

        coin::take(&mut pool.principal, principal_value, ctx)
    }

    // Claim interest from reward pool
    public fun claim_interest<T>(
        pool: &mut SavingsPool<T>,
        receipt: &SavingsReceipt<T>,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(pool.total_shares > 0, EInvalidAmount);
        let user_share_bps = receipt.shares * 10000 / pool.total_shares;
        let pending_reward = balance::value(&pool.reward_pool) * user_share_bps / 10000;
        assert!(pending_reward > 0, EInvalidAmount);
        coin::take(&mut pool.reward_pool, pending_reward, ctx)
    }

    // Admin: add rewards to pool
    public fun add_rewards<T>(
        _cap: &AdminCap<T>,
        pool: &mut SavingsPool<T>,
        reward: Coin<T>,
    ) {
        balance::join(&mut pool.reward_pool, coin::into_balance(reward));
    }

    // Admin: set interest rate
    public fun set_interest_rate<T>(
        _cap: &AdminCap<T>,
        pool: &mut SavingsPool<T>,
        new_rate_bps: u64,
    ) {
        pool.interest_rate_bps = new_rate_bps;
    }

    // Admin: pause/unpause
    public fun pause<T>(_cap: &AdminCap<T>, pool: &mut SavingsPool<T>) {
        pool.paused = true;
    }

    public fun unpause<T>(_cap: &AdminCap<T>, pool: &mut SavingsPool<T>) {
        pool.paused = false;
    }

    // View functions
    public fun total_shares<T>(pool: &SavingsPool<T>): u64 {
        pool.total_shares
    }

    public fun principal_balance<T>(pool: &SavingsPool<T>): u64 {
        balance::value(&pool.principal)
    }

    public fun reward_balance<T>(pool: &SavingsPool<T>): u64 {
        balance::value(&pool.reward_pool)
    }

    public fun is_paused<T>(pool: &SavingsPool<T>): bool {
        pool.paused
    }

    // Test helper: create, share pool and transfer admin cap
    #[test_only]
    public fun test_init<T>(
        interest_rate_bps: u64,
        ctx: &mut TxContext,
    ) {
        let pool = SavingsPool<T> {
            id: object::new(ctx),
            principal: balance::zero(),
            reward_pool: balance::zero(),
            total_shares: 0,
            interest_rate_bps,
            paused: false,
        };
        let cap = AdminCap<T> {
            id: object::new(ctx),
            pool_id: object::id(&pool),
        };
        transfer::share_object(pool);
        transfer::transfer(cap, ctx.sender());
    }

    // Test helper: destroy admin cap
    #[test_only]
    public fun destroy_admin_cap<T>(cap: AdminCap<T>) {
        let AdminCap { id, pool_id: _ } = cap;
        id.delete();
    }

    // Test helper: destroy receipt
    #[test_only]
    public fun destroy_receipt<T>(receipt: SavingsReceipt<T>) {
        let SavingsReceipt { id, pool_id: _, shares: _ } = receipt;
        id.delete();
    }

    // Test helper: destroy pool (must have zero balances)
    #[test_only]
    public fun destroy_pool<T>(pool: SavingsPool<T>) {
        let SavingsPool { id, principal, reward_pool, total_shares: _, interest_rate_bps: _, paused: _ } = pool;
        balance::destroy_zero(principal);
        balance::destroy_zero(reward_pool);
        id.delete();
    }
}
