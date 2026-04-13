# 17.7 Move 实现 Market Object

## 为什么是 Shared Object

预测市场需要多个用户在同一个 `Market` 上交易。Sui 的 Shared Object 模型天然适合：

```
Shared Object:
  任何人都可以在交易中引用
  通过 Narwhal/Bullshark 共识排序
  适合「公共池」类场景

Owned Object:
  只有拥有者可以使用
  可以无共识直接执行
  适合「私人头寸」类场景

Market → Shared Object（所有人交易）
Position → Owned Object（私人头寸）
```

## Market 结构体逐字段解析

```move
public struct Market<phantom T> has key, store {
    id: UID,
    b: u64,                    // LMSR 流动性参数
    q_yes: u64,                // LMSR 做市状态：YES 侧
    q_no: u64,                 // LMSR 做市状态：NO 侧
    vault: Balance<T>,         // 抵押品金库
    fee_bps: u64,              // 手续费（基点）
    trading_closes_ms: u64,    // 交易截止时间
    challenge_window_ms: u64,  // 争议窗口
    resolved: u8,              // 状态（0=交易中, 1=已结算）
    winning_outcome: u8,       // 胜出结果
    proposed_outcome: u8,      // 提议的结果
    proposal_time_ms: u64,     // 提议时间
    challenger: address,       // 质疑者地址
    challenge_stake: Balance<T>, // 质疑押金
}
```

```
字段分组:

定价组:
  b, q_yes, q_no
  → 这三个字段完全决定 LMSR 的报价
  → p_YES = exp(q_yes/b) / (exp(q_yes/b) + exp(q_no/b))

金库组:
  vault, fee_bps
  → vault 持有所有抵押品
  → fee_bps 在每次交易中按比例抽取

生命周期组:
  trading_closes_ms, resolved, winning_outcome
  → 控制市场的状态转换（17.6）

裁决组:
  proposed_outcome, proposal_time_ms, challenge_window_ms
  challenger, challenge_stake
  → 控制争议流程（17.26）
```

## create_market 逐行分析

```move
public fun create_market<T>(
    b: u64,
    initial_seed: Coin<T>,
    fee_bps: u64,
    trading_closes_ms: u64,
    challenge_window_ms: u64,
    ctx: &mut TxContext,
) {
    assert!(b > 0);                              // b=0 会导致除零
    let id = object::new(ctx);                   // 生成唯一 ID
    let market_id = object::uid_to_inner(&id);   // 提取 ID 用于事件
    let bal = coin::into_balance(initial_seed);  // Coin → Balance（不可退回）
    let m = Market<T> {
        id,
        b,
        q_yes: 0,                                // 初始对称：两侧均为 0
        q_no: 0,
        vault: bal,                              // 种子资金进入金库
        fee_bps,
        trading_closes_ms,
        challenge_window_ms,
        resolved: STATUS_TRADING,                // 初始状态
        winning_outcome: OUTCOME_NONE,
        proposed_outcome: OUTCOME_NONE,
        proposal_time_ms: 0,
        challenger: @0x0,
        challenge_stake: balance::zero(),        // 无初始争议
    };
    event::emit(MarketCreated { market_id, b, trading_closes_ms });
    transfer::public_share_object(m);            // 共享！任何人可交易
}
```

### 关键设计决策

```
q_yes = 0, q_no = 0 初始化:
  此时 p_YES = p_NO = 0.5（对称起始）
  这意味着市场一开始「不偏向任何一方」

initial_seed 的用途:
  LMSR 做市方（协议/创建者）需要资金吸收最坏损失
  seed 进入 vault，用于支付交易对手的赎回
  如果 seed 不足以覆盖 b × ln(2)，协议可能在极端情况下资不抵债

  数值:
    b = 1000, n = 2（二元）
    最坏净损失 ≈ b × ln(n) = 1000 × 0.693 = 693
    建议 initial_seed >= 700（留安全余量）

public_share_object vs share_object:
  public_share_object: 对象类型需要 store ability
  share_object: 不需要 store，但不能被其他模块引用
  → Market 有 store，所以用 public_share_object
```

## has key, store 的含义

```
has key:
  → Market 是一个 Sui 对象（有 UID）
  → 可以被 transfer / share / freeze

has store:
  → 可以被其他对象包含（dynamic_field 等）
  → 可以用 public_share_object 共享
  → 可以用 public_transfer 转移

如果只有 key 没有 store:
  → 只能用 share_object（限本模块）
  → 只能用 transfer（限本模块）
  → 其他模块无法操作这个对象
```

## 与 DEX Pool 的对比

| 维度 | DEX Pool (第 4 章) | Prediction Market |
|------|-------------------|-------------------|
| 定价变量 | `reserve_a`, `reserve_b` | `q_yes`, `q_no`, `b` |
| 不变量 | `x × y = k` | `C(q) = b × ln(Σ exp(q_i/b))` |
| 金库内容 | 两种代币余额 | 单一抵押品 |
| LP Token | `LP<A,B>` | 无（LMSR 不需要外部 LP） |
| 生命周期 | 无截止（持续交易） | 有截止 + 裁决 + 赎回 |
| 费用 | 进入池中增厚 LP | 进入金库或协议地址 |

## 自检

1. 如果 `b` 设得非常小（比如 1），会发生什么？（答：滑点极大，买 1 份可能使价格剧烈变化）
2. 为什么 `initial_seed` 不能为 0？（答：LMSR 最坏损失需要覆盖，否则 claim 时金库不足）
