# 5.10 DeFi 预言机插槽设计

## 为什么需要插槽模式

DeFi 协议直接依赖具体预言机实现会导致两个问题：

```
问题 1：供应商锁定
  协议写死了 Pyth 的接口 → 如果要换 Supra，需要改所有调用点

问题 2：难以升级
  预言机接口变更 → 需要修改协议核心逻辑 → 重新审计

解决方案：插槽模式（Oracle Slot / Oracle Adapter）
  定义抽象的预言机接口
  具体实现通过"插槽"插入
  切换预言机只需要替换插槽实现，不改协议逻辑
```

## Scallop 风格的预言机接口抽象

Scallop 是 Sui 上的借贷协议，它的预言机设计是一个很好的插槽模式参考：

```move
module oracle::slot {
    use sui::object::{Self, UID, ID};
    use sui::clock::Clock;
    use sui::tx_context::TxContext;
    use sui::event;

    const EUnauthorized: u64 = 0;
    const EInvalidOracle: u64 = 1;
    const EOracleNotSet: u64 = 2;

    public struct PriceData has store {
        price: u64,
        timestamp_ms: u64,
        source_id: u8,
        confidence: u64,
    }

    public struct OracleSlot has key {
        id: UID,
        current_oracle_id: ID,
        oracle_type: u8,
        admin: address,
        pending_oracle_id: Option<ID>,
        pending_oracle_type: Option<u8>,
        switch_time_ms: u64,
    }

    public struct OracleType {
        PYTH: u8;
        SUPRA: u8;
        SWITCHBOARD: u8;
        CUSTOM: u8;
    }

    public struct OracleSlotUpdated has copy, drop {
        old_type: u8,
        new_type: u8,
        timestamp_ms: u64,
    }

    public fun initialize(
        initial_oracle_id: ID,
        oracle_type: u8,
        ctx: &mut TxContext,
    ) {
        let slot = OracleSlot {
            id: object::new(ctx),
            current_oracle_id: initial_oracle_id,
            oracle_type,
            admin: ctx.sender(),
            pending_oracle_id: option::none(),
            pending_oracle_type: option::none(),
            switch_time_ms: 0,
        };
        transfer::share_object(slot);
    }

    public fun get_price(
        slot: &OracleSlot,
        asset: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): PriceData {
        let oracle_id = slot.current_oracle_id;
        let oracle_type = slot.oracle_type;

        if (oracle_type == OracleType.PYTH) {
            read_pyth_price(oracle_id, asset, clock, ctx)
        } else if (oracle_type == OracleType.SUPRA) {
            read_supra_price(oracle_id, asset, clock, ctx)
        } else if (oracle_type == OracleType.SWITCHBOARD) {
            read_switchboard_price(oracle_id, asset, clock, ctx)
        } else {
            read_custom_price(oracle_id, asset, clock, ctx)
        }
    }

    fun read_pyth_price(
        oracle_id: ID,
        asset: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): PriceData {
        let feed = object::borrow_mut<PriceFeed>(oracle_id);
        let (price, conf, ts, _) = price_feed::get_price(feed);
        PriceData {
            price,
            timestamp_ms: ts,
            source_id: OracleType.PYTH,
            confidence: conf,
        }
    }

    fun read_supra_price(
        oracle_id: ID,
        asset: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): PriceData {
        let oracle = object::borrow_mut<SupraOracle>(oracle_id);
        let (price, _, ts) = supra::get_price(oracle, asset_to_pair_index(asset));
        PriceData {
            price,
            timestamp_ms: ts,
            source_id: OracleType.SUPRA,
            confidence: 0,
        }
    }

    fun read_switchboard_price(
        oracle_id: ID,
        asset: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): PriceData {
        let aggregator = object::borrow_mut<Aggregator>(oracle_id);
        let result = switchboard::get_result(aggregator);
        let ts = switchboard::get_latest_timestamp(aggregator);
        PriceData {
            price: result,
            timestamp_ms: ts,
            source_id: OracleType.SWITCHBOARD,
            confidence: 0,
        }
    }

    fun read_custom_price(
        oracle_id: ID,
        asset: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): PriceData {
        PriceData {
            price: 0,
            timestamp_ms: clock.timestamp_ms(),
            source_id: OracleType.CUSTOM,
            confidence: 0,
        }
    }

    public fun propose_oracle_switch(
        slot: &mut OracleSlot,
        new_oracle_id: ID,
        new_oracle_type: u8,
        timelock_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == slot.admin, EUnauthorized);
        slot.pending_oracle_id = option::some(new_oracle_id);
        slot.pending_oracle_type = option::some(new_oracle_type);
        slot.switch_time_ms = clock.timestamp_ms() + timelock_ms;
    }

    public fun execute_switch(
        slot: &mut OracleSlot,
        clock: &Clock,
    ) {
        assert!(option::is_some(&slot.pending_oracle_id), EOracleNotSet);
        assert!(clock.timestamp_ms() >= slot.switch_time_ms, 0);
        let old_type = slot.oracle_type;
        let new_oracle_id = option::extract(&mut slot.pending_oracle_id);
        let new_type = option::extract(&mut slot.pending_oracle_type);
        slot.current_oracle_id = new_oracle_id;
        slot.oracle_type = new_type;
        event::emit(OracleSlotUpdated {
            old_type,
            new_type,
            timestamp_ms: clock.timestamp_ms(),
        });
    }

    public fun cancel_switch(
        slot: &mut OracleSlot,
        ctx: &mut TxContext,
    ) {
        assert!(ctx.sender() == slot.admin, EUnauthorized);
        slot.pending_oracle_id = option::none();
        slot.pending_oracle_type = option::none();
        slot.switch_time_ms = 0;
    }

    fun asset_to_pair_index(asset: address): u64 {
        0
    }

    public fun current_oracle_type(slot: &OracleSlot): u8 {
        slot.oracle_type
    }

    public fun has_pending_switch(slot: &OracleSlot): bool {
        option::is_some(&slot.pending_oracle_id)
    }
}
```

