# 5.15 实战：从选择预言机到上线

## 场景：为一个 Sui 借贷协议集成预言机

本节以一个完整的借贷协议为例，演示从零开始集成预言机的全过程。

## Step 1：需求分析

```
协议需求：
  - 支持 SUI、USDC、WETH 三种资产
  - 需要实时价格来计算健康因子和清算
  - TVL 预计 $1M-$10M
  - 安全要求：中高（涉及用户资金）

延迟要求：
  - 价格更新不超过 60 秒
  - 偏差容忍度：2%

安全要求：
  - 至少两个独立预言机
  - 有 fallback 机制
  - 紧急暂停功能
```

## Step 2：选型决策

```
选择：Pyth（主）+ Supra（备）+ TWAP（交叉验证）

理由：
  - Pyth：覆盖 SUI/USDC/WETH，Pull 模式低延迟
  - Supra：原生集成，作为备份和交叉验证
  - TWAP：从 DEX 池计算，作为最终 fallback
```

## Step 3：实现预言机插槽

```move
module lending::oracle_integration;

use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::object::{Self, UID, ID};
use sui::sui::SUI;
use sui::tx_context::TxContext;

#[error]
const EStale: vector<u8> = b"Stale";
#[error]
const EDeviation: vector<u8> = b"Deviation";
#[error]
const EPaused: vector<u8> = b"Paused";
#[error]
const EUnauthorized: vector<u8> = b"Unauthorized";

public struct AssetOracle has store {
    asset_type: String,
    pyth_feed_id: ID,
    supra_pair_index: u64,
    twap_pool_id: ID,
    decimals: u8,
}

public struct LendingOracle has key {
    id: UID,
    assets: vector<AssetOracle>,
    max_staleness_ms: u64,
    max_deviation_bps: u64,
    max_pyth_supra_deviation_bps: u64,
    last_prices: vector<u64>,
    fallback_prices: vector<u64>,
    paused: bool,
    admin: address,
}

public struct PriceRead has copy, drop {
    asset: String,
    price: u64,
    source: u8,
    timestamp_ms: u64,
}

const SOURCE_PYTH: u8 = 1;
const SOURCE_SUPRA: u8 = 2;
const SOURCE_TWAP: u8 = 3;
const SOURCE_FALLBACK: u8 = 4;

public fun create(max_staleness_ms: u64, max_deviation_bps: u64, ctx: &mut TxContext) {
    let oracle = LendingOracle {
        id: object::new(ctx),
        assets: vector::empty(),
        max_staleness_ms,
        max_deviation_bps,
        max_pyth_supra_deviation_bps: 300,
        last_prices: vector::empty(),
        fallback_prices: vector::empty(),
        paused: false,
        admin: ctx.sender(),
    };
    transfer::share_object(oracle);
}

public fun add_asset(
    oracle: &mut LendingOracle,
    asset_type: String,
    pyth_feed_id: ID,
    supra_pair_index: u64,
    twap_pool_id: ID,
    decimals: u8,
    initial_price: u64,
) {
    oracle
        .assets
        .push_back(AssetOracle {
            asset_type,
            pyth_feed_id,
            supra_pair_index,
            twap_pool_id,
            decimals,
        });
    oracle.last_prices.push_back(initial_price);
    oracle.fallback_prices.push_back(initial_price);
}

public fun get_price(
    oracle: &mut LendingOracle,
    asset_index: u64,
    pyth_price: u64,
    pyth_timestamp_ms: u64,
    supra_price: u64,
    supra_timestamp_ms: u64,
    twap_price: u64,
    clock: &Clock,
): u64 {
    assert!(!oracle.paused, EPaused);
    let now = clock.timestamp_ms();
    let last_price = *oracle.last_prices.borrow(asset_index);

    let pyth_fresh = now - pyth_timestamp_ms < oracle.max_staleness_ms;
    let supra_fresh = now - supra_timestamp_ms < oracle.max_staleness_ms;

    if (pyth_fresh && supra_fresh) {
        let dev = if (pyth_price > supra_price) {
            (pyth_price - supra_price) * 10000 / supra_price
        } else {
            (supra_price - pyth_price) * 10000 / pyth_price
        };
        if (dev <= oracle.max_pyth_supra_deviation_bps) {
            let price = (pyth_price + supra_price) / 2;
            update_price(oracle, asset_index, price, SOURCE_PYTH, now);
            price
        } else {
            let median = get_median(pyth_price, supra_price, twap_price);
            update_price(oracle, asset_index, median, SOURCE_TWAP, now);
            median
        }
    } else if (pyth_fresh) {
        update_price(oracle, asset_index, pyth_price, SOURCE_PYTH, now);
        pyth_price
    } else if (supra_fresh) {
        update_price(oracle, asset_index, supra_price, SOURCE_SUPRA, now);
        supra_price
    } else {
        update_price(oracle, asset_index, twap_price, SOURCE_TWAP, now);
        twap_price
    }
}

fun update_price(
    oracle: &mut LendingOracle,
    asset_index: u64,
    new_price: u64,
    source: u8,
    timestamp_ms: u64,
) {
    let last = *oracle.last_prices.borrow(asset_index);
    let dev = if (new_price > last) {
        (new_price - last) * 10000 / last
    } else {
        (last - new_price) * 10000 / new_price
    };
    assert!(dev <= oracle.max_deviation_bps, EDeviation);
    *oracle.last_prices.borrow_mut(asset_index) = new_price;
    *oracle.fallback_prices.borrow_mut(asset_index) = new_price;
    let asset = oracle.assets.borrow(asset_index);
    event::emit(PriceRead {
        asset: asset.asset_type,
        price: new_price,
        source,
        timestamp_ms,
    });
}

fun get_median(a: u64, b: u64, c: u64): u64 {
    if (a >= b) {
        if (b >= c) { b } else if (a >= c) { c } else { a }
    } else {
        if (a >= c) { a } else if (b >= c) { c } else { b }
    }
}

public fun emergency_pause(oracle: &mut LendingOracle, ctx: &mut TxContext) {
    assert!(ctx.sender() == oracle.admin, EUnauthorized);
    oracle.paused = true;
}

public fun emergency_unpause(oracle: &mut LendingOracle, ctx: &mut TxContext) {
    assert!(ctx.sender() == oracle.admin, EUnauthorized);
    oracle.paused = false;
}

public fun get_last_price(oracle: &LendingOracle, asset_index: u64): u64 {
    *oracle.last_prices.borrow(asset_index)
}
```

