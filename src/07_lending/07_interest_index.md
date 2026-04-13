# 7.7 利息累积指数（Interest Index）

当协议有数千个存款人时，如何高效地为所有人计算利息？Interest Index 是解决方案。

## 问题：逐账户更新太昂贵

```
朴素方案:
  每个区块（或每次操作），遍历所有存款人
  对每个账户: balance += balance × rate × dt

  问题:
  → 10000 个存款人 → 10000 次状态更新
  → Gas 成本 O(n)
  → 不可扩展

Interest Index 方案:
  维护一个全局 Index，每个账户记录 deposit_shares
  利息累积只更新 Index（O(1)）
  账户余额 = deposit_shares × current_index

  → 不管多少存款人，都是 O(1)
```

## Index 工作原理

```
初始状态:
  index = 1.0 × 10^27 (用整数模拟浮点)
  = 1,000,000,000,000,000,000,000,000,000

  Alice 存入 1000 SUI:
  normalized_balance = 1000 × 10^27 / index
                     = 1000 × 10^27 / 10^27
                     = 1000（存储的值）

  Alice 的实际余额 = 1000 × index / 10^27 = 1000 SUI

利率 5%，经过一年:
  index = 1.0 × (1 + 0.05) = 1.05 × 10^27

  Alice 的实际余额 = 1000 × 1.05 × 10^27 / 10^27
                   = 1050 SUI ✅

Bob 在一年后存入 1000 SUI:
  normalized_balance = 1000 × 10^27 / (1.05 × 10^27)
                     = 952.38

  Bob 的实际余额 = 952.38 × 1.05 × 10^27 / 10^27
                 = 1000 SUI ✅
```

## Index 更新公式

```
每次利息累积:
  newIndex = oldIndex × (1 + rate × timeDelta)

其中:
  rate: 年化利率
  timeDelta: 距上次更新的时间（以年为单位）

在区块级别:
  timeDelta = blocks_since_last / blocks_per_year

示例（利率 5%，10 秒间隔）:
  timeDelta = 10 / (365 × 24 × 3600) ≈ 3.17 × 10^-7
  factor = 1 + 0.05 × 3.17 × 10^-7 = 1.0000000158

  newIndex = oldIndex × 1.0000000158

使用 u128 避免溢出:
  index_value (u64): 10^27 精度
  rate × timeDelta 用 u128 计算
  最后截断回 u64
```

## 多周期累积示例

```
初始: index = 1.000000

周期 1（利率 4%/年，30天）:
  factor = 1 + 0.04 × 30/365 = 1.003288
  index = 1.000000 × 1.003288 = 1.003288

周期 2（利率 5%/年，30天）:
  factor = 1 + 0.05 × 30/365 = 1.004110
  index = 1.003288 × 1.004110 = 1.007414

周期 3（利率 6%/年，30天）:
  factor = 1 + 0.06 × 30/365 = 1.004932
  index = 1.007414 × 1.004932 = 1.012378

Alice 存入 10000 SUI（index=1.0时）:
  当前价值 = 10000 × 1.012378 / 1.0 = 10123.78 SUI
  收益: 123.78 SUI（约 1.24%，90天）
```

## Index 的优势

```
1. O(1) 更新成本
   → 每次操作只更新 index，不遍历账户
   → 不管有多少存款人

2. 精确的利息分配
   → 每个存款人按存款时间获得利息
   → 晚存款的人不会"占便宜"

3. 简洁的状态
   → 每个账户只存储 normalized_balance
   → 全局只存储一个 index

4. 可组合
   → Index 可以被其他合约读取
   → 用于计算存款价值、作为预言机数据源
```

## 与 sui_savings 的关系

```
sui_savings 使用简化版的 Index:
  exchange_rate = balance::value(&pool.principal) / pool.total_shares

  → 不是时间驱动的，而是操作驱动的
  → 利息通过管理员手动添加 reward_pool
  → principal 中的资金增长反映在汇率中

  本质相同: shares × exchange_rate = 实际价值

生产级 Index（如 Compound/Aave）:
  → 时间驱动的自动累积
  → supply_index 和 borrow_index 分别追踪
  → 每次操作时计算 timeDelta 并更新 index
```

## Move 实现模式

```move
// 生产级 Interest Index 的 Move 设计
public struct InterestState has store {
    index: u64,           // 当前累积指数（10^27 精度）
    last_update_timestamp: u64,  // 上次更新时间
    rate: u64,            // 当前年化利率（bps）
}

public fun accumulate_interest(state: &mut InterestState, now: u64) {
    let time_delta = now - state.last_update_timestamp;
    if (time_delta == 0) return;

    // 计算利息因子: factor = 1 + rate × timeDelta
    let SECONDS_PER_YEAR: u64 = 31536000;
    let PRECISION: u128 = 1000000000000000000; // 10^18

    let factor = (PRECISION
        + (state.rate as u128) * (time_delta as u128)
          * PRECISION / (SECONDS_PER_YEAR as u128) / 10000);

    state.index = ((state.index as u128) * factor / PRECISION) as u64;
    state.last_update_timestamp = now;
}
```

## 总结

```
Interest Index 核心思想:
  全局维护一个递增的 Index
  每个账户存储 normalized_balance
  实际余额 = normalized_balance × index / precision

关键公式:
  newIndex = oldIndex × (1 + rate × deltaTime)
  balance = normalized_balance × index / initial_index

这是所有主流借贷协议（Aave, Compound）的基础架构
```
