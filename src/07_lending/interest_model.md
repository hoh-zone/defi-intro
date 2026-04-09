# 6.4 利率模型与资金利用率

## 核心概念

借贷市场的利率不是固定的。它随资金的供需关系动态变化。

**资金利用率（Utilization Rate）** 是驱动利率的核心变量：

$$U = \frac{\text{Total Borrows}}{\text{Total Deposits}}$$

当 U 很低时（没人借钱），利率应该低，鼓励借款。
当 U 很高时（快没钱了），利率应该高，抑制借款、鼓励存款。

## 拐点利率模型（Kinked Rate Model）

最常用的利率模型是分段线性模型——在某个"最优利用率"处有一个拐点（kink）：

```
利率
  |              /
  |             / slope2（陡峭）
  |            /
  |           / ← kink（拐点）
  |          /
  |         / slope1（平缓）
  |        /
  |_______/________________ 利用率
  0      U_optimal        1
```

- 拐点前：利率平缓上升，借款成本可预测
- 拐点后：利率急速上升，惩罚性地抑制借款，保护流动性

### 公式

$$r = \begin{cases} r_0 + U \cdot s_1 & \text{if } U \leq U_{opt} \\ r_0 + U_{opt} \cdot s_1 + (U - U_{opt}) \cdot s_2 & \text{if } U > U_{opt} \end{cases}$$

其中：
- $r_0$ = 基础利率（Base Rate）
- $s_1$ = 拐点前斜率（Slope 1）
- $s_2$ = 拐点后斜率（Slope 2）
- $U_{opt}$ = 最优利用率

### Move 实现

```move
module interest_model {
    const BPS: u64 = 10000;

    struct InterestModel has store {
        base_rate_bps: u64,
        slope1_bps: u64,
        slope2_bps: u64,
        optimal_utilization_bps: u64,
    }

    public fun calculate_borrow_rate(
        model: &InterestModel,
        total_borrows: u64,
        total_deposits: u64,
    ): u64 {
        if (total_deposits == 0) { return model.base_rate_bps };
        let utilization = total_borrows * BPS / total_deposits;
        if (utilization <= model.optimal_utilization_bps) {
            model.base_rate_bps
                + utilization * model.slope1_bps / model.optimal_utilization_bps
        } else {
            let excess = utilization - model.optimal_utilization_bps;
            let remaining = BPS - model.optimal_utilization_bps;
            model.base_rate_bps
                + model.slope1_bps
                + excess * model.slope2_bps / remaining
        }
    }

    public fun calculate_supply_rate(
        model: &InterestModel,
        total_borrows: u64,
        total_deposits: u64,
        reserve_factor_bps: u64,
    ): u64 {
        let borrow_rate = calculate_borrow_rate(model, total_borrows, total_deposits);
        let utilization = total_borrows * BPS / total_deposits;
        borrow_rate * utilization / BPS * (BPS - reserve_factor_bps) / BPS
    }
}
```

## 数值示例

参数：
- base_rate = 2%（200 bps）
- slope1 = 4%（400 bps）
- slope2 = 75%（7500 bps）
- optimal_utilization = 80%（8000 bps）
- reserve_factor = 10%（1000 bps）

| 利用率 | 借款利率 | 存款利率 |
|--------|----------|----------|
| 0% | 2.0% | 0.0% |
| 20% | 3.0% | 0.54% |
| 40% | 4.0% | 1.44% |
| 60% | 5.0% | 2.70% |
| 80% | 6.0% | 4.32% |
| 85% | 9.75% | 7.47% |
| 90% | 13.5% | 10.94% |
| 95% | 17.25% | 14.77% |
| 100% | 21.0% | 18.9% |

关键观察：
- 80% 以下，利率变化温和（2% → 6%）
- 超过 80% 后，利率急速上升（6% → 21%）
- 这保护了存款人——当资金快被借完时，高利率吸引存款、抑制借款

## 存款利率公式

$$r_{supply} = r_{borrow} \times U \times (1 - f_{reserve})$$

其中 $f_{reserve}$ 是协议储备金比例。协议从借款利息中抽取一部分作为储备金，用于覆盖坏账。
