## 1.2 为什么是 Sui：对象模型与并行执行

### 账户模型 vs 对象模型

以太坊使用账户模型。所有状态都存储在账户的存储槽中，状态变更是全局的。一个 Uniswap V2 交易对的合约地址下存储着所有相关的储备量、LP 份额和手续费数据。每笔交易都需要修改这个全局状态，因此必须串行执行。

Sui 使用对象模型。每个独立的状态单元是一个**对象（Object）**，拥有全局唯一的 ID。对象之间的依赖关系由交易显式声明，运行时可以据此判断哪些交易能并行执行。

```move
module defi_book::demo_pool;

use sui::coin::{Self, Coin};
use sui::sui::SUI;

public struct USDC has drop {}

public struct Pool has key {
    id: UID,
    reserve_a: Coin<SUI>,
    reserve_b: Coin<USDC>,
    fee_bps: u64,
}

public struct Position has key, store {
    id: UID,
    pool_id: ID,
    liquidity: u64,
}

public struct PoolAdminCap has key {
    id: UID,
    pool_id: ID,
}
```

这段代码展示了 Sui 上 DeFi 协议的典型对象设计：

- `Pool` 是 **Shared Object**——所有用户与之交互，需要共识排序
- `Position` 是 **Owned Object**——创建后转移给用户，后续操作只需所有者签名
- `PoolAdminCap` 是 **Capability Object**——持有者拥有管理权限，不持有则无法调用管理函数

在 EVM 中，Pool 的数据存在合约存储中，Position 用 mapping 记录，AdminCap 用 `onlyOwner` 修饰符实现。三者混在同一个合约中。在 Sui 中，三者是独立的对象，生命周期独立管理。

### 并行执行对 DeFi 的影响

Sui 的并行执行基于一个简单判断：如果两笔交易不访问相同的 Shared Object，它们可以并行执行。

对 DeFi 而言，这意味着：

- 交易对 A（SUI/USDC）和交易对 B（ETH/USDC）的交易可以并行
- 同一个交易对内的多笔交易仍然需要排序（它们共享同一个 Pool 对象）
- 用户存取自己的 Position 不需要与任何 Shared Object 交互，走快速路径

```move
public entry fun swap(
    pool: &mut Pool,
    coin_in: Coin<SUI>,
    ctx: &mut TxContext,
): Coin<USDC> {
    let amount_in = coin_in.value(&coin_in);
    let reserve_a = pool.reserve_a.value(&pool.reserve_a);
    let reserve_b = pool.reserve_b.value(&pool.reserve_b);

    let amount_out = (reserve_b * amount_in * (10000 - pool.fee_bps))
        / ((reserve_a + amount_in) * 10000);

    let coin_out = coin::take(&mut pool.reserve_b, amount_out, ctx);
    coin::join(&mut pool.reserve_a, coin_in);

    coin_out
}
```

这笔 `swap` 操作需要 `&mut Pool`（可变引用 Shared Object），因此与其他操作同一 Pool 的交易串行。但如果另一个 DEX 有独立的 Pool 对象，两笔交易并行。

### Sui 资产表达的优势

在 Move 中，资产是一等公民。`Coin<T>` 是内置的类型，具有以下保证：

- **不能被复制**：Coin 没有 `copy` ability，转移就是移动
- **不能被丢弃**：Coin 没有 `drop` ability，必须被明确使用或转移
- **只能被存储**：Coin 有 `store` ability，可以放入其他对象

```move
fun demonstrate_asset_safety() {
    let coin: Coin<SUI> = coin::mint(1000, ctx);
    // coin.copy();          // 编译错误：Coin 没有 copy ability
    // let _ = coin;         // 编译错误：Coin 没有 drop ability，不能被丢弃
    coin::transfer(coin, recipient); // 唯一合法操作：转移
}
```

这种资源语义直接消除了 Solidity 中常见的两类漏洞：双花（通过复制）和资金锁定（通过丢弃引用）。编译器在编译期就阻止了这些操作，而不是在运行时。

> 风险提示：Move 的资源语义消除了很多低级漏洞，但不等于代码安全。机制设计层面的风险（如不合理的价格曲线、不当的清算参数）不会因为语言安全而消失。此外，Sui 的并行执行在极端情况下可能导致 Gas 竞争加剧——当多个交易竞争同一个 Shared Object 时，Gas 价格更高的交易优先。
