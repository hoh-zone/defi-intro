# 5.11 多预言机聚合与仲裁

## 为什么要用多个预言机

单个预言机是单点故障。使用多个预言机可以：

```
1. 交叉验证：如果 Pyth 说 $1000 而 Supra 说 $100，至少有一个错了
2. 中位数过滤：即使一个预言机出错，中位数仍然可靠
3. 可用性提升：一个预言机挂了，另一个还能用
4. 置信度提升：多个独立源说相同的价格，可信度更高
```

## 聚合策略

### 策略 1：中位数（Median）

```move
module oracle::median_aggregator;

public fun median(prices: vector<u64>): u64 {
    let mut sorted = prices;
    let n = sorted.length();
    assert!(n > 0, 0);
    let mut i = 0;
    while (i < n) {
        let mut j = i + 1;
        while (j < n) {
            if (*sorted.borrow(j) < *sorted.borrow(i)) {
                let tmp = *sorted.borrow(i);
                *sorted.borrow_mut(i) = *sorted.borrow(j);
                *sorted.borrow_mut(j) = tmp;
            };
            j = j + 1;
        };
        i = i + 1;
    };
    if (n % 2 == 1) {
        *sorted.borrow(n / 2)
    } else {
        (*sorted.borrow(n / 2 - 1) + *sorted.borrow(n / 2)) / 2
    }
}
```

### 策略 2：加权平均（Weighted Average）

```move
module oracle::weighted_aggregator;

public struct WeightedSource has store {
    source_id: u8,
    weight: u64,
    price: u64,
    timestamp_ms: u64,
}

public fun weighted_average(sources: vector<WeightedSource>): u64 {
    let mut total_weight = 0u64;
    let mut weighted_sum = 0u64;
    let mut i = 0;
    while (i < sources.length()) {
        let source = sources.borrow(i);
        total_weight = total_weight + source.weight;
        weighted_sum = weighted_sum + source.price * source.weight;
        i = i + 1;
    };
    assert!(total_weight > 0, 0);
    weighted_sum / total_weight
}
```

### 策略 3：偏差仲裁（Deviation Arbitration）

```move
module oracle::arbitration;

use sui::clock::Clock;

const MAX_DEVIATION_BPS: u64 = 300;

public struct ArbitratedPrice has store {
    price: u64,
    agreed_sources: u64,
    total_sources: u64,
    arbitration_result: u8,
}

const CONSENSUS: u8 = 0;
const OUTLIER_REMOVED: u8 = 1;
const DISAGREEMENT: u8 = 2;

public fun arbitrate(prices: vector<u64>, max_deviation_bps: u64): ArbitratedPrice {
    let n = prices.length();
    assert!(n >= 2, 0);
    let median = compute_median(prices);
    let mut agreed = 0;
    let mut i = 0;
    while (i < n) {
        let p = *prices.borrow(i);
        let dev = if (p > median) {
            (p - median) * 10000 / median
        } else {
            (median - p) * 10000 / median
        };
        if (dev <= max_deviation_bps) {
            agreed = agreed + 1;
        };
        i = i + 1;
    };
    let result = if (agreed == n) {
        CONSENSUS
    } else if (agreed >= n / 2 + 1) {
        OUTLIER_REMOVED
    } else {
        DISAGREEMENT
    };
    ArbitratedPrice {
        price: median,
        agreed_sources: agreed,
        total_sources: n,
        arbitration_result: result,
    }
}

fun compute_median(prices: vector<u64>): u64 {
    let mut sorted = prices;
    let n = sorted.length();
    let mut i = 0;
    while (i < n) {
        let mut j = i + 1;
        while (j < n) {
            if (*sorted.borrow(j) < *sorted.borrow(i)) {
                let tmp = *sorted.borrow(i);
                *sorted.borrow_mut(i) = *sorted.borrow(j);
                *sorted.borrow_mut(j) = tmp;
            };
            j = j + 1;
        };
        i = i + 1;
    };
    *sorted.borrow(n / 2)
}
```

## 多预言机聚合器完整实现

```move
module oracle::multi_source;

use sui::clock::Clock;
use sui::event;
use sui::object::{Self, UID};
use sui::tx_context::TxContext;

public struct OracleSource has store {
    source_id: u8,
    weight: u64,
    max_staleness_ms: u64,
    enabled: bool,
}

public struct MultiOracleAggregator has key {
    id: UID,
    sources: vector<OracleSource>,
    max_inter_source_deviation_bps: u64,
    last_aggregated_price: u64,
    admin: address,
}

public struct PriceAggregated has copy, drop {
    price: u64,
    source_count: u64,
    agreement: u8,
}

public fun aggregate(
    aggregator: &mut MultiOracleAggregator,
    raw_prices: vector<u64>,
    clock: &Clock,
): u64 {
    let mut valid_prices = vector::empty();
    let mut i = 0;
    while (i < raw_prices.length()) {
        let source = aggregator.sources.borrow(i);
        if (source.enabled) {
            valid_prices.push_back(*raw_prices.borrow(i));
        };
        i = i + 1;
    };
    assert!(valid_prices.length() > 0, 0);
    let price = compute_median(valid_prices);
    aggregator.last_aggregated_price = price;
    event::emit(PriceAggregated {
        price,
        source_count: valid_prices.length(),
        agreement: 0,
    });
    price
}

fun compute_median(prices: vector<u64>): u64 {
    let mut sorted = prices;
    let n = sorted.length();
    let mut i = 0;
    while (i < n) {
        let mut j = i + 1;
        while (j < n) {
            if (*sorted.borrow(j) < *sorted.borrow(i)) {
                let tmp = *sorted.borrow(i);
                *sorted.borrow_mut(i) = *sorted.borrow(j);
                *sorted.borrow_mut(j) = tmp;
            };
            j = j + 1;
        };
        i = i + 1;
    };
    *sorted.borrow(n / 2)
}

public fun set_source_weight(
    aggregator: &mut MultiOracleAggregator,
    source_id: u8,
    weight: u64,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == aggregator.admin, 0);
    let mut i = 0;
    while (i < aggregator.sources.length()) {
        let source = aggregator.sources.borrow_mut(i);
        if (source.source_id == source_id) {
            source.weight = weight;
        };
        i = i + 1;
    };
}
```

## 聚合策略对比

| 策略     | 优点           | 缺点                 | 适用场景     |
| -------- | -------------- | -------------------- | ------------ |
| 中位数   | 对异常值鲁棒   | 需要奇数个源         | 通用         |
| 加权平均 | 可信源权重更高 | 权重配置需要专业知识 | 源质量差异大 |
| 偏差仲裁 | 自动剔除异常源 | 实现复杂             | 高安全性要求 |

## 风险分析

| 风险         | 描述                                   |
| ------------ | -------------------------------------- |
| 关联失败     | 多个预言机可能共享同一数据源，同时出错 |
| 聚合逻辑 bug | 中位数/加权计算错误导致所有价格都错    |
| 源数量不足   | 只有 2 个源时，中位数无法判断谁对谁错  |
| 延迟叠加     | 需要等所有预言机都有数据才能聚合       |
