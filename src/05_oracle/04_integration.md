# 5.4 Sui 集成实践与防错设计

## 对象分离原则

预言机配置和协议资金池应该是**不同的对象**。原因：
- 预言机配置需要频繁更新（价格、参数）
- 资金池对象在更新时会有竞争
- 分离后，预言机更新不会阻塞资金池操作

```move
public struct LendingMarket has key {
    id: UID,
    reserves: vector<Reserve>,
    paused: bool,
}

public struct OracleConfig has key {
    id: UID,
    market_id: ID,
    max_price_age_ms: u64,
    max_deviation_bps: u64,
    min_confidence_bps: u64,
    emergency_admin: address,
}
```

## 完整的安全价格读取函数

```move
module defi_oracle {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};
    use pyth::price_feed::{Self, PriceFeed};

    const EPriceStale: u64 = 0;
    const EPriceZero: u64 = 1;
    const EPriceNegative: u64 = 2;
    const EConfTooWide: u64 = 3;
    const EDevTooHigh: u64 = 4;
    const ENotAdmin: u64 = 5;

    public struct PriceGuardConfig has key {
        id: UID,
        max_age_ms: u64,
        min_confidence_ratio_bps: u64,
        max_deviation_bps: u64,
        fallback_price: u64,
        use_fallback: bool,
    }

    public struct PriceSnapshot has store {
        last_valid_price: u64,
        last_valid_time: u64,
        twap_sum: u128,
        twap_start_time: u64,
    }

    public fun read_price_safe(
        config: &PriceGuardConfig,
        feed: &PriceFeed,
        snapshot: &mut PriceSnapshot,
    ): u64 {
        let (price, conf, ts) = price_feed::get_price(feed);
        let now = tx_context::timestamp_ms();

        if (now - ts > config.max_age_ms) {
            if (config.use_fallback) {
                return config.fallback_price
            };
            abort EPriceStale
        };

        if (price == 0) { abort EPriceZero };

        let conf_ratio = conf * 10000 / (price + 1);
        if (conf_ratio > config.min_confidence_ratio_bps) {
            abort EConfTooWide
        };

        if (snapshot.last_valid_price > 0) {
            let dev = if (price > snapshot.last_valid_price) {
                (price - snapshot.last_valid_price) * 10000 / snapshot.last_valid_price
            } else {
                (snapshot.last_valid_price - price) * 10000 / snapshot.last_valid_price
            };
            if (dev > config.max_deviation_bps) {
                abort EDevTooHigh
            };
        };

        snapshot.last_valid_price = price;
        snapshot.last_valid_time = now;
        let dt = now - snapshot.twap_start_time;
        snapshot.twap_sum = snapshot.twap_sum + (price as u128) * (dt as u128);
        snapshot.twap_start_time = now;

        price
    }

    public fun get_twap(snapshot: &PriceSnapshot): u64 {
        let dt = snapshot.last_valid_time - snapshot.twap_start_time;
        if (dt == 0) { return snapshot.last_valid_price };
        ((snapshot.twap_sum / (dt as u128)) as u64)
    }
}
```

## 四层防御总结

```
Layer 1: 时间校验 —— 价格不能太旧
Layer 2: 数值校验 —— 价格不能为零或负
Layer 3: 置信度校验 —— 置信区间不能太宽
Layer 4: 偏差校验 —— 与上次有效价格偏差不能太大
```

为什么需要四层而不是一层？因为每层防御针对不同的攻击向量：
- 时间校验防"过期价格被继续使用"
- 数值校验防"除零错误或极端值"
- 置信度校验防"数据源不确定性过高"
- 偏差校验防"闪电贷操纵或数据源异常"

## 紧急暂停机制

当所有校验都失败时，协议需要能紧急暂停：

```move
public fun emergency_pause(
    config: &PriceGuardConfig,
    market: &mut LendingMarket,
    cap: &EmergencyCap,
) {
    assert!(dummy_ctx().sender() == config.emergency_admin, ENotAdmin);
    market.paused = true;
}
```

暂停不是失败——暂停是最后的防线。一个在极端行情下自动暂停的协议，比一个继续运行直到破产的协议更值得信任。
