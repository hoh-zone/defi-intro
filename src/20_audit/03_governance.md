# 20.3 参数治理与去中心化路径

## 参数的分类

### 技术参数

影响协议运行的技术配置。修改风险高，需要谨慎。

| 参数         | 例子                      | 修改频率 |
| ------------ | ------------------------- | -------- |
| 利率模型参数 | base_rate, slope1, slope2 | 低       |
| 清算参数     | threshold, penalty        | 低       |
| 预言机配置   | max_age, max_deviation    | 极低     |
| 合约地址     | oracle_feed, treasury     | 极低     |

### 经济参数

影响协议经济模型的参数。修改需要经济学分析。

| 参数       | 例子           | 修改频率 |
| ---------- | -------------- | -------- |
| 债务上限   | debt_ceiling   | 中       |
| 存款上限   | deposit_cap    | 中       |
| 手续费     | fee_bps        | 低       |
| 储备金比例 | reserve_factor | 低       |

### 治理参数

影响协议治理过程的参数。

| 参数       | 例子                | 修改频率 |
| ---------- | ------------------- | -------- |
| 时间锁延迟 | timelock_delay      | 极低     |
| 多签阈值   | required_signatures | 极低     |
| 投票权重   | voting_power        | 低       |

## 渐进式去中心化的实践框架

```
阶段 0: 开发阶段
  - 团队完全控制
  - 频繁修改参数
  - 无需社区参与

阶段 1: 启动阶段
  - AdminCap 转移到多签
  - 关键操作加时间锁
  - 参数修改需要 3/5 签名
  - 社区可以查看但不能修改

阶段 2: 治理阶段
  - 引入治理代币
  - 参数修改通过提案投票
  - 技术参数仍由多签管理
  - 经济参数由社区决定

阶段 3: 不可变阶段
  - 核心合约不可升级
  - 所有参数通过治理管理
  - 团队权限最小化
  - 协议完全自治
```

## 治理即风险

每次参数修改都是一次潜在风险。治理不是"把决定权交给社区就安全了"——社区可能做出错误的决策。

治理安全的要素：

1. **信息透明**：提案必须附带充分的分析和模拟数据
2. **时间充裕**：投票期不能太短，社区需要时间分析
3. **门槛合理**：通过门槛不能太低（容易被操纵），也不能太高（无法通过任何提案）
4. **执行延迟**：通过的提案不能立即执行，需要有缓冲期

## Move 中的治理实现模式

### AdminCap + Timelock

```move
public struct AdminCap has key, store { id: UID }
public struct Timelock has key {
    id: UID,
    pending_action: Option<Action>,
    execute_after_epoch: u64,
}

public fun propose_update(
    _: &AdminCap,
    lock: &mut Timelock,
    action: Action,
    ctx: &mut TxContext,
) {
    // 记录待执行的操作和时间锁
    timelock::set_pending(lock, action, ctx.epoch() + DELAY_EPOCHS);
    event::emit(ProposalCreated { action, execute_after: ... });
}

public fun execute_pending(lock: &mut Timelock, ctx: &TxContext) {
    let pending = timelock::extract_pending(lock);
    assert!(ctx.epoch() >= pending.execute_after_epoch, ETooEarly);
    // 执行参数更新
    apply_action(pending.action);
    event::emit(ActionExecuted { ... });
}
```

关键检查点：
- `propose_update` 需要 `AdminCap`（多签持有）
- `execute_pending` **不需要** AdminCap，但有时间锁
- 两次操作之间至少经过 `DELAY_EPOCHS` 个 epoch
- 所有操作都有事件记录

### 紧急暂停模式

```move
public struct EmergencyCap has key, store { id: UID }

// 紧急暂停不需要时间锁——紧急情况需要快速响应
public fun emergency_pause(
    _: &EmergencyCap,
    system: &mut ProtocolSystem,
) {
    system.paused = true;
    event::emit(EmergencyPaused { timestamp: tx_context::epoch_timestamp_ms() });
}

// 恢复需要时间锁——防止管理员反复开关
public fun emergency_unpause(
    _: &AdminCap,
    lock: &mut Timelock,
    ...
) {
    // 走正常时间锁流程
}
```

设计原则：
- **暂停**可以快速执行（紧急情况）
- **恢复**需要时间锁（防止滥用）
- **暂停权限和恢复权限分离**（不同 Cap）

### 多签集成

在 Sui 上，AdminCap 通常被转移到一个多签地址。多签的交易通过 PTB（可编程交易块）构建：

```
多签交易流程：
1. 收集足够的签名
2. 构建 PTB：transfer_objects([AdminCap], multisig_address)
3. 或者：在 PTB 中使用 AdminCap 调用治理函数
```

多签安全要求：
- 至少 3/5 或更高阈值
- 签名者分布在不同的地理区域
- 签名者使用不同的密钥管理方案
- 定期轮换签名者
