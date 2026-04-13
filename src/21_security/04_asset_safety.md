# 21.4 资产处理安全：Coin、Balance 与资金安全

## 资金安全的第一性原理

DeFi 协议的核心不变量只有两条：

1. **资金不会凭空出现**——每个 mint 都有对应的存款或授权
2. **资金不会凭空消失**——每个 burn 都有对应的提取或销毁

违反任何一条，就是资金安全漏洞。Move 的线性类型帮助很大，但不够。以下逐一分析 `coin` 和 `balance` 模块的常见陷阱。

## Coin 操作的安全清单

### coin::take 和 coin::split

```move
use sui::coin::{Self, Coin};

public fun withdraw_from_pool(
    pool_balance: &mut Coin<SUI>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(coin::value(pool_balance) >= amount, EInsufficient);
    coin::take(pool_balance, amount, ctx)
}
```

`coin::take` 内部会检查余额并 abort，但显式 assert 能提供更好的错误信息和更早的失败点。

### coin::put 和 coin::join

```move
public fun deposit_to_pool(
    pool_balance: &mut Coin<SUI>,
    deposit: Coin<SUI>,
) {
    coin::put(pool_balance, deposit);
}
```

`coin::put` 消耗传入的 `Coin`。如果之后还需要引用这个值，必须在 `put` 之前记录金额。

### 常见错误 1：忘记处理 Coin 值

```move
public fun bad_swap(
    pool: &mut Pool,
    input: Coin<SUI>,
    ctx: &mut TxContext,
): Coin<USDC> {
    let output = internal_swap(pool, coin::value(&input), ctx);
    coin::destroy_zero(input);
    output
}
```

如果 `internal_swap` 返回错误但未消耗 `input`，`input` 会被丢弃。`Coin` 没有 `drop` ability，所以编译器会报错——这正是线性类型的保护。

### 常见错误 2：零金额处理

```move
public fun dangerous_zero(amount: u64, ctx: &mut TxContext): Coin<SUI> {
    let coin = coin::zero(ctx);
    if (amount > 0) {
        coin = coin::mint(&mut treasury, amount, ctx);
    };
    coin
}
```

这里 `coin::zero` 和 `coin::mint` 创建两个不同的 Coin 值。如果 `amount > 0`，`coin` 被重新绑定但旧的零值 `Coin` 被丢弃——因为 `Coin` 没有 `drop`，这会编译失败。

正确写法：

```move
public fun safe_create(amount: u64, ctx: &mut TxContext): Coin<SUI> {
    if (amount == 0) {
        coin::zero(ctx)
    } else {
        coin::mint(&mut treasury, amount, ctx)
    }
}
```

## Balance 类型：更轻量的资金表示

`Balance` 是 `Coin` 的底层原语，没有对象包装。适合协议内部记账：

```move
module defi::balance_safety;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::sui::SUI;

    public struct Vault has key {
        id: UID,
        total: Balance<SUI>,
        pending: Balance<SUI>,
    }

    public fun deposit(vault: &mut Vault, coin: Coin<SUI>) {
        let amount = coin::value(&coin);
        assert!(amount > 0, EZeroDeposit);

        balance::join(&mut vault.total, coin::into_balance(coin));
    }

    public fun withdraw(
        vault: &mut Vault,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        assert!(balance::value(&vault.total) >= amount, EInsufficient);
        let taken = balance::split(&mut vault.total, amount);
        coin::from_balance(taken, ctx)
    }

    public fun move_to_pending(vault: &mut Vault, amount: u64) {
        assert!(balance::value(&vault.total) >= amount, EInsufficient);
        let split = balance::split(&mut vault.total, amount);
        balance::join(&mut vault.pending, split);
    }

    #[error]
    const EZeroDeposit: vector<u8> = b"Zero Deposit";
    #[error]
    const EInsufficient: vector<u8> = b"Insufficient";
```

### Balance vs Coin 的选择

| 特性 | Coin | Balance |
|------|------|---------|
| 是否是对象 | 是（包含 UID） | 否 |
| Gas 成本 | 较高（对象处理） | 较低 |
| 可直接转账 | 是（transfer） | 否（需包装为 Coin） |
| 适用场景 | 跨地址转移 | 协议内部记账 |

最佳实践：**内部用 Balance，外部用 Coin**。在用户存入时 `coin::into_balance`，在用户提取时 `coin::from_balance`。

## 完整的资金安全审计模式

以下是一个完整的入金/出金函数，展示每个安全检查点：

