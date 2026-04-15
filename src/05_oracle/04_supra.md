# 5.4 Supra Oracle：原生预言机与 DORA

## Supra 的设计哲学

Supra 是一条独立的 Layer 1 链，同时提供预言机服务给其他链。在 Sui 上的特色是**原生集成**——Supra 的价格数据可以直接在 Sui Move 中调用，不需要额外的中间合约。

```
Supra vs Pyth 的架构差异：

Pyth：
  链下 → Hermes API → 用户 PTB → Sui 合约 → PriceFeed 对象

Supra：
  Supra 链验证者 → DORA 共识 → Sui 原生模块 → 直接读取
  （某些模式下不需要用户手动更新）
```

## DORA 协议

DORA（Distributed Oracle Agreement）是 Supra 的核心共识协议：

```
DORA 流程：
1. 多个数据源提供同一资产的价格
2. Supra 验证者各自收集价格并签名
3. 通过 Byzantine 容错共识达成一致
4. 将共识价格推送到目标链

安全保证：
  - 容忍 f < n/3 的恶意验证者
  - 数据源的多样性防止单源操纵
  - 密码学签名保证数据完整性
```

## Supra 在 Sui 上的集成方式

```move
module defi::supra_integration;

use sui::clock::Clock;

#[error]
const EStale_PRICE: vector<u8> = b"Stale_PRICE";
#[error]
const EInvalidPair: vector<u8> = b"Invalid Pair";

const MAX_STALENESS_MS: u64 = 60_000;

public struct SupraPrice has store {
    price: u64,
    decimals: u8,
    last_updated_ms: u64,
}

public fun get_price(supra_oracle: &SupraOracle, pair_index: u64, clock: &Clock): SupraPrice {
    let (price, decimals, timestamp) = supra::get_price(supra_oracle, pair_index);
    assert!(clock.timestamp_ms() - timestamp < MAX_STALENESS_MS, EStale_PRICE);
    SupraPrice { price, decimals, last_updated_ms: timestamp }
}

public fun get_sui_usd_price(oracle: &SupraOracle, clock: &Clock): u64 {
    let data = get_price(oracle, SUI_USD_PAIR_INDEX, clock);
    data.price
}

const SUI_USD_PAIR_INDEX: u64 = 0;
#[error]
const ETH_USD_PAIR_INDEX: vector<u8> = b"TH_USD_PAIR_INDEX";
const BTC_USD_PAIR_INDEX: u64 = 2;
const USDC_USD_PAIR_INDEX: u64 = 3;

public fun convert_amount(amount: u64, from_price: &SupraPrice, to_price: &SupraPrice): u64 {
    let from_decimals = from_price.decimals;
    let to_decimals = to_price.decimals;
    let adjusted_amount = if (from_decimals > to_decimals) {
        amount / (10 ^ (from_decimals - to_decimals))
    } else {
        amount * (10 ^ (to_decimals - from_decimals))
    };
    adjusted_amount * from_price.price / to_price.price
}

public fun is_fresh(data: &SupraPrice, clock: &Clock): bool {
    clock.timestamp_ms() - data.last_updated_ms < MAX_STALENESS_MS
}
```

## Supra 的 dSTREAM 自动化流水线

```
dSTREAM 是 Supra 的自动化价格推送服务：

传统模式：
  用户在交易中手动触发价格更新

dSTREAM 模式：
  Supra 自动按预设频率推送价格到链上
  协议直接读取，无需用户触发

适用场景：
  - 需要持续更新的借贷协议
  - 需要极低延迟的衍生品协议
  - 不想让用户承担更新成本的协议

配置参数：
  - 推送频率（如每 10 秒）
  - 价格偏差阈值（偏离多少才推送）
  - 目标链上的合约地址
```

## Supra vs Pyth 实际对比

| 场景       | Supra 优势                   | Pyth 优势             |
| ---------- | ---------------------------- | --------------------- |
| 借贷协议   | dSTREAM 自动推送，用户无感   | 价格 feeds 更多       |
| 衍生品     | 极低延迟，原生集成           | 多发布者交叉验证      |
| 长尾代币   | 覆盖较少                     | 覆盖更多交易对        |
| 集成复杂度 | 更简单（某些模式不需要 PTB） | 需要 Hermes + PTB     |
| 随机数     | 原生 VRF                     | Entropy commit-reveal |
| Gas 成本   | 较低（原生集成）             | 需要额外 update 步骤  |

## 在同一协议中同时使用 Supra 和 Pyth

```move
module defi::multi_oracle;

use sui::clock::Clock;

public struct OraclePrice has store {
    price: u64,
    source: String,
    timestamp_ms: u64,
}

public fun read_pyth_price(feed: &PriceFeed, clock: &Clock): OraclePrice {
    let (price, _, ts, _) = price_feed::get_price(feed);
    assert!(clock.timestamp_ms() - ts < 60_000, 0);
    OraclePrice { price, source: string::utf8(b"pyth"), timestamp_ms: ts }
}

public fun read_supra_price(oracle: &SupraOracle, pair: u64, clock: &Clock): OraclePrice {
    let (price, _, ts) = supra::get_price(oracle, pair);
    assert!(clock.timestamp_ms() - ts < 60_000, 0);
    OraclePrice { price, source: string::utf8(b"supra"), timestamp_ms: ts }
}

public fun compare_prices(p1: &OraclePrice, p2: &OraclePrice, max_deviation_bps: u64): bool {
    let deviation = if (p1.price > p2.price) {
        (p1.price - p2.price) * 10000 / p2.price
    } else {
        (p2.price - p1.price) * 10000 / p1.price
    };
    deviation <= max_deviation_bps
}
```

## 风险分析

| 风险          | 描述                                 |
| ------------- | ------------------------------------ |
| 依赖 Supra 链 | 如果 Supra 链出问题，价格更新会中断  |
| 原生集成深度  | 过度依赖可能导致迁移困难             |
| 推送频率      | dSTREAM 的推送频率可能不适合所有场景 |
| 覆盖范围      | 相比 Pyth 支持的交易对较少           |
