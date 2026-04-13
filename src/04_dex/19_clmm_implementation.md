# 4.19 完整实现 Sui CLMM

本节设计一个完整的 CLMM DEX 架构，参考 Cetus 的设计思路，使用 Sui Move 的特性构建集中流动性协议。

## 架构概览

```
clmm_dex/sources/
├── pool.move       # 池的创建和管理
├── tick.move       # Tick 数据结构
├── position.move   # LP Position 管理
├── swap.move       # Swap 核心算法
├── fee.move        # 手续费计算
└── math.move       # 数学工具
```

### 对象关系

```
Pool<A, B> (共享对象)
├── balance_a, balance_b           // 代币储备
├── current_tick, active_liquidity // 价格状态
├── fee_growth_global_a/b          // 全局手续费
└── dynamic fields: TickState      // 稀疏 Tick 存储

Position (独立对象 × N)
├── pool_id                        // 所属池
├── tick_lower, tick_upper         // 区间
├── liquidity                      // 流动量
└── fee snapshots                  // 手续费快照
```

## 关键数据结构

```move
public struct Pool<phantom A, phantom B> has key {
    id: UID,
    balance_a: Balance<A>,
    balance_b: Balance<B>,
    fee_balance_a: Balance<A>,
    fee_balance_b: Balance<B>,
    current_tick_index: u32,
    active_liquidity: u128,
    fee_growth_global_a: u128,
    fee_growth_global_b: u128,
    lp_fee_rate: u64,           // bps
    protocol_fee_rate: u64,     // bps
    tick_spacing: u32,
}

public struct TickState has store, copy, drop {
    liquidity_gross: u128,
    liquidity_net: i128,
    fee_growth_outside_a: u128,
    fee_growth_outside_b: u128,
}

public struct Position has key, store {
    id: UID,
    pool_id: ID,
    tick_lower_index: u32,
    tick_upper_index: u32,
    liquidity: u128,
    fee_growth_inside_last_a: u128,
    fee_growth_inside_last_b: u128,
    owed_a: u64,
    owed_b: u64,
}
```

## 核心函数

### create_pool

```move
public fun create_pool<A, B>(
    tick_spacing: u32, lp_fee_rate: u64,
    protocol_fee_rate: u64, initial_tick: u32,
    ctx: &mut TxContext,
): Pool<A, B> {
    assert!(lp_fee_rate + protocol_fee_rate <= 10000);
    assert!(initial_tick % tick_spacing == 0);
    Pool {
        id: object::new(ctx),
        balance_a: balance::zero(), balance_b: balance::zero(),
        fee_balance_a: balance::zero(), fee_balance_b: balance::zero(),
        current_tick_index: initial_tick, active_liquidity: 0,
        fee_growth_global_a: 0, fee_growth_global_b: 0,
        lp_fee_rate, protocol_fee_rate, tick_spacing,
    }
}
```

### open_position + add_liquidity

```move
public fun open_position_with_liquidity<A, B>(
    pool: &mut Pool<A, B>,
    coin_a: Coin<A>, coin_b: Coin<B>,
    tick_lower: u32, tick_upper: u32,
    ctx: &mut TxContext,
): Position {
    // 1. 初始化 Tick
    maybe_init_tick(pool, tick_lower);
    maybe_init_tick(pool, tick_upper);
    // 2. 计算需要的代币量和流动性
    let (amt_a, amt_b, liq) = math::calculate_deposit(
        pool.current_tick_index, tick_lower, tick_upper,
        coin::value(&coin_a), coin::value(&coin_b));
    // 3. 更新 Tick 状态
    update_tick(pool, tick_lower, liq, true);   // +liq
    update_tick(pool, tick_upper, liq, false);  // -liq
    // 4. 更新活跃流动性
    if (pool.current_tick_index >= tick_lower
        && pool.current_tick_index < tick_upper)
        { pool.active_liquidity = pool.active_liquidity + liq };
    // 5. 存入代币，退还多余
    deposit_and_refund(pool, coin_a, coin_b, amt_a, amt_b, ctx);
    // 6. 创建 Position
    Position { id: object::new(ctx), pool_id: ..., ... }
}
```

### swap

```move
public fun swap<A, B>(
    pool: &mut Pool<A, B>, coin_in: Coin<A>,
    min_amount_out: u64, ctx: &mut TxContext,
): Coin<B> {
    let fee = coin::value(&coin_in) * pool.lp_fee_rate / 10000;
    let (amount_out, new_tick) = swap_core(
        pool, coin::value(&coin_in) - fee, true);
    assert!(amount_out >= min_amount_out);
    pool.current_tick_index = new_tick;
    coin::join(&mut pool.balance_a, coin_in);
    coin::take(&mut pool.balance_b, amount_out, ctx)
}
```

## Tick 存储（动态字段）

```move
fun maybe_init_tick(pool: &mut Pool, idx: u32) {
    if (!df::exists_(&pool.id, TickIndex{idx}))
        { df::add(&mut pool.id, TickIndex{idx}, TickState{...}) };
}
fun get_tick(pool: &Pool, idx: u32): TickState {
    *df::borrow(&pool.id, TickIndex{idx})
}
fun set_tick(pool: &mut Pool, idx: u32, s: TickState) {
    *df::borrow_mut(&mut pool.id, TickIndex{idx}) = s;
}
```

## 测试场景

```move
#[test] fun test_create_and_swap() {
    // 创建池, 开仓 [6900,6960], 执行 Swap
    // 验证: tick 变化, 输出量, 手续费累计
}

#[test] fun test_fee_collection() {
    // 开仓 → 多次 Swap → collect_fees
    // 验证: 手续费 > 0 且按份额比例正确
}

#[test] fun test_close_position() {
    // 开仓 → Swap → 关仓
    // 验证: 本金 + 手续费正确返回, Position 销毁
}
```

## 与 Cetus 对比

```
本实现           | Cetus            | 说明
────────────────|──────────────────|──────────
Pool 共享对象    | 相同              | 一致
Position 独立   | 相同              | 天然 NFT
Tick 动态字段   | 相同              | 稀疏存储
三层手续费追踪  | 相同原理          | 全局→Tick→Pos
动态费率        | Cetus 额外特性    | 可扩展
借贷集成        | Cetus 自有        | 乐高组合
```

## 小结

Sui CLMM 要点：Pool 共享对象存储储备和 Tick，TickState 通过动态字段稀疏存储，Position 独立对象天然 NFT。Sui 的对象模型免去额外 NFT 合约，并行执行提升 Position 操作效率。下一节介绍 DLMM。
