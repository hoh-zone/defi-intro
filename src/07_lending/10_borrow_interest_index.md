# 7.10 借款利息累积（Debt Index）

完整的借贷协议需要两套独立的利息指数：Supply Index 和 Borrow Index。本节分析它们的关系。

## 两套指数

```
Supply Index:
  追踪存款的价值增长
  supply_index: 初始 1.0，随时间增长
  存款人余额 = deposit_shares × supply_index

Borrow Index:
  追踪债务的增长
  borrow_index: 初始 1.0，随时间增长
  借款人债务 = debt_shares × borrow_index

为什么需要两套:
  → 存款利率 ≠ 借款利率
  → 存款利率 < 借款利率（差额是协议收入）
  → 两套指数以不同速率增长
```

## 利率关系

```
利用率: U = total_borrow / total_supply

借款利率: borrow_rate = f(U)
  → 由利率模型计算（下一章详述）
  → 借款人支付的利率

存款利率: supply_rate = U × borrow_rate × (1 - reserve_factor)
  → 由借款利率推导
  → 存款人获得的利率

储备因子: reserve_factor（如 10%）
  → 协议保留的收入比例
  → 用于覆盖坏账、协议运营

示例:
  U = 80%, borrow_rate = 5%, reserve_factor = 10%
  supply_rate = 0.80 × 5% × (1 - 0.10) = 3.6%

  借款人支付 5%
  存款人获得 3.6%
  协议保留 0.4%（= 5% × 80% × 10%）
  差额 1.0% 是存借款利率差（不是协议收入，是数学上的差）
```

## 指数增长对比

```
初始:
  supply_index = 1.000000
  borrow_index = 1.000000
  total_supply = 10000 USDC
  total_borrow = 8000 USDC
  U = 80%

利率（假设固定）:
  borrow_rate = 5%
  supply_rate = 3.6%

30 天后:
  supply_index = 1.0 × (1 + 3.6% × 30/365) = 1.002960
  borrow_index = 1.0 × (1 + 5.0% × 30/365) = 1.004110

  存款人: 10000 × 1.002960 = 10029.60 (+29.60)
  借款人: 8000 × 1.004110 = 8032.88 (+32.88)

  协议储备: 10000 × 1.002960 + 协议收入 = total_assets
  总资产 = 存款 + 债务利息 - 借款人增长

90 天后:
  supply_index ≈ 1.008876
  borrow_index ≈ 1.012329

  存款人: 10088.76 (+88.76)
  借款人: 8098.63 (+98.63)
```

## 系统恒等式

```
在任何时刻:

total_assets = total_supply × supply_index
total_debt   = total_borrow × borrow_index

协议偿付能力:
  total_assets ≥ total_debt（每个借款人都有超额抵押）

个别用户:
  user_collateral × price × collateral_factor ≥ user_debt × price

利息流动:
  借款人支付: debt × borrow_rate × dt
  存款人获得: deposit × supply_rate × dt
  协议保留:   debt × borrow_rate × reserve_factor × dt

  supply_rate = U × borrow_rate × (1 - reserve_factor)
  → 确保: 总支付 ≥ 总获得 + 协议保留
```

## Move 中的实现模式

```move
// 生产级双 Index 设计
public struct InterestState has store {
    supply_index: u64,          // 存款指数
    borrow_index: u64,          // 借款指数
    last_update: u64,           // 上次更新时间戳
    reserve_factor_bps: u64,    // 储备因子
}

public fun update_indices(
    state: &mut InterestState,
    borrow_rate_bps: u64,
    now: u64,
) {
    let dt = now - state.last_update;
    if (dt == 0) return;

    let SECONDS_PER_YEAR: u128 = 31536000;
    let PRECISION: u128 = 1000000000000000000;

    // Borrow Index 增长
    let borrow_factor = PRECISION
        + (borrow_rate_bps as u128) * (dt as u128) * PRECISION
          / (SECONDS_PER_YEAR as u128) / 10000;
    state.borrow_index = ((state.borrow_index as u128) * borrow_factor / PRECISION) as u64;

    // Supply Index = borrow_rate × utilization × (1 - reserve_factor)
    // supply_rate = borrow_rate × U × (1 - reserve_factor)
    // 这里简化，实际需要计算 utilization
    // ...

    state.last_update = now;
}
```

## 为什么 Borrow Index 增长更快

```
根本原因:
  supply_rate < borrow_rate（对存款人来说，利率是"批发价"）
  borrow_rate 是"零售价"

  spread = borrow_rate - supply_rate
  = borrow_rate × (1 - U × (1 - reserve_factor))
  = borrow_rate × (1 - U + U × reserve_factor)

当 U = 80%, reserve_factor = 10%:
  spread = borrow_rate × (1 - 0.80 + 0.08) = borrow_rate × 0.28

  borrow_rate = 5%:
  spread = 1.4%
  supply_rate = 3.6%

这个 spread 确保协议有收入来源
```

## 与 lending_market 的关系

```
lending_market 的简化:
  → 不实现动态利息累积
  → calculate_interest_rate 只计算当前利率
  → 不追踪 supply_index 和 borrow_index
  → 用于教学利率模型的数学

如果加入利息累积:
  需要修改 Market 结构体:
  + supply_index: u64
  + borrow_index: u64
  + last_update_timestamp: u64
  + reserve_factor_bps: u64

  每次操作前调用 update_indices()
```

## 总结

```
双 Index 系统:
  Supply Index → 追踪存款价值增长
  Borrow Index → 追踪债务增长
  Borrow Index 增长 > Supply Index

利率关系:
  supply_rate = utilization × borrow_rate × (1 - reserve_factor)
  spread = 协议收入来源

恒等式:
  总存款 × supply_index = 总资产
  总借款 × borrow_index = 总债务
  总资产 > 总债务（偿付能力保证）
```
