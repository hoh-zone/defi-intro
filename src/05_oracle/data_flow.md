# 5.2 价格更新路径与信任边界

## 完整路径

价格数据从链下到链上，经过五个环节：

```mermaid
graph LR
    A[数据源] --> B[聚合]
    B --> C[签名/证明]
    C --> D[链上状态]
    D --> E[合约消费]
```

每个环节都是一个信任边界。

### 环节 1：数据源

数据从哪来？通常是多个 CEX 和 DEX 的价格。数据源的数量和多样性决定了抗操纵能力。

### 环节 2：聚合

多个数据源的价格如何合并？常见方法：
- 中位数（Median）——抗极端值
- 加权平均（Weighted Average）——按交易量加权
- VWAP（Volume Weighted Average Price）——按交易量加权的时间平均

### 环节 3：签名/证明

谁在为这个价格背书？
- 中心化预言机：运营方签名
- 去中心化预言机：多个节点签名，达到阈值后生效
- Pyth 风格：数据发布者签名 + 链上验证

### 环节 4：链上状态

价格数据如何存储在链上？

```move
struct PriceFeed has key {
    id: UID,
    price: u64,
    conf: u64,
    emit_time: u64,
    update_count: u64,
}
```

### 环节 5：合约消费

协议如何读取价格？

```move
public fun get_current_price(feed: &PriceFeed): (u64, u64, u64) {
    (feed.price, feed.conf, feed.emit_time)
}
```

## Push vs Pull 模型

### Push 模型

预言机节点定期将价格推送到链上。

- 优点：协议读取时价格一定已经在链上
- 缺点：每次推送都消耗 Gas；可能推送了不需要的价格更新
- 例子：Chainlink

### Pull 模型

价格数据链下可用，用户在需要时通过交易将价格拉到链上。

- 优点：只在需要时才付费；价格数据不占用链上存储
- 缺点：需要额外的交易步骤
- 例子：Pyth Network（Sui 上的主要预言机）

## Pyth 在 Sui 上的集成

```move
module lending_oracle {
    use pyth::price_feed::{Self, PriceFeed};
    use sui::object::{Self, ID};

    const EPriceTooOld: u64 = 100;
    const EPriceTooLow: u64 = 101;
    const EConfidenceTooLow: u64 = 102;
    const EDeviationTooHigh: u64 = 103;

    struct OracleConfig has key {
        id: UID,
        max_age_ms: u64,
        min_price: u64,
        max_deviation_bps: u64,
        min_confidence_ratio_bps: u64,
    }

    public fun safe_read_price(
        config: &OracleConfig,
        feed: &PriceFeed,
        reference_price: u64,
    ): u64 {
        let (price, conf, timestamp) = price_feed::get_price(feed);
        let now = tx_context::timestamp_ms();
        assert!(now - timestamp <= config.max_age_ms, EPriceTooOld);
        assert!(price >= config.min_price, EPriceTooLow);
        let conf_ratio = conf * 10000 / (price + 1);
        assert!(conf_ratio <= config.min_confidence_ratio_bps, EConfidenceTooLow);
        let deviation = if (price > reference_price) {
            (price - reference_price) * 10000 / reference_price
        } else {
            (reference_price - price) * 10000 / reference_price
        };
        assert!(deviation <= config.max_deviation_bps, EDeviationTooHigh);
        price
    }
}
```

这段代码展示了四层防御：
1. **时间校验**：价格不能太旧
2. **数值校验**：价格不能低于合理阈值
3. **置信度校验**：置信区间不能太宽
4. **偏差校验**：与参考价格的偏差不能太大

每一层都拦截一类攻击。单层防御是不够的。
