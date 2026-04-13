# 13.1 现货杠杆的机制与数学

## 基本原理

现货杠杆 = 借款买入 + 持有资产。步骤：

```
1. 存入 1000 SUI 作为抵押品
2. 借出 800 USDC（抵押率 80%）
3. 在 DEX 上用 800 USDC 买入 400 SUI
4. 将 400 SUI 再次存入作为抵押品
5. 现在持有 1400 SUI（40% SUI 多了），负债 800 USDC
```

有效杠杆 = 总资产 / 自有资产 = 1400 SUI / 1000 SUI = 1.4x

## 杠杆的数学

### 杠杆倍数

$$L = \frac{\text{Total Position}}{\text{Own Capital}} = \frac{\text{Collateral} + \text{Borrowed Value}}{\text{Collateral}}$$

### 盈亏放大

$$\text{PnL}_{leveraged} = L \times \text{PnL}_{unleveraged} - \text{Borrow Cost}$$

### 清算条件

$$\text{Liquidated when: } \frac{\text{Collateral Value} \times \text{Price}}{\text{Debt Value}} < \text{Liquidation Threshold}$$

### 最大可借金额

$$\text{Max Borrow} = \frac{\text{Collateral Value}}{\text{Liquidation Threshold}} \times (L - 1)$$

## 数值示例

初始：存入 1000 SUI（$2/枚），最大杠杆 3x

| 操作 | 抵押品 | 负债 | 净值 | 杠杆 |
|------|--------|------|------|------|
| 存入 1000 SUI | 1000 SUI | 0 | $2000 | 1.0x |
| 借 1333 USDC | 1000 SUI | $1333 | $667 | 3.0x |
| 买入 667 SUI | 1667 SUI | $1333 | $2001 | 3.0x |

SUI 涨到 $2.5：
| | |
|---|---|
| 抵押品价值 | 1667 × $2.5 = $4167 |
| 负债 | $1333 |
| 净值 | $2834 (+41.7%) |
| 未杠杆收益 | +25% |

SUI 跌到 $1.5：
| | |
|---|---|
| 抵押品价值 | 1667 × $1.5 = $2501 |
| 负债 | $1333 |
| 净值 | $1168 (-41.6%) |
| 未杠杆亏损 | -25% |

3x 杠杆下，价格波动被放大到约 1.67x（因为有借款成本）。

## 现货杠杆的 Move 框架

```move
module spot_leverage;
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};

    #[error]
    const EExceedsMaxLeverage: vector<u8> = b"Exceeds Max Leverage";
    #[error]
    const EHealthFactorTooLow: vector<u8> = b"Health Factor Too Low";

    public struct LeveragePosition has key, store {
        id: UID,
        owner: address,
        collateral_token: u8,
        debt_token: u8,
        collateral_amount: u64,
        debt_amount: u64,
        entry_price: u64,
        leverage_bps: u64,
        created_at: u64,
    }

    public struct LeverageConfig has store {
        max_leverage_bps: u64,
        collateral_threshold_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_penalty_bps: u64,
        max_debt_ratio_bps: u64,
    }

    public fun calculate_max_leverage(
        config: &LeverageConfig,
        collateral_value: u64,
        debt_value: u64,
    ): u64 {
        if (debt_value == 0) { return 10000 };
        let current_leverage = (collateral_value + debt_value) * 10000 / collateral_value;
        if (current_leverage > config.max_leverage_bps) {
            config.max_leverage_bps
        } else {
            current_leverage
        }
    }

    public fun calculate_liquidation_price(
        collateral_amount: u64,
        debt_amount: u64,
        liquidation_threshold_bps: u64,
        entry_price: u64,
        is_long: bool,
    ): u64 {
        if (is_long) {
            let collateral_value_needed = debt_amount * 10000 / liquidation_threshold_bps;
            collateral_value_needed * entry_price / (collateral_amount * entry_price)
        } else {
            debt_amount * liquidation_threshold_bps / (collateral_amount * 10000)
        }
    }
```