## 插槽设计的核心原则

```
原则 1：接口统一
  无论底层用哪个预言机，上层看到的都是 PriceData
  协议代码永远不直接引用具体预言机的类型

原则 2：可切换
  切换预言机不需要修改协议核心逻辑
  只需要替换插槽中的实现

原则 3：时间锁保护
  切换预言机不能即时生效
  需要 timelock（如 24 小时）
  给用户反应时间

原则 4：可回滚
  切换后发现问题，可以快速回滚到之前的预言机
```

## 协议如何使用插槽

```move
module lending::market {
    use oracle::slot::{Self, OracleSlot, PriceData};

    public struct Market has key {
        id: UID,
        oracle_slot: ID,
        reserves: vector<Reserve>,
    }

    public fun get_asset_price(
        market: &Market,
        asset: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        let slot = object::borrow_mut<OracleSlot>(market.oracle_slot);
        let data = slot::get_price(slot, asset, clock, ctx);
        data.price
    }

    public fun borrow(
        market: &mut Market,
        asset: address,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let price = get_asset_price(market, asset, clock, ctx);
        let health = calculate_health(market, asset, amount, price);
        assert!(health >= MIN_HEALTH_FACTOR, 0);
    }
}
```

## 风险分析

| 风险 | 描述 |
|---|---|
| 切换期间风险 | timelock 期间，用户不知道最终会切换到哪个预言机 |
| 插槽实现 bug | 统一接口层的实现可能有 bug，影响所有预言机 |
| 治理攻击 | 如果 admin 可以即时切换预言机，可能切换到恶意预言机 |
| 接口不完整 | 统一接口可能无法覆盖所有预言机的特殊功能 |
