# 21.7 升级安全与紧急响应

## Sui 包升级机制

Sui 的升级通过 `UpgradeCap` 控制。持有 `UpgradeCap` 的地址可以发布新版本的包：

```bash
# 构建新版本
sui move build

# 发布升级（需要 UpgradeCap）
sui client upgrade --upgrade-capability <UPGRADE_CAP_ID> \
  --gas-budget 100000000
```

### UpgradeCap 的安全含义

`UpgradeCap` 是一个 owned 对象，持有者可以无限制地升级包。这既是权力也是风险：

1. **单点故障**：UpgradeCap 被盗 = 合约被恶意修改
2. **不可逆**：升级后无法自动回滚
3. **兼容性**：升级可能破坏用户数据

### UpgradeCap 的生命周期管理

```move
module defi::upgrade_management;
    use sui::package::{Self, UpgradeCap};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;

    public struct UpgradeAdminCap has key, store { id: UID }

    public fun init(cap: UpgradeCap, ctx: &mut TxContext) {
        transfer::public_transfer(
            UpgradeAdminCap { id: object::new(ctx) },
            ctx.sender(),
        );
        let cap_uid = package::upgrade_caps_to_uid(cap);
        cap_uid.delete();
    }
```

等等——上面的代码把 `UpgradeCap` 的 UID 删除了，这实际上是销毁 UpgradeCap，使包永久不可升级。这对于确定不再需要升级的协议是正确的做法。

更常见的做法是将 `UpgradeCap` 转移到多签：

```bash
# 将 UpgradeCap 转移到多签地址
sui client transfer --object-id <UPGRADE_CAP_ID> \
  --to <MULTISIG_ADDRESS> \
  --gas-budget 100000000
```

## 兼容性升级 vs 破坏性升级

Sui 的升级策略有三种模式：

| 模式 | 允许的变更 | 兼容性 |
|------|------------|--------|
| `compatible` | 新增函数、新模块、修改函数体 | 完全兼容 |
| `additive` | 只能新增，不能修改 | 最安全 |
| `dep-only` | 只能改依赖 | 最低风险 |

```toml
# Move.toml 中指定升级策略
[addresses]
defi = "0x0"

[dev-addresses]
defi = "0x0"
```

### 兼容性规则

以下变更**总是安全**的：
- 新增 `public fun`
- 修改函数体实现（不改签名）
- 新增 struct
- 新增模块

以下变更**可能破坏兼容性**：
- 修改函数签名（参数类型、返回值）
- 删除 `public fun`
- 修改 struct 字段
- 删除模块

```move
module defi::version_control;
    use sui::object::{Self, UID};

    public struct Protocol has key {
        id: UID,
        version: u16,
    }

    public struct VersionEvent has copy, drop {
        old_version: u16,
        new_version: u16,
    }

    public fun get_version(protocol: &Protocol): u16 {
        protocol.version
    }

    public fun require_version(protocol: &Protocol, min_version: u16) {
        assert!(protocol.version >= min_version, EVersionTooOld);
    }

    public fun upgrade_version(protocol: &mut Protocol) {
        let old = protocol.version;
        protocol.version = protocol.version + 1;
        sui::event::emit(VersionEvent {
            old_version: old,
            new_version: protocol.version,
        });
    }

    #[error]
    const EVersionTooOld: vector<u8> = b"Version Too Old";
```

## 紧急暂停

紧急暂停是 DeFi 协议最重要的安全开关。设计要点：

1. **触发条件明确**：什么情况下应该暂停
2. **影响范围最小**：只暂停受影响的操作
3. **恢复门槛更高**：取消暂停应该比暂停更难

