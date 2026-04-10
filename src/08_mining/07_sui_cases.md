# 8.7 Sui 实例与激励风险

## Cetus 挖矿激励

Cetus 是 Sui 上最大的 CLMM DEX，其激励体系：

```
激励来源：CETUS 代币（协议代币）
激励对象：LP（流动性提供者）+ veCETUS 锁仓者

LP 激励：
  - 每个交易对有独立的奖励池
  - 奖励按 LP 在 CLMM 区间内的流动性大小分配（不是 LP Token 数量）
  - 多个交易对的奖励权重由治理投票决定

veCETUS 锁仓：
  - 锁仓 CETUS 获得 veCETUS
  - veCETUH 用于 gauge 投票决定各池奖励权重
  - 锁仓者获得交易手续费的分成
```

### Cetus LP 激励的 Move 伪代码结构

```move
module cetus::incentive {
    public struct IncentivePool has key {
        reward_funds: Bag,
        stake_positions: Table<ID, PositionStake>,
        global_reward_accumulators: Table<Type, Accumulator>,
    }

    public struct PositionStake has store {
        liquidity: u128,
        tick_lower: int32,
        tick_upper: int32,
        reward_debts: Bag,
    }

    public fun collect_fees_and_rewards(
        pool: &mut Pool,
        position_id: ID,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<SUI>, vector<Coin<CETUS>>) {
        let position = pool.positions.borrow_mut(position_id);
        let fees = collect_fees(pool, position);
        let rewards = collect_rewards(pool, position, clock);
        (fees, rewards)
    }
}
```

**关键点**：Cetus 的 LP 仓位是 NFT（包含价格区间信息），挖矿奖励按区间内的 `liquidity` 大小分配，不是按 NFT 数量。这与传统 Uniswap V2 风格的 LP Token 质押完全不同。

## Navi 挖矿激励

Navi Protocol 是 Sui 上的借贷协议：

```
激励结构：
  存款激励（Supply Incentive）：存款人获得 NAVX 代币奖励
  借款激励（Borrow Incentive）：借款人获得 NAVX 代币奖励

市场权重：
  SUI 市场：高存款激励，鼓励原生代币存款
  USDC 市场：高借款激励，鼓励稳定币借款
  vSUI 市场：最高存款激励，与 LSD 协作

衰减机制：
  按 Sui epoch（~1天）调整 emission rate
  每 30 个 epoch 进行一次参数回顾
```

### Navi 激励的典型 APR 结构

```
市场      存款 APY（基础利息）  存款激励 APR    借款激励 APR
SUI       2%                   15%            5%
USDC      3%                   8%             12%
WETH      1%                   10%            8%
vSUI      3%                   25%            3%
```

**警惕**：注意 vSUI 的存款激励 APR 高达 25%。这意味着什么？

```
真实收益 = 基础利息 + 激励 APR × 代币价格比
如果 NAVX 价格持续下跌：
  名义 APR = 25%
  实际 APR = 25% × (NAVX 跌幅) → 可能接近 0
```

## Scallop 挖矿激励

Scallop 是 Sui 上的另一个借贷协议，特色是"零利率借贷"：

```
激励结构：
  存款激励：sSCA 代币奖励
  借款激励：仅特定市场有借款激励
  保本基金：部分协议收入用于保险

不同之处：
  Scallop 更依赖协议自身收入（利息差）而非代币激励
  激励代币主要用于治理而非纯补贴
```

## 激励可持续性评估框架

评估一个协议的挖矿激励是否可持续，用以下框架：

### 1. 收入覆盖比

```
收入覆盖比 = 协议实际收入 / 代币排放价值

如果 < 1：协议在亏本运营，依赖代币增发补贴
如果 > 1：协议收入足以覆盖激励成本
如果 > 2：协议有健康的利润空间
```

### 2. Mercenary Capital 指标

```
Mercenary 比例 = (TVL 变动率) / (APR 变动率)

高 Mercenary 比例意味着：APR 稍微下降，TVL 就大量撤离
低 Mercenary 比例意味着：用户更看重协议本身而非纯补贴
```

### 3. 代币释放压力

```
月通胀率 = 月新增代币 / 流通代币总量

> 10%：高通胀，价格压力大
3-10%：中等，需要足够的需求吸收
< 3%：低通胀，相对可持续
```

## 激励设计中的常见错误

### 错误 1：固定 APR 而非固定排放量

```move
public fun bad_design(pool: &mut Pool, clock: &Clock) {
    let apr = 100;
    let reward = pool.total_stake * apr / 100;
}
```

如果 TVL 从 $1M 涨到 $100M，奖励需求也从 100 变成 10,000——代币通胀失控。

**正确做法**：固定排放量，让 APR 随 TVL 变化。

### 错误 2：没有衰减

```move
public fun no_decay(pool: &mut Pool) {
    pool.reward_rate = 1000;
}
```

永远 1000 token/天意味着代币无限增发。

**正确做法**：引入衰减调度器（8.5 节）。

### 错误 3：奖励不随质押量缩放

```move
public fun bad_acc(pool: &mut Pool, elapsed: u64) {
    pool.acc_reward_per_share = pool.acc_reward_per_share + pool.reward_rate * elapsed;
}
```

没有除以 `total_stake`——质押者越多，每人分得越多，违反直觉。

**正确做法**：`acc_reward_per_share += rate * elapsed / total_stake`。

## 风险总结

| 风险类别 | 具体风险 | 影响程度 |
|---|---|---|
| 经济模型 | 通胀螺旋：高 APR → 增发 → 价格跌 → 更高 APR | 致命 |
| 经济模型 | Mercenary capital：补贴停 TVL 跑 | 高 |
| 合约安全 | 奖励计算精度丢失 | 中 |
| 合约安全 | 累加器溢出 | 高 |
| 治理 | Gauge bribery 与 vote buying | 高 |
| 治理 | 权重操控导致奖励集中 | 中 |
| 协议设计 | 借款激励 > 利息导致负利率 | 高 |
| 流动性 | 激励代币流动性不足，无法卖出 | 中 |

本章的每一行代码都对应一个真实的风险点。流动性挖矿看似简单——"质押领奖"——但其背后的数学和工程实现直接决定了协议的生死。
