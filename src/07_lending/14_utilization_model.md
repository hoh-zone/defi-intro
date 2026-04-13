# 7.14 利用率模型（Utilization）

利用率是连接供需与利率的核心指标。本节分析它的定义和经济含义。

## 定义

```
利用率 U = Total Borrow / Total Supply

Total Supply = Total Borrow + Available Liquidity

因此:
  U = Borrow / Supply = Borrow / (Borrow + Available)

含义:
  U = 0%:  没有人借款，资金闲置
  U = 50%: 一半资金被借出
  U = 80%: 80% 的资金被借出（行业拐点）
  U = 100%: 所有资金被借出（无法取款！）
```

## 数值示例

```
场景: USDC 借贷池

LP 存入: 1,000,000 USDC
借款人借出: 600,000 USDC
可用流动性: 400,000 USDC

U = 600,000 / 1,000,000 = 60%

不同利用率状态:
  U = 30%: 资金闲置多，利率低 → 鼓励借款
  U = 60%: 平衡状态，利率适中
  U = 85%: 资金紧张，利率升高 → 抑制借款
  U = 95%: 非常紧张，利率很高 → 鼓励还款
  U = 100%: 无流动性，存款人无法取款 → 危险！
```

## 利用率如何驱动利率

```
利率是利用率的函数: rate = f(U)

理想行为:
  U 低 → rate 低（鼓励借款，提高利用率）
  U 高 → rate 高（抑制借款，保护流动性）

为什么 U=100% 是危险的:
  → 存款人无法取回资金
  → 借款人没有动力还款（利率已经很高了）
  → 可能导致银行挤兑

利率模型的目标:
  → 在 U < kink 时: 利率温和增长
  → 在 U > kink 时: 利率急剧增长
  → 防止 U 接近 100%
```

## 利用率的变化因素

```
利用率上升:
  → 新的借款（Borrow ↑）
  → 存款人取款（Supply ↓）
  → 两者叠加

利用率下降:
  → 借款人还款（Borrow ↓）
  → 新存款人存入（Supply ↑）
  → 两者叠加

时间维度:
  利率变化 → 行为变化 → 利用率变化
  → 高利率 → 鼓励还款 + 吸引存款 → U 下降
  → 低利率 → 鼓励借款 → U 上升
  → 自我调节的市场机制
```

## 在 lending_market 中的计算

```move
public fun calculate_interest_rate<Collateral, Borrow>(
    market: &Market<Collateral, Borrow>,
): u64 {
    let total_supply = balance::value(&market.collateral_vault);
    if (total_supply == 0) {
        return market.base_rate_bps
    };

    let total_borrow = market.total_borrow;
    let utilization_bps = total_borrow * BPS_BASE / total_supply;

    // ... 根据 utilization_bps 计算利率
}
```

```
注意这里的 total_supply:
  → 用 collateral_vault 的余额作为 total_supply
  → 实际上应该是 collateral + borrow_vault

  更准确的计算:
  total_supply = collateral_vault + borrow_vault（简化为只用 collateral）
  → 在教学代码中足够说明概念

BPS 精度:
  utilization_bps = total_borrow × 10000 / total_supply
  → 用基点（BPS）避免浮点数
  → 6000 bps = 60%
```

## 利用率与存款人收益

```
存款人视角:
  supply_rate = U × borrow_rate × (1 - reserve_factor)

  U=0%:  supply_rate = 0%（没人借钱，没收益）
  U=50%: supply_rate = 50% × borrow_rate × 0.9
  U=80%: supply_rate = 80% × borrow_rate × 0.9
  U=100%: supply_rate = 100% × borrow_rate × 0.9（但取不出钱）

  存款人的困境:
    → 高利用率 = 高收益 = 高风险（流动性不足）
    → 低利用率 = 低收益 = 低风险
    → 需要利率模型自动平衡
```

## 利用率的监控指标

```
健康范围: U = 40%-80%
  → 存款人有合理收益
  → 借款人有充足流动性
  → 利率在合理区间

警告范围: U = 80%-95%
  → 利率开始急剧上升
  → 存款人可能无法取款
  → 需要监控

危险范围: U > 95%
  → 极高的借款利率
  → 存款人几乎无法取款
  → 可能需要紧急注入流动性
```

## 总结

```
利用率 U = Borrow / Supply
  → 衡量资金使用效率
  → 驱动利率变化
  → 是借贷协议的"供需晴雨表"

关键洞察:
  U 低 → 利率低 → 鼓励借款 → U 上升
  U 高 → 利率高 → 鼓励还款 → U 下降
  → 自动调节的市场机制
```
