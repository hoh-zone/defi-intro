/// Module: reward_accumulator::accumulator
///
/// A reward accumulator (liquidity mining) implementation.
///
/// Key concepts:
/// - Users stake a `StakeCoin` and earn `RewardCoin` over time.
/// - Rewards are distributed proportionally based on each user's share of the
///   total staked amount.
/// - An "accumulator" pattern tracks `acc_reward_per_share` so that pending
///   rewards can be computed on-demand without iterating over every user.
module reward_accumulator::accumulator;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::bag::{Self, Bag};
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::event;

    // ======= Constants =======

    /// Precision factor for reward math (1e9) to avoid integer truncation.
    const PRECISION: u64 = 1_000_000_000;

    // ======= Error Codes =======

    #[error]
    const ENotPoolOwner: vector<u8> = b"Not Pool Owner";
    #[error]
    const EInsufficientStake: vector<u8> = b"Insufficient Stake";
    #[error]
    const ENoStakeFound: vector<u8> = b"No Stake Found";
    #[error]
    const EZeroAmount: vector<u8> = b"Zero Amount";
    #[error]
    const EZeroDuration: vector<u8> = b"Zero Duration";
    #[error]
    const EPoolExpired: vector<u8> = b"Pool Expired";

    // ======= Structs =======

    /// Shared object that holds all pool state. Parameterised by the stake
    /// coin type and the reward coin type so that multiple pools can coexist.
    public struct RewardPool<phantom StakeCoin, phantom RewardCoin> has key {
        id: UID,
        /// Total amount of `StakeCoin` currently staked.
        total_stake: u64,
        /// Accumulated reward per full share, scaled by PRECISION.
        acc_reward_per_share: u64,
        /// Reward amount (in RewardCoin units) emitted per millisecond.
        reward_rate_per_ms: u64,
        /// Millisecond timestamp of the last reward update.
        last_update_ms: u64,
        /// Millisecond timestamp when the pool stops emitting rewards.
        end_ms: u64,
        /// Remaining reward tokens that have not yet been distributed.
        remaining_reward: Balance<RewardCoin>,
        /// Bag mapping `address -> UserStake`.
        stakes: Bag,
    }

    /// Per-user stake information stored inside the pool's Bag.
    public struct UserStake has store {
        amount: u64,
        /// Tracks how much reward has already been accounted for:
        /// `reward_debt = amount * acc_reward_per_share / PRECISION` at the
        /// time of the user's last interaction.
        reward_debt: u64,
    }

    // ======= Creation =======

    /// Create a new reward pool and share it as a shared object.
    ///
    /// `reward_coin`  -- the total reward tokens to distribute.
    /// `duration_ms`  -- distribution window in milliseconds.
    /// `current_ms`   -- current timestamp (from `clock.timestamp_ms()`).
    entry fun create_pool<StakeCoin, RewardCoin>(
        reward_coin: Coin<RewardCoin>,
        duration_ms: u64,
        current_ms: u64,
        ctx: &mut TxContext,
    ) {
        assert!(duration_ms > 0, EZeroDuration);

        let reward_value = coin::value(&reward_coin);
        assert!(reward_value > 0, EZeroAmount);

        let reward_rate_per_ms = reward_value / duration_ms;
        let end_ms = current_ms + duration_ms;

        let pool = RewardPool<StakeCoin, RewardCoin> {
            id: object::new(ctx),
            total_stake: 0,
            acc_reward_per_share: 0,
            reward_rate_per_ms,
            last_update_ms: current_ms,
            end_ms,
            remaining_reward: coin::into_balance(reward_coin),
            stakes: bag::new(ctx),
        };

        transfer::share_object(pool);
    }

    // ======= Internal: update_reward =======

    /// Update the global accumulator `acc_reward_per_share`.
    ///
    /// This is the core of the accumulator pattern:
    ///   acc_reward_per_share += reward_rate_per_ms * elapsed * PRECISION / total_stake
    ///
    /// Called at the start of every mutating operation (stake, unstake, claim).
    fun update_reward<StakeCoin, RewardCoin>(
        pool: &mut RewardPool<StakeCoin, RewardCoin>,
        current_ms: u64,
    ) {
        // No-op if nobody is staking.
        if (pool.total_stake == 0) {
            pool.last_update_ms = current_ms;
            return;
        };

        // Compute elapsed time, clamped to the pool's end.
        let effective_ms = if (current_ms < pool.end_ms) {
            current_ms
        } else {
            pool.end_ms
        };

        let elapsed = if (effective_ms > pool.last_update_ms) {
            effective_ms - pool.last_update_ms
        } else {
            0
        };

        if (elapsed == 0) {
            return;
        };

        // reward = reward_rate_per_ms * elapsed
        let mut reward = pool.reward_rate_per_ms * elapsed;

        // Only accumulate what we actually have left.
        let remaining = balance::value(&pool.remaining_reward);
        if (reward > remaining) {
            reward = remaining;
        };

        // acc_reward_per_share += reward * PRECISION / total_stake
        pool.acc_reward_per_share = pool.acc_reward_per_share
            + (reward * PRECISION / pool.total_stake);

        pool.last_update_ms = effective_ms;
    }

    // ======= Mutating operations =======

    /// Stake `coin` into the pool on behalf of `user_addr`.
    entry fun stake<StakeCoin, RewardCoin>(
        pool: &mut RewardPool<StakeCoin, RewardCoin>,
        coin: Coin<StakeCoin>,
        user_addr: address,
        current_ms: u64,
    ) {
        let amount = coin::value(&coin);
        assert!(amount > 0, EZeroAmount);

        // 1. Update global accumulator.
        update_reward(pool, current_ms);

        // 2. Merge the new coins into the pool-level stake balance.
        //    Stored in the Bag under a well-known key.
        let pool_key = b"pool_stake_funds";
        if (!bag::contains_with_type<vector<u8>, Balance<StakeCoin>>(&pool.stakes, pool_key)) {
            bag::add<vector<u8>, Balance<StakeCoin>>(
                &mut pool.stakes,
                pool_key,
                coin::into_balance(coin),
            );
        } else {
            let pool_bal: &mut Balance<StakeCoin> = bag::borrow_mut<vector<u8>, Balance<StakeCoin>>(
                &mut pool.stakes,
                pool_key,
            );
            balance::join(pool_bal, coin::into_balance(coin));
        };

        // 3. Update user stake.
        if (bag::contains(&pool.stakes, user_addr)) {
            let user_stake: &mut UserStake = bag::borrow_mut(
                &mut pool.stakes,
                user_addr,
            );
            user_stake.reward_debt = user_stake.amount * pool.acc_reward_per_share / PRECISION;
            user_stake.amount = user_stake.amount + amount;
        } else {
            let user_stake = UserStake {
                amount,
                reward_debt: amount * pool.acc_reward_per_share / PRECISION,
            };
            bag::add(&mut pool.stakes, user_addr, user_stake);
        };

        pool.total_stake = pool.total_stake + amount;

        event::emit(StakeEvent<StakeCoin, RewardCoin> {
            user: user_addr,
            amount,
        });
    }

    /// Unstake `amount` tokens and return them to the caller.
    entry fun unstake<StakeCoin, RewardCoin>(
        pool: &mut RewardPool<StakeCoin, RewardCoin>,
        amount: u64,
        user_addr: address,
        current_ms: u64,
        ctx: &mut TxContext,
    ) {
        assert!(amount > 0, EZeroAmount);
        assert!(
            bag::contains(&pool.stakes, user_addr),
            ENoStakeFound,
        );

        // 1. Update global accumulator.
        update_reward(pool, current_ms);

        // 2. Read and update user stake.
        let user_stake: &mut UserStake = bag::borrow_mut(
            &mut pool.stakes,
            user_addr,
        );
        assert!(user_stake.amount >= amount, EInsufficientStake);

        user_stake.amount = user_stake.amount - amount;
        user_stake.reward_debt = user_stake.amount * pool.acc_reward_per_share / PRECISION;

        pool.total_stake = pool.total_stake - amount;

        // If user has no more stake, remove the entry to keep the Bag clean.
        if (user_stake.amount == 0) {
            let removed: UserStake = bag::remove(&mut pool.stakes, user_addr);
            let UserStake { amount: _, reward_debt: _ } = removed;
        };

        // 3. Withdraw staked coins from the pool balance.
        let pool_key = b"pool_stake_funds";
        let pool_bal: &mut Balance<StakeCoin> = bag::borrow_mut<vector<u8>, Balance<StakeCoin>>(
            &mut pool.stakes,
            pool_key,
        );
        let withdraw_bal = balance::split(pool_bal, amount);
        let withdraw_coin = coin::from_balance(withdraw_bal, ctx);

        transfer::public_transfer(withdraw_coin, user_addr);

        event::emit(UnstakeEvent<StakeCoin, RewardCoin> {
            user: user_addr,
            amount,
        });
    }

    /// Claim all pending rewards for `user_addr`.
    public entry fun claim<StakeCoin, RewardCoin>(
        pool: &mut RewardPool<StakeCoin, RewardCoin>,
        user_addr: address,
        current_ms: u64,
        ctx: &mut TxContext,
    ) {
        // 1. Update global accumulator.
        update_reward(pool, current_ms);

        // 2. Calculate pending reward.
        assert!(
            bag::contains(&pool.stakes, user_addr),
            ENoStakeFound,
        );

        let user_stake: &mut UserStake = bag::borrow_mut(
            &mut pool.stakes,
            user_addr,
        );

        let pending = user_stake.amount * pool.acc_reward_per_share / PRECISION
            - user_stake.reward_debt;

        // Reset reward debt.
        user_stake.reward_debt = user_stake.amount * pool.acc_reward_per_share / PRECISION;

        // 3. Transfer reward.
        if (pending > 0) {
            let reward_bal = balance::split(&mut pool.remaining_reward, pending);
            let reward_coin = coin::from_balance(reward_bal, ctx);
            transfer::public_transfer(reward_coin, user_addr);
        };

        event::emit(ClaimEvent<StakeCoin, RewardCoin> {
            user: user_addr,
            amount: pending,
        });
    }

    // ======= View functions =======

    /// Returns the pending reward for `user_addr` without mutating state.
    public fun pending_reward<StakeCoin, RewardCoin>(
        pool: &RewardPool<StakeCoin, RewardCoin>,
        user_addr: address,
        current_ms: u64,
    ): u64 {
        if (pool.total_stake == 0) {
            return 0
        };

        // Compute what acc_reward_per_share would be after an update.
        let effective_ms = if (current_ms < pool.end_ms) {
            current_ms
        } else {
            pool.end_ms
        };

        let elapsed = if (effective_ms > pool.last_update_ms) {
            effective_ms - pool.last_update_ms
        } else {
            0
        };

        let mut acc = pool.acc_reward_per_share;
        if (elapsed > 0) {
            let mut reward = pool.reward_rate_per_ms * elapsed;
            let remaining = balance::value(&pool.remaining_reward);
            if (reward > remaining) {
                reward = remaining;
            };
            acc = acc + (reward * PRECISION / pool.total_stake);
        };

        if (!bag::contains(&pool.stakes, user_addr)) {
            return 0
        };

        let user_stake: &UserStake = bag::borrow(&pool.stakes, user_addr);
        let pending = user_stake.amount * acc / PRECISION - user_stake.reward_debt;

        pending
    }

    /// Returns key pool information.
    public fun pool_info<StakeCoin, RewardCoin>(
        pool: &RewardPool<StakeCoin, RewardCoin>,
    ): (u64, u64, u64, u64, u64) {
        (
            pool.total_stake,
            pool.reward_rate_per_ms,
            pool.last_update_ms,
            pool.end_ms,
            balance::value(&pool.remaining_reward),
        )
    }

    /// Returns the stake info for a user.
    public fun user_stake_info<StakeCoin, RewardCoin>(
        pool: &RewardPool<StakeCoin, RewardCoin>,
        user_addr: address,
    ): (u64, u64) {
        if (!bag::contains(&pool.stakes, user_addr)) {
            return (0, 0)
        };
        let user_stake: &UserStake = bag::borrow(&pool.stakes, user_addr);
        (user_stake.amount, user_stake.reward_debt)
    }

    // ======= Events =======

    public struct StakeEvent<phantom StakeCoin, phantom RewardCoin> has copy, drop {
        user: address,
        amount: u64,
    }

    public struct UnstakeEvent<phantom StakeCoin, phantom RewardCoin> has copy, drop {
        user: address,
        amount: u64,
    }

    public struct ClaimEvent<phantom StakeCoin, phantom RewardCoin> has copy, drop {
        user: address,
        amount: u64,
    }

    // ======= Test helpers =======

    #[test_only]
    public fun destroy_pool<StakeCoin, RewardCoin>(
        pool: RewardPool<StakeCoin, RewardCoin>,
    ) {
        let RewardPool {
            id,
            total_stake: _,
            acc_reward_per_share: _,
            reward_rate_per_ms: _,
            last_update_ms: _,
            end_ms: _,
            remaining_reward,
            mut stakes,
        } = pool;

        remaining_reward.destroy_for_testing();
        // Drain any remaining entries from the bag before destroying it.
        // After full unstaking the pool_stake_funds Balance may still be present
        // (with zero value), so we remove it explicitly.
        let pool_key = b"pool_stake_funds";
        if (bag::contains_with_type<vector<u8>, Balance<StakeCoin>>(&stakes, pool_key)) {
            let pool_bal: Balance<StakeCoin> = bag::remove<vector<u8>, Balance<StakeCoin>>(
                &mut stakes,
                pool_key,
            );
            pool_bal.destroy_for_testing();
        };
        bag::destroy_empty(stakes);
        id.delete();
    }
