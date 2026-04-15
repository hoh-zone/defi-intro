# 第 7 章 借贷：从储蓄池到完整借贷协议

借贷是 DeFi 的核心原语之一。如果说 DEX 解决了"交换"的问题，预言机解决了"定价"的问题，那么借贷协议解决的是"时间价值"的问题——让闲置资产产生收益，让急需资金的人获得流动性。

## 本章学习路径

本章共 30 节，分为 9 个部分，从零开始构建一个完整的借贷协议：

```
Part 0 — 设计基础（7.1-7.4）
  借贷的核心问题、模块分层、Sui 特有优势、整体架构

Part 1 — Supply Pool（7.5-7.7）
  存款凭证设计、Supply Pool 实现、利息累积指数

Part 2 — 借款系统（7.8-7.10）
  Debt Token 设计、Borrow/Repay 实现、借款利息累积

Part 3 — 抵押系统（7.11-7.13）
  Collateral Object、LTV 与 Health Factor、抵押管理实现

Part 4 — 利率模型（7.14-7.17）
  利用率、线性模型、Jump Rate Model、动态利率实现

Part 5 — 清算系统（7.18-7.21）
  清算触发、奖励罚金、部分清算、Liquidation Engine 实现

Part 6 — 闪电贷（7.22-7.24）
  Flash Loan 原理、原子安全模型、Move 实现

Part 7 — 高级架构（7.25-7.27）
  Cross Collateral、Isolated Market、架构对比实现

Part 8 — 风险与组装（7.28-7.30）
  预言机接口、参数设计方法、完整协议组装
```

## 配套代码

本章包含 3 个可运行的 Move 代码包：

| 代码包         | 路径                   | 说明                                                                |
| -------------- | ---------------------- | ------------------------------------------------------------------- |
| sui_savings    | `code/sui_savings/`    | 储蓄池（Share Token、deposit/withdraw、interest）                   |
| lending_market | `code/lending_market/` | 完整借贷市场（collateral、borrow、repay、liquidation、kinked rate） |
| flash_loan     | `code/flash_loan/`     | 闪电贷（hot potato 模式）                                           |

所有代码包均可独立编译和测试，章节内容会逐步引用这些实现。
