# 17.10 Position Object 设计

## 为什么头寸是 Owned Object

```
Market = Shared Object（所有人的公共状态）
Position = Owned Object（私人头寸）

类比:
  Market ≈ 银行的总账本（公共、共识）
  Position ≈ 你的存折（私人、无需共识）

好处:
  1. 不同用户的 Position 不争用同一对象 → 并发性好
  2. Position 可以转让给其他人（has store）
  3. 无需共享对象共识 → 更快

Sui 特色:
  在 EVM 中，所有用户余额存在合约 mapping(address => uint)
  → 每笔交易都争用同一个 storage slot
  在 Sui 中，每个用户有独立的 Position 对象
  → 不同用户的交易可以并行
```

## Position 结构体

```move
public struct Position has key, store {
    id: UID,
    market_id: ID,   // 绑定到哪个 Market
    yes: u64,        // YES 份额余额
    no: u64,         // NO 份额余额
}
```

```
字段说明:

id: UID
  → Sui 对象唯一标识
  → 创建时由 object::new(ctx) 生成

market_id: ID
  → 记录这个 Position 属于哪个 Market
  → 所有操作都会检查: object::id(market) == pos.market_id
  → 防止用 A 市场的 Position 操作 B 市场

yes: u64
  → 持有的 YES 结果份额
  → 结算时如果 YES 赢，按此金额赎回抵押

no: u64
  → 持有的 NO 结果份额
  → 结算时如果 NO 赢，按此金额赎回抵押
```

## 创建 Position

```move
public fun new_position<T>(market: &Market<T>, ctx: &mut TxContext): Position {
    Position {
        id: object::new(ctx),
        market_id: object::id(market),
        yes: 0,
        no: 0,
    }
}
```

```
注意:
  参数 market 是不可变引用（&Market<T>），只读取 ID
  不修改 Market 状态 → 不需要共享对象共识
  → 创建 Position 是低成本操作

使用模式:
  用户第一次参与某市场时调用一次
  后续 split/merge/claim 都复用同一个 Position
```

## 与动态字段方案的对比

```
方案 A — Owned Position（本章选择）:

  Market (shared)          User
  ┌─────────────┐         ┌──────────────┐
  │ q_yes, q_no │         │ Position     │
  │ vault       │         │ { yes, no }  │
  │ b, fees     │         └──────────────┘
  └─────────────┘
  各用户的 Position 独立，不争用

方案 B — Table<address, Balance>:

  Market (shared)
  ┌─────────────────────────────────┐
  │ q_yes, q_no, vault, b, fees    │
  │ balances: Table<address, u64>  │ ← 所有用户余额在这
  └─────────────────────────────────┘
  每笔交易都要修改 Market → 所有用户串行

方案 C — Dynamic Field:

  Market (shared)
  ┌────────────────┐
  │ q_yes, q_no    │
  │ vault          │
  │ df[user1] = .. │ ← 动态字段附加在 Market 上
  │ df[user2] = .. │
  └────────────────┘
  比 Table 灵活，但仍需访问 Market 共享对象

对比表:

  维度          │ Owned Position │ Table       │ Dynamic Field
  ─────────────┼───────────────┼────────────┼──────────────
  并发性        │ ✅ 高          │ ❌ 低       │ ⚠️ 中
  可转让        │ ✅ 可以       │ ❌ 不行     │ ❌ 不行
  实现复杂度    │ 低            │ 低          │ 中
  适合场景      │ 教学 + 生产   │ 简单场景    │ 复杂嵌套
```

## 安全约束：market_id 检查

```
每个操作 Position 的函数都必须验证:
  assert!(object::id(market) == pos.market_id);

如果不检查会怎样:
  Alice 在市场 A 做了 Split → Position { yes: 1000, no: 1000 }
  Alice 拿这个 Position 去市场 B 的 Merge
  → 从市场 B 的金库取出 1000
  → 但市场 B 的金库没有收过这笔钱
  → 市场 B 的金库赤字！

代码中所有涉及 Position 的函数:
  split   → assert!(object::id(market) == pos.market_id)
  merge   → assert!(object::id(market) == pos.market_id)
  claim   → assert!(object::id(market) == pos.market_id)
```

## Position 的生命周期

```
创建:
  new_position(&market, ctx) → Position { yes: 0, no: 0 }

使用（可多次）:
  split  → yes += X, no += X
  merge  → yes -= X, no -= X
  buy/sell 时如需记入头寸 → yes += N 或 no += N

结算后:
  claim → 胜出侧余额赎回，双侧清零

销毁:
  教学代码没有实现 destroy_position
  生产环境应允许清零后销毁（回收 storage rebate）

  可添加:
  public fun destroy_position(pos: Position) {
      assert!(pos.yes == 0 && pos.no == 0);
      let Position { id, .. } = pos;
      id.delete();
  }
```

## 自检

1. 为什么 `new_position` 用 `&Market<T>`（不可变引用）而不是 `&mut Market<T>`？
2. 如果一个用户创建了两个 Position 对象绑定同一个 Market，会有问题吗？（答：不会有安全问题，但可能导致头寸分散。）
