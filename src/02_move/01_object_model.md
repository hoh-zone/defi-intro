## 2.1 对象模型：Owned Object 与 Shared Object

### 对象是 Sui 的基本状态单元

Sui 上的所有状态都存在于对象中。每个对象有唯一 ID、所有者、版本号和存储的数据。对于 DeFi 开发者，理解两种对象类型至关重要。

**Owned Object**：被特定地址拥有的对象。只有所有者可以将其作为交易输入。交易只涉及 Owned Object 时，Sui 使用"快速路径"（拜占庭一致性）确认，无需经过共识。

**Shared Object**：被共享的对象。任何人都可以将其作为交易输入。涉及 Shared Object 的交易必须经过共识排序，保证全局一致性。

```move
module defi_book::object_demo;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;

    public struct Vault has key {
        id: UID,
        deposits: Balance<SUI>,
    }

    public struct UserPosition has key, store {
        id: UID,
        vault_id: ID,
        deposited: u64,
        reward_debt: u64,
    }

    public entry fun create_vault(ctx: &mut TxContext) {
        let vault = Vault {
            id: object::new(ctx),
            deposits: balance::zero(),
        };
        transfer::share_object(vault);
    }

    public entry fun deposit(
        vault: &mut Vault,
        coin: Coin<SUI>,
        ctx: &mut TxContext,
) {
        let amount = coin.value(&coin);
        balance::join(&mut vault.deposits, coin.into_balance());
        let position = UserPosition {
            id: object::new(ctx),
            vault_id: object::id(vault),
            deposited: amount,
            reward_debt: 0,
        };
        transfer::transfer(position, ctx.sender());
    }
```

这段代码展示了 DeFi 中最常见的对象分工：

- `Vault` 通过 `transfer::share_object` 变为 Shared Object——任何人都可以存款
- `UserPosition` 通过 `transfer::transfer` 变为 Owned Object——只有存款人可以操作自己的仓位

### 交易执行路径

当用户调用 `deposit` 时：

1. 交易包含两个对象引用：`Vault`（Shared）和 `Coin<SUI>`（Owned）
2. Sui 验证节点对 Shared Object 进行共识排序
3. 执行交易，创建新的 `UserPosition` 对象
4. `UserPosition` 转移给用户，成为 Owned Object

后续如果用户想查看自己的存款金额，只需要读取自己的 `UserPosition`，不需要访问 Shared Object。这种设计减少了 Shared Object 的争用。

### 存储费用

Sui 的存储费用与对象大小成正比。创建对象需要支付存储押金，删除对象时押金退还。这对 DeFi 协议设计有直接影响：

```move
public entry fun withdraw(
    vault: &mut Vault,
    position: UserPosition,
    ctx: &mut TxContext,
): Coin<SUI> {
    let UserPosition { id, vault_id: _, deposited, reward_debt: _ } = position;
    .delete()(id);
    let coin = coin::take(&mut vault.deposits, deposited, ctx);
    coin
}
```

`withdraw` 中，`position` 被按值接收（不是引用），然后解构并删除。这退还了存储押金。如果 Position 包含大量数据（如完整的交易历史），存储费用会很高——这鼓励 DeFi 开发者保持用户仓位数据的精简。

> 风险提示：Shared Object 是 DeFi 协议的性能瓶颈。所有涉及同一个 Shared Object 的交易必须串行执行。如果你的 DEX 只有一个 Pool 对象，所有交易对都会互相阻塞。将不同交易对设计为独立的 Pool 对象是利用 Sui 并行能力的关键设计决策。
