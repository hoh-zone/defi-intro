# 17.23 Polymarket 市场生命周期（真实产品对照）

本节拿 Polymarket 作为参照，对比教学实现与商业系统的差异。**注意**：以下描述基于公开资料，商业产品随版本演进，应以官方文档为准。

## Polymarket 的核心架构

```
Polymarket 不是纯 LMSR:

  教学实现（本章）             Polymarket（商业产品）
  ─────────────────           ────────────────────
  链上 LMSR 定价              链下订单簿撮合
  链上金库持有抵押             链上 CTF 合约持有抵押
  链上交易入口                链下匹配 + 链上结算
  无需信任链下                需要信任匹配引擎
  低吞吐、高 Gas              高吞吐、低延迟
```

## 生命周期对比

```
阶段 1 — 市场创建:
  教学: create_market(b, seed, fee, closes_ms, ...) → 链上共享对象
  Poly: 内部团队/DAO 创建命题 → 链下注册 + 链上部署 CTF 条件

阶段 2 — 流动性:
  教学: seed 注入 vault → LMSR 自动报价
  Poly: 做市商挂限价单 → 订单簿逐步填充

阶段 3 — 交易:
  教学: 用户调用 buy_yes/buy_no → 链上 LMSR 计算
  Poly: 用户下限价/市价单 → 链下匹配 → 链上 CTF 结算

阶段 4 — 截止:
  教学: clock > trading_closes_ms → 禁止交易
  Poly: 根据命题条件截止 → 停止接单

阶段 5 — 裁决:
  教学: submit_result → challenge_window → finalize
  Poly: UMA Optimistic Oracle → 争议仲裁

阶段 6 — 赎回:
  教学: claim → 胜出侧 Position 赎回
  Poly: redeem → 胜出条件代币赎回抵押
```

## 链下撮合的利弊

```
为什么 Polymarket 不用链上 LMSR:

  延迟:
    LMSR 链上计算 = 每笔交易等链上确认（~400ms Sui, ~12s ETH）
    链下撮合 = 毫秒级匹配 → 用户体验接近 CEX

  Gas:
    LMSR 每笔交易需要 exp/ln 计算 = 较高 Gas
    链下撮合 = 零 Gas（结算时才上链）

  价格发现:
    LMSR = 公式驱动 → 只有一种报价
    订单簿 = 多个挂单者竞争 → 更紧的价差

  但链下撮合的代价:
    信任假设: 需要信任匹配引擎不作恶
    复杂度:   需要维护链下基础设施
    监管:     可能被归类为交易所
```

## CTF 结算合约

```
Polymarket 的核心链上组件是 Gnosis CTF（Conditional Token Framework）:

CTF 合约做的事:
  1. Split: 存入 USDC → 铸造 YES + NO 代币
  2. Merge: 存入 YES + NO → 取回 USDC
  3. Redeem: 结算后，胜出代币 → 取回 USDC

  与本章教学代码的对应:
    CTF Split ≈ pm::split
    CTF Merge ≈ pm::merge
    CTF Redeem ≈ pm::claim

  关键区别:
    CTF 使用 ERC-1155 代币 → 可在任何 DEX 交易
    教学版用 Position 记账 → 不能在 DEX 交易
    CTF 有 condition_id 组合 → 支持复合条件
    教学版只有 market_id → 简单二元
```

## UMA Optimistic Oracle

```
Polymarket 的裁决流程:

  1. Proposer 提交结果 + 保证金（如 1000 USDC）
  2. 争议窗口（如 2 小时）
  3. 如果无人争议 → 自动确认
  4. 如果有人争议:
     → 争议者存入保证金
     → 升级到 UMA DVM（token 持有者投票）
     → 投票结果作为最终裁决
     → 输方丢失保证金

  本章教学版的简化:
    submit_result → challenge_result (+ stake) → finalize_result
    → 没有投票机制
    → 没有保证金没收逻辑（只是 stub）
    → 教学目的：展示「提议-争议-最终化」的状态机，不模拟完整仲裁
```

## 不应该 1:1 对照的地方

| 本章教学 | Polymarket | 为什么不同 |
|---------|-----------|-----------|
| 纯链上 LMSR | 链下订单簿 | 性能 vs 去中心化取舍 |
| Position 记账 | ERC-1155 代币 | 工程复杂度 vs 可组合性 |
| 简化争议 | UMA Optimistic Oracle | 教学 vs 生产级仲裁 |
| 单一 fee_bps | 多档费率 + 做市商返佣 | 简单 vs 商业激励设计 |
| b 参数固定 | 无 b（订单簿定价） | LMSR 特有 vs 不适用 |

## Augur 的不同路径

```
Augur（另一个知名预测市场）:

  Augur v1: 完全链上（ETH L1）→ Gas 过高，用户少
  Augur v2: 订单簿 + 链上结算 → 改善但仍然慢
  Augur Turbo: 链上 AMM（类似 LMSR 变体）→ 回归自动做市

  裁决: Augur 用 REP 代币持有者投票
    → 与 UMA 不同，Augur 自建了一整套争议系统
    → 复杂度极高，多次出现裁决争议

教训:
  裁决机制是预测市场最难的部分
  不是代码难写，而是激励设计和社会共识难做
  → 这就是为什么本章诚实地说「教学版只展示状态机」
```

## 自检

1. 如果 Polymarket 的链下匹配引擎宕机，链上 CTF 合约还能工作吗？（答：可以 split/merge/redeem，但不能新建订单）
2. 为什么 Polymarket 不直接用 Uniswap 来交易 YES/NO 代币？（答：可以，但 Uniswap 的 CPMM 不如订单簿适合二元代币的价格发现）
