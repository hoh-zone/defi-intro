# 第 4 章 DEX：从链上交易到全类型交易所

DEX（Decentralized Exchange）是 DeFi 的入口协议。不是因为它最复杂，而是因为它做的事情最基础——**产生价格**。后续所有协议都依赖 DEX 产生的价格：借贷用价格算抵押率，CDP 用价格维持锚定，衍生品用价格算保证金。

## 本章为什么需要 30 节

传统 DEX 教材往往只讲 AMM。但 Sui 生态的 DEX 格局已经非常多元：Cetus 用 CLMM、Turbos 用 CLMM、DeepBook 用 Orderbook、FlowX 用 Hybrid、Kriya 用 AMM+Perps。只理解 AMM 无法理解这些协议的差异和选择。

本章从最简单的固定汇率开始，逐步构建到完整的交易系统：

```
Part 0 — 交易基础（4.1-4.4）
  什么是链上交易 → Sui 的独特优势 → 生态概览 → 核心模块

Part 1 — 第一个 Swap（4.5-4.7）
  固定汇率 → 最小流动性池 → 费用机制

Part 2 — CPMM AMM（4.8-4.11）
  数学推导 → 滑点分析 → 套利机制 → 完整实现

Part 3 — AMM 经济模型（4.12-4.14）
  无常损失 → LP 收益 → 多池设计

Part 4 — CLMM 集中流动性（4.15-4.19）
  为什么需要 → Tick 机制 → Position NFT → Swap 算法 → 完整实现

Part 5 — DLMM（4.20-4.22）
  概念 → Bin 模型 → 实现

Part 6 — StableSwap（4.23-4.24）
  曲线数学 → 实现

Part 7 — Orderbook（4.25-4.27）
  为什么需要 → 撮合引擎 → 实现

Part 8 — 高级设计（4.28-4.30）
  Hybrid DEX → 多池路由 → 架构选择框架
```

## 学习路径建议

- **快速入门**：读 Part 0 + Part 1，理解基本概念
- **AMM 掌握**：Part 2 + Part 3，理解最常用的 DEX 模型
- **全面理解**：Part 4-7，掌握所有主流 DEX 类型
- **架构设计**：Part 8，学会选择合适的 DEX 架构
