# 8.1 流动性挖矿的动机与问题

## 冷启动困境

一个新 DEX 上线时面临一个鸡生蛋的问题：

- 用户不会来一个没有流动性的交易所
- 流动性提供者（LP）不会来一个没有用户的交易所

传统金融通过做市商协议解决：交易所付费聘请专业做市商提供报价。DeFi 的解决方案是：**用协议代币补贴 LP**。

这不是"免费的钱"。这是协议在用自己的股权（代币）购买一种关键资源（流动性）。理解这一点至关重要——每个增发的代币都在稀释现有持有者。

## 激励对齐的三种模式

```
模式 1：补贴流动性（大多数 DEX）
  → LP 质押 LP Token → 获得 协议代币
  → 目标：吸引 TVL，降低滑点
  → 风险：mercenary capital，补贴一停 TVL 就跑

模式 2：补贴使用（大多数借贷）
  → 存款人获得存款激励 / 借款人获得借款激励
  → 目标：扩大存贷规模
  → 风险：借款激励可能导致不负责任的借贷

模式 3：补贴治理参与（Curve 风格）
  → 锁仓 veToken → 获得 boost + 投票权
  → 目标：长期对齐
  → 风险：治理集中化
```

## Mercenary Capital 问题

```
时间线：
  Day 0：协议宣布 200% APR 挖矿奖励
  Day 1：TVL 从 $0 暴涨到 $50M（mercenary capital 涌入）
  Day 30：代币价格因持续抛售下跌 80%
  Day 31：APR 降为 40%（因为代币价格跌了）
  Day 32：TVL 从 $50M 跌回 $2M（mercenary capital 撤离）
```

这不是假设——这是 2020-2023 年数百个 DeFi 协议的真实历史。

## 用 Move 定义挖矿的核心数据结构

在我们深入每一节的实现之前，先定义最核心的类型：

```move
module liquidity_mining::core;

use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::tx_context::TxContext;

#[error]
const EInsufficientStake: vector<u8> = b"Insufficient Stake";
#[error]
const ENotAuthorized: vector<u8> = b"Not Authorized";
#[error]
const EPoolExpired: vector<u8> = b"Pool Expired";

public struct StakeInfo has drop, store {
    amount: u64,
    reward_debt: u64,
}

public struct RewardPool<phantom StakeCoin, phantom RewardCoin> has key {
    id: UID,
    total_stake: u64,
    reward_per_share_stored: u64,
    reward_rate: u64,
    last_update_time_ms: u64,
    reward_duration_ms: u64,
    period_finish_ms: u64,
    reward_balance: Coin<RewardCoin>,
    stake_balance: Coin<StakeCoin>,
    stakes: Bag,
}

public struct UserStake has drop, store {
    stake_amount: u64,
    reward_debt: u64,
    pending_reward: u64,
}
```

### 关键字段解释

| 字段                      | 含义                         |
| ------------------------- | ---------------------------- |
| `total_stake`             | 池中总质押量                 |
| `reward_per_share_stored` | 累计每份额奖励（核心累加器） |
| `reward_rate`             | 每毫秒释放的奖励数量         |
| `last_update_time_ms`     | 上次更新累加器的时间         |
| `stakes`                  | 用户地址 → UserStake 的映射  |

这个数据结构是后面所有挖矿算法的基础。8.2 节将详细解释 `reward_per_share` 累加器的数学原理。

## 风险分析

| 风险              | 描述                                                   |
| ----------------- | ------------------------------------------------------ |
| 通胀螺旋          | 高 APR → 代币增发 → 价格下跌 → 需要更高 APR → 恶性循环 |
| Mercenary capital | 追逐高 APR 的短期资本，补贴一停就撤离                  |
| 智能合约风险      | 奖励计算错误可能导致奖励耗尽或用户无法提取             |
| 治理攻击          | 持有大量代币的 mercenary 可能通过治理改变参数          |
