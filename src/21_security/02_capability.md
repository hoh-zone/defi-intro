# 21.2 对象权限与 Capability 模式

## Sui 对象的三种所有权

Sui 的每个对象有明确的归属，这直接影响安全性：

| 所有权类型           | 修改权限             | DeFi 场景                      |
| -------------------- | -------------------- | ------------------------------ |
| Owned（单所有者）    | 只有所有者           | 用户仓位（Position）、LP Token |
| Shared（共享可变）   | 任何人可发起交易修改 | AMM Pool、Lending Market       |
| Frozen（共享不可变） | 无人可修改           | 只读配置、发布后的包对象       |

```move
module defi::ownership_example;

use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;

public struct UserPosition has key, store {
    id: UID,
    collateral: u64,
    debt: u64,
}

public struct Pool has key {
    id: UID,
    reserve_a: u64,
    reserve_b: u64,
}

public struct Config has key {
    id: UID,
    fee_rate: u64,
}

public fun create_position(ctx: &mut TxContext) {
    let pos = UserPosition {
        id: object::new(ctx),
        collateral: 0,
        debt: 0,
    };
    transfer::public_transfer(pos, ctx.sender());
}

public fun create_shared_pool(ctx: &mut TxContext) {
    let pool = Pool {
        id: object::new(ctx),
        reserve_a: 0,
        reserve_b: 0,
    };
    transfer::public_share_object(pool);
}

public fun create_frozen_config(ctx: &mut TxContext) {
    let config = Config {
        id: object::new(ctx),
        fee_rate: 300,
    };
    transfer::public_freeze_object(config);
}
```

### 安全含义

- **Owned 对象**：只有持有者能发起修改交易。你的 `UserPosition` 别人无法动。
- **Shared 对象**：任何人可调用修改函数，但函数内部的鉴权逻辑保护数据安全。
- **Frozen 对象**：一旦冻结，任何人都无法修改。适合不可变配置。

关键点：DeFi 协议的共享对象（如 Pool）必须通过函数逻辑而非对象所有权来控制访问。

## Capability 模式

Capability 是 Move 中最核心的权限设计模式。一个 Capability 对象就是"持有此对象才能执行某操作"的证明。

### 基础 Capability

```move
module defi::capability_basic;

use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;

public struct AdminCap has key, store {
    id: UID,
}

public struct Protocol has key {
    id: UID,
    fee_rate: u64,
    paused: bool,
}

public fun init(ctx: &mut TxContext) {
    let admin = AdminCap { id: object::new(ctx) };
    let protocol = Protocol {
        id: object::new(ctx),
        fee_rate: 300,
        paused: false,
    };
    transfer::public_share_object(protocol);
    transfer::public_transfer(admin, ctx.sender());
}

public fun set_fee_rate(_: &AdminCap, protocol: &mut Protocol, new_rate: u64) {
    assert!(new_rate <= 1000, EFeeTooHigh);
    protocol.fee_rate = new_rate;
}

public fun pause(_: &AdminCap, protocol: &mut Protocol) {
    protocol.paused = true;
}

#[error]
const EFeeTooHigh: vector<u8> = b"Fee Too High";
```

`set_fee_rate` 和 `pause` 的第一个参数是 `&AdminCap`。没有 `AdminCap` 对象的引用，无法调用这些函数。Sui 运行时在交易验证阶段就会拒绝。

### 角色 Capability

生产环境不应该用单一 AdminCap——管理员不应该同时拥有暂停和调参权限：

