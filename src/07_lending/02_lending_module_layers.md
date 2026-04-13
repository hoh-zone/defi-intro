# 7.2 Lending Protocol 的模块分层

一个完整的借贷协议由 5 个核心模块组成。本节分析每个模块的职责和它们之间的关系。

## 五大模块总览

```
┌─────────────────────────────────────────────────┐
│              Lending Protocol                    │
│                                                 │
│  ┌────────────┐  ┌────────────┐                │
│  │ Supply Pool │  │Borrow Engine│                │
│  │  存取款     │  │ 借款/还款  │                │
│  │ Share 记账  │  │ Debt 记账  │                │
│  └──────┬─────┘  └──────┬─────┘                │
│         │               │                       │
│  ┌──────┴───────────────┴──────┐               │
│  │      Interest Model         │               │
│  │    利率计算 / 利用率追踪     │               │
│  └──────────────┬──────────────┘               │
│                 │                               │
│  ┌──────────────┴──────────────┐               │
│  │    Liquidation Engine       │               │
│  │  健康监控 / 抵押品清算      │               │
│  └──────────────┬──────────────┘               │
│                 │                               │
│  ┌──────────────┴──────────────┐               │
│  │       Risk Engine           │               │
│  │  LTV 限制 / 资产风险参数    │               │
│  └─────────────────────────────┘               │
└─────────────────────────────────────────────────┘
```

## 模块 1: Supply Pool（存款池）

```
职责:
  - 接受存款人的资产存入
  - 发行存款凭证（Share Token）
  - 处理取款请求
  - 追踪总存款量

核心数据:
  total_supply: 存款总量
  total_shares: 份额总量
  exchange_rate: 份额与资产的汇率

关键函数:
  deposit(amount) → shares
  withdraw(shares) → amount
  get_exchange_rate() → rate

状态转换:
  存款时: total_supply += amount, total_shares += new_shares
  取款时: total_supply -= amount, total_shares -= burned_shares
  利息累积: total_supply 自动增长（借款人还款的利息）
```

## 模块 2: Borrow Engine（借款引擎）

```
职责:
  - 处理借款请求
  - 追踪每位借款人的债务
  - 处理还款
  - 检查借款是否安全

核心数据:
  total_borrow: 总借款量
  debt_per_user: 每位借款人的债务
  borrow_index: 借款利息累积指数

关键函数:
  borrow(amount) → debt_token
  repay(debt_token) → 清除债务
  get_debt(user) → 当前债务（含利息）

状态转换:
  借款时: total_borrow += amount, mint debt_token
  还款时: total_borrow -= amount, burn debt_token
  利息累积: debt 随时间增长
```

## 模块 3: Interest Model（利率模型）

```
职责:
  - 根据供需计算当前利率
  - 追踪利用率
  - 提供借款利率和存款利率

核心数据:
  utilization: 利用率 = borrow / supply
  borrow_rate: 借款利率
  supply_rate: 存款利率

关键函数:
  calculate_rate(utilization) → borrow_rate
  get_supply_rate() → supply_rate

利率计算频率:
  → 每个区块（或每次操作时）更新
  → 利率影响下一个周期的利息累积
```

## 模块 4: Liquidation Engine（清算引擎）

```
职责:
  - 监控所有仓位健康度
  - 触发不健康仓位的清算
  - 处理抵押品没收和债务偿还

核心数据:
  health_factor: 每个仓位的健康因子
  liquidation_threshold: 清算触发线
  liquidation_bonus: 清算奖励

关键函数:
  check_health(position) → health_factor
  liquidate(position) → seize collateral, repay debt

清算条件:
  health_factor < 1.0 → 可清算
  health_factor >= 1.0 → 安全
```

## 模块 5: Risk Engine（风险引擎）

```
职责:
  - 管理每种资产的风险参数
  - 设置 LTV 上限
  - 设置清算阈值
  - 限制单资产最大敞口

核心数据:
  collateral_factor: 抵押因子（如 75%）
  liquidation_threshold: 清算阈值（如 80%）
  borrow_cap: 借款上限
  supply_cap: 存款上限

关键函数:
  set_risk_params(asset, params)
  validate_borrow(user, amount) → bool

参数层次:
  collateral_factor < liquidation_threshold
  → 留出安全缓冲
  → 例: 75% < 80%，中间有 5% 的缓冲区
```

## 模块间的数据流

```
用户存款:
  User → Supply Pool (存入资产)
  Supply Pool → Interest Model (更新利用率)
  Interest Model → Supply Pool (返回新利率)

用户借款:
  User → Borrow Engine (请求借款)
  Borrow Engine → Risk Engine (检查 LTV)
  Risk Engine → Borrow Engine (批准/拒绝)
  Borrow Engine → Supply Pool (取出资产)
  Borrow Engine → Interest Model (更新利用率)

清算:
  Liquidator → Liquidation Engine (触发清算)
  Liquidation Engine → Risk Engine (确认不健康)
  Liquidation Engine → Borrow Engine (偿还债务)
  Liquidation Engine → Supply Pool (没收抵押品)

利息累积:
  Interest Model → Borrow Engine (更新债务)
  Interest Model → Supply Pool (更新存款价值)
```

## 在我们的代码中的体现

```
lending_market 代码包的模块映射:

Supply Pool:
  → supply_collateral() 函数
  → collateral_vault, total_collateral

Borrow Engine:
  → borrow(), repay() 函数
  → borrow_vault, total_borrow
  → BorrowReceipt

Interest Model:
  → calculate_interest_rate() 函数
  → base_rate_bps, kink_bps, multiplier_bps, jump_multiplier_bps

Liquidation Engine:
  → liquidate() 函数
  → health_factor() 函数

Risk Engine:
  → AdminCap 管理的参数
  → collateral_factor_bps, liquidation_threshold_bps
```

## 总结

```
五大模块各司其职:
  Supply Pool  → 管理存款和取款
  Borrow Engine → 管理借款和还款
  Interest Model → 定价资金的时间价值
  Liquidation Engine → 维护系统安全
  Risk Engine → 管理全局风险参数

模块间通过状态变量和函数调用协作
下一节分析 Sui Object Model 如何优化这一架构
```
