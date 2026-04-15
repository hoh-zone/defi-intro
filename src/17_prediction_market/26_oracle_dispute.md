# 17.26 Oracle 与争议窗口设计

裁决是预测市场最危险的环节。LMSR 数学再正确，如果 `resolve` 写错了赢家，用户的钱就没了。

## 为什么裁决比定价更难

```
定价:
  输入: q_yes, q_no, b（链上状态）
  输出: price（纯数学计算）
  → 可验证、可测试、确定性

裁决:
  输入: "BTC 在 2025-12-31 是否 >= $150K？"
  输出: YES 或 NO
  → 依赖链外世界的事实
  → 事实可能有争议（哪个交易所的价格？用哪个时间点？）
  → 裁决者可能被贿赂

裁决不是「链上数据读取」:
  预言机（第 5 章）: 读取已确定的价格数据 → 技术问题
  预测市场裁决: 判断「未来事件是否发生」→ 治理 + 信任问题
```

## 三种裁决模式

### 模式 1：中心化裁决（最简单）

```
创建市场时指定 resolver 地址
只有 resolver 可以调用 submit_result

优点: 简单、快速
缺点: 单点故障、可被贿赂

  如果 resolver 被贿赂 → 所有用户资金受损
  如果 resolver 消失 → 市场永远无法结算

适用: 信任度高的场景（如团队内部市场、友人赌局）
```

### 模式 2：Optimistic Oracle（UMA 风格）

```
流程:
  1. 任何人可以提交结果 + 保证金（如 1000 USDC）
  2. 争议窗口（如 2 小时）
  3. 如果无人争议:
     → 结果自动确认
     → Proposer 取回保证金
  4. 如果有人争议:
     → Disputer 存入保证金
     → 升级到仲裁（token 投票 / 多签 / DAO）
     → 赢方获得对方保证金

优点: 大多数情况下无需投票（只在争议时升级）
缺点: 需要设计仲裁机制 + 保证金经济学

本章实现的是简化版:
  submit_result → challenge_result → finalize_result
  → 只有「提议-争议-最终化」的状态机
  → 没有保证金没收和仲裁逻辑
```

### 模式 3：去中心化投票

```
Augur 模式:
  1. 指定 Reporter 提交初始结果
  2. REP 代币持有者可以争议
  3. 每轮争议保证金翻倍
  4. 最终「分叉」如果争议无法解决

复杂度: 极高
历史: Augur v1 的裁决争议频繁，用户体验差
教训: 完全去中心化的裁决≠更好的裁决
```

## 教学代码的裁决实现

### submit_result

```move
public fun submit_result<T>(
    market: &mut Market<T>,
    outcome: u8,
    clock: &Clock,
) {
    assert!(market.resolved == STATUS_TRADING);
    assert!(outcome == OUTCOME_YES || outcome == OUTCOME_NO);
    market.proposed_outcome = outcome;
    market.proposal_time_ms = clock.timestamp_ms();
}
```

```
分析:
  任何人都可以调用 → 没有权限检查
  → 这是教学简化！生产版必须限制调用者

  proposed_outcome 记录提议
  proposal_time_ms 记录时间 → 用于计算争议窗口

  安全问题:
    如果恶意用户先调用 submit_result → 可能影响其他人
    → 生产版: 需要保证金 + 白名单
```

### challenge_result

```move
public fun challenge_result<T>(
    market: &mut Market<T>,
    stake: Coin<T>,
    clock: &Clock,
    ctx: &TxContext
) {
    assert!(market.resolved == STATUS_TRADING);
    assert!(market.proposed_outcome != OUTCOME_NONE);
    assert!(clock.timestamp_ms() <= market.proposal_time_ms + market.challenge_window_ms);
    let v = coin::value(&stake);
    assert!(v > 0);
    market.challenger = ctx.sender();
    balance::join(&mut market.challenge_stake, coin::into_balance(stake));
}
```

```
分析:
  必须在争议窗口内调用
  challenger 存入 stake（保证金）
  → 但教学版没有处理 stake 的退还/没收逻辑
  → 这是明确的 stub，不是遗漏

  生产版需要:
    1. 如果挑战成功 → 返还 challenger stake + proposer 保证金
    2. 如果挑战失败 → 没收 challenger stake
    3. 升级仲裁 → 调用外部合约或 DAO 投票
```

### finalize_result

```move
public fun finalize_result<T>(
    market: &mut Market<T>,
    clock: &Clock,
) {
    assert!(market.resolved == STATUS_TRADING);
    assert!(market.proposed_outcome != OUTCOME_NONE);
    assert!(clock.timestamp_ms() > market.proposal_time_ms + market.challenge_window_ms);
    market.resolved = STATUS_RESOLVED;
    market.winning_outcome = market.proposed_outcome;
    event::emit(Resolved { market_id: object::id(market), outcome: market.winning_outcome });
}
```

```
分析:
  争议窗口过后才能调用
  如果有 challenge → 当前实现忽略（直接用 proposed_outcome）
  → 这是教学简化！生产版必须处理争议结果

  生产版:
    如果有 challenge 且仲裁翻转结果:
      market.winning_outcome = 翻转后的结果
      返还 challenger stake
    如果仲裁维持原结果:
      market.winning_outcome = proposed_outcome
      没收 challenger stake
```

## 裁决攻击面

| 攻击          | 描述                                          | 防御                      |
| ------------- | --------------------------------------------- | ------------------------- |
| 贿赂 Resolver | 支付 resolver 写错结果                        | 多签 + 争议窗口           |
| 抢先提交      | 在截止前知道结果，最后一秒大量买入            | 交易截止 < 事件确定       |
| 操纵争议      | 用大量 stake 阻止正确裁决                     | 保证金递增 + 最终仲裁     |
| Resolver 消失 | 没有人提交结果 → 资金锁死                     | 超时退款机制              |
| 命题歧义      | "BTC 突破 $150K" — 哪个交易所？UTC 还是 EST？ | 精确的命题文本 + 裁决标准 |

## 自检

1. 如果 `challenge_window_ms = 0`，争议机制形同虚设，但代码还是能跑。这说明了什么？（答：安全不能只靠代码编译通过）
2. 为什么教学版的 `submit_result` 没有权限检查？在什么情况下这是不安全的？
