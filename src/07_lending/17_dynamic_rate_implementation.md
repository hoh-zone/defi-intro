# 7.17 Move 实现动态利率模型

本节逐行分析 lending_market 中的利率计算实现。

## calculate_interest_rate 完整代码

```move
public fun calculate_interest_rate<Collateral, Borrow>(
    market: &Market<Collateral, Borrow>,
): u64 {
    let total_supply = balance::value(&market.collateral_vault);
    if (total_supply == 0) {
        return market.base_rate_bps
    };

    let total_borrow = market.total_borrow;
    // utilization in bps = total_borrow * BPS_BASE / total_supply
    let utilization_bps = total_borrow * BPS_BASE / total_supply;

    if (utilization_bps <= market.kink_bps) {
        // rate = base_rate + (utilization * multiplier) / BPS_BASE
        market.base_rate_bps + (utilization_bps * market.multiplier_bps) / BPS_BASE
    } else {
        // rate = base_rate + (kink * multiplier) / BPS_BASE
        //      + ((utilization - kink) * multiplier * jump_multiplier) / (BPS_BASE * BPS_BASE)
        let rate_at_kink = market.base_rate_bps
            + (market.kink_bps * market.multiplier_bps) / BPS_BASE;
        let excess_utilization = utilization_bps - market.kink_bps;
        let jump_rate = excess_utilization * market.multiplier_bps
            * market.jump_multiplier_bps / (BPS_BASE * BPS_BASE);
        rate_at_kink + jump_rate
    }
}
```

## BPS 计算详解

```
为什么用 BPS:
  Move 没有浮点数 → 用整数 × 精度因子

  1% = 100 bps (basis points)
  100% = 10000 bps

  利用率 BPS: U_bps = total_borrow × 10000 / total_supply
  利率 BPS:   rate_bps = 结果（除以 10000 得百分比）

精度问题:
  整数除法会截断 → 有精度损失
  → 对借贷协议来说可接受（误差 < 0.01%）
  → 生产级用更高精度（如 10^18 或 10^27）
```

## 数值验证

### U = 0%（无借款）

```
utilization_bps = 0 × 10000 / total_supply = 0

分支: utilization_bps (0) <= kink_bps (8000) → True
rate = base_rate_bps + 0 = 200 bps = 2.0% ✅
```

### U = 50%

```
utilization_bps = 50 × 10000 / 100 = 5000

分支: 5000 <= 8000 → True
rate = 200 + (5000 × 1000) / 10000
     = 200 + 500 = 700 bps = 7.0% ✅
```

### U = 80%（拐点）

```
utilization_bps = 80 × 10000 / 100 = 8000

分支: 8000 <= 8000 → True（边界情况，走第一个分支）
rate = 200 + (8000 × 1000) / 10000
     = 200 + 800 = 1000 bps = 10.0% ✅
```

### U = 90%（超过拐点）

```
utilization_bps = 90 × 10000 / 100 = 9000

分支: 9000 > 8000 → False（走跳跃分支）

rate_at_kink = 200 + (8000 × 1000) / 10000 = 1000
excess = 9000 - 8000 = 1000
jump_rate = 1000 × 1000 × 5000 / (10000 × 10000)
          = 5000000000 / 100000000 = 50
rate = 1000 + 50 = 1050 bps = 10.5% ✅
```

## 测试验证

```
// 来自 market_test.move 的利率测试

test_interest_calculation:
  设置参数: base=200, kink=8000, mult=1000, jump=5000

  U=0%:  rate = 200 bps ✅
  U=50%: rate = 700 bps ✅
  U=80%: rate = 1000 bps ✅
  U=90%: rate = 1050 bps ✅
```

## Supply Rate 计算

```
lending_market 只计算 borrow_rate
supply_rate 由 borrow_rate 推导:

supply_rate = U × borrow_rate × (1 - reserve_factor)

示例:
  U = 80%, borrow_rate = 10%, reserve_factor = 10%
  supply_rate = 0.80 × 10% × 0.90 = 7.2%

  借款人支付: 10%
  存款人获得: 7.2%
  协议保留: 80% × 10% × 10% = 0.8%
  总收入: 10% × 80% = 8%（来自被借出的 80%）
  其中: 7.2% 给存款人, 0.8% 给协议

Move 实现:
  fun supply_rate(
      utilization_bps: u64,
      borrow_rate_bps: u64,
      reserve_factor_bps: u64,
  ): u64 {
      utilization_bps * borrow_rate_bps * (10000 - reserve_factor_bps)
          / (10000 * 10000)
  }
```

## 溢出安全分析

```
潜在溢出:
  excess_utilization × multiplier × jump
  = 2000 × 1000 × 5000 = 10,000,000,000

  u64 max = 18,446,744,073,709,551,615
  → 不会溢出 ✅

  除以 10000 × 10000 = 100,000,000
  结果 = 100 bps

极端情况:
  utilization = 10000, kink = 1000, multiplier = 50000, jump = 10000
  excess × mult × jump = 9000 × 50000 × 10000 = 4,500,000,000,000

  仍在 u64 范围内 ✅

  但如果参数不合理，可能溢出:
  → 生产级代码需要检查参数范围
  → 或使用 u128 中间计算
```

## 总结

```
lending_market 的利率模型实现:
  1. 计算利用率（BPS）
  2. 两个分支: ≤ kink 和 > kink
  3. 整数运算避免浮点
  4. BPS 精度（1 bps = 0.01%）

关键公式:
  U ≤ kink: rate = base + U × mult / 10000
  U > kink: rate = base + kink × mult / 10000
            + (U - kink) × mult × jump / 10000^2
```
