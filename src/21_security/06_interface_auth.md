# 21.6 公共接口安全与鉴权模式

## 函数可见性的安全边界

Move 的函数可见性决定了谁能调用：

| 可见性 | 调用者 | DeFi 场景 |
|--------|--------|-----------|
| `public` | 任何模块 | 用户入口（deposit, swap） |
| `public(package)` | 同一包内的模块 | 内部跨模块调用 |
| `public(friend)` | 友元模块 | 受信任的集成方 |
| 私有（无修饰符） | 同一模块 | 内部辅助函数 |
| `entry` | 只有 PTB 顶层 | 用户直接调用 |

```move
module defi::visibility;
    use sui::object::{Self, UID};

    public struct AdminCap has key, store { id: UID }
    public struct Protocol has key { id: UID, paused: bool }

    entry fun user_deposit(
        protocol: &mut Protocol,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        assert!(!protocol.paused, EPaused);
    }

    public fun deposit_internal(
        protocol: &mut Protocol,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        assert!(!protocol.paused, EPaused);
    }

    public(package) fun _update_state(
        protocol: &mut Protocol,
    ) {
    }

    public fun admin_pause(
        _: &AdminCap,
        protocol: &mut Protocol,
    ) {
        protocol.paused = true;
    }

    #[error]
    const EPaused: vector<u8> = b"Paused";
```

### 可见性选择决策树

```
这个函数是否只应该被终端用户直接调用？
  └─ 是 → entry fun
  └─ 否 → 是否只应该被同一包的其他模块调用？
       └─ 是 → public(package) fun
       └─ 否 → 是否只应该被特定受信任模块调用？
            └─ 是 → public(friend) fun
            └─ 否 → 是否任何人都应该能调用？
                 └─ 是 → public fun（但加鉴权参数）
                 └─ 否 → 私有 fun（同一模块内）
```

## sender 鉴权

最基础的鉴权是检查交易发起者：

```move
module defi::sender_auth;
    use sui::object::{Self, UID};
    use sui::tx_context;

    public struct UserVault has key {
        id: UID,
        owner: address,
        balance: u64,
    }

    public fun withdraw(
        vault: &mut UserVault,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        assert!(
            vault.owner == ctx.sender(),
            ENotOwner,
        );
        assert!(vault.balance >= amount, EInsufficient);
        vault.balance = vault.balance - amount;
    }

    #[error]
    const ENotOwner: vector<u8> = b"Not Owner";
    #[error]
    const EInsufficient: vector<u8> = b"Insufficient";
```

但在 Sui 中，owned 对象只有所有者能发起修改交易，所以对于 owned 对象，`sender` 检查是冗余的。`sender` 鉴权主要用于 **shared 对象**。

## 对象 ID 鉴权

更安全的方式是检查传入的对象是否是你期望的对象：

```move
module defi::object_id_auth;
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;

    public struct RoleTicket has key, store {
        id: UID,
        role: u8,
    }

    public struct Marketplace has key {
        id: UID,
        authorized_tickets: vector<ID>,
    }

    public fun list_item(
        marketplace: &mut Marketplace,
        ticket: &RoleTicket,
        item_id: ID,
    ) {
        let ticket_id = object::id(ticket);
        let mut authorized = false;
        let len = vector::length(&marketplace.authorized_tickets);
        let mut i = 0;
        while (i < len) {
            if (*vector::borrow(&marketplace.authorized_tickets, i) == ticket_id) {
                authorized = true;
            };
            i = i + 1;
        };
        assert!(authorized, EUnauthorized);
    }

    #[error]
    const EUnauthorized: vector<u8> = b"Unauthorized";
```

## Capability 鉴权（最佳实践）

如 21.2 节所述，Capability 是 Move 中最推荐的鉴权模式。但 Capability 鉴权有几个微妙点：

### Capability 的传递问题

```move
public fun dangerous_proxy(
    _: &AdminCap,
    protocol: &mut Protocol,
) {
}
```

如果 `AdminCap` 是 owned 对象且可以转让，攻击者可能通过社会工程学获取 Capability。防护措施：

1. 将 Capability 存入不可转让的共享对象
2. 使用多签持有 Capability
3. 在 Capability 中嵌入过期时间

```move
module defi::expiring_cap;
    use sui::object::{Self, UID};
    use sui::clock::Clock;

    public struct SessionCap has key {
        id: UID,
        expires_at: u64,
    }

    public fun require_valid(cap: &SessionCap, clock: &Clock) {
        assert!(
            sui::clock::timestamp_ms(clock) < cap.expires_at,
            EExpired,
        );
    }

    #[error]
    const EExpired: vector<u8> = b"Expired";
```

## 拒绝服务防护

DeFi 协议的公共接口可能被恶意用户用于阻塞：

### DoS 向量 1：存储膨胀

```move
public fun register_user(market: &mut Market, ctx: &mut TxContext) {
    let user = UserRecord {
        id: object::new(ctx),
        registered_at: 0,
    };
    vector::push_back(&mut market.users, object::id(&user));
    transfer::public_transfer(user, ctx.sender());
}
```

如果注册没有成本，攻击者可以用大量地址注册，膨胀 `market.users` 向量，使所有遍历该向量的操作变慢。

防护：收取注册费或使用 object ID 动态字段替代向量。

```move
public fun register_user(
    market: &mut Market,
    payment: Coin<SUI>,
    ctx: &mut TxContext,
) {
    let fee = coin::value(&payment);
    assert!(fee >= REGISTRATION_FEE, EFeeTooLow);

    let user = UserRecord {
        id: object::new(ctx),
        registered_at: 0,
    };
    dynamic_field::add(
        &mut market.id,
        object::id(&user),
        true,
    );
    transfer::public_transfer(user, ctx.sender());
}
```

### DoS 向量 2：循环依赖

```move
public fun process_all(pending: &mut vector<PendingOp>) {
    let len = vector::length(pending);
    let mut i = 0;
    while (i < len) {
        process_single(vector::borrow_mut(pending, i));
        i = i + 1;
    };
}
```

如果 `pending` 可以被攻击者填充到极大，`process_all` 会消耗过多 gas。

防护：限制单次处理数量。

```move
public fun process_batch(
    pending: &mut vector<PendingOp>,
    max_count: u64,
) {
    let len = vector::length(pending);
    let count = if (len < max_count) { len } else { max_count };
    let mut i = 0;
    while (i < count) {
        process_single(vector::borrow_mut(pending, i));
        i = i + 1;
    };
    let mut j = 0;
    while (j < count) {
        vector::remove(pending, 0);
        j = j + 1;
    };
}
```

### DoS 向量 3：事件洪水

大量发出事件可以增加全节点的存储负担。虽然没有直接的 gas 惩罚，但应该限制单个交易的事件数量。

## 接口安全清单

| 检查项 | 说明 |
|--------|------|
| 共享对象的入口函数都有鉴权？ | 检查 sender、Capability 或对象 ID |
| entry fun 不暴露内部操作？ | 管理操作不用 `entry` |
| 参数范围检查完整？ | amount > 0, amount < MAX, deadline > now |
| 无无限循环？ | 循环次数有上限 |
| 向量操作有上限？ | 遍历和处理都有最大数量 |
| 事件数量有限制？ | 单次交易不会发出过多事件 |
| 错误码有意义？ | 不是全部 `assert!(false, 0)` |

## 小结

接口安全是 DeFi 协议的"大门"。正确的可见性选择、适当的鉴权模式和 DoS 防护共同构成入口防护层。Move 的类型系统帮助很大——Capability 模式让鉴权成为编译期保证——但业务逻辑层面的防护仍然需要人工审查。