## Step 4：测试

```move
#[test]
fun test_normal_price_read() {
    let mut oracle = create_test_oracle();
    let clock = clock::create_for_testing();
    let price = get_price(&mut oracle, 0, 1000, clock.timestamp_ms(), 1002, clock.timestamp_ms(), 1001, &clock);
    assert!(price == 1001);
}

#[test]
fun test_pyth_only_fresh() {
    let mut oracle = create_test_oracle();
    let clock = clock::create_for_testing();
    let old_ts = clock.timestamp_ms() - 120_000;
    let price = get_price(&mut oracle, 0, 1000, clock.timestamp_ms(), 1002, old_ts, 1001, &clock);
    assert!(price == 1000);
}

#[test]
#[expected_failure(abort_code = EPaused)]
fun test_paused_rejects() {
    let mut oracle = create_test_oracle();
    oracle.paused = true;
    let clock = clock::create_for_testing();
    get_price(&mut oracle, 0, 1000, clock.timestamp_ms(), 1002, clock.timestamp_ms(), 1001, &clock);
}
```

## Step 5：部署与上线检查清单

```
部署前：
  □ 所有测试通过（单元 + 场景 + fuzz）
  □ 预言机对象 ID 已确认
  □ max_staleness 和 max_deviation 参数已设置
  □ admin 地址使用多签钱包
  □ 监控告警已配置

上线时：
  □ 先用小额资金测试
  □ 手动触发预言机失效场景，验证 fallback
  □ 检查 PriceRead 事件是否正常发出
  □ 验证紧急暂停功能

上线后：
  □ 持续监控 24 小时
  □ 检查 PriceRejected 事件频率
  □ 对比预言机价格与 CEX 价格
  □ 准备好切换预案
```

## 本章总结

预言机是 DeFi 最重要的基础设施之一。本章从"什么是预言机"出发，深入介绍了 Sui 上所有主流预言机的集成方式，提供了完整的插槽设计、安全读取函数和最佳实践清单。

核心教训：**永远不要无条件信任任何预言机价格。多层防御不是过度设计——它是被数十亿美元损失换来的经验。**
