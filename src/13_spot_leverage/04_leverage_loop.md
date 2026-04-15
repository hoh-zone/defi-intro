# 13.4 循环借贷与杠杆螺旋

## 什么是循环借贷

循环借贷（Leverage Loop）是通过反复"存入 → 借出 → 买入 → 存入"来放大杠杆的过程。

## 单次循环

```
初始资本: 1000 SUI ($2000)
存入 → 借出 1500 USDC (75% LTV) → 买入 750 SUI → 持有 1750 SUI
杠杆: 1.75x
```

## 多次循环

```
循环 0: 存入 1000 SUI ($2000)
循环 1: 借 1500 USDC → 买 750 SUI → 存入 → 总持有 1750 SUI
循环 2: 借 1125 USDC → 买 562 SUI → 存入 → 总持有 2312 SUI
循环 3: 借 844 USDC → 买 422 SUI → 存入 → 总持有 2734 SUI
循环 4: 借 633 USDC → 买 316 SUI → 存入 → 总持有 3050 SUI
...
收敛到 ~4x 杠杆（LTV=75% 的理论最大值）
```

## 数学极限

给定 LTV（贷款价值比），理论最大杠杆：

$$L_{max} = \frac{1}{1 - LTV}$$

| LTV | 最大杠杆 |
| --- | -------- |
| 50% | 2.0x     |
| 60% | 2.5x     |
| 70% | 3.33x    |
| 75% | 4.0x     |
| 80% | 5.0x     |
| 90% | 10.0x    |

## Move 实现：杠杆螺旋计算器

```move
module leverage_calculator;
    public fun calculate_loop_leverage(
        initial_capital: u64,
        ltv_bps: u64,
        max_loops: u64,
    ): (u64, u64, u64) {
        let mut total_position = initial_capital;
        let mut total_debt = 0u64;
        let mut i = 0;

        while (i < max_loops) {
            let max_borrow = total_position * ltv_bps / 10000;
            if (max_borrow == 0) { break };
            total_debt = total_debt + max_borrow;
            total_position = total_position + max_borrow;
            i = i + 1;
        };

        let leverage_bps = total_position * 10000 / initial_capital;
        (leverage_bps, total_position, total_debt)
    }

    public fun calculate_liquidation_price(
        total_position: u64,
        total_debt: u64,
        liquidation_threshold_bps: u64,
        current_price: u64,
    ): u64 {
        let collateral_needed = total_debt * 10000 / liquidation_threshold_bps;
        let price_drop_ratio = if (collateral_needed < total_position * current_price) {
            (total_position * current_price - collateral_needed) * 10000
                / (total_position * current_price)
        } else {
            0u64
        };
        current_price * price_drop_ratio / 10000
    }

    public fun calculate_net_apr(
        leverage_bps: u64,
        asset_apy_bps: u64,
        borrow_apr_bps: u64,
    ): u128 {
        let gross_yield = (leverage_bps as u128) * (asset_apy_bps as u128) / 10000;
        let borrow_cost = if (leverage_bps > 10000) {
            ((leverage_bps - 10000) as u128) * (borrow_apr_bps as u128) / 10000
        } else {
            0u128
        };
        if (gross_yield >= borrow_cost) {
            gross_yield - borrow_cost
        } else {
            0u128
        }
    }
```

## 杠杆螺旋的风险

### 1. 清算距离缩短

每次循环都让清算线更近：

```
1x 杠杆: SUI 需跌 100% 才归零
2x 杠杆: SUI 需跌 50%
3x 杠杆: SUI 需跌 33%
4x 杠杆: SUI 需跌 25%
```

### 2. 利率风险

借款利率是浮动的。如果利率飙升：

- 借款成本增加
- 净收益可能变为负数
- 如果利息超过收益，仓位持续亏损

### 3. 级联清算

```
SUI 下跌 → 所有杠杆仓位同时接近清算线
→ 大量清算同时发生
→ DEX 被 SUI 卖单淹没
→ SUI 进一步下跌
→ 更多清算
→ 恶性循环
```

## 安全的杠杆使用原则

1. **不要用最大杠杆**：留 20-30% 的安全缓冲
2. **监控借款利率**：设置利率上限告警
3. **设置止损**：在清算之前主动减仓
4. **分散风险**：不要把所有资金投入单一杠杆仓位
5. **了解清算机制**：清算不是"以市价卖出"，清算罚金是额外损失
