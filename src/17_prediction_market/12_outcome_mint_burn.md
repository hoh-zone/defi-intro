# 17.12 Outcome Token 铸造与销毁的经济语义

前一节讲了 Split/Merge 的代码实现。本节退后一步，用经济语言理解这两种操作的含义。

## 两套语言，同一件事

链上条件代币有两种等价的描述方式：

```
语言 A — 「铸造/销毁」（Mint/Burn）:
  Split  = 铸造一对互补代币（YES + NO）
  Merge  = 销毁一对互补代币
  Redeem = 销毁胜出代币，获得抵押

语言 B — 「保险/对赌」:
  Split  = 购买一份「全险保单」（无论结果如何都能赎回）
  Merge  = 退保（全额退款）
  Redeem = 理赔（只有一侧获赔）

这两套语言在数学上完全等价:
  存入 1 USDC → 获得 1 YES + 1 NO
  无论哪边赢，1 YES + 1 NO 总值 1 USDC
  → 「铸造全集合」 = 「买全险」 = 无风险操作
```

## 从 Split 到有敞口的头寸

```
步骤 1 — Split:
  Alice 存 100 USDC → { yes: 100, no: 100 }
  此时 Alice 没有方向性敞口
  无论结果如何，她都能赎回 100（通过 Merge 或 Claim）

步骤 2 — 在市场上卖出一侧:
  Alice 通过场外或 LMSR 卖出 100 NO
  → Alice: { yes: 100, no: 0 }
  → 现在 Alice 有了 YES 方向的敞口

  如果 YES 赢: Alice 赎回 100 USDC（加上卖 NO 收到的钱）
  如果 NO 赢:  Alice 赎回 0（但之前卖 NO 已收钱）

  Alice 的净损益 = Claim 收入 + 卖 NO 收入 - Split 成本
```

### 等价方式：直接通过 LMSR 买入

```
步骤 1 — 直接 buy_yes:
  Bob 支付 ΔC = C(q' ) - C(q)
  Bob 没有持有条件代币，但 LMSR 状态记录了他的购买
  → 与 Polymarket 的「直接买 YES」在用户体验上类似

两种路径的对比:
  Split → 卖一侧:
    用户先拿全集合 → 选择性地暴露一侧
    → 适合场外交易或跨合约组合

  直接 LMSR 买入:
    用户付成本差 → 获得价格暴露
    → 适合简单交易界面

教学代码的选择:
  LMSR 状态（q_yes/q_no）和 Position 余额是分开的
  → 两种路径都有体现，方便读者理解两种心智模型
  → 17.22 节讨论如何在同一事务中组合
```

## 铸造守恒律

```
系统级不变量:

total_yes_outstanding = Σ(所有 Position 的 yes)
total_no_outstanding  = Σ(所有 Position 的 no)

每次 Split(X):
  total_yes += X
  total_no  += X
  vault     += X

每次 Merge(X):
  total_yes -= X
  total_no  -= X
  vault     -= X

因此:
  vault_增量 ≡ total_yes_增量 ≡ total_no_增量（始终相等）

Claim 时（假设 YES 赢）:
  vault -= Σ(winner.yes)
  total_yes -= Σ(winner.yes)
  total_no 清零（作废）

  最终 vault = initial_seed + LMSR_net_收入

如果 LMSR_net_收入 > 0 → 协议赚钱
如果 LMSR_net_收入 < 0 → 亏损由 seed 兜底（最坏 ≈ b × ln2）
```

## 与 CDP 铸造的类比

```
CDP（第 9 章）:
  存入 ETH 抵押 → 铸造 DAI
  DAI 可自由流通 → 市场定价
  偿还 DAI → 取回 ETH

预测市场:
  存入 USDC 抵押 → 铸造 YES + NO（全集合）
  YES/NO 可自由交易 → 市场定价
  Merge YES + NO → 取回 USDC

区别:
  CDP: 铸造单一资产，有清算风险
  PM:  铸造一对互补资产，无清算风险
  CDP: 抵押率 < 100% 时被清算
  PM:  全集合永远值 100% 抵押 → 不需要清算
```

## 自检

1. 如果 Split 只铸造 YES 不铸造 NO，会违反哪个不变量？
2. 用经济语言解释：为什么 Merge 必须同时消耗两侧？