```move
module defi::emergency_pause;
    use sui::object::{Self, UID};
    use sui::event;
    use sui::clock::Clock;

    public struct PauseCap has key, store { id: UID }
    public struct UnpauseCap has key, store { id: UID }

    public struct PauseState has key {
        id: UID,
        deposits_paused: bool,
        withdrawals_paused: bool,
        borrows_paused: bool,
        liquidations_paused: bool,
        paused_at: u64,
        pause_reason: u8,
    }

    const REASON_ADMIN: u8 = 1;
    const REASON_ORACLE: u8 = 2;
    const REASON_SECURITY: u8 = 3;
    const REASON_CIRCUIT_BREAKER: u8 = 4;

    public struct Paused has copy, drop {
        reason: u8,
        timestamp: u64,
    }

    public struct Unpaused has copy, drop {
        timestamp: u64,
    }

    public fun pause_all(
        _: &PauseCap,
        state: &mut PauseState,
        reason: u8,
        clock: &Clock,
    ) {
        state.deposits_paused = true;
        state.withdrawals_paused = true;
        state.borrows_paused = true;
        state.liquidations_paused = true;
        state.paused_at = sui::clock::timestamp_ms(clock);
        state.pause_reason = reason;

        event::emit(Paused {
            reason,
            timestamp: state.paused_at,
        });
    }

    public fun pause_deposits(
        _: &PauseCap,
        state: &mut PauseState,
        clock: &Clock,
    ) {
        state.deposits_paused = true;
        state.paused_at = sui::clock::timestamp_ms(clock);
    }

    public fun unpause_all(
        _: &UnpauseCap,
        state: &mut PauseState,
        clock: &Clock,
    ) {
        state.deposits_paused = false;
        state.withdrawals_paused = false;
        state.borrows_paused = false;
        state.liquidations_paused = false;
        state.paused_at = 0;
        state.pause_reason = 0;

        event::emit(Unpaused {
            timestamp: sui::clock::timestamp_ms(clock),
        });
    }

    public fun assert_not_paused(state: &PauseState, operation: u8) {
        let paused = if (operation == OP_DEPOSIT) {
            state.deposits_paused
        } else if (operation == OP_WITHDRAW) {
            state.withdrawals_paused
        } else if (operation == OP_BORROW) {
            state.borrows_paused
        } else if (operation == OP_LIQUIDATE) {
            state.liquidations_paused
        } else {
            false
        };
        assert!(!paused, EOperationPaused);
    }

    const OP_DEPOSIT: u8 = 1;
    const OP_WITHDRAW: u8 = 2;
    const OP_BORROW: u8 = 3;
    const OP_LIQUIDATE: u8 = 4;
    #[error]
    const EOperationPaused: vector<u8> = b"Operation Paused";
```

关键设计：
- `PauseCap` 和 `UnpauseCap` 分离——暂停用 2-of-3，恢复用 3-of-5
- 细粒度暂停——可以只暂停存款而不影响提款
- 原因记录——便于事后审计

## 紧急响应预案

### 预案模板

```move
module defi::emergency_plan;
    public struct Plan has store {
        level: u8,
        actions: vector<u8>,
        contacts: vector<address>,
        estimated_time_ms: u64,
    }

    const LEVEL_INFO: u8 = 1;
    const LEVEL_WARNING: u8 = 2;
    const LEVEL_CRITICAL: u8 = 3;
    const LEVEL_EMERGENCY: u8 = 4;

    const ACTION_PAUSE_DEPOSITS: u8 = 1;
    const ACTION_PAUSE_ALL: u8 = 2;
    const ACTION_FREEZE_PROTOCOL: u8 = 3;
    const ACTION_NOTIFY_AUDITORS: u8 = 4;
    const ACTION_PUBLIC_ANNOUNCEMENT: u8 = 5;
```

### 响应流程

```
发现异常
  │
  ├─ 确认影响范围
  │    ├─ 单一市场？→ 暂停该市场
  │    ├─ 跨市场？→ 全协议暂停
  │    └─ 资金安全？→ 紧急关停
  │
  ├─ 通知团队（内部频道）
  │
  ├─ 执行暂停（2-of-3 多签）
  │
  ├─ 发布公告（原因 + 预计恢复时间）
  │
  ├─ 分析根因
  │    ├─ 预言机异常？→ 等待恢复 + 检查仓位
  │    ├─ 代码漏洞？→ 准备补丁升级
  │    └─ 外部攻击？→ 联系安全团队 + 取证
  │
  └─ 恢复（3-of-5 多签 + 时间锁）
```

## 回滚预案

Sui 的包升级不可自动回滚，但可以部署修复版本：

```bash
# 1. 紧急暂停
sui client call --package <PACKAGE_ID> --module emergency_pause \
  --function pause_all --args <PAUSE_CAP> <PAUSE_STATE> <CLOCK>

# 2. 构建修复版本
# 修改代码，修复漏洞
sui move build

# 3. 升级到修复版本（需要 UpgradeCap 的多签批准）
sui client upgrade --upgrade-capability <UPGRADE_CAP_ID>

# 4. 验证修复
sui client call --package <NEW_PACKAGE_ID> --module version_control \
  --function get_version --args <PROTOCOL>

# 5. 取消暂停
sui client call --package <PACKAGE_ID> --module emergency_pause \
  --function unpause_all --args <UNPAUSE_CAP> <PAUSE_STATE> <CLOCK>
```

### 关键时间线

| 事件 | 最大响应时间 |
|------|-------------|
| 检测到异常 | 实时（监控告警） |
| 确认并暂停 | < 15 分钟 |
| 发布公告 | < 30 分钟 |
| 根因分析 | < 4 小时 |
| 补丁开发 + 测试 | < 24 小时 |
| 多签批准 + 升级 | < 48 小时 |
| 恢复运营 | < 72 小时 |

## 小结

升级安全和紧急响应是"希望永远用不上但必须准备好"的基础设施。UpgradeCap 必须由多签持有。紧急暂停应该细粒度、可分级。恢复的门槛应该高于暂停。每一分钟的反应时间差，可能意味着数百万资金的安全或损失。
