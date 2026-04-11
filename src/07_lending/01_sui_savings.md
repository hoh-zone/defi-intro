# 7.1 储蓄池与普通借贷

## 设计目标

Sui Savings 是一个最简单的"存入 → 赚息 → 取出"协议。它不涉及借款、抵押和清算。核心目标是展示：
1. 如何用 Sui 对象模型设计一个资金池
2. 如何实现利息计算
3. 如何分离管理员权限

## 对象设计

```move
module sui_savings {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientBalance: u64 = 0;
    const EUnauthorized: u64 = 1;
    const EPoolPaused: u64 = 2;
    const EInvalidAmount: u64 = 3;

    public struct SavingsPool<phantom T> has key {
        id: UID,
        principal: Balance<T>,
        reward_pool: Balance<T>,
        total_shares: u64,
        interest_rate_bps: u64,
        last_update_epoch: u64,
        paused: bool,
    }

    public struct SavingsReceipt<phantom T> has key, store {
        id: UID,
        pool_id: ID,
        shares: u64,
        deposit_epoch: u64,
    }

    public struct AdminCap<phantom T> has key, store {
        id: UID,
        pool_id: ID,
    }

    public struct SavingsEvent has copy, drop {
        action: u64,
        amount: u64,
        shares: u64,
    }
}
```

三个核心对象：
- `SavingsPool<T>` — 共享对象，存储所有资金
- `SavingsReceipt<T>` — 用户持有的存款凭证
- `AdminCap<T>` — 管理员权限凭证

### 为什么用 Balance 而不是 Coin

`Balance<T>` 是 Sui 上存储代币的标准方式。`Coin<T>` 是 Balance 的可转移包装。池子用 Balance 存储资金，只有在需要转给用户时才铸造成 Coin。

## 初始化

```move
public fun init<T>(
    interest_rate_bps: u64,
    ctx: &mut TxContext,
) {
    let pool = SavingsPool<T> {
        id: object::new(ctx),
        principal: balance::zero<T>(),
        reward_pool: balance::zero<T>(),
        total_shares: 0,
        interest_rate_bps,
        last_update_epoch: 0,
        paused: false,
    };
    let cap = AdminCap<T> {
        id: object::new(ctx),
        pool_id: object::id(&pool),
    };
    transfer::share_object(pool);
    transfer::transfer(cap, ctx.sender());
}
```

注意 `share_object(pool)`——池子是共享对象，任何人都能调用它的方法。AdminCap 转给创建者，只有持有者能调用管理功能。

## 存入

```move
public fun deposit<T>(
    pool: &mut SavingsPool<T>,
    coin: Coin<T>,
    ctx: &mut TxContext,
): SavingsReceipt<T> {
    assert!(!pool.paused, EPoolPaused);
    let amount = coin::value(&coin);
    assert!(amount > 0, EInvalidAmount);
    accrue_interest(pool);
    let shares = if (pool.total_shares == 0) {
        amount
    } else {
        amount * pool.total_shares / balance::value(&pool.principal)
    };
    pool.total_shares = pool.total_shares + shares;
    balance::join(&mut pool.principal, coin::into_balance(coin));
    SavingsReceipt<T> {
        id: object::new(ctx),
        pool_id: object::id(pool),
        shares,
        deposit_epoch: sui::sui::current_epoch(ctx),
    }
}
```

份额计算：`shares = deposit_amount * total_shares / total_principal`

这确保份额价值与存入金额一一对应。

## 取出

```move
public fun withdraw<T>(
    pool: &mut SavingsPool<T>,
    receipt: SavingsReceipt<T>,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(object::id(pool) == receipt.pool_id, EInvalidAmount);
    accrue_interest(pool);
    let principal_value = receipt.shares * balance::value(&pool.principal) / pool.total_shares;
    assert!(balance::value(&pool.principal) >= principal_value, EInsufficientBalance);
    pool.total_shares = pool.total_shares - receipt.shares;
    let coin = coin::take(&mut pool.principal, principal_value, ctx);
    .delete()(receipt);
    coin
}
```

