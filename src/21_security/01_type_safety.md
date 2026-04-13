# 21.1 Move 安全模型与类型系统防御

## Move 与 EVM 的根本区别

EVM 是"一切皆 storage slot"的世界。任何合约可以读写任何地址的存储，重入是常态，整数溢出曾经需要手动检查（Solidity < 0.8）。Move 采取了不同的安全哲学：

| 安全属性 | EVM (Solidity) | Move |
|----------|----------------|------|
| 重入 | 可能，需手动防护 | 不可能（无动态调用） |
| 双花 | 可能，需手动检查 | 不可能（线性类型保证资源唯一） |
| 整数溢出 | < 0.8 默认不检查 | 编译期/运行期均检查 |
| 未授权访问 | 需手动 require | Capability 模式强制鉴权 |
| 存储冲突 | 可能 | 不可能（对象所有权隔离） |

Move 不需要 SafeERC20 包装器，不需要 ReentrancyGuard，不需要 SafeMath——因为这些保护内建在语言里。

## Ability 系统的安全含义

Move 的四种 Ability 直接约束了数据的安全性：

```move
public struct Coin has store { value: u64 }
```

- `copy`：允许复制。没有 `copy` 的结构体（如 `Coin`）无法被意外复制。
- `drop`：允许丢弃。没有 `drop` 的结构体必须被显式消耗，不会凭空消失。
- `store`：允许存入对象或全局存储。
- `key`：允许成为全局存储的顶层数据。

### 没有 copy 和 drop 的安全保证

```move
module defi::asset_safety {
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;

    public struct LockedVault has key {
        id: UID,
        balance: Coin<SUI>,
    }

    public fun deposit(vault: &mut LockedVault, coin: Coin<SUI>) {
        let amount = coin::value(&coin);
        assert!(amount > 0, EInvalidAmount);
        coin::put(&mut vault.balance, coin);
    }

    public fun withdraw(
        vault: &mut LockedVault,
        amount: u64,
        ctx: &mut TxContext,
    ): Coin<SUI> {
        assert!(coin::value(&vault.balance) >= amount, EInsufficientBalance);
        coin::take(&mut vault.balance, amount, ctx)
    }

    const EInvalidAmount: u64 = 0;
    const EInsufficientBalance: u64 = 1;
}
```

`Coin<SUI>` 没有 `copy` 和 `drop`。这意味着：

1. **不可能凭空创建**：`Coin` 只能通过 `coin::mint` 或 `coin::take` 获得
2. **不可能意外丢弃**：函数必须显式处理每个 `Coin` 值
3. **不可能复制**：不存在两个指向同一余额的引用

### 对比 EVM 的对应漏洞

```solidity
// EVM: 以下代码有双花漏洞
mapping(address => uint256) public balances;

function transfer(address to, uint256 amount) public {
    // 未检查余额！可能 underflow
    balances[msg.sender] -= amount;
    balances[to] += amount;
}
```

Move 中，这段代码对应的操作是：

```move
public fun transfer(coin: Coin<SUI>, recipient: address, ctx: &mut TxContext) {
    let taken = coin::take(&mut coin, amount, ctx);
    transfer::public_transfer(taken, recipient);
}
```

`coin::take` 内部检查余额，`Coin` 类型保证金额不会凭空出现或消失。编译器保证 `coin` 被正确消耗。

## 结构体可见性的安全效果

```move
module defi::internal_state {
    use sui::object::{Self, UID};

    public struct ProtocolState has key {
        id: UID,
        total_debt: u64,
        total_deposit: u64,
        paused: bool,
    }

    public fun total_debt(state: &ProtocolState): u64 {
        state.total_debt
    }

    public fun total_deposit(state: &ProtocolState): u64 {
        state.total_deposit
    }
}
```

Move 的 struct 字段默认模块私有的。外部模块无法直接读写 `total_debt`，只能通过公开函数访问。这防止了外部合约篡改内部状态——在 EVM 中这需要额外的访问控制。

## 类型即权限

利用类型系统编码权限约束，是 Move 安全设计的核心模式：

```move
module defi::typed_permissions {
    use sui::object::{Self, UID};

    public struct Level1 has drop {}
    public struct Level2 has drop {}
    public struct Level3 has drop {}

    public struct Vault has key {
        id: UID,
        value: u64,
    }

    public fun deposit_level1(vault: &mut Vault, _witness: Level1, amount: u64) {
        assert!(amount <= 1000, EExceedLimit);
        vault.value = vault.value + amount;
    }

    public fun deposit_level2(vault: &mut Vault, _witness: Level2, amount: u64) {
        assert!(amount <= 10000, EExceedLimit);
        vault.value = vault.value + amount;
    }

    public fun deposit_level3(vault: &mut Vault, _witness: Level3, amount: u64) {
        vault.value = vault.value + amount;
    }

    const EExceedLimit: u64 = 0;
}
```

`Level1`、`Level2`、`Level3` 是只有 `drop` ability 的类型。只有能创建这些类型的模块才能调用对应的函数。编译器在编译时保证权限正确——不需要运行时的 `require` 检查。

## 警惕：Move 不能阻止什么

Move 的类型系统很强大，但它无法阻止以下问题：

1. **业务逻辑错误**：类型系统不理解你的业务规则。你可以写出数学上正确但业务上错误的代码。
2. **外部数据信任**：预言机返回的价格是否可靠，类型系统无法判断。
3. **治理错误**：多签签署了恶意交易，Move 不会拒绝。
4. **升级风险**：兼容性错误的升级可以破坏用户数据。
5. **整数精度**：Move 检查溢出，但不检查精度丢失。

```move
public fun dangerous_precision(a: u64, b: u64): u64 {
    a / b * b
}
```

这个函数编译通过、不溢出，但当 `a < b` 时返回 0 而非 `a`。类型系统无法捕获这种语义错误。

## 小结

Move 的安全模型通过线性类型、Ability 约束和模块封装，消除了 EVM 生态中最常见的整类漏洞。但"更少的漏洞类别"不等于"没有漏洞"——业务逻辑、外部数据和治理层面的问题仍然需要人为防御。后续章节逐一展开这些防御手段。
