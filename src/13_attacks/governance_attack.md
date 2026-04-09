# 11.5 治理攻击与权限滥用

## 管理员权限是最大的单点故障

一个协议的管理员（AdminCap 持有者）通常可以：
- 修改利率参数
- 暂停/恢复协议
- 调整清算阈值
- 更新预言机地址
- 提取手续费

如果管理员密钥被盗或恶意操作，所有用户资金都面临风险。

## 常见攻击方式

### 1. 密钥泄露

管理员私钥被盗（钓鱼、社工、设备被入侵）。攻击者获得 AdminCap 后：
- 修改清算阈值为 0，触发全部仓位清算
- 暂停协议，锁定所有资金
- 修改预言机地址指向恶意合约

### 2. 恶意参数修改

即使管理员没有被盗，也可能做出不当决策：
- 在市场波动时突然修改清算参数，影响用户仓位
- 过高设置手续费，提取用户收益
- 修改债务上限，阻止用户借款

### 3. 治理操纵

在 DAO 治理的协议中，攻击者通过闪电贷借入大量治理代币，投票通过有利于自己的提案。

## 防御措施

### 时间锁（Timelock）

```move
struct TimelockedAction has key {
    id: UID,
    action_type: u8,
    new_value: u64,
    execute_after: u64,
    created_by: address,
    cancelled: bool,
}

public fun propose_action(
    action_type: u8,
    new_value: u64,
    delay_ms: u64,
    ctx: &mut TxContext,
): TimelockedAction {
    TimelockedAction {
        id: object::new(ctx),
        action_type,
        new_value,
        execute_after: sui::clock::timestamp_ms(sui::clock::create_for_testing()) + delay_ms,
        created_by: tx_context::sender(ctx),
        cancelled: false,
    }
}

public fun execute_action(
    action: &TimelockedAction,
    system: &mut CDPSystem,
) {
    assert!(!action.cancelled, 0);
    let now = sui::clock::timestamp_ms(sui::clock::create_for_testing());
    assert!(now >= action.execute_after, 1);
    apply_action(system, action.action_type, action.new_value);
}
```

时间锁确保参数修改不会立即生效——用户有时间审查和反应。

### 多签（Multisig）

```move
struct MultisigCap has key {
    id: UID,
    required_signatures: u64,
    signers: vector<address>,
    pending_actions: vector<PendingAction>,
}

struct PendingAction has store {
    action_type: u8,
    new_value: u64,
    signatures: vector<address>,
    executed: bool,
}
```

### 渐进式去中心化

```
阶段 1: 团队完全控制（快速迭代）
  ↓
阶段 2: 多签 + 时间锁（安全过渡）
  ↓
阶段 3: DAO 治理（社区决策）
  ↓
阶段 4: 不可变合约（完全去中心化）
```

## 原则

1. **最小权限原则**：AdminCap 只能做必要的事情
2. **时间锁原则**：所有关键操作都有延迟
3. **多签原则**：重要操作需要多人签名
4. **透明原则**：所有参数变更都有事件通知
5. **可审计原则**：治理历史完整可查
