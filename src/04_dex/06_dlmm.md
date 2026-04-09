# 4.6 DLMM：动态流动性做市

## V3 的问题

Uniswap V3 的集中流动性需要 LP 手动选择价格区间。如果价格移出区间：
1. LP 不再赚取手续费
2. 资金变成单边持仓
3. 需要手动重新提供流动性

这导致大量 V3 LP 实际收益不如预期——因为他们在大部分时间里仓位是不活跃的。

## DLMM 的改进

DLMM（Dynamic Liquidity Market Making）在 V3 基础上增加了**动态区间调整**：

- 流动性集中在当前价格附近的 bin（区间）
- 当价格移动时，流动性自动集中在新的价格区域
- LP 不需要手动调整区间

### Bin vs Tick

| 概念 | Uniswap V3 | DLMM (Cetus) |
|------|-----------|--------------|
| 基本单位 | Tick | Bin |
| 价格粒度 | 1.0001^i | 按 bin_id 线性分布 |
| 流动性分布 | 每个 tick 独立 | 每个 bin 独立 |
| 区间调整 | 手动 | 可自动（通过策略） |

## Move 实现

```move
module dlmm {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientLiquidity: u64 = 200;
    const EInvalidBin: u64 = 201;
    const EPoolPaused: u64 = 202;
    const EInvalidAmount: u64 = 203;

    struct Pool<phantom A, phantom B> has key {
        id: UID,
        active_bin: u64,
        bin_step: u64,
        base_fee_bps: u64,
        total_liquidity: u128,
        protocol_fee_a: u64,
        protocol_fee_b: u64,
        paused: bool,
    }

    struct Bin has store {
        bin_id: u64,
        price: u64,
        reserve_a: u64,
        reserve_b: u64,
        total_supply: u64,
    }

    struct BinPosition has key, store {
        id: UID,
        pool_id: ID,
        bin_id: u64,
        shares: u64,
    }

    public fun get_price_for_bin(bin_step: u64, bin_id: u64): u64 {
        let base = 10000;
        let step = bin_step;
        (base + step) * bin_id + base
    }

    public fun add_liquidity_to_bin<A, B>(
        pool: &mut Pool<A, B>,
        bin_id: u64,
        amount_a: Coin<A>,
        amount_b: Coin<B>,
        ctx: &mut TxContext,
    ): BinPosition {
        assert!(!pool.paused, EPoolPaused);
        let val_a = coin::value(&amount_a);
        let val_b = coin::value(&amount_b);
        assert!(val_a > 0 || val_b > 0, EInvalidAmount);

        let bin = get_or_create_bin(pool, bin_id);
        let shares = if (bin.total_supply == 0) {
            sqrt((val_a as u128) * (val_b as u128))
        } else if (val_a > 0) {
            (val_a as u128) * (bin.total_supply as u128) / (bin.reserve_a as u128)
        } else {
            (val_b as u128) * (bin.total_supply as u128) / (bin.reserve_b as u128)
        };

        bin.reserve_a = bin.reserve_a + val_a;
        bin.reserve_b = bin.reserve_b + val_b;
        bin.total_supply = bin.total_supply + (shares as u64);
        pool.total_liquidity = pool.total_liquidity + shares;

        BinPosition {
            id: object::new(ctx),
            pool_id: object::id(pool),
            bin_id,
            shares: shares as u64,
        }
    }

    public fun swap<A, B>(
        pool: &mut Pool<A, B>,
        amount_in: u64,
        zero_for_one: bool,
        ctx: &mut TxContext,
    ): Coin<B> {
        assert!(!pool.paused, EPoolPaused);
        let mut remaining = amount_in;
        let mut total_output = 0u64;
        let mut current_bin = pool.active_bin;

        while (remaining > 0) {
            let bin = get_bin_mut(pool, current_bin);
            if (zero_for_one) {
                let available = bin.reserve_b;
                let max_out = remaining * get_price_for_bin(pool.bin_step, current_bin) / 1000000;
                let output = if (max_out <= available) { max_out } else { available };
                let consumed = output * 1000000 / get_price_for_bin(pool.bin_step, current_bin);
                remaining = remaining - consumed;
                total_output = total_output + output;
                bin.reserve_a = bin.reserve_a + consumed;
                bin.reserve_b = bin.reserve_b - output;
                if (bin.reserve_b == 0) {
                    current_bin = current_bin + 1;
                };
            } else {
                let available = bin.reserve_a;
                let max_out = remaining * 1000000 / get_price_for_bin(pool.bin_step, current_bin);
                let output = if (max_out <= available) { max_out } else { available };
                let consumed = output * get_price_for_bin(pool.bin_step, current_bin) / 1000000;
                remaining = remaining - consumed;
                total_output = total_output + output;
                bin.reserve_b = bin.reserve_b + consumed;
                bin.reserve_a = bin.reserve_a - output;
                if (bin.reserve_a == 0) {
                    current_bin = if (current_bin > 0) { current_bin - 1 } else { 0 };
                };
            };
        };

        pool.active_bin = current_bin;
        assert!(total_output > 0, EInsufficientLiquidity);
        coin::take(&mut pool.coin_b, total_output, ctx)
    }

    fun get_or_create_bin(pool: &mut Pool<A, B>, bin_id: u64): &mut Bin {
        // 查找或创建 bin
    }
}
```

## DLMM vs V3 对比

| 维度 | Uniswap V3 | DLMM (Cetus) |
|------|-----------|--------------|
| 基本单位 | Tick（对数间距） | Bin（可配置间距） |
| LP 操作 | 选区间 + 提供流动性 | 选 bin + 提供流动性 |
| 区间调整 | 手动 | 可自动再平衡 |
| 费率 | 固定（每个池子） | 可按 bin 动态调整 |
| 复杂度 | 高 | 中 |
| Sui 代表 | — | Cetus |

## Cetus 的 DLMM 特点

1. **多费率档位**：同一交易对可以有 0.01%、0.05%、0.25%、1% 四个不同费率的池子
2. **Bin 粒度可配**：`bin_step` 控制相邻 bin 的价格间距
3. **闪电聚合**：Cetus 内部跨池路由
4. **杠杆 LP**：LP 可以通过借贷放大做市资金

Cetus 是 Sui 上 TVL 最高的 DEX，其 DLMM 实现是目前 Sui 生态最成熟的集中流动性方案。
