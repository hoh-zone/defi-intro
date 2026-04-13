# 7.30 完整 Lending Protocol 组装

本节将前面 29 节的所有模块组装成完整的借贷协议系统。

## 模块整合

```
┌──────────────────────────────────────────────────────────┐
│                  完整 Lending Protocol                    │
│                                                          │
│  Supply Pool (7.5-7.7)                                   │
│  ┌────────────────┐  ┌────────────────┐                 │
│  │ Share Token    │  │ Interest Index │                 │
│  │ deposit/withdraw│ │ global index   │                 │
│  └────────────────┘  └────────────────┘                 │
│                                                          │
│  Borrow Engine (7.8-7.10)                                │
│  ┌────────────────┐  ┌────────────────┐                 │
│  │ Debt Token     │  │ Borrow Index   │                 │
│  │ borrow/repay   │  │ debt tracking  │                 │
│  └────────────────┘  └────────────────┘                 │
│                                                          │
│  Collateral (7.11-7.13)                                  │
│  ┌────────────────┐  ┌────────────────┐                 │
│  │ Collateral Obj │  │ LTV & HF       │                 │
│  │ add/remove     │  │ safety check   │                 │
│  └────────────────┘  └────────────────┘                 │
│                                                          │
│  Interest Model (7.14-7.17)                              │
│  ┌────────────────┐  ┌────────────────┐                 │
│  │ Utilization    │  │ Jump Rate      │                 │
│  │ U = borrow/sup │  │ kinked model   │                 │
│  └────────────────┘  └────────────────┘                 │
│                                                          │
│  Liquidation (7.18-7.21)                                 │
│  ┌────────────────┐  ┌────────────────┐                 │
│  │ HF < 1 触发    │  │ 奖励 & 罚金    │                 │
│  │ partial/full   │  │ seize + repay  │                 │
│  └────────────────┘  └────────────────┘                 │
│                                                          │
│  Flash Loan (7.22-7.24)                                  │
│  ┌────────────────┐  ┌────────────────┐                 │
│  │ Hot Potato     │  │ borrow/repay   │                 │
│  │ atomic safety  │  │ fee collection │                 │
│  └────────────────┘  └────────────────┘                 │
│                                                          │
│  Architecture (7.25-7.27)                                │
│  ┌────────────────┐  ┌────────────────┐                 │
│  │ Cross Collateral│ │ Isolated Market│                 │
│  │ aggregate HF   │  │ per-pair risk  │                 │
│  └────────────────┘  └────────────────┘                 │
│                                                          │
│  Risk & Oracle (7.28-7.29)                               │
│  ┌────────────────┐  ┌────────────────┐                 │
│  │ Price Oracle   │  │ Risk Params    │                 │
│  │ get_price()    │  │ factor/threshold│                │
│  └────────────────┘  └────────────────┘                 │
└──────────────────────────────────────────────────────────┘
```

## 用户完整生命周期

```
步骤 1: 准备
  LP 存入流动性 → add_liquidity(market, USDC)
  → 市场有可借资金

步骤 2: 存款
  Alice → supply_collateral(market, 10000 SUI)
  → 获得 DepositReceipt { collateral: 10000 }

步骤 3: 借款
  Alice → borrow(market, &receipt, 5000)
  → 检查 HF: 10000 × 75% / 5000 = 15000 > 10000 ✅
  → 获得 5000 USDC + BorrowReceipt { debt: 5000 }

步骤 4: 利息累积
  Market 自动:
  → 利用率 U = 5000 / (10000 + borrow_vault)
  → 计算 borrow_rate（Jump Rate Model）
  → supply_index 和 borrow_index 增长
  → Alice 的债务增长，LP 的存款增值

步骤 5: 还款
  Alice → repay(market, borrow_receipt, 5000 + interest)
  → BorrowReceipt 销毁
  → 债务清除

步骤 6: 取回
  Alice → withdraw_collateral(market, deposit_receipt, ...)
  → 检查无借款后取回
  → DepositReceipt 销毁
  → 获得 10000 SUI（+ 剩余利息）
```

## 清算场景

```
Alice: collateral=10000 SUI, debt=7000 USDC
SUI 价格暴跌 → HF < 1.0

清算人:
  → 监控发现 HF < 1.0
  → 准备 7000 USDC
  → liquidate(market, borrow_receipt, 7000 USDC, deposit_receipt)
  → 获得 7000 × 1.05 = 7350 SUI
  → 在 DEX 卖出获利

Alice:
  → 失去 7350 SUI
  → 剩余 2650 SUI
  → 债务清除
```

## lending_market 代码映射

```
模块                    │ 代码位置
───────────────────────┼──────────────────────
Supply Pool            │ supply_collateral(), collateral_vault
Borrow Engine          │ borrow(), repay(), borrow_vault
Interest Model         │ calculate_interest_rate(), kinked model
Liquidation Engine     │ liquidate(), health_factor()
Collateral Management  │ withdraw_collateral()
Risk Parameters        │ collateral_factor, liquidation_threshold
Admin                  │ AdminCap, set_*() functions

文件:
  sources/market.move — 完整借贷逻辑 (560 行)
  tests/market_test.move — 8 个测试覆盖所有场景
```

## flash_loan 代码映射

```
模块           │ 代码位置
──────────────┼──────────────────────
Flash Pool     │ FlashPool struct, deposit/withdraw
Borrow/Repay   │ borrow(), repay() with hot potato
Fee System     │ fee_bps, accumulated_fees
Admin          │ AdminCap, withdraw_fees

文件:
  sources/flash_loan.move — 闪电贷 (242 行)
  tests/flash_loan_test.move — 9 个测试
```

## sui_savings 代码映射

```
模块           │ 代码位置
──────────────┼──────────────────────
Supply Pool    │ SavingsPool, deposit/withdraw
Share Token    │ SavingsReceipt, shares
Interest       │ reward_pool, claim_interest
Admin          │ AdminCap, pause/unpause

文件:
  sources/savings.move — 储蓄池 (226 行)
  tests/savings_test.move — 8 个测试
```

## 本章核心收获

```
30 节的核心知识:

借贷基础:
  → 超额抵押是 DeFi 借贷的基础
  → Supplier, Borrower, Liquidator 三位一体
  → 五大模块各司其职

存款系统:
  → Share Token 追踪存款份额
  → Interest Index 高效计算利息
  → Exchange Rate 自动反映收益

借款系统:
  → Debt Token 追踪债务
  → 双 Index 系统追踪存借款增长

抵押与风险:
  → LTV 限制借款能力
  → Health Factor 衡量仓位安全
  → 安全缓冲 = threshold - factor

利率模型:
  → 利用率驱动利率
  → Jump Rate Model 是行业标准
  → 拐点设计保护流动性

清算系统:
  → HF < 1 触发清算
  → 清算奖励激励清算人
  → 部分清算更友好

闪电贷:
  → 热土豆模式保证原子安全
  → 零资本套利和清算

架构选择:
  → Cross Collateral: 高效但复杂
  → Isolated Market: 安全但碎片化
  → 根据资产类型选择

Sui 优势:
  → Object Model: 仓位对象化
  → 并行执行: 多市场并行
  → PTB: 原子化复杂操作
  → 低延迟: 及时清算
```
