# 12.3 部署、升级与紧急暂停

## 部署是一个过程

部署不是"点一下发布按钮"。它是一个多步骤的过程：

### 部署清单

```bash
1. 在测试网部署并运行完整测试套件
   sui move test

2. 在测试网运行压力测试
   模拟大量并发存款/借款/清算

3. 在测试网模拟升级流程
   验证升级后数据兼容性

4. 审计合约
   内部自查 + 外部审计

5. 在主网部署初始版本
   使用可升级模式

6. 初始化协议参数
   设置利率、清算阈值、预言机地址等

7. 转移 AdminCap 到多签地址
   使用至少 3/5 多签

8. 公告部署完成
   包含合约地址、参数、审计报告
```

## 升级策略

Sui 支持合约升级。升级策略：

```move
module protocol::upgrade {
    struct PackageCap has key {
        id: UID,
        package_id: ID,
    }

    struct UpgradePolicy has store {
        max_upgrade_delay_ms: u64,
        required_signatures: u64,
        pending_upgrade: Option<UpgradeProposal>,
    }

    struct UpgradeProposal has store {
        new_package_digest: vector<u8>,
        proposed_at: u64,
        signers: vector<address>,
    }
}
```

### 升级兼容性规则

| 修改类型 | 兼容？ | 说明 |
|----------|--------|------|
| 新增 public 函数 | 是 | 不影响现有调用 |
| 修改函数签名 | 否 | 必须通过新函数迁移 |
| 新增 struct 字段 | 否 | 需要迁移方案 |
| 修改错误码 | 谨慎 | 可能影响错误处理逻辑 |
| 修改事件结构 | 谨慎 | 可能影响链下监控 |

## 紧急暂停机制

```move
module protocol::pause {
    struct PauseState has store {
        deposits_paused: bool,
        withdrawals_paused: bool,
        borrows_paused: bool,
        liquidations_paused: bool,
        all_paused: bool,
    }

    public fun pause_deposits(_cap: &AdminCap, state: &mut PauseState) {
        state.deposits_paused = true;
    }

    public fun pause_all(_cap: &AdminCap, state: &mut PauseState) {
        state.all_paused = true;
    }

    public fun is_paused(state: &PauseState, action: u8): bool {
        if (state.all_paused) { return true };
        match (action) {
            0 => state.deposits_paused,
            1 => state.withdrawals_paused,
            2 => state.borrows_paused,
            3 => state.liquidations_paused,
            _ => false,
        }
    }
}
```

细粒度暂停：可以只暂停存款而不影响取款。确保用户在紧急情况下仍能退出。
