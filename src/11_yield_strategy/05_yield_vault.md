# 11.5 收益金库（Yield Vault）

## 从手动到自动

前面几节讲的做市策略都需要手动操作：选区间、再平衡、调整报价。收益金库（Yield Vault）将这些操作自动化：

```
用户存入资产 → Vault 自动分配到收益策略 → 自动复投 → 用户随时提取

典型流程：
  1. 用户存入 1000 SUI 到 Vault
  2. Vault 将 SUI 存入借贷协议赚取利息
  3. 利息自动买入更多 SUI 并存入
  4. 用户份额持续增长
```

## Yearn 风格 Vault 的核心设计

```
Vault Token（份额代币）：
  用户存入 1000 SUI → 获得 1000 vault shares
  Vault 赚取收益后，每个 share 对应更多 SUI
  用户提取时按 share 比例取回

净值计算：
  price_per_share = Vault 总资产 / 总 shares
  初始 price_per_share = 1.0
  随着收益累积，price_per_share 逐渐增长
```

## 完整 Move 实现

```move
module yield_strategy::yield_vault {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::event;

    const E_NOT_OWNER: u64 = 0;
    const E_ZERO_DEPOSIT: u64 = 1;
    const E_ZERO_WITHDRAW: u64 = 2;
    const E_INSUFFICIENT_SHARES: u64 = 3;
    const E_STRATEGY_FAILED: u64 = 4;
    const PRECISION: u64 = 1_000_000_000;

    public struct Vault<phantom Asset> has key {
        id: UID,
        balance: Balance<Asset>,
        total_shares: u64,
        strategy: Strategy,
        fee_rate_bps: u64,
        performance_fee_bps: u64,
        fees_collected: Balance<Asset>,
        owner: address,
    }

    public struct Strategy has store {
        target_protocol: String,
        last_harvest_ms: u64,
        harvest_interval_ms: u64,
        total_earned: u64,
    }

    public struct VaultShare has store {
        shares: u64,
    }

    public struct Deposited has copy, drop {
        user: address,
        amount: u64,
        shares_minted: u64,
    }

    public struct Withdrawn has copy, drop {
        user: address,
        shares_burned: u64,
        amount: u64,
    }

    public struct Harvested has copy, drop {
        profit: u64,
        performance_fee: u64,
    }

    public fun create<Asset>(
        initial: Coin<Asset>,
        fee_rate_bps: u64,
        performance_fee_bps: u64,
        ctx: &mut TxContext,
    ) {
        let balance = coin::into_balance(initial);
        let vault = Vault<Asset> {
            id: object::new(ctx),
            balance,
            total_shares: PRECISION,
            strategy: Strategy {
                target_protocol: string::utf8(b"auto"),
                last_harvest_ms: 0,
                harvest_interval_ms: 86_400_000,
                total_earned: 0,
            },
            fee_rate_bps,
            performance_fee_bps,
            fees_collected: balance::zero(),
            owner: tx_context::sender(ctx),
        };
        transfer::share_object(vault);
    }

    public fun price_per_share<Asset>(vault: &Vault<Asset>): u64 {
        if (vault.total_shares == 0) { return PRECISION };
        balance::value(&vault.balance) * PRECISION / vault.total_shares
    }

    public fun deposit<Asset>(
        vault: &mut Vault<Asset>,
        coin: Coin<Asset>,
        ctx: &mut TxContext,
    ) {
        let amount = coin::value(&coin);
        assert!(amount > 0, E_ZERO_DEPOSIT);
        let shares = if (vault.total_shares == 0) {
            amount * PRECISION / PRECISION
        } else {
            amount * vault.total_shares / balance::value(&vault.balance)
        };
        assert!(shares > 0, E_ZERO_DEPOSIT);
        balance::join(&mut vault.balance, coin::into_balance(coin));
        vault.total_shares = vault.total_shares + shares;
        event::emit(Deposited {
            user: tx_context::sender(ctx),
            amount,
            shares_minted: shares,
        });
    }

    public fun withdraw<Asset>(
        vault: &mut Vault<Asset>,
        shares: u64,
        ctx: &mut TxContext,
    ): Coin<Asset> {
        assert!(shares > 0, E_ZERO_WITHDRAW);
        assert!(shares <= vault.total_shares, E_INSUFFICIENT_SHARES);
        let amount = shares * balance::value(&vault.balance) / vault.total_shares;
        let withdrawal_fee = amount * vault.fee_rate_bps / 10000;
        let net_amount = amount - withdrawal_fee;
        balance::join(&mut vault.fees_collected, balance::split(balance::split(&mut vault.balance, amount), withdrawal_fee));
        vault.total_shares = vault.total_shares - shares;
        event::emit(Withdrawn {
            user: tx_context::sender(ctx),
            shares_burned: shares,
            amount: net_amount,
        });
        coin::from_balance(balance::split(&mut vault.balance, net_amount), ctx)
    }

    public fun harvest<Asset>(
        vault: &mut Vault<Asset>,
        profit: Coin<Asset>,
        clock_ms: u64,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);
        let profit_amount = coin::value(&profit);
        let perf_fee = profit_amount * vault.performance_fee_bps / 10000;
        let net_profit = profit_amount - perf_fee;
        let fee_balance = coin::split(&mut profit, perf_fee, ctx);
        balance::join(&mut vault.fees_collected, coin::into_balance(fee_balance));
        balance::join(&mut vault.balance, coin::into_balance(profit));
        vault.strategy.total_earned = vault.strategy.total_earned + net_profit;
        vault.strategy.last_harvest_ms = clock_ms;
        event::emit(Harvested {
            profit: net_profit,
            performance_fee: perf_fee,
        });
    }

    public fun total_assets<Asset>(vault: &Vault<Asset>): u64 {
        balance::value(&vault.balance)
    }

    public fun collect_fees<Asset>(
        vault: &mut Vault<Asset>,
        ctx: &mut TxContext,
    ): Coin<Asset> {
        assert!(tx_context::sender(ctx) == vault.owner, E_NOT_OWNER);
        let amount = balance::value(&vault.fees_collected);
        coin::take(&mut vault.fees_collected, amount, ctx)
    }
}
```

## Vault 的收益来源链

```
简单 Vault（单策略）：
  SUI → 存入 Navi → 赚取利息 + NAVX 激励
  自动复投：利息 + 激励 → 换成 SUI → 再存入 Navi

复杂 Vault（多策略）：
  SUI → 分配到多个策略：
    ├─ 50% 存入 Navi（安全收益）
    ├─ 30% LP Cetus SUI/USDC（手续费 + 激励）
    └─ 20% 网格交易（主动收益）
  根据各策略的表现动态调整比例
```

## 复投的复利效应

```
初始投入：1000 SUI
APY：20%
复投频率：每天

1 年后：
  不复投：1000 × 1.20 = 1200 SUI
  每天复投：1000 × (1 + 0.20/365)^365 ≈ 1221 SUI

差异：21 SUI（约 2.1% 的额外收益）

复投越频繁，复利效应越大，但 gas 成本也越高。
Vault 的价值在于自动化这个过程。
```

## 风险分析

| 风险 | 描述 |
|---|---|
| 策略失败 | 底层策略（如借贷协议）出问题，Vault 资金受损 |
| 管理员作恶 | harvest 函数的管理员权限可能被滥用 |
| 费用过高 | performance fee + withdrawal fee 可能吃掉大部分收益 |
| 复投滑点 | 自动复投时在 DEX 换币有滑点 |
| 资金锁定 | 策略侧可能有提款延迟 |
