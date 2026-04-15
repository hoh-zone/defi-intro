# 5.13 预言机与协议的架构分离

## 对象分离原则

在 Sui 上，预言机配置和协议核心应该是**不同的对象**：

```
❌ 反模式：预言机数据嵌入协议对象
  public struct Market {
      oracle_price: u64,
      oracle_update_time: u64,
      reserves: vector<Reserve>,
      ...
  }
  → 预言机更新会阻塞其他操作

✅ 正确模式：预言机配置独立对象
  public struct Market { reserves: vector<Reserve>, ... }
  public struct OracleConfig { market_id: ID, max_staleness: u64, ... }
  → 预言机更新不影响 Market 对象
```

## 架构分离的 Move 实现

```move
module defi::separated_architecture;

use sui::clock::Clock;
use sui::event;
use sui::object::{Self, UID, ID};
use sui::tx_context::TxContext;

public struct Market has key {
    id: UID,
    oracle_config_id: ID,
    reserves: vector<Reserve>,
    paused: bool,
    admin: address,
}

public struct Reserve has store {
    coin_type: String,
    total_deposits: u64,
    total_borrows: u64,
    collateral_factor_bps: u64,
    liquidation_threshold_bps: u64,
}

public struct OracleConfig has key {
    id: UID,
    market_id: ID,
    primary_oracle_type: u8,
    primary_oracle_id: ID,
    fallback_oracle_type: u8,
    fallback_oracle_id: ID,
    max_staleness_ms: u64,
    max_deviation_bps: u64,
    emergency_admin: address,
}

public struct OracleSwitched has copy, drop {
    market_id: address,
    old_type: u8,
    new_type: u8,
}

public fun create_market(primary_oracle_type: u8, primary_oracle_id: ID, ctx: &mut TxContext) {
    let market = Market {
        id: object::new(ctx),
        oracle_config_id: object::id(&oracle_config),
        reserves: vector::empty(),
        paused: false,
        admin: ctx.sender(),
    };
    let oracle_config = OracleConfig {
        id: object::new(ctx),
        market_id: object::id(&market),
        primary_oracle_type,
        primary_oracle_id,
        fallback_oracle_type: 0,
        fallback_oracle_id: object::id_from_address(@0x0),
        max_staleness_ms: 60_000,
        max_deviation_bps: 300,
        emergency_admin: ctx.sender(),
    };
    transfer::share_object(market);
    transfer::share_object(oracle_config);
}

public fun get_price(
    market: &Market,
    oracle_config: &OracleConfig,
    asset: address,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    assert!(!market.paused, 0);
    read_safe_price(oracle_config, asset, clock, ctx)
}

fun read_safe_price(
    config: &OracleConfig,
    asset: address,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    0
}

public fun emergency_switch_oracle(
    oracle_config: &mut OracleConfig,
    new_type: u8,
    new_id: ID,
    ctx: &mut TxContext,
) {
    assert!(ctx.sender() == oracle_config.emergency_admin, 0);
    let old_type = oracle_config.primary_oracle_type;
    oracle_config.fallback_oracle_type = old_type;
    oracle_config.fallback_oracle_id = oracle_config.primary_oracle_id;
    oracle_config.primary_oracle_type = new_type;
    oracle_config.primary_oracle_id = new_id;
    event::emit(OracleSwitched {
        market_id: object::uid_to_address(&oracle_config.market_id),
        old_type,
        new_type,
    });
}

public fun pause_market(market: &mut Market, ctx: &mut TxContext) {
    assert!(ctx.sender() == market.admin, 0);
    market.paused = true;
}
```

## 紧急切换流程

```
预言机紧急切换的标准流程：

1. 检测：监控系统发现预言机异常
   - 价格停滞超过 max_staleness
   - 价格偏离 AMM 价格超过阈值
   - 预言机合约出现错误

2. 决策：管理员判断是否需要切换
   - 确认不是短暂波动
   - 评估影响范围

3. 执行：调用 emergency_switch_oracle
   - 当前预言机降级为 fallback
   - 备用预言机升级为 primary
   - 发出 OracleSwitched 事件

4. 通知：通过事件和社交媒体告知用户
   - 说明切换原因
   - 新预言机的类型和地址
   - 预计恢复正常的时间

5. 监控：密切监控新预言机的表现
   - 如果新预言机也有问题
   - 启用 fallback 或暂停协议
```

## Sui 对象模型的优势

```
在 EVM 上：
  所有状态在一个合约中 → 预言机更新需要获取合约锁
  → 高并发时性能瓶颈

在 Sui 上：
  Market 和 OracleConfig 是不同对象
  → 预言机更新和用户操作可以并行执行
  → Sui 的并行执行引擎天然支持这种分离
```

## 风险分析

| 风险         | 描述                                           |
| ------------ | ---------------------------------------------- |
| 对象引用断裂 | 如果 oracle_config_id 指向错误的对象           |
| 紧急权限滥用 | emergency_admin 可以即时切换预言机             |
| 切换延迟     | 在切换期间，协议可能使用旧（错误）的价格       |
| 对象所有权   | 谁拥有 OracleConfig 对象？共享对象 vs 拥有对象 |
