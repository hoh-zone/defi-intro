/// Liquid Staking Token (LST) — Non-rebasing approach
///
/// Exchange rate increases over time as rewards accumulate:
///   exchange_rate = total_sui / total_lst_minted
///   Staking:  lst_amount  = sui_amount * total_lst / total_sui  (1:1 if first)
///   Unstaking: sui_amount = lst_amount * total_sui / total_lst
///
/// As rewards are added, total_sui grows while total_lst stays same → rate increases.

module liquid_staking::liquid_staking;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::object::{Self, UID};
    use sui::event;
    use sui::dynamic_field;
    use sui::url::{Self, Url};
    use std::option;

    const PRECISION: u64 = 1_000_000_000;

    #[error]
    const EPoolPaused: vector<u8> = b"Pool Paused";
    #[error]
    const EPoolNotPaused: vector<u8> = b"Pool Not Paused";
    #[error]
    const EInsufficientPoolBalance: vector<u8> = b"Insufficient Pool Balance";
    #[error]
    const EStakeAmountZero: vector<u8> = b"Stake Amount Zero";
    #[error]
    const EUnstakeAmountZero: vector<u8> = b"Unstake Amount Zero";

    public struct LIQUID_STAKING has drop {}

    public struct StakingPool has key, store {
        id: UID,
        total_sui: Balance<SUI>,
        total_lst_minted: u64,
        reward_rate_per_epoch: u64,
        paused: bool,
    }

    public struct AdminCap has key, store {
        id: UID,
    }

    public struct Staked has copy, drop { user: address, sui_amount: u64, lst_amount: u64 }
    public struct Unstaked has copy, drop { user: address, lst_amount: u64, sui_amount: u64 }
    public struct RewardsAdded has copy, drop { amount: u64 }

    // Wrapper structs for storing TreasuryCap as a dynamic field
    public struct TreasuryHolder has store { cap: TreasuryCap<LIQUID_STAKING> }
    public struct TreasuryKey has copy, drop, store {}

    fun init(witness: LIQUID_STAKING, ctx: &mut TxContext) {
        let (treasury_cap, coin_metadata) = coin::create_currency<LIQUID_STAKING>(
            witness, 9, b"LST", b"Liquid Staked SUI",
            b"LST representing staked SUI with accrued rewards",
            option::none<Url>(), ctx,
        );

        let mut pool = StakingPool {
            id: object::new(ctx),
            total_sui: balance::zero(),
            total_lst_minted: 0,
            reward_rate_per_epoch: 0,
            paused: false,
        };

        // Store TreasuryCap as dynamic field on the pool
        dynamic_field::add(&mut pool.id, TreasuryKey {}, TreasuryHolder { cap: treasury_cap });

        transfer::public_transfer(coin_metadata, ctx.sender());
        transfer::public_share_object(pool);
        transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
    }

    // === Test Helpers ===

    /// Create a StakingPool for testing with a TreasuryCap stored as a dynamic field.
    /// The pool is shared and the AdminCap is transferred to the sender.
    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext) {
        let treasury_cap = coin::create_treasury_cap_for_testing<LIQUID_STAKING>(ctx);

        let mut pool = StakingPool {
            id: object::new(ctx),
            total_sui: balance::zero(),
            total_lst_minted: 0,
            reward_rate_per_epoch: 0,
            paused: false,
        };

        // Store TreasuryCap as dynamic field on the pool
        dynamic_field::add(&mut pool.id, TreasuryKey {}, TreasuryHolder { cap: treasury_cap });

        transfer::public_share_object(pool);
        transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
    }

    // Borrow TreasuryCap from pool's dynamic field
    fun borrow_treasury(pool: &mut StakingPool): &mut TreasuryCap<LIQUID_STAKING> {
        let holder: &mut TreasuryHolder = dynamic_field::borrow_mut(
            &mut pool.id, TreasuryKey {},
        );
        &mut holder.cap
    }

    /// Calculate exchange rate: total_sui * PRECISION / total_lst
    fun calculate_exchange_rate(pool: &StakingPool): u64 {
        if (pool.total_lst_minted == 0) { return PRECISION };
        ((balance::value(&pool.total_sui) as u128) * (PRECISION as u128) / (pool.total_lst_minted as u128)) as u64
    }

    /// Stake SUI → receive LST
    public fun stake(pool: &mut StakingPool, sui_coin: Coin<SUI>, ctx: &mut TxContext): Coin<LIQUID_STAKING> {
        assert!(!pool.paused, EPoolPaused);
        let sui_amount = coin::value(&sui_coin);
        assert!(sui_amount > 0, EStakeAmountZero);

        let lst_amount = if (pool.total_lst_minted == 0) {
            sui_amount // first staker: 1:1
        } else {
            ((sui_amount as u128) * (pool.total_lst_minted as u128) / (balance::value(&pool.total_sui) as u128)) as u64
        };

        balance::join(&mut pool.total_sui, coin::into_balance(sui_coin));
        pool.total_lst_minted = pool.total_lst_minted + lst_amount;

        let lst = coin::mint(borrow_treasury(pool), lst_amount, ctx);

        event::emit(Staked { user: ctx.sender(), sui_amount, lst_amount });
        lst
    }

    /// Unstake LST → receive SUI (more than originally staked after rewards)
    public fun unstake(pool: &mut StakingPool, lst_coin: Coin<LIQUID_STAKING>, ctx: &mut TxContext): Coin<SUI> {
        let lst_amount = coin::value(&lst_coin);
        assert!(lst_amount > 0, EUnstakeAmountZero);
        assert!(pool.total_lst_minted > 0, EUnstakeAmountZero);

        let total_sui_value = balance::value(&pool.total_sui);
        let sui_amount = ((lst_amount as u128) * (total_sui_value as u128) / (pool.total_lst_minted as u128)) as u64;
        assert!(sui_amount <= total_sui_value, EInsufficientPoolBalance);

        pool.total_lst_minted = pool.total_lst_minted - lst_amount;
        coin::burn(borrow_treasury(pool), lst_coin);
        let sui_coin = coin::take(&mut pool.total_sui, sui_amount, ctx);

        event::emit(Unstaked { user: ctx.sender(), lst_amount, sui_amount });
        sui_coin
    }

    // === View Functions ===

    public fun exchange_rate(pool: &StakingPool): u64 { calculate_exchange_rate(pool) }

    public fun preview_stake(pool: &StakingPool, sui_amount: u64): u64 {
        if (pool.total_lst_minted == 0) { return sui_amount };
        let total_sui = balance::value(&pool.total_sui);
        if (total_sui == 0) { return 0 };
        ((sui_amount as u128) * (pool.total_lst_minted as u128) / (total_sui as u128)) as u64
    }

    public fun preview_unstake(pool: &StakingPool, lst_amount: u64): u64 {
        if (pool.total_lst_minted == 0) { return 0 };
        ((lst_amount as u128) * (balance::value(&pool.total_sui) as u128) / (pool.total_lst_minted as u128)) as u64
    }

    public fun total_staked_sui(pool: &StakingPool): u64 { balance::value(&pool.total_sui) }
    public fun total_lst_supply(pool: &StakingPool): u64 { pool.total_lst_minted }
    public fun is_paused(pool: &StakingPool): bool { pool.paused }

    // === Admin Functions ===

    /// Add rewards — increases exchange rate by adding SUI without minting LST
    public fun add_rewards(_cap: &AdminCap, pool: &mut StakingPool, reward: Coin<SUI>) {
        let amount = coin::value(&reward);
        balance::join(&mut pool.total_sui, coin::into_balance(reward));
        event::emit(RewardsAdded { amount });
    }

    public fun set_reward_rate(_cap: &AdminCap, pool: &mut StakingPool, rate: u64) {
        pool.reward_rate_per_epoch = rate;
    }

    public fun pause(_cap: &AdminCap, pool: &mut StakingPool) {
        assert!(!pool.paused, EPoolNotPaused);
        pool.paused = true;
    }

    public fun unpause(_cap: &AdminCap, pool: &mut StakingPool) {
        assert!(pool.paused, EPoolPaused);
        pool.paused = false;
    }
