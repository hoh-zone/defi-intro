# 4.22 Sui DLMM 实现

本节设计 Sui 上的 DLMM 协议实现，讨论数据结构、Swap 算法、LP 操作以及 Sui 并行执行的独特优势。

## 对象架构

```
Pool<A, B> (共享对象)
├── active_bin_id, bin_step
├── base_fee_rate, protocol_fee_rate
└── dynamic fields: BinState

DLMMPosition (独立对象 × N)
├── pool_id
└── bin_shares: vector<BinShare>
    每个 BinShare: bin_id + shares + fee_snapshot
```

## 数据结构

```move
public struct Pool<phantom A, phantom B> has key {
    id: UID,
    active_bin_id: u32,
    bin_step: u64,        // 价格步长
    base_fee_rate: u64,
    protocol_fee_rate: u64,
    decimals_a: u8,
    decimals_b: u8,
}

public struct BinState has store, copy, drop {
    bin_id: u32,
    amount_x: u64,
    amount_y: u64,
    total_shares: u128,
    fee_accumulated_x: u128,
    fee_accumulated_y: u128,
}

public struct DLMMPosition has key, store {
    id: UID,
    pool_id: ID,
    bin_shares: vector<BinShare>,
}

public struct BinShare has store, copy, drop {
    bin_id: u32,
    shares: u128,
    fee_snapshot_x: u128,
    fee_snapshot_y: u128,
}
```

## Swap 算法

```move
public fun swap<A, B>(
    pool: &mut Pool<A, B>, coin_in: Coin<A>,
    min_amount_out: u64, ctx: &mut TxContext,
): Coin<B> {
    let remaining = coin::value(&coin_in);
    let mut out = 0;
    let mut bin_id = pool.active_bin_id;

    while (remaining > 0) {
        let price = bin_math::price(bin_id, pool.bin_step);
        let mut bin = get_bin(pool, bin_id);
        let max_y = bin.amount_y;
        let max_x_for_y = max_y * 10000 / (price * 10000 / 10000);

        if (remaining <= max_x_for_y) {
            // 当前 Bin 够用
            let dy = remaining * price / 10000;
            bin.amount_x = bin.amount_x + remaining;
            bin.amount_y = bin.amount_y - dy;
            out = out + dy;
            remaining = 0;
        } else {
            // 买空当前 Bin
            out = out + bin.amount_y;
            remaining = remaining - max_x_for_y;
            bin.amount_x = bin.amount_x + max_x_for_y;
            bin.amount_y = 0;
            bin_id = bin_id - 1;  // 价格下降方向
            if (!bin_exists(pool, bin_id)) { break };
        };
        set_bin(pool, bin_id, bin);
    };

    pool.active_bin_id = bin_id;
    assert!(out >= min_amount_out);
    coin::join(&mut pool.balance_a, coin_in);
    coin::take(&mut pool.balance_b, out, ctx)
}
```

## LP 操作

### 存入多个 Bin

```move
public fun deposit_to_bins<A, B>(
    pool: &mut Pool<A, B>,
    coin_a: Coin<A>, coin_b: Coin<B>,
    bin_ids: vector<u32>,
    distribution: vector<u64>,  // 权重
    ctx: &mut TxContext,
): DLMMPosition {
    // 按权重比例分配到每个 Bin
    // 每个 Bin 独立计算 share
    // 返回包含多个 BinShare 的 Position
}
```

### 取出和费用领取

```move
// 从指定 Bin 取出流动性
public fun withdraw_from_bins<A, B>(
    position: &mut DLMMPosition,
    pool: &mut Pool<A, B>,
    bins: vector<u32>,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>)

// 领取所有 Bin 的手续费
public fun collect_fees(
    position: &mut DLMMPosition,
    pool: &Pool,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    // 遍历 bin_shares
    // fee = shares × (bin.fee_accumulated - snapshot) / total_shares
}
```

## 并行执行机会

```
DLMM 在 Sui 上的并行性:

1. Fee Collection 并行
   不同 Position 是独立对象 → 可同时领取手续费

2. 不同 Bin 的 LP 操作 (如果 Bin 为独立对象)
   Tx-1: 向 Bin 6930 存入  ||  Tx-2: 从 Bin 6935 取出

3. Swap 仍然串行 (&mut Pool)
   但单 Bin 计算简单，Gas 更低

对象存储方案选择:
  推荐: Bin 作为 Pool dynamic field
  简单可靠，Swap 串行但计算快
  Position 独立对象 → 并行领取手续费
```

## DLMM vs CLMM 实现对比

```
维度         | CLMM              | DLMM
──────────── | ───────────────── | ─────────────────
Swap 计算    | √P + 虚拟储备     | 直接 P 比率 (更简单)
费用追踪     | 三层 (全局→Tick→Pos)| 两层 (Bin→Pos)
LP 操作      | 按区间比例         | 按 Bin 分布 (更灵活)
代码量       | ~2000 行           | ~1500 行
Gas (Swap)   | 中等               | 略低 (单 Bin 简单)
LP 灵活性    | 一个 Position=区间 | 一个 Position=多 Bin
```

## 测试场景

```move
#[test] fun test_single_bin_swap() {
    // 存入单 Bin → Swap → 验证状态
}
#[test] fun test_cross_bin_swap() {
    // 存入 3 Bin → 大额 Swap 跨 Bin → 验证 active_bin_id
}
#[test] fun test_multi_lp_fees() {
    // 多 LP 存入不同 Bin → Swap → 领费 → 验证比例
}
#[test] fun test_withdraw() {
    // 存入 → Swap → 取出 → 验证本金 + 手续费
}
```

## 小结

Sui DLMM 实现：Bin 用 dynamic field 稀疏存储，Position 独立对象天然 NFT。Swap 按 Bin 迭代，比 CLMM 计算更简单。Sui 的并行执行让 Position 操作（费用领取）可并行。与 CLMM 相比，DLMM 代码更简洁、LP 灵活性更高，是 AMM 模型的极致进化方向。
