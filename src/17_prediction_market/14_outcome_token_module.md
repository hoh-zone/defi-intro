# 17.14 Move 实现 Outcome Token 模块

本节讨论「结果代币」在 Move 中的实现选择，以及教学代码为什么选择了 `Position` 记账而不是独立的 `Coin` 类型。

## 三种实现方案详解

### 方案 A：每市场独立 Coin 类型（生产级）

```move
// 需要 One-Time Witness（OTW）工厂模式

module market_factory::yes_token_42;

public struct YES_TOKEN_42 has drop {}

fun init(witness: YES_TOKEN_42, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency(
        witness,
        9,           // decimals
        b"YES-42",
        b"YES Market 42",
        b"",
        option::none(),
        ctx,
    );
    // treasury_cap 用于铸造/销毁
    transfer::public_transfer(treasury, @market_factory);
    transfer::public_freeze_object(metadata);
}
```

```
优点:
  → YES 和 NO 是标准 Coin 类型
  → 可以在 DEX 上交易（二级市场）
  → 可以被其他协议组合使用（抵押、借贷等）
  → 与 Gnosis CTF 设计思想最接近

缺点:
  → 每个市场需要发布一个新模块
  → 部署成本高（每个市场 1 次 publish）
  → 管理 TreasuryCap 的逻辑复杂

适用: 高频交易的主流市场（如选举、体育赛事）
```

### 方案 B：Position 记账（本章选择）

```move
public struct Position has key, store {
    id: UID,
    market_id: ID,
    yes: u64,
    no: u64,
}
```

```
优点:
  → 一个模块支持无限市场
  → 实现简单，概念清晰
  → 不需要 OTW，不需要 TreasuryCap
  → Position 有 store，可以转让

缺点:
  → Position 不是标准 Coin，不能直接在 DEX 上交易
  → 需要自定义转让逻辑
  → 不能直接用作其他协议的抵押品

适用: 教学、快速原型、不需要二级市场的场景
```

### 方案 C：通用 OutcomeToken + market_id 索引

```move
// 一种折中方案
public struct OutcomeToken has key, store {
    id: UID,
    market_id: ID,
    outcome: u8,     // YES(1) 或 NO(2)
    amount: u64,
}
```

```
优点:
  → 每个 token 是独立对象
  → 可以独立转让和组合
  → 比 Position 更接近「代币」的心智模型

缺点:
  → 对象碎片化严重（每次交易可能创建新对象）
  → Merge 需要收集多个 OutcomeToken 对象
  → Gas 成本较高

适用: 需要粒度控制但不想部署 OTW 的中间方案
```

## 为什么教学代码选择方案 B

```
教学目标优先级:
  1. 概念清晰 — Position 的 yes/no 字段直观
  2. 实现简单 — 不需要额外的代币模块
  3. 不变量可验证 — yes/no 同增同减，容易测试
  4. 聚焦机制 — 读者注意力放在 LMSR 和 CTF 逻辑上

不需要关注的:
  → 二级市场交易（本章不涉及）
  → 跨协议组合（不是本章重点）
  → Gas 优化（教学不考虑）

如果读者想升级到方案 A:
  参考第 9 章 CDP 的代币发行模式
  → create_currency + TreasuryCap 的完整流程
```

## LMSR 状态 vs Position 余额

教学代码中这两组数据是**分开的**，这是一个刻意的设计选择：

```
Market.q_yes / Market.q_no:
  → LMSR 做市状态
  → 决定当前报价
  → buy/sell 时更新

Position.yes / Position.no:
  → 用户的条件代币余额
  → split/merge 时更新
  → claim 时用于赎回

它们的关系:
  q_yes 增加 → 有人通过 LMSR 买了 YES → 但 Position.yes 不自动变
  Position.yes 增加 → 有人做了 Split → 但 q_yes 不变

组合使用（如果需要）:
  在同一 PTB 中: buy_yes + split → 既更新 LMSR 又记入 Position
  或者: 修改 buy_internal 让它直接更新 Position
  → 这是产品层选择，不是协议层限制
```

## 扩展：Position 转让

```move
// 教学代码中 Position has store → 可以 public_transfer
// 用户可以把整个 Position 转给其他人

// 使用:
transfer::public_transfer(my_position, recipient);

// 效果:
// recipient 获得 Position 的完整所有权
// 可以用它 merge 或 claim

// 限制:
// 不能只转让 YES 不转让 NO（因为 yes/no 在同一对象中）
// → 如果需要独立转让，需要方案 A 或 C
```

## 自检

1. 如果一个用户通过 LMSR `buy_yes` 买了 100 份，但他没有 Position 或 Position 中 yes=0，他结算时能赎回吗？（答：不能，因为 `claim` 检查的是 `Position.yes`，不是 `Market.q_yes`）
2. 设计题：如何修改 `buy_internal` 使得买入时自动增加 `Position.yes`？需要什么额外参数？
