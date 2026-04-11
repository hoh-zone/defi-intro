# 5.9 安全价格读取函数：四层防御

## 为什么需要防御式读取

直接信任预言机价格是危险的。任何价格读取函数都应该包含多层检查：

```
四层防御：
  Layer 1: Staleness Check — 价格是否太旧？
  Layer 2: Deviation Check — 价格是否偏离太多？
  Layer 3: Confidence Check — 预言机自己对价格有多确定？
  Layer 4: Fallback — 如果以上检查都失败，怎么办？
```

## 完整四层防御的 Move 实现

```move
module oracle::safe_reader {
    use sui::clock::Clock;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::event;

    const EStale_PRICE: u64 = 0;
    const EPriceDeviation: u64 = 1;
    const ELowConfidence: u64 = 2;
    const EEmergencyPause: u64 = 3;

    public struct SafeOracleConfig has store {
        max_staleness_ms: u64,
        max_deviation_bps: u64,
        min_confidence_ratio_bps: u64,
        fallback_price: u64,
        last_good_price: u64,
        emergency_admin: address,
        paused: bool,
    }

    public struct SafePriceReader has key {
        id: UID,
        config: SafeOracleConfig,
        price_source: String,
    }

    public struct PriceRejected has copy, drop {
        reason: String,
        oracle_price: u64,
        last_good_price: u64,
        timestamp_ms: u64,
    }

    public fun create(
        max_staleness_ms: u64,
        max_deviation_bps: u64,
        min_confidence_ratio_bps: u64,
        initial_price: u64,
        ctx: &mut TxContext,
    ) {
        let reader = SafePriceReader {
            id: object::new(ctx),
            config: SafeOracleConfig {
                max_staleness_ms,
                max_deviation_bps,
                min_confidence_ratio_bps,
                fallback_price: initial_price,
                last_good_price: initial_price,
                emergency_admin: ctx.sender(),
                paused: false,
            },
            price_source: string::utf8(b"pyth"),
        };
        transfer::share_object(reader);
    }

    public fun safe_read(
        reader: &mut SafePriceReader,
        raw_price: u64,
        confidence: u64,
        publish_time_ms: u64,
        clock: &Clock,
    ): u64 {
        assert!(!reader.config.paused, EEmergencyPause);

        let now = clock.timestamp_ms();

        if (now > publish_time_ms + reader.config.max_staleness_ms) {
            event::emit(PriceRejected {
                reason: string::utf8(b"stale"),
                oracle_price: raw_price,
                last_good_price: reader.config.last_good_price,
                timestamp_ms: now,
            });
            return reader.config.fallback_price
        };

        let deviation = if (raw_price > reader.config.last_good_price) {
            (raw_price - reader.config.last_good_price) * 10000 / reader.config.last_good_price
        } else {
            (reader.config.last_good_price - raw_price) * 10000 / raw_price
        };
        if (deviation > reader.config.max_deviation_bps) {
            event::emit(PriceRejected {
                reason: string::utf8(b"deviation"),
                oracle_price: raw_price,
                last_good_price: reader.config.last_good_price,
                timestamp_ms: now,
            });
            return reader.config.last_good_price
        };

        if (confidence * 10000 > raw_price * reader.config.min_confidence_ratio_bps) {
            event::emit(PriceRejected {
                reason: string::utf8(b"low_confidence"),
                oracle_price: raw_price,
                last_good_price: reader.config.last_good_price,
                timestamp_ms: now,
            });
            return reader.config.last_good_price
        };

        reader.config.last_good_price = raw_price;
        raw_price
    }

    public fun update_config(
        reader: &mut SafePriceReader,
        max_staleness_ms: u64,
        max_deviation_bps: u64,
        min_confidence_ratio_bps: u64,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == reader.config.emergency_admin, 0);
        reader.config.max_staleness_ms = max_staleness_ms;
        reader.config.max_deviation_bps = max_deviation_bps;
        reader.config.min_confidence_ratio_bps = min_confidence_ratio_bps;
    }

    public fun emergency_pause(reader: &mut SafePriceReader, ctx: &mut TxContext) {
        assert!(ctx.sender() == reader.config.emergency_admin, 0);
        reader.config.paused = true;
    }

    public fun emergency_unpause(reader: &mut SafePriceReader, ctx: &mut TxContext) {
        assert!(ctx.sender() == reader.config.emergency_admin, 0);
        reader.config.paused = false;
    }

    public fun set_fallback_price(reader: &mut SafePriceReader, price: u64, ctx: &mut TxContext) {
        assert!(ctx.sender() == reader.config.emergency_admin, 0);
        reader.config.fallback_price = price;
    }

    public fun get_last_good_price(reader: &SafePriceReader): u64 {
        reader.config.last_good_price
    }
}
```

## 四层防御的逻辑流

```
读取价格 → Layer 1: Staleness Check
              价格太旧？ → YES → 使用 fallback 价格，发出事件
              NO ↓
            Layer 2: Deviation Check
              偏离上次价格 > 阈值？ → YES → 使用上次好价格，发出事件
              NO ↓
            Layer 3: Confidence Check
              置信区间太宽？ → YES → 使用上次好价格，发出事件
              NO ↓
            更新 last_good_price
            返回新价格
```

## 参数建议

| 参数 | 保守值 | 激进值 | 说明 |
|---|---|---|---|
| max_staleness_ms | 60,000 (1 分钟) | 300,000 (5 分钟) | 越短越安全，但更容易触发 fallback |
| max_deviation_bps | 200 (2%) | 500 (5%) | 越小越安全，但剧烈波动时会卡住 |
| min_confidence_ratio_bps | 100 (1%) | 300 (3%) | 置信区间不能超过价格的这个比例 |

## Fallback 策略

```
策略 1：使用上次好价格（最常见）
  优点：安全，不会使用错误价格
  缺点：如果市场真的变了，价格不准

策略 2：使用 TWAP
  优点：更平滑
  缺点：需要额外的 TWAP 组件

策略 3：暂停协议
  优点：最安全
  缺点：用户无法操作

策略 4：多预言机切换
  优点：持续可用
  缺点：实现复杂
```

## 风险分析

| 风险 | 描述 |
|---|---|
| 过度保守 | 参数设太紧，频繁触发 fallback，协议实际停摆 |
| fallback 价格过时 | 如果长时间使用 fallback，价格严重偏离 |
| 紧急权限滥用 | emergency_admin 可以暂停或设置任意 fallback 价格 |
| 事件未监控 | PriceRejected 事件如果不被监控，攻击可能持续进行 |