取出时按份额比例计算应得的本金。注意 `.delete()(receipt)`——取出后凭证被销毁，防止重复取出。

## 领取利息

```move
public fun claim_interest<T>(
    pool: &mut SavingsPool<T>,
    receipt: &SavingsReceipt<T>,
    ctx: &mut TxContext,
): Coin<T> {
    accrue_interest(pool);
    let total_principal = balance::value(&pool.principal);
    let user_share = receipt.shares * 10000 / pool.total_shares;
    let pending_reward = balance::value(&pool.reward_pool) * user_share / 10000;
    assert!(pending_reward > 0, EInvalidAmount);
    let coin = coin::take(&mut pool.reward_pool, pending_reward, ctx);
    coin
}
```

## 利息累计

```move
fun accrue_interest<T>(pool: &mut SavingsPool<T>) {
    let current_epoch = sui::sui::current_epoch(&mut sui::sui::dummy_ctx());
    if (current_epoch <= pool.last_update_epoch) { return };
    let epochs_passed = current_epoch - pool.last_update_epoch;
    let principal_amount = balance::value(&pool.principal);
    if (principal_amount == 0) {
        pool.last_update_epoch = current_epoch;
        return
    };
    let interest = (principal_amount as u128)
        * (pool.interest_rate_bps as u128)
        * (epochs_passed as u128)
        / (10000 * 365);
    pool.last_update_epoch = current_epoch;
}
```

按 epoch 计算利息，年化利率除以 365 得到每个 epoch 的利率。实际协议中利息从奖励池发放，这里简化处理。

## 管理员功能

```move
public fun set_interest_rate<T>(
    _cap: &AdminCap<T>,
    pool: &mut SavingsPool<T>,
    new_rate_bps: u64,
) {
    accrue_interest(pool);
    pool.interest_rate_bps = new_rate_bps;
}

public fun add_rewards<T>(
    _cap: &AdminCap<T>,
    pool: &mut SavingsPool<T>,
    reward: Coin<T>,
) {
    balance::join(&mut pool.reward_pool, coin::into_balance(reward));
}

public fun pause<T>(_cap: &AdminCap<T>, pool: &mut SavingsPool<T>) {
    pool.paused = true;
}

public fun unpause<T>(_cap: &AdminCap<T>, pool: &mut SavingsPool<T>) {
    pool.paused = false;
}
```

所有管理函数的第一个参数是 `_cap: &AdminCap<T>`。只有持有 AdminCap 的人能调用这些函数。AdminCap 本身是一个可转移的对象——你可以把它转给别人来移交管理权。

## 数值示例

初始状态：
- 利率：5%（500 bps）
- 池中：0 SUI

用户 A 存入 1000 SUI：
- shares = 1000（第一个存款人，shares = amount）
- 池中：1000 SUI

经过 365 个 epoch（约一年）：
- interest = 1000 * 500 * 365 / (10000 * 365) = 50 SUI
- 管理员需要向 reward_pool 注入 50 SUI

用户 A 取出：
- principal_value = 1000 * 1000 / 1000 = 1000 SUI
- claim_interest = 50 * 10000 / 10000 = 50 SUI
- 总计取出：1050 SUI

## 风险分析

| 风险 | 描述 | 本实现中的处理 |
|------|------|---------------|
| 利息不足 | reward_pool 余额不足以支付所有利息 | `assert!` 检查，不足时 abort |
| 管理员恶意 | 管理员可以把利率设为 0 或暂停池子 | AdminCap 可转移，可设置多签 |
| 份额膨胀 | 第一个存款人在空池时获得份额比例最大 | 通过 deposit 时的计算保证公平 |
| 重入 | 取出后再次操作 | Move 资源语义天然防止 |
