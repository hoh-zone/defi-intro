# 10.2 白名单、配售与公平性

## 白名单的双重作用

1. **资格认证**：只允许符合条件的用户参与
2. **节奏控制**：限制每个用户的认购量，防止大户垄断

## 配售策略对比

| 策略 | 机制 | 公平性 | Bot 防御 | 复杂度 |
|------|------|--------|----------|--------|
| FCFS | 先到先得 | 低 | 差 | 低 |
| Pro-rata | 按比例分配 | 中 | 中 | 中 |
| 抽签（Lottery） | 随机选择 | 高 | 好 | 高 |
| 分层（Tiered） | 按条件分等级 | 中 | 中 | 中 |
| 封顶（Capped） | 设个人上限 | 中高 | 中 | 低 |

## 三层公平性

### 机会公平

所有符合条件的用户都有机会参与。白名单标准公开透明。

### 过程公平

认购过程不会被 Bot 或 Sybil 攻击扭曲。防御措施：
- 最小持仓时间要求
- KYC 或链上行为验证
- 交易频率限制

### 结果公平

最终分配结果符合预期。Pro-rata 确保每个人按比例获得份额，而不是被 FCFS 中的 Bot 抢光。

## Bot 防御的 Move 实现

```move
struct AntiBot has store {
    min_stake_duration_ms: u64,
    max_subscriptions_per_epoch: u64,
    subscription_count: u64,
    current_epoch: u64,
}

public fun check_antibot(
    antibot: &mut AntiBot,
    user_stake_time: u64,
    current_time: u64,
) {
    assert!(
        current_time - user_stake_time >= antibot.min_stake_duration_ms,
        EStakeDurationTooShort
    );
    let epoch = current_time / 86400000;
    if (epoch != antibot.current_epoch) {
        antibot.subscription_count = 0;
        antibot.current_epoch = epoch;
    };
    antibot.subscription_count = antibot.subscription_count + 1;
    assert!(
        antibot.subscription_count <= antibot.max_subscriptions_per_epoch,
        ETooManySubscriptions
    );
}
```
