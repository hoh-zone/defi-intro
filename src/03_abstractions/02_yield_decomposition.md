# 3.2 收益拆解：APR、APY 与真实收益

## APR 与 APY 的区别

**APR（Annual Percentage Rate）**：年化收益率，不计复利。

$$APR = \frac{\text{单期收益}}{\text{本金}} \times \text{每年期数}$$

**APY（Annual Percentage Yield）**：年化收益率，计入复利。

$$APY = \left(1 + \frac{r}{n}\right)^n - 1$$

其中 $r$ 是单期利率，$n$ 是每年的复利次数。

当复利频率越高，APY 越大于 APR。在 DeFi 中，很多协议每区块（甚至每秒）都在复利，APY 可以远高于 APR。

### Move 实现

```move
module yield_math;
    const EPSILON: u64 = 1_000_000;

    public fun calculate_apr(
        period_yield: u64,
        principal: u64,
        periods_per_year: u64,
    ): u64 {
        let annual_yield = (period_yield as u128)
            * (periods_per_year as u128)
            / (principal as u128);
        (annual_yield * 10000 / EPSILON) as u64
    }

    public fun calculate_apy(
        period_rate_bps: u64,
        periods_per_year: u64,
    ): u64 {
        let r = period_rate_bps as u128;
        let n = periods_per_year as u128;
        let one = 10000u128;
        let compounded = one + r / n;
        let result = one;
        let mut i = 0u64;
        while (i < n as u64) {
            result = result * compounded / one;
            i = i + 1;
        };
        ((result - one) * 100) as u64
    }
```

## 收益的三层构成

DeFi 协议展示的"总收益"通常是三层之和：

### 第一层：手续费收益

来自协议真实的经济活动。DEX 的 swap 手续费、借贷的利差、清算的罚金。这一层反映协议是否创造了真实价值。

### 第二层：激励收益

来自代币排放。协议用原生代币奖励用户，吸引流动性。这一层依赖代币是否有实际价值——如果代币无人购买，激励就是纸上富贵。

### 第三层：补贴收益

来自项目方或投资人的预算。"前 60 天三倍收益"、"存入即空投"等。这一层有明确的到期时间，到期后收益断崖式下降。

### 如何拆解

```move
public struct YieldBreakdown has copy, drop, store {
    fee_apy_bps: u64,
    incentive_apy_bps: u64,
    subsidy_apy_bps: u64,
    subsidy_ends_at: u64,
}

public fun real_apy(yb: &YieldBreakdown): u64 {
    yb.fee_apy_bps + yb.incentive_apy_bps
}

public fun total_apy(yb: &YieldBreakdown): u64 {
    yb.fee_apy_bps + yb.incentive_apy_bps + yb.subsidy_apy_bps
}
```

关键判断：`real_apy` 才是协议长期可持续的收益率。`total_apy` 只在补贴期内有效。

## 为什么"高 APY"不构成信息

一个协议展示"APY 200%"时，你应该立刻问三个问题：

1. **这个 APY 的计算基数是什么？** 如果基数是代币价格，当代币价格下跌 90%，你的实际收益可能是负的。
2. **收益构成是什么？** 如果 95% 来自代币排放，你需要评估代币的卖出压力。
3. **复利频率是多少？** APR 100% 按秒复利后显示为 APY 172%，但实际到手取决于你多久复利一次。

```move
public fun is_sustainable(yb: &YieldBreakdown): bool {
    let fee_share = yb.fee_apy_bps * 100
        / (yb.fee_apy_bps + yb.incentive_apy_bps + yb.subsidy_apy_bps + 1);
    fee_share > 30
}
```

如果手续费收益占比低于 30%，这个 APY 的高位数大概率不可持续。
