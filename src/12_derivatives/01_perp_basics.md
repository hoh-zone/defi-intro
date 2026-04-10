# 12.1 持有资产与持有敞口

## 期货 vs 永续合约

### 期货（Futures）

有到期日的合约。到期时，多头和空头按结算价交割。到期日前，合约价格围绕现货价格波动，但可能产生溢价（contango）或折价（backwardation）。

### 永续合约（Perpetual）

没有到期日。通过**资金费率（Funding Rate）**机制让合约价格锚定现货价格。

- 当合约价格 > 现货价格：多头向空头支付资金费率（鼓励做空）
- 当合约价格 < 现货价格：空头向多头支付资金费率（鼓励做多）

## PnL 计算

```move
module perp_math {
    public fun calculate_pnl(
        entry_price: u64,
        exit_price: u64,
        size: u64,
        is_long: bool,
    ): i128 {
        if (is_long) {
            ((exit_price as i128) - (entry_price as i128)) * (size as i128) / (entry_price as i128)
        } else {
            ((entry_price as i128) - (exit_price as i128)) * (size as i128) / (entry_price as i128)
        }
    }

    public fun calculate_liquidation_price(
        entry_price: u64,
        margin: u64,
        size: u64,
        maintenance_margin_bps: u64,
        is_long: bool,
    ): u64 {
        let effective_leverage = size * 10000 / margin;
        if (is_long) {
            entry_price * (10000 - maintenance_margin_bps) / effective_leverage
        } else {
            entry_price * (10000 + maintenance_margin_bps) / effective_leverage
        }
    }
}
```

## 交易示例

BTC 现货价格 = $40,000。用户开 10x 做多，保证金 $4,000：

- 仓位大小 = $40,000（1 BTC）
- 入场价 = $40,000
- 强平价 ≈ $36,400（维持保证金率 0.5%）

| BTC 价格 | PnL | 收益率 |
|----------|-----|--------|
| $44,000 | +$4,000 | +100% |
| $42,000 | +$2,000 | +50% |
| $40,000 | $0 | 0% |
| $38,000 | -$2,000 | -50% |
| $36,400 | -$3,600 | -90%（接近强平） |

10x 杠杆意味着价格波动 10%，你的保证金波动 100%。
