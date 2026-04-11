# 7.2 利率模型演进：从固定到动态

利率模型是借贷协议的"定价引擎"。它决定了借款人付多少利息、存款人赚多少收益。

## 第一代：固定利率

最简单的模型——利率不变，不随市场供需变化。

```move
public struct FixedRateModel has store {
    rate_bps: u64,
}

public fun calculate_rate(model: &FixedRateModel): u64 {
    model.rate_bps
}
```

问题：不管有没有人借钱，利率都一样。没人借时利率太高（白付利息），大家都来借时利率太低（钱不够分）。

## 第二代：线性利率

利率与利用率（Utilization）线性相关：

$$r = r_0 + U \cdot s$$

```move
public struct LinearModel has store {
    base_rate_bps: u64,
    slope_bps: u64,
}

public fun calculate_rate(model: &LinearModel, utilization_bps: u64): u64 {
    model.base_rate_bps + utilization_bps * model.slope_bps / 10000
}
```

问题：利用率 100% 时利率仍然不够高——没有惩罚性地抑制借款，池子容易被借空。

## 第三代：拐点利率模型（Kinked Model）

Aave 和 Compound 采用的模型。在最优利用率处有一个拐点，拐点后利率急速上升：

```
利率
  |              /
  |             / slope2（陡峭）
  |            /
  |           / ← kink（拐点，如 U=80%）
  |          /
  |         / slope1（平缓）
  |        /
  |_______/________________ 利用率
  0      U_opt
```

```move
public struct KinkedModel has store {
    base_rate_bps: u64,
    slope1_bps: u64,
    slope2_bps: u64,
    optimal_bps: u64,
}

public fun calculate_borrow_rate(
    model: &KinkedModel,
    total_borrows: u64,
    total_deposits: u64,
): u64 {
    if (total_deposits == 0) { return model.base_rate_bps };
    let u = total_borrows * 10000 / total_deposits;
    if (u <= model.optimal_bps) {
        model.base_rate_bps + u * model.slope1_bps / model.optimal_bps
    } else {
        let excess = u - model.optimal_bps;
        let remaining = 10000 - model.optimal_bps;
        model.base_rate_bps + model.slope1_bps + excess * model.slope2_bps / remaining
    }
}

public fun calculate_supply_rate(
    borrow_rate: u64,
    utilization_bps: u64,
    reserve_factor_bps: u64,
): u64 {
    borrow_rate * utilization_bps / 10000 * (10000 - reserve_factor_bps) / 10000
}
```

### 数值示例

参数：base=2%, slope1=4%, slope2=75%, U_opt=80%

| 利用率 | 借款利率 | 存款利率 |
|--------|----------|----------|
| 0% | 2.0% | 0% |
| 40% | 4.0% | 1.44% |
| 80% | 6.0% | 4.32% |
| 85% | 9.75% | 7.47% |
| 90% | 13.5% | 10.94% |
| 100% | 21.0% | 18.9% |

拐点后利率急速上升，保护流动性不被借空。

## 第四代：动态利率（Dynamic Rate）

Aave V3 引入。利率不是实时固定的，而是在一个目标利用率附近波动：

- 利用率低于目标 → 降低利率，鼓励借款
- 利用率高于目标 → 提高利率，抑制借款

```move
public struct DynamicModel has store {
    base_rate_bps: u64,
    slope1_bps: u64,
    slope2_bps: u64,
    optimal_bps: u64,
    target_bps: u64,
    adjustment_speed_bps: u64,
    current_rate_bps: u64,
}

public fun update_dynamic_rate(
    model: &mut DynamicModel,
    utilization_bps: u64,
): u64 {
    let ideal_rate = if (utilization_bps <= model.optimal_bps) {
        model.base_rate_bps + utilization_bps * model.slope1_bps / model.optimal_bps
    } else {
        let excess = utilization_bps - model.optimal_bps;
        let remaining = 10000 - model.optimal_bps;
        model.base_rate_bps + model.slope1_bps + excess * model.slope2_bps / remaining
    };
    let diff = if (ideal_rate > model.current_rate_bps) {
        ideal_rate - model.current_rate_bps
    } else {
        model.current_rate_bps - ideal_rate
    };
    let speed = diff * model.adjustment_speed_bps / 10000;
    if (ideal_rate > model.current_rate_bps) {
        model.current_rate_bps = model.current_rate_bps + speed;
    } else {
        model.current_rate_bps = model.current_rate_bps - speed;
    };
    model.current_rate_bps
}
```

## 四代对比

| 模型 | 利率变化 | 优点 | 缺点 | 代表 |
|------|----------|------|------|------|
| 固定 | 不变 | 简单可预测 | 不反映供需 | 早期协议 |
| 线性 | 平滑 | 有供需响应 | 高利用率保护不足 | 早期 DAI |
| 拐点 | 分段 | 保护流动性 | 参数需要人工调优 | Aave V2, Compound V2 |
| 动态 | 渐进 | 减少利率跳跃 | 实现复杂 | Aave V3+ |
