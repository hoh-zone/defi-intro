# 17.1 预言机操纵攻击

## 攻击公式

$$\text{攻击利润} = \text{操纵成本} < \text{从协议中提取的价值}$$

当操纵一个预言机的成本低于从中获取的利润时，攻击就会发生。

## 攻击步骤

```
1. 攻击者通过闪电贷借入大量 Token A（成本 ≈ 0）
2. 在流动性较浅的 DEX 池中，用 Token A 大量买入 Token B
3. Token B 价格在该池中被大幅推高
4. 预言机读取该池的价格，Token B 价格被人为抬高
5. 攻击者在借贷协议中用 Token B 作抵押，借出更多 Token A
6. 在 DEX 上反向交易，恢复正常价格
7. 偿还闪电贷，保留多借出的 Token A
```

## 攻击代码演示（教学用）

```move
module attack_oracle_manipulation {
    use amm::Pool;
    use lending::Market;
    use flash_loan::FlashLoanPool;
    use sui::coin::Coin;
    use sui::tx_context::TxContext;

    public fun attack(
        flash_pool: &mut FlashLoanPool<TokenA>,
        target_dex: &mut Pool<TokenA, TokenB>,
        lending_market: &mut Market,
        borrow_amount: u64,
        ctx: &mut TxContext,
    ) {
        let (loan, due) = flash_loan::borrow(flash_pool, 10000000, ctx);

        let token_b = amm::swap_a_to_b(target_dex, loan, ctx);

        let now_b_price = get_price_from_pool(target_dex);

        let deposit_pos = lending::supply(lending_market, TOKEN_B_RESERVE, token_b, ctx);
        lending::enable_collateral(&mut deposit_pos);
        let borrow_pos = lending::borrow(
            lending_market,
            TOKEN_A_RESERVE,
            borrow_amount,
            &vector[&deposit_pos],
            ctx,
        );

        let recovery_a = amm::swap_b_to_a(target_dex, token_b_remaining, ctx);

        flash_loan::repay(flash_pool, recovery_a, due);
    }
}
```

**这段代码仅作教学演示，展示攻击路径。实际使用需要更多细节处理。**

## 防御措施

### 1. TWAP（时间加权平均价格）

不用即时价格，用一段时间内的加权平均价格。

```move
struct TWAP has store {
    cumulative_price: u128,
    last_timestamp: u64,
    last_price: u64,
}

public fun update_twap(twap: &mut TWAP, price: u64, timestamp: u64) {
    let dt = timestamp - twap.last_timestamp;
    twap.cumulative_price = twap.cumulative_price + (price as u128) * (dt as u128);
    twap.last_price = price;
    twap.last_timestamp = timestamp;
}

public fun get_twap(twap: &TWAP, lookback_ms: u64, now: u64): u64 {
    let dt = now - twap.last_timestamp + lookback_ms;
    ((twap.cumulative_price) / (dt as u128)) as u64
}
```

TWAP 使得攻击者需要在整个时间窗口内维持扭曲价格，攻击成本从"一笔交易"变为"持续操纵"。

### 2. 多源验证

使用多个预言机来源，取中位数或加权平均。

### 3. 偏差阈值

拒绝与上次有效价格偏差过大的更新。

```move
public fun validate_with_deviation(
    new_price: u64,
    last_price: u64,
    max_deviation_bps: u64,
): bool {
    let dev = if (new_price > last_price) {
        (new_price - last_price) * 10000 / last_price
    } else {
        (last_price - new_price) * 10000 / last_price
    };
    dev <= max_deviation_bps
}
```
