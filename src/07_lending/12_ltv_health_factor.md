# 7.12 LTV 与 Health Factor

LTV 和 Health Factor 是借贷协议最关键的风险指标。本节详细推导公式并用数值示例说明。

## LTV（Loan-To-Value）

```
定义:
  LTV = 借款价值 / 抵押品价值

含义:
  你借了多少钱，占抵押品价值的多少比例

示例:
  抵押 1000 SUI（价值 $2000）
  借出 1200 USDC

  LTV = 1200 / 2000 = 60%

LTV 的安全范围:
  0%       → 没有借款，完全安全
  60%      → 安全，有充足缓冲
  75%      → 达到抵押因子上限（不能再借）
  80%      → 达到清算阈值（可以被清算）
  100%     → 无抵押状态（非常危险）
  >100%    → 资不抵债（坏账）
```

## 两个关键阈值

```
Collateral Factor（抵押因子）:
  最大允许的 LTV（借款时的限制）
  例: 75% → 最多借抵押品价值的 75%

Liquidation Threshold（清算阈值）:
  触发清算的 LTV
  例: 80% → LTV 超过 80% 时可被清算

安全缓冲 = 清算阈值 - 抵押因子
  = 80% - 75% = 5%

为什么需要缓冲:
  → 价格可能在区块间大幅波动
  → 清算需要时间执行
  → 5% 的缓冲给清算人反应时间
```

## Health Factor 公式

```
Health Factor (HF) = 抵押品价值 × 清算阈值 / 借款价值

用 BPS 表示:
  HF = collateral_value × liquidation_threshold_bps / debt_value

判断标准:
  HF > 1.0 (> 10000 bps) → 安全
  HF = 1.0 (= 10000 bps) → 边缘
  HF < 1.0 (< 10000 bps) → 可清算

注意:
  计算借款限制时用 collateral_factor
  计算清算条件时用 liquidation_threshold
  这是两个不同的参数！
```

## lending_market 的实现

```move
public fun health_factor(
    collateral_value: u64,
    debt_value: u64,
    factor_bps: u64,
): HealthFactor {
    if (debt_value == 0) {
        return HealthFactor { value_bps: 0xFFFFFFFFFFFFFFFF }
    };
    HealthFactor {
        value_bps: collateral_value * factor_bps / debt_value,
    }
}
```

```
实现要点:
  → debt_value == 0 时返回最大值（完全安全）
  → 使用 u64 乘法（collateral × factor）避免溢出
  → BPS 精度（10000 = 100%）
  → 返回 HealthFactor 包装类型（可读性好）
```

## 数值示例

### 场景 1: 安全借款

```
Alice 存入 1000 SUI 作为抵押（假设 1 SUI = $2）
借款 1200 USDC
liquidation_threshold = 80%

HF = 1000 × 2 × 8000 / 1200 = 13333 bps = 1.33

HF > 1.0 → 安全 ✅
可以承受 SUI 价格下跌到: 1200 / (1000 × 0.80) = $1.50
→ SUI 需要跌 25% 才会被清算
```

### 场景 2: 接近清算

```
Bob 存入 500 SUI（$1000）
借款 750 USDC
liquidation_threshold = 80%

HF = 500 × 2 × 8000 / 750 = 10667 bps = 1.07

HF > 1.0 但接近 1.0 → 危险 ⚠️
SUI 只需跌到 $750 / (500 × 0.80) = $1.875
→ SUI 跌 6.25% 就会被清算
```

### 场景 3: 被清算

```
SUI 价格跌到 $1.50
Bob 的抵押品价值 = 500 × 1.50 = $750
债务 = 750 USDC

HF = 500 × 1.50 × 8000 / 750 = 8000 bps = 0.80

HF < 1.0 → 可清算 ❌
清算人可以替 Bob 还债并没收抵押品
```

## 价格与 HF 的关系

```
假设:
  collateral = 1000 SUI, debt = 1200 USDC
  liquidation_threshold = 80%

  SUI 价格   │ 抵押品价值 │  HF     │ 状态
  ───────────┼────────────┼────────┼────────
  $2.50      │ $2500      │ 1.67   │ 安全
  $2.00      │ $2000      │ 1.33   │ 安全
  $1.75      │ $1750      │ 1.17   │ 安全
  $1.50      │ $1500      │ 1.00   │ 边缘
  $1.25      │ $1250      │ 0.83   │ 可清算
  $1.00      │ $1000      │ 0.67   │ 严重不足

清算触发价格:
  P_liquidation = debt / (collateral × threshold)
  = 1200 / (1000 × 0.80)
  = $1.50
```

## 多资产 HF（生产级）

```
lending_market: 单一抵押品/借款对
  HF = collateral × threshold / debt

生产级（如 Aave）:
  多种抵押品，多种借款

  总加权抵押品 = Σ (collateral_i × price_i × threshold_i)
  总债务 = Σ (debt_j × price_j)

  HF = 总加权抵押品 / 总债务

  例:
    ETH: 10 个，$3000，threshold=82% → 10×3000×0.82 = 24600
    SUI: 5000 个，$2，threshold=75% → 5000×2×0.75 = 7500
    总抵押品 = 32100

    USDC 债务: 20000
    HF = 32100 / 20000 = 1.605 → 安全
```

## 总结

```
关键公式:
  LTV = debt / collateral
  HF = collateral × threshold / debt

  HF > 1 → 安全
  HF < 1 → 可清算

两个重要参数:
  collateral_factor: 借款上限（如 75%）
  liquidation_threshold: 清算线（如 80%）
  缓冲 = threshold - factor

价格下跌 → HF 下降 → 触发清算
这是借贷协议风险管理的核心机制
```
