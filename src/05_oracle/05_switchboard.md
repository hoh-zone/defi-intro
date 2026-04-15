# 5.5 Switchboard：聚合数据源与队列模型

## Switchboard 的设计理念

Switchboard 的核心创新是**让任何人都可以创建数据 Feed**。不同于 Pyth（只有授权发布者）和 Supra（自有验证者网络），Switchboard 采用开放聚合器模型：

```
Pyth 模型：
  只有授权发布者（Binance、OKX 等）可以提供数据

Supra 模型：
  Supra 自有验证者网络收集和验证数据

Switchboard 模型：
  任何人都可以创建一个 Aggregator（聚合器）
  → 定义数据源、更新条件、聚合方式
  → Oracle 队列中的节点竞争提供数据
  → 结果聚合后上链
```

## 架构：队列 + 聚合器

```
┌─────────────────────────────────────┐
│  Oracle Queue（预言机队列）           │
│  ┌────────┐ ┌────────┐ ┌────────┐   │
│  │Oracle 1│ │Oracle 2│ │Oracle N│   │
│  │(节点)  │ │(节点)  │ │(节点)  │   │
│  └───┬────┘ └───┬────┘ └───┬────┘   │
│      │          │          │         │
│      ▼          ▼          ▼         │
│  ┌──────────────────────────────┐    │
│  │  Aggregator（聚合器）         │    │
│  │  ├─ 定义数据源（Job）         │    │
│  │  ├─ 定义聚合方式（中位数等）  │    │
│  │  ├─ 定义更新条件（阈值/心跳）│    │
│  │  └─ 输出聚合结果             │    │
│  └──────────────────────────────┘    │
└─────────────────────────────────────┘
         │
         ▼
    Sui 链上 Aggregator 对象
    （包含最新聚合结果）
```

## 在 Sui 上使用 Switchboard

```move
module defi::switchboard_integration;

use sui::clock::Clock;

#[error]
const EStale_PRICE: vector<u8> = b"Stale_PRICE";
#[error]
const EInvalidAggregator: vector<u8> = b"Invalid Aggregator";
const MAX_STALENESS_MS: u64 = 120_000;

public struct SwitchboardPrice has store {
    value: u64,
    timestamp_ms: u64,
    decimals: u8,
}

public fun read_aggregator(aggregator: &Aggregator, clock: &Clock): SwitchboardPrice {
    let result = switchboard::get_result(aggregator);
    let timestamp = switchboard::get_latest_timestamp(aggregator);
    assert!(clock.timestamp_ms() - timestamp < MAX_STALENESS_MS, EStale_PRICE);
    SwitchboardPrice {
        value: result,
        timestamp_ms: timestamp,
        decimals: 8,
    }
}

public fun get_price_value(data: &SwitchboardPrice): u64 {
    data.value
}

public fun is_fresh(data: &SwitchboardPrice, clock: &Clock): bool {
    clock.timestamp_ms() - data.timestamp_ms < MAX_STALENESS_MS
}
```

## 自定义数据 Feed

Switchboard 的最大优势是可以创建自定义 Feed：

```
示例：创建一个获取 Sui TVL 的数据 Feed

Job 1：从 DeFiLlama API 获取 Sui TVL
Job 2：从 DefiLlama 备用 API 获取相同数据
Job 3：从 Sui 链上计算 TVL

聚合方式：中位数
更新条件：每 60 秒或变化 > 5%
Oracle 队列：10 个节点竞争提供数据
```

### 创建聚合器的 Move 代码

```move
module defi::custom_feed;

use sui::coin::Coin;
use sui::sui::SUI;

public fun create_tvl_aggregator(
    queue: &mut OracleQueue,
    reward: Coin<SUI>,
    ctx: &mut TxContext,
): Aggregator {
    let mut jobs = vector::empty();
    jobs.push_back(
        create_job(
            string::utf8(b"https://api.llama.fi/v2/historicalChainTvl/Sui"),
            string::utf8(b"$[0].tvl"),
        ),
    );
    switchboard::create_aggregator(
        queue,
        jobs,
        10,
        60_000,
        500,
        reward,
        ctx,
    )
}

fun create_job(url: String, selector: String): Job {
    Job { url, selector }
}
```

## Switchboard VRF（可验证随机函数）

```move
module defi::switchboard_vrf;

use sui::coin::Coin;
use sui::sui::SUI;

public struct VrfRequest has key {
    id: UID,
    seed: vector<u8>,
    callback: String,
}

public struct VrfResult has store {
    randomness: vector<u8>,
    proof: vector<u8>,
}

public fun request_randomness(
    vrf: &mut VrfAccount,
    seed: vector<u8>,
    reward: Coin<SUI>,
    ctx: &mut TxContext,
) {
    switchboard::request_randomness(vrf, seed, reward, ctx);
}

public fun consume_randomness(vrf_account: &mut VrfAccount, result: VrfResult): u64 {
    let bytes = result.randomness;
    let mut value = 0u64;
    let mut i = 0;
    while (i < 8 && i < bytes.length()) {
        value = value + ((*bytes.borrow(i) as u64) << (i * 8));
        i = i + 1;
    };
    value
}

public fun random_in_range(random: u64, min: u64, max: u64): u64 {
    min + random % (max - min + 1)
}
```

## 三大预言机集成复杂度对比

```
Pyth 集成步骤：
  1. 找到 PriceFeed 对象 ID
  2. 从 Hermes API 获取 update data
  3. PTB: update_price_feed → 协议操作
  → 复杂度：中等（需要链下 API + PTB）

Supra 集成步骤：
  1. 找到 SupraOracle 对象和 pair index
  2. 直接调用 get_price（或配置 dSTREAM）
  → 复杂度：低（某些模式下直接读取）

Switchboard 集成步骤：
  1. 创建或找到 Aggregator 对象
  2. 确保 Oracle 队列有足够的节点
  3. 读取聚合结果
  → 复杂度：中高（需要管理队列和聚合器）
```

## 风险分析

| 风险      | 描述                                             |
| --------- | ------------------------------------------------ |
| 队列质量  | 自定义 Feed 的质量取决于队列中 Oracle 节点的质量 |
| 数据延迟  | 聚合器更新需要队列调度，可能有延迟               |
| Feed 维护 | 自定义 Feed 需要持续维护（奖励、参数）           |
| 节点不足  | 如果队列中活跃节点太少，聚合结果不可靠           |
