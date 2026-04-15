# 17.28 Claim 奖励系统

## 赎回的核心逻辑

```
结算完成后（winning_outcome 已确定）:
  如果 YES 赢:
    持有 YES 份额的用户: 每份赎回 1 单位抵押
    持有 NO 份额的用户: 份额归零，无赎回

  如果 NO 赢:
    持有 NO 份额的用户: 每份赎回 1 单位抵押
    持有 YES 份额的用户: 份额归零，无赎回

简单说: 赢家拿走钱，输家清零。
```

## claim 逐行分析

```move
public fun claim<T>(
    market: &mut Market<T>,
    pos: &mut Position,
    ctx: &mut TxContext
): Coin<T> {
    assert!(object::id(market) == pos.market_id);  // ① 市场匹配
    assert!(market.resolved == STATUS_RESOLVED);    // ② 已结算
    let w = market.winning_outcome;
    let amt = if (w == OUTCOME_YES) {               // ③ 确定赎回量
        assert!(pos.yes > 0);                       // ④ 持有胜出侧
        let a = pos.yes;
        pos.yes = 0;                                // ⑤ 清零
        pos.no = 0;                                 // ⑥ 输侧也清零
        a
    } else if (w == OUTCOME_NO) {
        assert!(pos.no > 0);
        let a = pos.no;
        pos.yes = 0;
        pos.no = 0;
        a
    } else {
        abort ENotResolved                          // ⑦ 异常状态
    };
    let out = balance::split(&mut market.vault, amt); // ⑧ 从金库取
    coin::from_balance(out, ctx)                     // ⑨ 返回 Coin
}
```

### 逐步解析

```
① market_id 检查:
   防止用市场 A 的 Position 去市场 B 赎回

② 结算检查:
   只有 RESOLVED 状态才能 claim

③ 根据胜出方确定赎回:
   YES 赢 → 赎回 pos.yes
   NO 赢 → 赎回 pos.no

④ 必须持有胜出侧:
   如果 YES 赢但 pos.yes == 0 → assert 失败
   → 纯 NO 持有者不能调用（节省 Gas）

⑤⑥ 双侧清零:
   胜出侧赎回后，输侧也清零
   → 防止重复 claim
   → Position 变为「空壳」

⑧ 从金库取出:
   1:1 赎回（每份 YES/NO 赎回 1 单位抵押）
   如果 vault < amt → abort（不应发生，除非 seed 不足）

⑨ 返回 Coin:
   调用者决定如何处理（转账、存入其他协议等）
```

## 数值示例

```
市场: b = 1000, seed = 1000, fee = 2%

Alice: Split 500 → { yes: 500, no: 500 }, vault += 500
Bob:   买 300 YES (LMSR cost = 160), vault += 163 (含 fee)
Carol: 买 200 NO  (LMSR cost = 60),  vault += 61

vault = 1000 + 500 + 163 + 61 = 1724

结算: YES 赢

Alice claim:
  amt = pos.yes = 500
  vault: 1724 - 500 = 1224
  Alice 获得 500 USDC

Bob claim:
  Bob 没有 Position（他通过 LMSR 买入但没有记入 Position）
  → 在教学版中，Bob 不能 claim（LMSR 和 Position 是分开的）
  → 这是一个教学设计选择（17.14 讨论过）

Carol claim:
  Carol 的 Position 中 no > 0, yes = 0
  → assert!(pos.yes > 0) 失败
  → Carol 不能 claim → 她的 NO 份额归零

剩余 vault:
  1224 USDC = seed(1000) + LMSR 净收入(163+61) - Alice claim(500)
  → 如果没有更多人 claim → 这些资金留在 vault
  → 生产版: 协议可以提取剩余资金
```

## 边界情况

| 场景                  | 结果       | 原因                          |
| --------------------- | ---------- | ----------------------------- |
| 未结算时 claim        | 失败       | `resolved != STATUS_RESOLVED` |
| 输家 claim            | 失败       | `pos.yes/no == 0`             |
| 赢家 claim 两次       | 第二次失败 | 第一次已清零                  |
| vault 不足            | abort      | `balance::split` 失败         |
| Position 来自其他市场 | 失败       | `market_id` 不匹配            |

## 舍入问题

```
在整数运算中，可能出现微小的舍入差异:

例: LMSR 计算的 ΔC = 100.7 → 截断为 100（u64）
    实际金库收入少了 0.7
    如果大量交易累积 → 金库可能少几个单位

防御:
  1. 用 u128 中间计算减少截断次数
  2. 截断方向一致（总是向上取整收费 → 金库略有盈余）
  3. 测试中验证 vault >= 所有可能的 claim 总额

教学版的做法:
  cost_state 返回 u128 → 截断为 u64 时只在最后一步
  → 累积误差很小
  → 但生产版需要严格的数学证明
```

## Claim 后的 Position 处理

```
claim 后:
  pos.yes = 0, pos.no = 0
  → Position 变成空壳
  → 占用 Sui storage（有 storage rebate）

选项 1 — 自动销毁:
  在 claim 中添加 Position 解构
  → 用户获得 storage rebate
  → 但 claim 的签名需要改变（Position 不再是引用）

选项 2 — 手动销毁:
  提供 destroy_position(pos) 函数
  → 用户单独调用
  → 灵活但多一次交易

选项 3 — 保留（教学版）:
  空 Position 留在链上
  → 最简单但浪费存储
```

## 自检

1. 如果 Alice 只 Split 了但没有卖出任何一侧（yes=500, no=500），YES 赢后她 claim 多少？NO 侧怎么处理？（答：claim 500 USDC，no 清零作废）
2. 为什么 `claim` 返回 `Coin<T>` 而不是直接 `transfer`？（答：灵活性——调用者可以决定把赎回的钱做什么）
