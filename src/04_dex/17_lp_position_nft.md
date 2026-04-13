# 4.17 LP Position NFT

CLMM 中每个 LP 的价格区间不同，Position 无法互换，必须用 NFT 表示。Sui 的对象模型天然适配这一需求。

## 为什么 CLMM 需要 NFT

```
CPMM: 所有 LP 完全等价
  LP-1 存 $1000 → 100 LP Token
  LP-2 存 $2000 → 200 LP Token
  → 同质化，可用 ERC-20/Coin

CLMM: 每个 Position 独一无二
  LP-1: 区间 $1.90-$2.10, 流动性 500
  LP-2: 区间 $1.95-$2.05, 流动性 300
  LP-3: 区间 $1.99-$2.01, 流动性 100
  → 不同区间、流动性、手续费 → 不可互换 → 必须用 NFT
```

## Sui 对象模型的优势

### ERC-721 vs Sui 原生对象

```
EVM (ERC-721):                    Sui (原生对象):
  NFT 注册在合约 mapping 中         Position 直接是独立对象
  转账需调用合约函数                transfer::transfer(pos, addr) 一行
  抵押需 approve + deposit         直接传入函数参数
  每个操作都是合约调用              对象自带类型信息

Sui 的 Position:
  ✅ 自动有唯一 UID → 天然 NFT
  ✅ 不需要额外 NFT 合约
  ✅ 可以被其他协议直接引用
  ✅ 不同 Position 操作可并行
```

### Position 结构设计

```move
public struct Position has key, store {
    id: UID,
    pool_id: ID,
    tick_lower_index: u32,
    tick_upper_index: u32,
    liquidity: u128,
    fee_growth_inside_last_a: u128,  // 手续费快照
    fee_growth_inside_last_b: u128,
    owed_token_a: u64,               // 待领手续费
    owed_token_b: u64,
}
```

## Position 生命周期

```
1. Open Position    2. Add Liquidity   3. Active (Earning Fees)
┌──────────┐      ┌──────────────┐    ┌──────────────┐
│ 选择区间  │─────▶│ 存入 A + B   │───▶│ 赚取手续费   │
└──────────┘      └──────────────┘    └──────┬───────┘
                                              │
                              ┌───────────────┤
                              ▼               ▼
                       4a. Collect Fees  4b. Adjust Range
                       ┌────────────┐   ┌────────────┐
                       │ 领取 A, B  │   │ 关仓+重开  │
                       └────────────┘   └────────────┘
                              │               │
                              ▼               ▼
                       5. Close Position
                       ┌────────────────────┐
                       │ 取回本金 + 手续费  │
                       │ 销毁 Position 对象 │
                       └────────────────────┘
```

### 关键函数签名

```move
// 开仓
public fun open_position<A, B>(
    pool: &mut Pool<A, B>, tick_lower: u32, tick_upper: u32,
    ctx: &mut TxContext,
): Position

// 添加流动性
public fun add_liquidity(
    position: &mut Position, pool: &mut Pool,
    coin_a: Coin<A>, coin_b: Coin<B>,
)

// 领取手续费
public fun collect_fees(
    position: &mut Position, pool: &Pool, ctx: &mut TxContext,
): (Coin<A>, Coin<B>)

// 关仓
public fun close_position<A, B>(
    position: Position, pool: &mut Pool<A, B>, ctx: &mut TxContext,
): (Coin<A>, Coin<B>, Coin<A>, Coin<B>)  // (本金A, 本金B, 手续费A, 手续费B)
```

## Position 作为 DeFi 乐高

```
Sui 生态的 Position 复用:

Cetus CLMM Position NFT
        │
        ├──▶ Scallop Lending (作为抵押品借出 USDC)
        ├──▶ Navi Lending (同样支持)
        └──▶ 杠杆 LP 策略 (借出 → 新 Position → 再抵押)

Sui 中抵押流程:
  transfer::transfer(position, lending_object_id)
  → 一行代码完成，无需 approve/revoke
```

## 小结

CLMM 的 Position 必须是 NFT（每个区间独特）。Sui 对象模型天然适配：独立 UID、原生转移、直接作为参数传入其他协议。Position 成为 DeFi 乐高的核心组件。下一节深入 CLMM 的 Swap 算法。
