# 17.27 Market Resolution

## 结算的两个含义

```
含义 1 — 逻辑结算:
  确定「YES 赢还是 NO 赢」
  → 写入 market.winning_outcome

含义 2 — 经济结算:
  每个用户根据持有的头寸赎回抵押
  → 调用 claim → 从 vault 取钱

这两步必须分开:
  先逻辑结算（不可逆）→ 再经济结算（可逐个进行）
  如果同时做 → 前面的人赎回后，后面的人可能被操纵
```

## 结算状态转换

```
STATUS_TRADING (0)
    │
    │ submit_result(outcome)
    ▼
proposed_outcome = YES/NO
proposal_time_ms = now
    │
    │ wait: clock > proposal_time_ms + challenge_window_ms
    ▼
STATUS_RESOLVED (1)
winning_outcome = proposed_outcome
    │
    │ claim (each user)
    ▼
vault → 0 (eventually)
```

## finalize_result 的幂等性

```move
public fun finalize_result<T>(market: &mut Market<T>, clock: &Clock) {
    assert!(market.resolved == STATUS_TRADING);       // ← 只能调用一次
    assert!(market.proposed_outcome != OUTCOME_NONE);
    assert!(clock.timestamp_ms() > market.proposal_time_ms + market.challenge_window_ms);
    market.resolved = STATUS_RESOLVED;
    market.winning_outcome = market.proposed_outcome;
    event::emit(Resolved { ... });
}
```

```
关键: assert!(market.resolved == STATUS_TRADING) 保证了:
  1. 只能结算一次（防止重复结算）
  2. 结算后不能修改结果
  3. 如果结果有误 → 无法链上修复 → 这是设计选择

生产版可选:
  添加 emergency_override(admin_cap, new_outcome) 函数
  → 只有多签/DAO 可以在极端情况下纠正
  → 引入中心化风险，需要权衡
```

## 结算后的约束

```
结算后应禁止的操作:
  ✗ buy_yes / buy_no → assert!(resolved == STATUS_TRADING)
  ✗ sell_yes / sell_no → assert!(resolved == STATUS_TRADING)
  ✗ submit_result → assert!(resolved == STATUS_TRADING)

结算后应允许的操作:
  ✓ claim → 赎回胜出头寸
  ✓ split / merge → 教学版未禁止（生产应禁止）

  为什么结算后应禁止 split/merge:
    split 会给用户新的 YES + NO 份额
    但 NO 已经没有价值了
    用户可能误操作浪费资金
    → 生产版: assert!(market.resolved == STATUS_TRADING) in split/merge
```

## 时间线验证

```
正常流程:
  t = 1000ms  创建市场 (closes = 5000, challenge = 2000)
  t = 3000ms  最后一笔交易 (buy_yes)
  t = 5001ms  submit_result(YES)
  t = 7001ms  finalize_result() → RESOLVED, winner = YES
  t = 8000ms  Alice claim → 获得 YES 余额 × 1 USDC
  t = 9000ms  Bob claim → YES = 0, NO > 0 → 不满足 pos.yes > 0 → abort

异常流程 1 — 没人 submit:
  t = 100000ms 仍然没有 submit → vault 中资金锁死
  → 需要超时退款（教学版未实现）

异常流程 2 — 错误结算:
  t = 5001ms  恶意用户 submit_result(NO)（但 YES 实际赢了）
  t = 5500ms  无人 challenge（没人注意到）
  t = 7001ms  finalize_result() → RESOLVED, winner = NO
  → 所有 YES 持有者损失 → 这就是争议窗口的意义

异常流程 3 — 成功 challenge:
  t = 5001ms  submit_result(NO)
  t = 5500ms  challenge_result(stake=1000) → 有人争议
  t = 7001ms  finalize_result() → 当前教学版仍然用 proposed = NO
  → 教学版的 challenge 是 stub，不会翻转结果
  → 生产版需要仲裁逻辑
```

## Resolved 事件

```move
public struct Resolved has copy, drop {
    market_id: ID,
    outcome: u8,   // OUTCOME_YES(1) 或 OUTCOME_NO(2)
}
```

```
事件的用途:
  1. 前端: 显示「市场已结算，YES 赢」
  2. 索引器: 更新市场状态数据库
  3. 跨合约: 其他合约可以根据事件触发后续逻辑
  4. 审计: 链上可追溯的结算记录

事件不可逆:
  一旦发出 → 不能撤回
  → 与 market.resolved = STATUS_RESOLVED 一致
```

## 自检

1. 如果有两个人同时调用 `finalize_result`，会发生什么？（答：第二个会因 `assert!(resolved == STATUS_TRADING)` 失败）
2. 设计题：如何实现「超时退款」——如果创建后 30 天仍未结算，所有用户可以按比例取回 vault？
