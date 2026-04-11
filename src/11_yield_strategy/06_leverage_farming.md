# 11.6 杠杆挖矿

## 杠杆挖矿的循环

杠杆挖矿是最激进的收益策略——通过循环借贷放大本金：

```
循环步骤：
1. 存入 100 SUI 作为抵押品到借贷协议
2. 借出 80 USDC（80% LTV）
3. 在 DEX 将 80 USDC 换成 SUI
4. 将换得的 SUI 再次存入借贷协议
5. 再次借出 USDC...
6. 重复直到达到目标杠杆倍数

最终效果：
  本金 100 SUI
  存入总量 ~300 SUI（通过循环）
  借入总量 ~240 USDC
  实际杠杆 ~3x
```

### 杠杆挖矿的收益放大

```
普通挖矿：
  本金 100 SUI，APR 20%
  年收益 = 20 SUI

3x 杠杆挖矿：
  实际本金 300 SUI（100 自己 + 200 循环借入）
  LP APR 20%，借款利率 8%
  年收益 = 300 × 20% - 200 × 8% = 44 SUI
  实际 ROI = 44/100 = 44%（对比无杠杆的 20%）
```

### 杠杆挖矿的风险放大

```
普通挖矿：
  SUI 跌 30%，亏损 30 SUI

3x 杠杆挖矿：
  SUI 跌 30%
  存入资产价值：300 × 0.7 = 210 SUI
  借入债务：240 USDC（不变）
  净值 = 210 × price - 240
  如果 SUI 价格从 $1 跌到 $0.70：
    存入 = 210 × $0.70 = $147
    借入 = $240
    净值 = $147 - $240 = -$93（已被清算）
```

## 杠杆挖矿的 Move 实现

```move
module yield_strategy::leverage_farming {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::event;

    const ENotOwner: u64 = 0;
    const ECollateralRatio: u64 = 1;
    const EZeroAmount: u64 = 2;
    const EMaxLeverage: u64 = 3;
    const PRECISION: u64 = 1_000_000_000;

    public struct LeveragedPosition has key {
        id: UID,
        owner: address,
        deposited_base: Balance<BaseCoin>,
        borrowed_quote: Balance<QuoteCoin>,
        lp_shares: u64,
        leverage: u64,
        entry_base_price: u64,
        liquidation_threshold_bps: u64,
    }

    public struct PositionOpened has copy, drop {
        owner: address,
        base_deposited: u64,
        quote_borrowed: u64,
        leverage: u64,
    }

    public struct Liquidated has copy, drop {
        position: address,
        base_seized: u64,
        debt_repaid: u64,
        remaining: u64,
    }

    public fun open_position<BaseCoin, QuoteCoin>(
        base_collateral: Coin<BaseCoin>,
        target_leverage_bps: u64,
        base_price_in_quote: u64,
        ctx: &mut TxContext,
    ) {
        let collateral_amount = base_collateral.value();
        assert!(collateral_amount > 0, EZeroAmount);
        assert!(target_leverage_bps > PRECISION && target_leverage_bps <= 5 * PRECISION, EMaxLeverage);
        let leverage = target_leverage_bps / PRECISION;
        let total_base = collateral_amount * leverage;
        let borrow_base_equivalent = total_base - collateral_amount;
        let borrow_quote = borrow_base_equivalent * base_price_in_quote / PRECISION;
        let position = LeveragedPosition {
            id: object::new(ctx),
            owner: ctx.sender(),
            deposited_base: coin::into_balance(base_collateral),
            borrowed_quote: balance::zero(),
            lp_shares: 0,
            leverage: leverage,
            entry_base_price: base_price_in_quote,
            liquidation_threshold_bps: 7500,
        };
        event::emit(PositionOpened {
            owner: ctx.sender(),
            base_deposited: collateral_amount,
            quote_borrowed: borrow_quote,
            leverage,
        });
        transfer::transfer(position, ctx.sender());
    }

    public fun health_factor(
        position: &LeveragedPosition,
        current_base_price: u64,
    ): u64 {
        let base_value = position.deposited_base.value() * current_base_price / PRECISION;
        let debt = position.borrowed_quote.value();
        if (debt == 0) { return PRECISION * 10 };
        base_value * position.liquidation_threshold_bps / (debt * 100)
    }

    public fun is_liquidatable(
        position: &LeveragedPosition,
        current_base_price: u64,
    ): bool {
        health_factor(position, current_base_price) < PRECISION
    }

    public fun calculate_max_leverage(
        collateral: u64,
        liquidation_threshold_bps: u64,
        price: u64,
    ): u64 {
        let max_borrow = collateral * price / PRECISION * liquidation_threshold_bps / 10000;
        (collateral * price / PRECISION + max_borrow) * PRECISION / (collateral * price / PRECISION)
    }

    public fun estimated_liquidation_price(
        position: &LeveragedPosition,
    ): u64 {
        let debt = position.borrowed_quote.value();
        let collateral = position.deposited_base.value();
        if (collateral == 0) { return 0 };
        debt * 10000 / (collateral * position.liquidation_threshold_bps / PRECISION)
    }

    public fun add_collateral<BaseCoin, QuoteCoin>(
        position: &mut LeveragedPosition<BaseCoin, QuoteCoin>,
        more: Coin<BaseCoin>,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == position.owner, ENotOwner);
        balance::join(&mut position.deposited_base, coin::into_balance(more));
    }

    public fun close_position<BaseCoin, QuoteCoin>(
        position: LeveragedPosition<BaseCoin, QuoteCoin>,
        repayment: Coin<QuoteCoin>,
        ctx: &mut TxContext,
    ): Coin<BaseCoin> {
        assert!(ctx.sender() == position.owner, ENotOwner);
        let debt = position.borrowed_quote.value();
        let repaid = repaid.value();
        assert!(repaid >= debt, ECollateralRatio);
        let remaining_base = position.deposited_base.value();
        let base = coin::from_balance(position.deposited_base, ctx);
        coin::destroy_zero(coin::from_balance(position.borrowed_quote, ctx));
        coin::destroy_zero(repayment);
        let LeveragedPosition { id, owner: _, deposited_base: _, borrowed_quote: _, lp_shares: _, leverage: _, entry_base_price: _, liquidation_threshold_bps: _ } = position;
        id.delete();
        base
    }
}
```

