# 12.3 保证金、杠杆与强平机制

## 三层保证金

### 初始保证金（Initial Margin）

开仓时必须存入的最低保证金。

$$IM = \frac{\text{Position Size}}{\text{Max Leverage}}$$

例如 10x 杠杆下，仓位 $40,000，初始保证金 = $4,000。

### 维持保证金（Maintenance Margin）

仓位不被清算所需的最低保证金。通常低于初始保证金。

$$MM = \text{Position Size} \times \text{MM Rate}$$

例如 MM Rate = 0.5%，仓位 $40,000，维持保证金 = $200。

### 追加保证金（Margin Call）

当保证金低于维持保证金时，用户需要追加保证金或减仓。如果用户不行动，协议强制清算。

```move
public fun is_liquidatable<Base, Quote>(
    market: &PerpMarket<Base, Quote>,
    position: &Position<Base, Quote>,
): bool {
    let unrealized_pnl = calculate_pnl(
        position.entry_price,
        market.mark_price,
        position.size,
        position.is_long,
    );
    let effective_margin = if (unrealized_pnl >= 0) {
        (position.margin + (unrealized_pnl as u64)) as u128
    } else {
        let loss = (-unrealized_pnl) as u64;
        if (loss >= position.margin) { return true };
        (position.margin - loss) as u128
    };
    let margin_ratio = effective_margin * 10000 / (position.size as u128);
    margin_ratio < market.maintenance_margin_bps as u128
}
```

## 杠杆放大的到底是什么

杠杆放大的不是收益，而是**风险暴露的倍数**。

| 杠杆 | BTC 涨 10% | BTC 跌 10% | 强平跌幅 |
|------|-----------|-----------|----------|
| 1x | +10% | -10% | 100% |
| 5x | +50% | -50% | 20% |
| 10x | +100% | -100% | 10% |
| 50x | +500% | -100% | 2% |
| 100x | +1000% | -100% | 1% |

50x 杠杆下，BTC 只需下跌 2%，你的保证金就全部亏光。而且考虑到资金费率和手续费，实际强平线会更近。

## 完整示例：10x BTC 多单的生命周期

```
初始状态：
  BTC = $40,000
  保证金 = $4,000
  仓位 = 1 BTC ($40,000)
  杠杆 = 10x
  维持保证金率 = 0.5%

场景 1：BTC 涨到 $44,000
  PnL = ($44,000 - $40,000) * 1 = +$4,000
  保证金 = $8,000 (+100%)

场景 2：BTC 跌到 $38,000
  PnL = ($38,000 - $40,000) * 1 = -$2,000
  保证金 = $2,000 (-50%)
  维持保证金 = $38,000 * 0.5% = $190
  保证金率 = $2,000 / $38,000 = 5.26% > 0.5% → 安全

场景 3：BTC 跌到 $36,400
  PnL = ($36,400 - $40,000) * 1 = -$3,600
  保证金 = $400 (-90%)
  维持保证金 = $36,400 * 0.5% = $182
  保证金率 = $400 / $36,400 = 1.1% > 0.5% → 安全

场景 4：加上 8 小时资金费率 -$120
  保证金 = $400 - $120 = $280
  保证金率 = $280 / $36,400 = 0.77% > 0.5% → 仍然安全

场景 5：BTC 再跌到 $36,200
  PnL = ($36,200 - $40,000) * 1 = -$3,800
  保证金 = $200
  保证金率 = $200 / $36,200 = 0.55% → 接近危险

场景 6：BTC 跌到 $36,000
  保证金 = $200 - 80(继续付资金费率) = $120
  保证金率 = $120 / $36,000 = 0.33% < 0.5%
  → 触发强制清算
```

## 三个常见误解

### 1. 资金费率 ≠ 收益

很多人把正向资金费率（多头支付空头）当作"做空赚收益"。但资金费率是波动的，可能在亏损时变为负值。

### 2. 高杠杆 ≠ 高效率

100x 杠杆意味着 1% 的价格波动就可能导致清算。这不是效率，这是赌博。

### 3. 快速清算 ≠ 充分保护

即使协议有快速清算机制，如果 DEX 流动性不足，清算者卖出抵押品时会进一步压低价格，形成恶性循环。
