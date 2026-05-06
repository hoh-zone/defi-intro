# 5.5 Pyth 与 Switchboard 实例对比

## Pyth Network

### 设计理念

Pyth 的核心理念是**价格事实（Price Facts）**——不是"预言机告诉你价格是多少"，而是"数据发布者声明价格是多少，你验证这个声明是否可信"。

### 工作模式：Pull

Pyth 在 Sui 上使用 Pull 模式。价格数据链下可用，用户在需要时通过交易将价格拉到链上。

交易流程：

1. 用户从 Pyth 的 Hermes API 获取最新的价格更新数据（链下）
2. 在交易中将更新数据提交到链上的 PriceFeed 对象
3. 协议读取 PriceFeed 对象中的价格

```move
use pyth::price_feed::{Self, PriceFeed};

public fun update_and_read(
    feed: &mut PriceFeed,
    update_data: vector<u8>,
    ctx: &mut TxContext,
): u64 {
    pyth::update_price_feed(feed, update_data, ctx);
    let (price, _, _) = price_feed::get_price(feed);
    price
}
```

### 优势

- 数据发布者是第一方（交易所、做市商），不是第三方节点
- 更新成本低（只在需要时更新）
- 置信区间提供数据质量的量化指标

### 注意事项

- 需要在交易中手动提交更新数据
- 如果 Hermes API 不可用，价格无法更新
- 需要自己在交易中包含价格校验逻辑

## Switchboard

### 设计理念

Switchboard 的核心理念是**按需喂价（On-demand）**——每次交易获取当时最新的价格，价格绑定到具体交易。

### 工作模式

Switchboard 在 Sui 上使用不同的集成方式。价格更新通常由专门的聚合器节点触发，协议直接读取链上状态。

```move
use switchboard::aggregator::{Self, Aggregator};

public fun read_switchboard_price(
    aggregator: &Aggregator,
): u64 {
    let result = aggregator::get_latest_result(aggregator);
    let (value, timestamp) = (result.value, timestamp);
    assert!(tx_context::timestamp_ms() - timestamp < 60000, 0);
    value
}
```

### 优势

- 更新频率可配置
- 支持自定义数据源和聚合逻辑
- 可以创建非价格类的数据 feed

### 注意事项

- 依赖聚合器节点的正常运行
- 更新频率受节点配置影响
- 需要关注链上状态的新鲜度

## 选择框架

| 维度     | Pyth                     | Switchboard            |
| -------- | ------------------------ | ---------------------- |
| 数据来源 | 第一方（交易所、做市商） | 第三方节点聚合         |
| 更新模式 | Pull（用户提交）         | Push（节点推送）+ Pull |
| 置信区间 | 有（量化数据质量）       | 无标准化的置信区间     |
| Gas 开销 | 更新者在交易中支付       | 节点支付更新 Gas       |
| 适合场景 | 需要高精度价格事实       | 需要自定义数据源       |
| 风险点   | Hermes API 可用性        | 节点可靠性和频率       |

### 选择依据

选择的根本标准不是"哪个更准"，而是**它的失效模式在你的协议中是否可控**。

- 如果你的协议需要"价格事实"级别的可验证性 → Pyth
- 如果你的协议需要灵活的数据源配置 → Switchboard
- 如果安全要求极高 → **两者都接入，取交集或互相验证**
