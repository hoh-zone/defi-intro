# 17.6 市场生命周期

预测市场不是「一直在交易」的东西——它有明确的开始、截止、裁决和赎回阶段。搞错状态机，轻则用户困惑，重则资金锁死。

## 六阶段状态机

```
┌──────────┐    create_market     ┌──────────┐
│  不存在   │ ──────────────────→  │  TRADING  │
└──────────┘                      └────┬─────┘
                                       │
                     clock > trading_closes_ms
                                       │
                                       ▼
                                 ┌──────────┐
                                 │  CLOSED   │
                                 └────┬─────┘
                                      │
                             submit_result(outcome)
                                      │
                                      ▼
                                ┌───────────┐
                          ┌───→ │ CHALLENGED│ ←── challenge_result
                          │     └─────┬─────┘
                          │           │
                          │    finalize_result
                          │    (after window)
                          │           │
                                      ▼
                                ┌───────────┐
                                │ RESOLVED  │
                                └─────┬─────┘
                                      │
                                  claim(pos)
                                      │
                                      ▼
                                ┌───────────┐
                                │ 金库清空   │
                                └───────────┘
```

## 每个阶段允许什么操作

| 阶段     | 允许                    | 禁止                     |
| -------- | ----------------------- | ------------------------ |
| TRADING  | buy, sell, split, merge | submit_result, claim     |
| CLOSED   | submit_result           | buy, sell                |
| PROPOSED | challenge_result        | buy, sell                |
| RESOLVED | claim                   | buy, sell, submit_result |

## 数值时间线示例

```
时间轴（UTC 毫秒）:

t = 1000  create_market(trading_closes_ms = 5000, challenge_window_ms = 2000)
          → Market 创建，TRADING 状态

t = 2000  buy_yes(shares=100)
          → 正常交易

t = 5001  buy_yes(shares=50)
          → ❌ 失败: clock > trading_closes_ms

t = 6000  submit_result(OUTCOME_YES)
          → proposed_outcome = YES, proposal_time_ms = 6000

t = 7500  challenge_result(stake=1000)
          → ✅ 成功: 7500 <= 6000 + 2000

t = 8001  finalize_result()
          → ❌ 失败: 还在争议窗口内 (8001 <= 8000)

t = 8500  finalize_result()
          → ✅ 成功: 8500 > 8000, 写入 winning_outcome = YES

t = 9000  claim(position)
          → YES 持有者赎回抵押
```

## Move 中的状态实现

教学代码用两个字段实现状态机：

```move
public struct Market<phantom T> has key, store {
    // ...
    resolved: u8,            // STATUS_TRADING(0) 或 STATUS_RESOLVED(1)
    trading_closes_ms: u64,  // 交易截止时间
    proposed_outcome: u8,    // 提议的结果（OUTCOME_NONE / YES / NO）
    proposal_time_ms: u64,   // 提议时间戳
    challenge_window_ms: u64,// 争议窗口
    // ...
}
```

```
每个入口函数的断言:

buy_internal / sell_internal:
  assert!(market.resolved == STATUS_TRADING);       // 还在交易
  assert!(clock.timestamp_ms() <= trading_closes_ms); // 没到截止

submit_result:
  assert!(market.resolved == STATUS_TRADING);       // 还没定

challenge_result:
  assert!(proposed_outcome != OUTCOME_NONE);        // 有人提了
  assert!(clock <= proposal_time_ms + challenge_window_ms); // 窗口内

finalize_result:
  assert!(clock > proposal_time_ms + challenge_window_ms); // 窗口过
  → resolved = STATUS_RESOLVED

claim:
  assert!(market.resolved == STATUS_RESOLVED);      // 已定
```

## 生产级扩展

教学实现只有两个状态值（`TRADING` / `RESOLVED`），生产系统通常需要更多：

```
状态枚举（生产建议）:
  CREATED     → 市场刚创建，等待初始流动性
  TRADING     → 正常交易
  PAUSED      → 紧急暂停（管理员操作）
  CLOSED      → 交易截止，等待结果
  PROPOSED    → 有人提交了裁决结果
  DISPUTED    → 有人质押争议
  RESOLVED    → 最终结算完成
  EXPIRED     → 超时无人结算（需退款路径）

教学实现 vs 生产实现:
  教学: resolved(0/1) + 时间判断 → 够讲清主干
  生产: enum 状态 + 权限矩阵 + 事件审计 → 必须完整

缺省状态 EXPIRED 的风险:
  如果 Oracle 永远不提交结果 → 用户资金锁死
  生产必须有超时退款路径（教学版未实现）
```

## 自检

1. 如果 `challenge_window_ms = 0`，争议机制等于不存在，会有什么风险？
2. 如果允许在 `RESOLVED` 状态后仍然 `split/merge`，会发生什么？