## 杠杆挖矿的不同场景

### 场景 1：做多 SUI（看涨）

```
存入 SUI → 借出 USDC → 买入 SUI → LP SUI/USDC → 质押挖矿
收益 = LP 手续费 + 挖矿激励 - 借款利息
风险 = SUI 下跌时被清算
```

### 场景 2：杠杆 LP（中性）

```
存入 SUI → 借出 USDC → 等量配对 LP → 质押挖矿
收益 = LP 手续费 + 挖矿激励 - 借款利息
风险 = SUI 下跌导致仓位偏斜 + 清算风险
```

### 场景 3：循环借贷（递归）

```
存入 SUI → 借出 USDC → 换成 SUI → 再存入 → 再借出 ...
最大循环次数取决于 LTV：
  LTV = 80% → 理论最大杠杆 = 1/(1-0.8) = 5x
  实际安全杠杆 = 2-3x（留清算缓冲）
```

## 杠杆挖矿的清算价格计算

```
设：
  存入 C 个 SUI
  借出 D 个 USDC
  清算阈值 = 75%

清算价格 = D / (C × 75%)

示例：
  存入 300 SUI，借入 200 USDC
  清算价格 = 200 / (300 × 0.75) = $0.889

  当前价格 $1.00 → 安全
  价格跌到 $0.889 → 被清算
  距离清算：11.1% 的下跌空间
```

## 风险分析

| 风险 | 描述 | 严重程度 |
|---|---|---|
| 清算 | 价格下跌到清算阈值，仓位被强制平仓，损失清算罚金 | 致命 |
| 级联清算 | 大量杠杆仓位同时被清算，价格进一步下跌 | 致命 |
| 利率飙升 | 借款需求增加导致利率上升，挖矿收益被利息吃掉 | 高 |
| 激励下降 | 挖矿奖励减少但杠杆成本不变，净收益转负 | 高 |
| 通胀螺旋 | 激励代币被杠杆挖矿者卖出，价格持续下跌 | 高 |
| 合约风险 | 循环操作涉及多个协议，任一出问题都可能导致资金损失 | 中 |
