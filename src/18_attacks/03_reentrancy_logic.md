# 18.3 重入与逻辑漏洞

## Move 的天然防重入

Move 的资源语义天然防止经典重入攻击。原因：

1. 对象在函数执行期间被锁定，不能被二次访问
2. 没有动态调用（call/delegatecall），无法回调攻击者合约
3. 资源的线性类型确保每个对象只有一个引用

```move
public fun withdraw(pool: &mut Pool, position: Position, ctx: &mut TxContext): Coin<T> {
    let amount = position.shares * pool.balance / pool.total_shares;
    pool.total_shares = pool.total_shares - position.shares;
    let coin = coin::take(&mut pool.coins, amount, ctx);
    .delete()(position);
    coin
}
```

在 EVM 中，这段代码可能在 `coin::take` 之前被重入。在 Move 中，`pool: &mut` 引用在函数执行期间独占，不可能被另一个函数同时访问。

## 但逻辑漏洞不在此列

Move 防了重入，但防不了逻辑错误。以下是常见的逻辑漏洞：

### 1. 状态更新顺序错误

```move
public fun buggy_withdraw(pool: &mut Pool, amount: u64, ctx: &mut TxContext): Coin<T> {
    let coin = coin::take(&mut pool.coins, amount, ctx);
    pool.balance = pool.balance - amount;
    coin
}
```

如果 `coin::take` abort（余额不足），`pool.balance` 不会更新。这本身没问题。但如果在 `take` 和更新之间有其他逻辑，可能导致不一致。

### 2. 权限检查遗漏

```move
public fun dangerous_update_config(
    pool: &mut Pool,
    new_fee: u64,
) {
    pool.fee_bps = new_fee;
}
```

没有检查调用者是否持有 AdminCap。任何人都可以调用这个函数修改费率。

正确做法：

```move
public fun safe_update_config(
    _cap: &AdminCap,
    pool: &mut Pool,
    new_fee: u64,
) {
    pool.fee_bps = new_fee;
}
```

### 3. 整数溢出（Move 已防范）

Move 的整数运算在溢出时会 abort，不会静默回绕。但逻辑上的溢出仍然可能：

```move
let shares = deposit_amount * pool.total_shares / pool.balance;
```

如果 `deposit_amount * pool.total_shares` 超过 `u64` 最大值，交易会 abort。解决方案：

```move
let shares = ((deposit_amount as u128) * (pool.total_shares as u128) / (pool.balance as u128)) as u64;
```

### 4. 条件检查不完整

```move
public fun borrow(
    pool: &mut Pool,
    amount: u64,
    collateral: u64,
) {
    assert!(collateral * 150 / 100 >= amount, 0);
    pool.borrows = pool.borrows + amount;
}
```

缺少检查：

- `pool.borrows + amount <= pool.deposits`（可用流动性）
- `amount > 0`（零借款）
- `collateral > 0`（零抵押）

## 防御原则

1. **每个修改状态的函数都要检查权限**
2. **先检查所有前置条件，再修改状态**
3. **用 u128 做中间计算，避免溢出**
4. **所有 public 函数都要考虑"如果传入 0 会怎样"**
