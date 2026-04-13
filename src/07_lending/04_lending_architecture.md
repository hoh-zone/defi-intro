# 7.4 借贷协议整体架构图

本节展示借贷协议的完整系统蓝图——我们本章要实现的最终系统。

## 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│                     Lending Protocol                         │
│                                                              │
│   ┌──────────────────────────────────────────────────────┐   │
│   │            Market<Collateral, Borrow>                │   │
│   │                   (Shared Object)                     │   │
│   │                                                      │   │
│   │  ┌──────────────┐  ┌──────────────┐                 │   │
│   │  │collateral_vault│  │ borrow_vault │                 │   │
│   │  │  (Balance<C>) │  │ (Balance<B>) │                 │   │
│   │  └──────────────┘  └──────────────┘                 │   │
│   │                                                      │   │
│   │  total_collateral │ total_borrow                     │   │
│   │  collateral_factor │ liquidation_threshold            │   │
│   │  liquidation_bonus │ base_rate │ kink │ multiplier   │   │
│   └──────────────────────────┬───────────────────────────┘   │
│                              │                               │
│            ┌─────────────────┼─────────────────┐             │
│            ↓                 ↓                 ↓             │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│   │DepositReceipt│  │BorrowReceipt │  │  AdminCap    │     │
│   │ (Owned Obj)  │  │ (Owned Obj)  │  │ (Owned Obj)  │     │
│   │              │  │              │  │              │     │
│   │collateral_amt│  │ borrow_amount│  │  market_id   │     │
│   └──────────────┘  └──────────────┘  └──────────────┘     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## 用户生命周期

```
┌─────────────────────────────────────────────────────────────┐
│                    用户完整操作流程                           │
│                                                             │
│  1. 存款                                                    │
│  User ──Coin<C>──→ supply_collateral() ──→ DepositReceipt   │
│                                                             │
│  2. 借款                                                    │
│  DepositReceipt + Market ──→ borrow() ──→ Coin<B>           │
│                                    └──→ BorrowReceipt       │
│                                                             │
│  3. 利息累积                                                │
│  Market 自动计算利率 → 债务增长 → 存款增值                  │
│                                                             │
│  4. 还款                                                    │
│  BorrowReceipt + Coin<B> ──→ repay() ──→ 债务清除           │
│                                                             │
│  5. 取回抵押品                                              │
│  DepositReceipt ──→ withdraw_collateral() ──→ Coin<C>       │
│                                                             │
│  （如果被清算）                                              │
│  BorrowReceipt + Coin<B> ──→ liquidate() ──→ Coin<C>       │
│  └── 部分抵押品被没收作为惩罚                               │
└─────────────────────────────────────────────────────────────┘
```

## 对象所有权关系

```
                    Market (Shared)
                   ╱      │       ╲
                  ╱       │        ╲
    DepositReceipt  BorrowReceipt  AdminCap
     (Alice 拥有)    (Alice 拥有)  (Admin 拥有)
         │              │
    DepositReceipt  BorrowReceipt
     (Bob 拥有)      (Bob 拥有)

每个用户拥有自己的 Receipt 对象
→ 互不干扰
→ 可以并行操作
→ 对象可以转移（DeFi 组合性）
```

## Market 核心状态

```
Market<Collateral, Borrow> 维护的状态:

资产状态:
  collateral_vault: Balance<C>   — 锁定的抵押品
  borrow_vault: Balance<B>       — 可借出的资产
  total_collateral: u64          — 总抵押量
  total_borrow: u64              — 总借款量

风险参数:
  collateral_factor_bps: u64     — 抵押因子 (如 7500 = 75%)
  liquidation_threshold_bps: u64 — 清算阈值 (如 8000 = 80%)
  liquidation_bonus_bps: u64     — 清算奖励 (如 500 = 5%)

利率参数:
  base_rate_bps: u64             — 基础利率
  kink_bps: u64                  — 拐点利用率
  multiplier_bps: u64            — 拐点以下斜率
  jump_multiplier_bps: u64       — 拐点以上跳跃斜率

计算得出:
  utilization = total_borrow / total_supply
  borrow_rate = f(utilization, rate_params)
  health_factor = collateral * threshold / debt
```

## 核心函数一览

```
┌─────────────────────┬──────────────────────────────────────┐
│ 函数                │ 说明                                 │
├─────────────────────┼──────────────────────────────────────┤
│ create_market()     │ 创建新市场，共享 Market 对象         │
│ supply_collateral() │ 存入抵押品，获得 DepositReceipt      │
│ borrow()            │ 抵押借款，检查 HF，获得 BorrowReceipt│
│ repay()             │ 偿还借款，销毁 BorrowReceipt         │
│ withdraw_collateral │ 取回抵押品，检查 HF，销毁 Receipt    │
│ liquidate()         │ 清算不健康仓位                       │
│ calculate_interest  │ 计算当前利率（kinked 模型）          │
│ health_factor()     │ 计算仓位健康因子                     │
│ set_*()             │ 管理员更新风险参数                   │
└─────────────────────┴──────────────────────────────────────┘
```

## 安全检查流程

```
borrow() 的安全检查:
  1. amount > 0?                    → 非零检查
  2. market_id 匹配?                → Receipt 归属检查
  3. borrow_vault >= amount?        → 流动性检查
  4. HF > 1.0?                      → 偿付能力检查
  5. 更新 total_borrow              → 状态更新

liquidate() 的安全检查:
  1. market_id 匹配?                → Receipt 归属检查
  2. repay_amount == debt?          → 全额还款检查
  3. HF < 1.0?                      → 确认可清算
  4. seized <= collateral?          → 没收不超过抵押
  5. collateral_vault >= seized?    → 资金充足检查
  6. 更新所有状态                    → 状态更新
```

## 配套代码说明

```
本章有三个代码包:

lending_market/ — 完整借贷协议
  对应 Part 0-5 的所有模块
  包含: Market, Receipt, 利率模型, 清算

sui_savings/ — 储蓄池（简化版 Supply Pool）
  对应 Part 1 的 Supply Pool 模块
  演示: Share Token, deposit/withdraw, interest

flash_loan/ — 闪电贷
  对应 Part 6 的 Flash Loan 模块
  演示: Hot Potato 模式, 原子借贷

后续章节将逐步引用这些代码的具体实现
```

## 总结

```
整体架构的核心设计:
  Market 作为唯一的 Shared Object
  → 所有资产汇聚于此

DepositReceipt / BorrowReceipt 作为 Owned Object
  → 用户独立管理自己的仓位

AdminCap 管理员权限
  → 风险参数的治理

这种 Shared + Owned 的混合模式
是 Sui 借贷协议的典型架构
```
