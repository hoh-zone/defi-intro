# Sui DeFi：从入门到警惕

> 面向开发者的 Sui DeFi 技术书——理解机制 · 编写代码 · 识别风险 · 构建可信赖协议

[![Build and Deploy](https://github.com/hoh-zone/defi-intro/actions/workflows/deploy.yml/badge.svg)](https://github.com/hoh-zone/defi-intro/actions/workflows/deploy.yml)

## 在线阅读

**[https://hoh-zone.github.io/defi-intro](https://hoh-zone.github.io/defi-intro)**

## 这本书讲什么

这不是一本 DeFi 概念科普书，也不是协议白皮书翻译集。这是一本**教你在 Sui 上用 Move 写 DeFi 协议**的技术书，每一章都有完整、可运行的 Move 代码。

核心理念：**从入门到警惕**——先理解机制，再识别风险，最终写出经得起审计的代码。

## 全书结构（22 章 + 附录）

```
第一篇 认知地基（第 1-3 章）
  对象模型 · Move 语言 · DeFi 核心抽象 · 风险语言

第二篇 价格基础设施（第 4-6 章）
  DEX（固定汇率 → AMM → V2 → V3 → DLMM → StableSwap → 订单簿）
  预言机 · 聚合器

第三篇 信用与货币（第 7-9 章）
  借贷（储蓄池 → Aave/Compound → Navi/Scallop）
  流动性挖矿（累加器 → 衰减 → Boost/VeToken）
  稳定币（法币抵押 · CDP · 算法）

第四篇 收益与杠杆（第 10-17 章）
  LSD · 自动做市（CLMM/网格/Vault/Delta中性）
  衍生品 · 现货杠杆 · 套利 · Launchpad
  跨链桥与链上保险 · 预测市场（CTF + LMSR + 结算）

第五篇 警惕（第 18-22 章）
  攻击模式 · 协议工程化 · 审计准备 · Move 安全实践 · 风险控制全景
```

## 目标读者

- **开发者**：想在 Sui 上构建或贡献 DeFi 协议（首要读者）
- **安全研究员**：需要理解 DeFi 攻击面和防御机制
- **产品/投资研究者**：需要深度理解协议运作逻辑

前置要求：至少一门编程语言经验，了解区块链基本概念。不假设你有 Move 或 Sui 经验。

## 每章的统一结构

每一章都遵循同一套分析框架：

| 模块 | 内容 |
|------|------|
| 业务问题 | 这个协议解决什么问题？ |
| 资产流 | 资产如何流转？谁可以动？ |
| Move 实现 | 完整的可运行代码 |
| Sui 案例分析 | Cetus / DeepBook / Navi / Scallop 等真实协议 |
| 风险分析 | 什么会出错？怎么防？ |

## 本地构建

```bash
# 安装 mdBook
cargo install mdbook

# 克隆仓库
git clone https://github.com/hoh-zone/defi-intro.git
cd defi-intro

# 构建并预览
mdbook build
mdbook serve --open
```

代码块中的 **Move / Sui Move** 语法高亮使用 [highlightjs-sui](https://github.com/hoh-zone/highlightjs-sui)。预构建脚本已提交在 `theme/highlight-sui-move.bundle.js`，一般无需安装 Node。若你升级了 `highlightjs-sui` 或修改了 `scripts/mdbook-sui-bridge.js`，请在仓库根目录执行 `npm install && npm run build:highlight` 再 `mdbook build`。

## 章节速查

| 篇 | 章 | 主题 | 核心代码 |
|----|----|------|----------|
| 一 | 1 | DeFi 全景与 Sui 定位 | — |
| 一 | 2 | Move 语言精要 | Object · Ability · PTB |
| 一 | 3 | 核心抽象与风险语言 | Pool · Position · APR |
| 二 | 4 | DEX 全类型 | FixedRate · AMM · V2 · V3 · DLMM · StableSwap · Orderbook |
| 二 | 5 | 预言机 | PriceGuard · TWAP |
| 二 | 6 | DEX 聚合器 | Router · SplitOrder |
| 三 | 7 | 借贷 | Savings · Lending · FlashLoan |
| 三 | 8 | 流动性挖矿 | RewardAccumulator · Decay · VeToken |
| 三 | 9 | 稳定币 | Fiat · CDP · Algo |
| 四 | 10 | LSD | StakedSUI · LST |
| 四 | 11 | 自动做市 | GridBot · YieldVault · DeltaNeutral |
| 四 | 12 | 衍生品 | PerpMarket · Margin |
| 四 | 13 | 现货杠杆 | LeverageLoop |
| 四 | 14 | 套利 | SpreadArb · MEV |
| 四 | 15 | Launchpad | StateMachine · Vesting |
| 四 | 16 | 跨链与保险 | Bridge · Insurance · PredictionMarket |
| 四 | 17 | 预测市场 | CTF · LMSR · Oracle · Claim |
| 五 | 18 | 攻击模式 | OracleAttack · FlashLoanAttack · GovernanceAttack |
| 五 | 19 | 协议工程化 | AdminCap · PauseState · FuzzTest |
| 五 | 20 | 审计准备 | PermissionMatrix · Governance |
| 五 | 21 | Move 安全实践 | Capability · SafeMath · Multisig · Checklist |
| 五 | 22 | 风险控制全景 | LTV · 清算 · 挤兑 · 治理 · Launch Checklist |

## 技术栈

- **链**：Sui
- **语言**：Move（Sui Move 方言）
- **协议案例**：Cetus · DeepBook · Navi · Scallop
- **书籍格式**：[mdBook](https://rust-lang.github.io/mdBook/)

## 许可

MIT License
