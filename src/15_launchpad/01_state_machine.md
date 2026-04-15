# 15.1 代币发售的状态机设计

## 五个状态

```
Draft → WhitelistOpen → SaleOpen → ClaimOpen → Closed
                              ↓
                          Cancelled
```

| 状态          | 允许的操作     |
| ------------- | -------------- |
| Draft         | 管理员配置参数 |
| WhitelistOpen | 用户注册白名单 |
| SaleOpen      | 白名单用户认购 |
| ClaimOpen     | 用户领取代币   |
| Closed        | 无操作         |
| Cancelled     | 退款           |

## Move 实现

```move
module launchpad;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    #[error]
    const EInvalidState: vector<u8> = b"Invalid State";
    #[error]
    const ENotWhitelisted: vector<u8> = b"Not Whitelisted";
    #[error]
    const EExceedsAllocation: vector<u8> = b"Exceeds Allocation";
    #[error]
    const ESaleNotEnded: vector<u8> = b"Sale Not Ended";
    #[error]
    const ENothingToClaim: vector<u8> = b"Nothing To Claim";
    #[error]
    const EUnauthorized: vector<u8> = b"Unauthorized";
    #[error]
    const EAlreadyWhitelisted: vector<u8> = b"Already Whitelisted";

    const STATE_DRAFT: u8 = 0;
    const STATE_WHITELIST_OPEN: u8 = 1;
    const STATE_SALE_OPEN: u8 = 2;
    const STATE_CLAIM_OPEN: u8 = 3;
    const STATE_CLOSED: u8 = 4;
    const STATE_CANCELLED: u8 = 5;

    public struct LaunchpadRound has key {
        id: UID,
        state: u8,
        token_price: u64,
        total_supply: u64,
        sold_amount: u64,
        min_allocation: u64,
        max_allocation: u64,
        sale_start_time: u64,
        sale_end_time: u64,
        claim_start_time: u64,
        vesting_duration_ms: u64,
        cliff_duration_ms: u64,
        paused: bool,
    }

    public struct Whitelist has key {
        id: UID,
        round_id: ID,
        entries: vector<address>,
        allocations: vector<u64>,
    }

    public struct Subscription has key, store {
        id: UID,
        round_id: ID,
        buyer: address,
        amount: u64,
        claimed: u64,
    }

    public struct AdminCap has key, store {
        id: UID,
        round_id: ID,
    }

    public fun init(
        token_price: u64,
        total_supply: u64,
        min_allocation: u64,
        max_allocation: u64,
        ctx: &mut TxContext,
    ) {
        let round = LaunchpadRound {
            id: object::new(ctx),
            state: STATE_DRAFT,
            token_price,
            total_supply,
            sold_amount: 0,
            min_allocation,
            max_allocation,
            sale_start_time: 0,
            sale_end_time: 0,
            claim_start_time: 0,
            vesting_duration_ms: 0,
            cliff_duration_ms: 0,
            paused: false,
        };
        let whitelist = Whitelist {
            id: object::new(ctx),
            round_id: object::id(&round),
            entries: vector::empty(),
            allocations: vector::empty(),
        };
        let cap = AdminCap {
            id: object::new(ctx),
            round_id: object::id(&round),
        };
        transfer::share_object(round);
        transfer::share_object(whitelist);
        transfer::transfer(cap, ctx.sender());
    }

    public fun start_whitelist(
        _cap: &AdminCap,
        round: &mut LaunchpadRound,
    ) {
        assert!(round.state == STATE_DRAFT, EInvalidState);
        round.state = STATE_WHITELIST_OPEN;
    }

    public fun add_to_whitelist(
        _cap: &AdminCap,
        whitelist: &mut Whitelist,
        addr: address,
        allocation: u64,
    ) {
        assert!(!is_whitelisted(whitelist, addr), EAlreadyWhitelisted);
        vector::push_back(&mut whitelist.entries, addr);
        vector::push_back(&mut whitelist.allocations, allocation);
    }

    public fun start_sale(
        _cap: &AdminCap,
        round: &mut LaunchpadRound,
        start_time: u64,
        end_time: u64,
    ) {
        assert!(round.state == STATE_WHITELIST_OPEN, EInvalidState);
        round.state = STATE_SALE_OPEN;
        round.sale_start_time = start_time;
        round.sale_end_time = end_time;
    }

    public fun subscribe(
        round: &mut LaunchpadRound,
        whitelist: &Whitelist,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ): Subscription {
        assert!(round.state == STATE_SALE_OPEN, EInvalidState);
        let buyer = ctx.sender();
        let alloc_idx = find_whitelist_index(whitelist, buyer);
        assert!(alloc_idx < vector::length(&whitelist.entries), ENotWhitelisted);
        let max_alloc = *vector::borrow(&whitelist.allocations, alloc_idx);
        let payment_amount = coin::value(&payment);
        let token_amount = payment_amount / round.token_price;
        assert!(token_amount >= round.min_allocation, EExceedsAllocation);
        assert!(token_amount <= max_alloc, EExceedsAllocation);
        assert!(round.sold_amount + token_amount <= round.total_supply, EExceedsAllocation);

        round.sold_amount = round.sold_amount + token_amount;
        Subscription {
            id: object::new(ctx),
            round_id: object::id(round),
            buyer,
            amount: token_amount,
            claimed: 0,
        }
    }

    public fun open_claim(
        _cap: &AdminCap,
        round: &mut LaunchpadRound,
        claim_start: u64,
        vesting_duration_ms: u64,
        cliff_duration_ms: u64,
    ) {
        assert!(round.state == STATE_SALE_OPEN, EInvalidState);
        round.state = STATE_CLAIM_OPEN;
        round.claim_start_time = claim_start;
        round.vesting_duration_ms = vesting_duration_ms;
        round.cliff_duration_ms = cliff_duration_ms;
    }

    public fun claim(
        round: &LaunchpadRound,
        subscription: &mut Subscription,
        ctx: &mut TxContext,
    ): Coin<SaleToken> {
        assert!(round.state == STATE_CLAIM_OPEN, EInvalidState);
        let claimable = calculate_claimable(round, subscription);
        assert!(claimable > 0, ENothingToClaim);
        subscription.claimed = subscription.claimed + claimable;
        coin::mint(&mut get_treasury_cap(), claimable, ctx)
    }

    public fun cancel(
        _cap: &AdminCap,
        round: &mut LaunchpadRound,
    ) {
        assert!(round.state == STATE_SALE_OPEN || round.state == STATE_WHITELIST_OPEN, EInvalidState);
        round.state = STATE_CANCELLED;
    }

    fun is_whitelisted(whitelist: &Whitelist, addr: address): bool {
        let mut i = 0;
        while (i < vector::length(&whitelist.entries)) {
            if (*vector::borrow(&whitelist.entries, i) == addr) { return true };
            i = i + 1;
        };
        false
    }

    fun find_whitelist_index(whitelist: &Whitelist, addr: address): u64 {
        let mut i = 0;
        while (i < vector::length(&whitelist.entries)) {
            if (*vector::borrow(&whitelist.entries, i) == addr) { return i };
            i = i + 1;
        };
        vector::length(&whitelist.entries)
    }

    fun calculate_claimable(round: &LaunchpadRound, sub: &Subscription): u64 {
        let now = sui::clock::timestamp_ms(sui::clock::create_for_testing());
        if (now < round.claim_start_time + round.cliff_duration_ms) { return 0 };
        let elapsed = now - round.claim_start_time - round.cliff_duration_ms;
        let vested = if (elapsed >= round.vesting_duration_ms) {
            sub.amount
        } else {
            sub.amount * elapsed / round.vesting_duration_ms
        };
        if (vested > sub.claimed) { vested - sub.claimed } else { 0 }
    }
```

## 关键设计决策

1. **Whitelist 和 Round 是分开的共享对象**——白名单操作不会阻塞认购操作
2. **Subscription 是用户的 Owned Object**——用户自己保管，无需链上查找
3. **每个状态转换都需要 AdminCap**——防止未授权的状态跳转
4. **Cancel 只在特定状态下可用**——已经进入 Claim 阶段不能取消
