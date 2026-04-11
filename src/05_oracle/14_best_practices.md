# 5.14 预言机最佳实践清单

## 选型决策树（详细版）

```
Step 1：确定数据类型
  ├─ 价格 → Step 2
  ├─ 随机数 → Step 5
  └─ 特色数据 → Switchboard 自定义 Feed

Step 2：确定资产类型
  ├─ 主流（BTC/ETH/SOL/SUI）→ Step 3
  └─ 长尾代币 → Pyth（覆盖最广）+ TWAP 补充

Step 3：确定延迟要求
  ├─ < 1 秒 → Supra（原生集成）
  ├─ 1-60 秒 → Pyth 或 Supra
  └─ > 60 秒 → 任何预言机 + TWAP

Step 4：确定安全要求
  ├─ 低风险（小额）→ 单预言机 + staleness check
  ├─ 中风险（常规 DeFi）→ 双预言机 + 偏差检查
  └─ 高风险（大额借贷）→ 三预言机 + 中位数 + TWAP 交叉验证

Step 5：确定随机数需求
  ├─ 低价值 → sui::random
  ├─ 中价值 → Pyth Entropy
  └─ 高价值 → Supra VRF
```

## 安全检查清单

```
□ 价格读取前检查 staleness
□ 价格读取后检查 deviation（与上次价格对比）
□ 检查 confidence interval（Pyth 提供）
□ 有 fallback 预言机或 fallback 价格
□ 预言机配置与资金池对象分离
□ 预言机切换有 timelock 保护
□ 紧急暂停功能可用
□ PriceRejected 事件有监控告警
□ 多预言机聚合有偏差仲裁
□ 测试覆盖预言机失效场景
```

## 集成代码模板

```move
module defi::oracle_template {
    use sui::object::{Self, UID};
    use sui::clock::Clock;
    use sui::tx_context::TxContext;
    use sui::event;

    public struct OracleConfig has key {
        id: UID,
        max_staleness_ms: u64,
        max_deviation_bps: u64,
        last_good_price: u64,
        fallback_price: u64,
        paused: bool,
        admin: address,
    }

    public fun read_price_safe(
        config: &mut OracleConfig,
        oracle_price: u64,
        oracle_confidence: u64,
        oracle_timestamp_ms: u64,
        clock: &Clock,
    ): u64 {
        assert!(!config.paused, 0);
        let now = clock.timestamp_ms();
        if (now > oracle_timestamp_ms + config.max_staleness_ms) {
            event::emit(PriceRejected { reason: 0 });
            return config.fallback_price
        };
        let dev = if (oracle_price > config.last_good_price) {
            (oracle_price - config.last_good_price) * 10000 / config.last_good_price
        } else {
            (config.last_good_price - oracle_price) * 10000 / config.last_good_price
        };
        if (dev > config.max_deviation_bps) {
            event::emit(PriceRejected { reason: 1 });
            return config.last_good_price
        };
        config.last_good_price = oracle_price;
        oracle_price
    }

    public struct PriceRejected has copy, drop { reason: u64 }
}
```

## 测试策略

```
单元测试：
  □ 正常价格读取
  □ 过时价格被拒绝
  □ 偏差过大被拒绝
  □ fallback 价格正确返回
  □ 紧急暂停生效

场景测试：
  □ 预言机突然返回 0
  □ 预言机价格暴涨 10x
  □ 预言机 5 分钟不更新
  □ 多预言机价格不一致
  □ 切换预言机后协议正常

对抗测试（Fuzz）：
  □ 随机价格输入，协议不应 panic
  □ 极端价格（0, MAX_U64）不应导致溢出
  □ 并发读取和更新不应死锁
```

## 监控与告警

```
监控指标：
  - 预言机价格更新频率
  - 预言机价格与 AMM 价格的偏差
  - PriceRejected 事件触发次数
  - 预言机置信区间变化
  - Fallback 使用频率

告警规则：
  - 预言机 5 分钟未更新 → P1 告警
  - 价格偏差 > 2% → P2 告警
  - Fallback 价格被使用 → P1 告警
  - 紧急暂停触发 → P0 告警
  - 预言机切换事件 → P1 告警
```

## 升级路径设计

```
版本 1（冷启动）：
  单预言机（Pyth）+ 管理员 fallback
  → 快速上线，安全依赖管理员

版本 2（成熟）：
  双预言机（Pyth + Supra）+ 偏差检查
  → 更安全，减少对管理员的依赖

版本 3（去中心化）：
  三预言机 + TWAP + 中位数聚合 + 治理投票切换
  → 最安全，但最复杂
```

## 风险分析

| 风险 | 描述 |
|---|---|
| 过度工程 | 三预言机 + TWAP 对于小额协议来说太复杂 |
| 监控疲劳 | 如果告警太频繁，团队可能忽略真正的异常 |
| 测试覆盖不足 | 预言机失效场景容易被忽视 |
| 文档缺失 | 如果没有记录预言机配置参数，切换时可能出错 |