```move
module defi::role_capability;

use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;

public struct PauseCap has key, store { id: UID }
public struct ParamsCap has key, store { id: UID }
public struct OracleCap has key, store { id: UID }
public struct EmergencyCap has key, store { id: UID }

public struct Protocol has key {
    id: UID,
    paused: bool,
    fee_rate: u64,
    oracle_address: address,
    emergency_shutdown: bool,
}

public fun init(ctx: &mut TxContext) {
    let protocol = Protocol {
        id: object::new(ctx),
        paused: false,
        fee_rate: 300,
        oracle_address: @0x0,
        emergency_shutdown: false,
    };
    transfer::public_share_object(protocol);

    transfer::public_transfer(
        PauseCap { id: object::new(ctx) },
        ctx.sender(),
    );
    transfer::public_transfer(
        ParamsCap { id: object::new(ctx) },
        ctx.sender(),
    );
    transfer::public_transfer(
        OracleCap { id: object::new(ctx) },
        ctx.sender(),
    );
    transfer::public_transfer(
        EmergencyCap { id: object::new(ctx) },
        ctx.sender(),
    );
}

public fun pause(_: &PauseCap, protocol: &mut Protocol) {
    protocol.paused = true;
}

public fun unpause(_: &PauseCap, protocol: &mut Protocol) {
    protocol.paused = false;
}

public fun set_fee_rate(_: &ParamsCap, protocol: &mut Protocol, rate: u64) {
    assert!(rate <= 1000, EInvalidRate);
    protocol.fee_rate = rate;
}

public fun set_oracle(_: &OracleCap, protocol: &mut Protocol, addr: address) {
    protocol.oracle_address = addr;
}

public fun emergency_shutdown(_: &EmergencyCap, protocol: &mut Protocol) {
    protocol.emergency_shutdown = true;
}

#[error]
const EInvalidRate: vector<u8> = b"Invalid Rate";
```

四个独立的 Capability 分配给四个角色。可以各自放入不同的多签钱包。任何一个被攻破，不会影响其他权限。

### Capability 工厂模式

当协议需要动态创建多个子市场时，Capability 可以作为工厂凭证：

```move
module defi::capability_factory;

use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::TxContext;

public struct MarketCap has key, store { id: UID }
public struct PoolCap has key, store { id: UID, market_id: ID }

public struct Market has key {
    id: UID,
    pools: vector<ID>,
}

public struct Pool has key {
    id: UID,
    market_id: ID,
    reserve: u64,
}

public fun init(ctx: &mut TxContext) {
    let market = Market {
        id: object::new(ctx),
        pools: vector::empty(),
    };
    transfer::public_share_object(market);
    transfer::public_transfer(
        MarketCap { id: object::new(ctx) },
        ctx.sender(),
    );
}

public fun create_pool(
    _: &MarketCap,
    market: &mut Market,
    initial_reserve: u64,
    ctx: &mut TxContext,
) {
    let market_id = object::id(market);
    let pool = Pool {
        id: object::new(ctx),
        market_id,
        reserve: initial_reserve,
    };
    let pool_id = object::id(&pool);
    vector::push_back(&mut market.pools, pool_id);
    transfer::public_share_object(pool);

    let pool_cap = PoolCap {
        id: object::new(ctx),
        market_id,
    };
    transfer::public_transfer(pool_cap, ctx.sender());
}

public fun pool_deposit(_: &PoolCap, pool: &mut Pool, amount: u64) {
    pool.reserve = pool.reserve + amount;
}
```

`PoolCap` 绑定了 `market_id`，确保只有对应市场的池子管理员能操作。创建者获得 `PoolCap`，可以后续存取资金。

## Capability 的安全最佳实践

1. **最小权限原则**：每个 Capability 只授权一个操作或一组相关操作
2. **不可转让 vs 可转让**：如果 Capability 有 `store` ability，可以通过 `transfer` 传递；去掉 `store` 可以限制只能在初始化时创建
3. **Capability 不应该有 `drop`**：带 `drop` 的 Capability 可以被任何人通过"丢弃"来消除，破坏权限模型
4. **TransferPolicy 控制**：对于需要限制转让的 Capability，使用 `transfer::TransferPolicy`

```move
public struct AdminCap has key {
    id: UID,
}
```

没有 `store`，意味着 `AdminCap` 不能存入其他对象或通过 `public_transfer` 的泛型约束被包装——但仍然可以通过 `transfer::transfer` 转让。如果需要完全不可转让，应该不发布转让函数。

## 小结

Sui 的对象所有权模型提供了三种粒度的访问控制。Capability 模式将"谁能做什么"从运行时检查提升到类型系统层面。角色分离、工厂模式和最小权限原则是构建安全 DeFi 协议的基础设施。
