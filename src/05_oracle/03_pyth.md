# 5.3 Pyth Network：价格事实与 Pull 模式

## Pyth 的设计理念

Pyth 的核心概念是**价格事实（Price Fact）**——不是"预言机告诉你价格是多少"，而是"数据发布者声明价格是多少，你验证这个声明是否可信"。

```
传统预言机模型：
  数据源 → 预言机合约 → 链上价格
  信任点：预言机合约正确转发数据

Pyth 模型：
  数据发布者 → 签名价格 → 链上 PriceFeed 对象
  信任点：发布者的签名有效 + 足够多的发布者同意
```

## Pull 模式 vs Push 模式

```
Push 模式（Chainlink 风格）：
  预言机节点定期将价格推送到链上
  → 协议直接读取链上存储的价格
  → 优点：协议端简单
  → 缺点：需要预言机持续付费上链，价格可能不够新

Pull 模式（Pyth 风格）：
  价格数据链下可用，用户在需要时拉到链上
  → 用户的交易中包含价格更新数据
  → 优点：价格总是最新的，预言机不付 gas
  → 缺点：用户的交易稍微复杂（需要先获取更新数据）
```

## Pyth 在 Sui 上的架构

```
链下：
  ┌──────────────────────────────────┐
  │  数据发布者（90+）                 │
  │  ├─ Binance、OKX、Jane Street...  │
  │  └─ 各自签名并提交价格             │
  │                                   │
  │  Hermes API（Pyth 的链下服务）     │
  │  └─ 聚合多发布者价格               │
  │  └─ 提供 update data（二进制）     │
  └──────────────────────────────────┘
         │
         │ update_data（通过 PTB 传入）
         ▼
链上：
  ┌──────────────────────────────────┐
  │  PriceFeed 对象（每个交易对一个）   │
  │  ├─ price: u64                    │
  │  ├─ conf: u64（置信区间）          │
  │  ├─ publish_time: u64             │
  │  └─ ema_price: u64（指数移动平均） │
  │                                   │
  │  pyth::price_feed 模块             │
  │  └─ update_price_feed()           │
  │  └─ get_price()                   │
  └──────────────────────────────────┘
```

## 完整 Move 集成代码

```move
module defi::pyth_integration;

use pyth::price_feed::{Self, PriceFeed};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::sui::SUI;

#[error]
const EStale_PRICE: vector<u8> = b"Stale_PRICE";
#[error]
const EPriceTooLow: vector<u8> = b"Price Too Low";
#[error]
const EConfidenceTooWide: vector<u8> = b"Confidence Too Wide";
#[error]
const ENegativePrice: vector<u8> = b"Negative Price";

const MAX_STALENESS_MS: u64 = 60_000;
const MAX_CONFIDENCE_RATIO_BPS: u64 = 500;
const PRICE_SCALE: u64 = 1_000_000_000;

public struct PriceData has store {
    price: u64,
    confidence: u64,
    publish_time_ms: u64,
    ema_price: u64,
}

public fun update_feed(feed: &mut PriceFeed, update_data: vector<vector<u8>>, ctx: &mut TxContext) {
    pyth::update_price_feeds(update_data, ctx);
}

public fun safe_read_price(feed: &PriceFeed, clock: &Clock): PriceData {
    let (price, conf, publish_time, ema_price) = price_feed::get_price(feed);
    assert!(price >= 0, ENegativePrice);
    let now = clock.timestamp_ms();
    assert!(now - publish_time < MAX_STALENESS_MS, EStale_PRICE);
    assert!(conf * 10000 < price * MAX_CONFIDENCE_RATIO_BPS, EConfidenceTooWide);
    PriceData { price, confidence: conf, publish_time_ms: publish_time, ema_price }
}

public fun get_usd_price(data: &PriceData): u64 {
    data.price
}

public fun get_price_with_confidence(data: &PriceData): (u64, u64) {
    (data.price, data.confidence)
}

public fun get_twap_price(data: &PriceData): u64 {
    data.ema_price
}

public fun convert_to_sui_amount(usd_amount: u64, sui_price: &PriceData): u64 {
    usd_amount * PRICE_SCALE / sui_price.price
}

public fun is_price_fresh(data: &PriceData, clock: &Clock): bool {
    clock.timestamp_ms() - data.publish_time_ms < MAX_STALENESS_MS
}
```

## PTB 中的使用方式

在 Sui 上使用 Pyth 需要 Programmable Transaction Block（PTB），因为要在同一笔交易中先更新价格再使用：

```typescript
import { PythHttpClient } from "@pythnetwork/pyth-sui-js";

const pythClient = new PythHttpClient("https://hermes.pyth.network");

async function borrowWithPyth(feedId: string) {
    const updateData = await pythClient.getPriceFeedsUpdateData([feedId]);

    const tx = new Transaction();
    tx.moveCall({
        target: "0xpyth::price_feed::update_price_feeds",
        arguments: [tx.pure.vector("vector<u8>", updateData)],
    });

    tx.moveCall({
        target: "0xdefi::lending::borrow",
        arguments: [
            tx.object(MARKET_ID),
            tx.object(PRICE_FEED_ID),
            tx.pure.vector("vector<u8>", updateData),
            tx.pure.u64(borrowAmount),
        ],
    });

    return tx;
}
```

## PriceFeed 对象的生命周期

```
创建：
  Pyth 部署时为每个 price feed 创建一个共享对象

更新：
  用户通过 update_price_feed() 传入签名数据
  Pyth 合约验证签名后更新 PriceFeed 对象

读取：
  任何合约可以读取 PriceFeed 的当前状态
  但必须检查价格是否够新

不存在的操作：
  Pyth 不提供"删除"或"暂停"功能
  价格始终存在，只是可能过时
```

## 关键参数

| 参数           | 含义                       | 典型值                      |
| -------------- | -------------------------- | --------------------------- |
| `price`        | 当前价格（带精度）         | 取决于 feed，通常 10^8 精度 |
| `conf`         | 置信区间（±）              | 价格的 0.1%-2%              |
| `publish_time` | 价格发布时间戳             | Unix ms                     |
| `ema_price`    | 指数移动平均价格           | 用于 TWAP 场景              |
| `expo`         | 价格的指数（负数表示小数） | 通常 -8                     |

## 风险分析

| 风险            | 描述                                       |
| --------------- | ------------------------------------------ |
| 依赖 Hermes API | 如果 Hermes 宕机，无法获取更新数据         |
| 置信区间过宽    | 在高波动时 conf 可能很大，意味着价格不确定 |
| 发布者串通      | 如果足够多的发布者提供虚假价格             |
| 更新成本        | Pull 模式下用户需要额外 gas 来更新价格     |