```move
module defi::fund_safety;
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::event;

    public struct Pool has key {
        id: UID,
        asset_balance: Balance<SUI>,
        total_shares: u64,
        paused: bool,
    }

    public struct DepositEvent has copy, drop {
        user: address,
        amount: u64,
        shares_minted: u64,
    }

    public struct WithdrawEvent has copy, drop {
        user: address,
        amount: u64,
        shares_burned: u64,
    }

    public fun deposit(
        pool: &mut Pool,
        coin: Coin<SUI>,
        ctx: &mut TxContext,
    ): u64 {
        assert!(!pool.paused, EProtocolPaused);

        let amount = coin::value(&coin);
        assert!(amount >= MIN_DEPOSIT, EBelowMinDeposit);
        assert!(amount <= MAX_DEPOSIT, EAboveMaxDeposit);

        let shares = if (pool.total_shares == 0) {
            amount
        } else {
            let total_value = balance::value(&pool.asset_balance);
            ((amount as u256) * (pool.total_shares as u256) / (total_value as u256) as u64)
        };

        assert!(shares > 0, EZeroShares);

        balance::join(&mut pool.asset_balance, coin::into_balance(coin));
        pool.total_shares = pool.total_shares + shares;

        event::emit(DepositEvent {
            user: ctx.sender(),
            amount,
            shares_minted: shares,
        });

        shares
    }

    public fun withdraw(
        pool: &mut Pool,
        shares: u64,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        assert!(!pool.paused, EProtocolPaused);
        assert!(shares > 0, EZeroShares);
        assert!(shares <= pool.total_shares, EExceedsTotalShares);

        let total_value = balance::value(&pool.asset_balance);
        let amount = ((shares as u256) * (total_value as u256) / (pool.total_shares as u256) as u64);

        assert!(amount > 0, EZeroWithdraw);
        assert!(amount <= total_value, EExceedsBalance);

        pool.total_shares = pool.total_shares - shares;

        let withdrawn = balance::split(&mut pool.asset_balance, amount);
        let coin = coin::from_balance(withdrawn, ctx);

        event::emit(WithdrawEvent {
            user: ctx.sender(),
            amount,
            shares_burned: shares,
        });

        coin
    }

    const MIN_DEPOSIT: u64 = 100000000;
    const MAX_DEPOSIT: u64 = 100000000000000;
    #[error]
    const EProtocolPaused: vector<u8> = b"Protocol Paused";
    #[error]
    const EBelowMinDeposit: vector<u8> = b"Below Min Deposit";
    #[error]
    const EAboveMaxDeposit: vector<u8> = b"Above Max Deposit";
    #[error]
    const EZeroShares: vector<u8> = b"Zero Shares";
    #[error]
    const EZeroWithdraw: vector<u8> = b"Zero Withdraw";
    #[error]
    const EExceedsTotalShares: vector<u8> = b"Exceeds Total Shares";
    #[error]
    const EExceedsBalance: vector<u8> = b"Exceeds Balance";
```

关键检查点：
1. 暂停检查在最前面——避免资金被锁在正在处理中的交易
2. 金额范围检查——防止极端值导致精度问题
3. 份额计算用 `u256`——避免乘法溢出
4. 双重检查——份额→金额→余额，确保不会取出超过存入
5. 事件记录——每个资金操作都有可审计的事件

## 资金安全不变量验证

在测试中，应该验证以下不变量：

```move
#[test]
fun test_invariant_deposit_withdraw_roundtrip() {
    let ctx = test_scenario::begin(@0xa);
    let pool = create_test_pool(test_scenario::ctx(&mut ctx));

    let deposit_amount = 1000000000u64;
    let deposit_coin = mint_sui(deposit_amount, test_scenario::ctx(&mut ctx));

    let initial_balance = get_pool_balance(&pool);
    let shares = deposit(&mut pool, deposit_coin, test_scenario::ctx(&mut ctx));

    let withdraw_coin = withdraw(&mut pool, shares, test_scenario::ctx(&mut ctx));
    let final_balance = get_pool_balance(&pool);

    assert!(coin::value(&withdraw_coin) == deposit_amount);
    assert!(final_balance == initial_balance);
    assert!(pool.total_shares == 0);

    test_scenario::end(ctx);
}
```

这个测试验证：存入再取出，余额完全一致，份额归零。任何偏差都意味着资金泄漏。

## 小结

Move 的线性类型消除了 EVM 中"忘记处理返回值"类的资金漏洞，但精度问题、边界检查和暂停机制仍然需要人工保障。资金安全的核心是两个不变量：资金不凭空出现、不凭空消失。每一条存取路径都应该被测试验证。
