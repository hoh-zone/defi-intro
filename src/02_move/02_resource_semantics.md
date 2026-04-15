## 2.2 Move 资源语义与 Ability 系统

### 四种 Ability 的金融含义

Move 的每个 struct 可以拥有零到四种 ability：`key`、`store`、`drop`、`copy`。这四种 ability 的组合直接决定了 struct 实例的生命周期约束——在 DeFi 中，这等同于资产的约束。

```move
module defi_book::ability_demo;

use sui::coin::Coin;
use sui::sui::SUI;

public struct CoinAsset has key, store {
    id: UID,
    value: u64,
}

public struct AccessTicket has drop {
    round: u64,
}

public struct PriceFeed has copy, drop, store {
    price: u64,
    timestamp: u64,
}

public struct AdminCap has key, store {
    id: UID,
    module_name: String,
}
```

逐一分析：

| Ability | 含义                               | 金融含义                               |
| ------- | ---------------------------------- | -------------------------------------- |
| `key`   | 可以作为全局存储的顶层对象         | 这是链上资产——有 ID，有独立存在        |
| `store` | 可以存储在其他对象中或转移         | 这是可转移资产——可以放入钱包或存入合约 |
| `drop`  | 可以被丢弃（不使用也不会编译错误） | 这是临时凭证——用完即弃，不是资产       |
| `copy`  | 可以被复制                         | 这是信息/价格——复制不会创造价值        |

**关键规则**：真正的资产（Coin、LP Token、NFT）不应有 `copy` 和 `drop`。如果 Coin 有 `copy`，它可以被无限复制（通货膨胀漏洞）。如果 Coin 有 `drop`，它可以被意外销毁（资金丢失漏洞）。

```move
public struct BadCoin has key, store, copy, drop {
    id: UID,
    value: u64,
}

public struct GoodCoin has key, store {
    id: UID,
    value: u64,
}

fun exploit(bad: &BadCoin): BadCoin {
    copy bad // 编译通过！BadCoin 可以被复制
}

// fun exploit_good(good: &GoodCoin): GoodCoin {
//     copy good // 编译错误！GoodCoin 没有 copy ability
// }
```

### AdminCap 模式

在 Sui 上，权限管理通过 Capability 对象实现。AdminCap 是一个只有管理员持有的对象，管理函数要求调用者提供这个对象作为参数。

```move
module defi_book::admin_cap_demo;

use sui::coin::{Self, Coin};
use sui::sui::SUI;

public struct Pool has key {
    id: UID,
    reserve: Coin<SUI>,
    fee_bps: u64,
    paused: bool,
}

public struct PoolAdminCap has key, store {
    id: UID,
    pool_id: ID,
}

public entry fun create_pool(ctx: &mut TxContext) {
    let pool = Pool {
        id: object::new(ctx),
        reserve: coin::zero(ctx),
        fee_bps: 30,
        paused: false,
    };
    let cap = PoolAdminCap {
        id: object::new(ctx),
        pool_id: object::id(&pool),
    };
    transfer::share_object(pool);
    transfer::transfer(cap, ctx.sender());
}

public fun set_fee(_cap: &PoolAdminCap, pool: &mut Pool, new_fee_bps: u64) {
    pool.fee_bps = new_fee_bps;
}

public fun set_paused(_cap: &PoolAdminCap, pool: &mut Pool, paused: bool) {
    pool.paused = paused;
}

public entry fun swap(pool: &mut Pool, coin_in: Coin<SUI>, ctx: &mut TxContext): Coin<SUI> {
    assert!(!pool.paused, EPaused);
    let amount_in = coin.value(&coin_in);
    let reserve = pool.reserve.value(&pool.reserve);
    let amount_out =
        reserve * amount_in * (10000 - pool.fee_bps)
            / ((reserve + amount_in) * 10000);
    let coin_out = coin::take(&mut pool.reserve, amount_out, ctx);
    coin::join(&mut pool.reserve, coin_in);
    coin_out
}

#[error]
const EPaused: vector<u8> = b"Paused";
```

`set_fee` 和 `set_paused` 都要求传入 `&PoolAdminCap`。没有这个对象，任何人都无法调用这两个函数。`swap` 不需要 AdminCap——它是公开函数。这就是 Sui 上的权限模型：**权限即对象**，而不是访问控制列表。

### 模块边界 = 安全边界

Move 的模块系统提供了强封装。struct 的字段只能在定义它的模块内访问。这意味着：

```move
// 同一 .move 文件内若声明多个 module，编译器要求使用花括号形式（见本书技能：move/syntax）
module defi_book::pool_module {
    public struct Pool has key {
        id: UID,
        reserve: Balance<SUI>, // 外部模块无法直接访问
        fee_bps: u64,
    }
}

module attacker::exploit {
    use defi_book::pool_module::Pool;

    // fun drain(pool: &mut Pool) {
    //     pool.reserve = balance::zero(); // 编译错误！字段不可访问
    // }
}
```

外部模块只能通过 `pool_module` 暴露的公共函数与 Pool 交互。这是 Move 比 Solidity 更强的封装保证——Solidity 的 `private` 只限制继承链，不限制同一合约内的其他函数。

> 风险提示：AdminCap 有 `store` ability 意味着它可以被转移。如果管理员不小心将 AdminCap 转移给了错误地址，协议将失去管理能力。建议在创建时考虑是否真的需要 `store` ability——如果 AdminCap 不需要转移（例如永远由创建者持有），可以去掉 `store`。
