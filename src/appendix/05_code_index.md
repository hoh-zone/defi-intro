# 附录 E 本书案例索引与代码仓库

## 代码示例索引

### AMM / DEX

| 示例 | 位置 | 描述 |
|------|------|------|
| 固定汇率兑换 | 第 4 章 4.2 | 最简单的 DEX：直接互换 |
| AMM Pool 完整实现 | 第 4 章 4.3 | 恒定乘积做市商，含 swap/provide/remove |
| Swap 数值示例 | 第 4 章 4.3 | SUI/USDC 池的完整交易周期 |
| Uniswap V2 完整实现 | 第 4 章 4.4 | 含手续费、K 值检查、报价函数 |
| 集中流动性 Position | 第 4 章 4.5 | CLPosition 对象设计 |
| DLMM 动态流动性 | 第 4 章 4.6 | Bin 结构 + 跨 bin swap |
| StableSwap 曲线 | 第 4 章 4.7 | 稳定币互换 invariant |
| 订单簿 Order struct | 第 4 章 4.8 | Order + OrderBook 对象设计 |

### 预言机

| 示例 | 位置 | 描述 |
|------|------|------|
| safe_read_price | 第 5 章 5.4 | 四层防御的价格读取函数 |
| PriceGuard | 第 5 章 5.4 | 价格偏差验证 |
| TWAP 实现 | 第 5 章 5.12 | 时间加权平均价格 |

### 聚合器

| 示例 | 位置 | 描述 |
|------|------|------|
| 问题与三层架构 | 第 6 章 6.1–6.2 | 链下报价 / 链上 Router / DEX 结算 |
| SwapContext 与 router | 第 6 章 6.3 | `new_swap_context` / `new_swap_context_v2`、`confirm_swap` |
| DexRouter 与 Path | 第 6 章 6.4 | 适配器接口、`FlattenedPath`、`MAX_AMOUNT_IN` |
| Cetus CLMM / DLMM | 第 6 章 6.5–6.6 | `CetusRouter`、多 `published_at` |
| DeepBook V3 | 第 6 章 6.7 | 订单簿腿与 `extended_details` |
| 报价 API 与 PTB | 第 6 章 6.8 | `packages` 映射与交易组装 |
| 拆单 / Gas / 风控 | 第 6 章 6.9–6.10 | 滑点、工程清单与免责 |
| SwapContext 教学模块（可编译） | 第 6 章代码 `aggregator_router_tutorial` | `router_tutorial.move`：min_out、max_in、confirm |

### 借贷

| 示例 | 位置 | 描述 |
|------|------|------|
| Sui Savings 完整实现 | 第 7 章 7.1 | 储蓄池原型，含 deposit/withdraw/claim |
| Lending Market | 第 7 章 7.2 | 常规借贷，含 supply/borrow/repay/liquidate |
| 闪电贷 | 第 7 章 7.3 | FlashLoanPool 完整实现 + 套利示例 + 清算机器人 |
| 利率模型 | 第 7 章 7.2 | Kinked Rate Model 的 Move 实现 |
| 健康因子 | 第 7 章 7.2 | Health Factor 计算与清算函数 |

### 流动性挖矿

| 示例 | 位置 | 描述 |
|------|------|------|
| 奖励累加器 | 第 8 章 8.2 | RewardPool + acc_reward_per_share |
| DEX 多池挖矿 | 第 8 章 8.3 | 权重分配 MiningMaster |
| 借贷挖矿 | 第 8 章 8.4 | 存款/借款双激励 |
| 衰减调度器 | 第 8 章 8.5 | 线性/阶梯/指数衰减 |
| Boost + VeToken | 第 8 章 8.6 | 锁仓 boost + gauge 投票 |

### CDP / 稳定币

| 示例 | 位置 | 描述 |
|------|------|------|
| CDP 完整实现 | 第 9 章 9.2 | open_position/add_collateral/repay/liquidate |
| 治理参数更新 | 第 9 章 9.2 | update_parameters with AdminCap |

### LSD

| 示例 | 位置 | 描述 |
|------|------|------|
| StakedSUI | 第 10 章 10.2 | 升值型 LST 实现 |
| LiquidStakingPool | 第 10 章 10.2 | 数量增长型 LST 实现 |
| 杠杆收益计算 | 第 10 章 10.3 | leveraged_stake_cost 函数 |

### 自动做市与收益策略

| 示例 | 位置 | 描述 |
|------|------|------|
| IL 计算器 | 第 11 章 11.1 | 无常损失与净收益计算 |
| 自动再平衡 | 第 11 章 11.2 | CLMM 自动再平衡 Vault |
| 订单簿做市商 | 第 11 章 11.3 | 双边报价 + 库存管理 |
| 网格交易 | 第 11 章 11.4 | GridBot 完整实现 |
| Yield Vault | 第 11 章 11.5 | Yearn 风格自动复投 |
| 杠杆挖矿 | 第 11 章 11.6 | 循环借贷 + LP + 质押 |
| Delta 中性 | 第 11 章 11.7 | 对冲仓位管理 |

### 衍生品

| 示例 | 位置 | 描述 |
|------|------|------|
| 永续合约完整实现 | 第 12 章 12.2 | PerpMarket + Position + 开仓/减仓/强平 |
| PnL 计算 | 第 12 章 12.1 | perp_math 模块 |
| 清算价格计算 | 第 12 章 12.1 | calculate_liquidation_price |

### 现货杠杆

| 示例 | 位置 | 描述 |
|------|------|------|
| Cetus 杠杆借贷 | 第 13 章 13.2 | PTB 组合借贷 + DEX |
| DeepBook 杠杆做市 | 第 13 章 13.3 | 订单簿上的杠杆策略 |
| 杠杆螺旋 | 第 13 章 13.4 | 循环借贷风险分析 |

### 套利

| 示例 | 位置 | 描述 |
|------|------|------|
| DEX 价差套利 | 第 14 章 14.2 | 跨 DEX 套利 Move 实现 |
| 三明治攻击 | 第 14 章 14.3 | 攻击模拟代码 |
| 闪电贷套利 | 第 14 章 14.4 | 零资本套利实现 |
| 清算套利 | 第 14 章 14.5 | 清算机器人实现 |

### Launchpad

| 示例 | 位置 | 描述 |
|------|------|------|
| 状态机完整实现 | 第 15 章 15.1 | 5 状态 + 6 状态转换 |
| 白名单管理 | 第 15 章 15.1 | Whitelist + Subscription |
| AntiBot | 第 15 章 15.2 | Bot 防御机制 |
| Vesting 计算 | 第 15 章 15.3 | calculate_vested 函数 |

### 跨链与保险

| 示例 | 位置 | 描述 |
|------|------|------|
| 锁铸桥实现 | 第 16 章 16.2 | lock/mint/burn/release 全流程 |
| 跨链消息总线 | 第 16 章 16.3 | MessageBus + 超时回滚 |
| 参数型保险 | 第 16 章 16.6 | InsurancePool 完整实现 |
| 预测市场（短引） | 第 16 章 16.7 | 保险视角下的裁决与代币 |
| 安全基金 | 第 16 章 16.8 | 协议内置保险基金 |

### 预测市场（完整章）

| 示例 | 位置 | 描述 |
|------|------|------|
| 条件代币 Split/Merge | 第 17 章 17.11 | 抵押拆分与合并不变量 |
| LMSR 定价与成本 | 第 17 章 17.16–17.19 | softmax 价格、成本函数、链上定点 exp |
| 交易与池 | 第 17 章 17.22、17.25 | buy_yes/buy_no、sell、费用与抵押池 |
| Oracle 争议窗口 | 第 17 章 17.26 | submit / challenge / finalize |
| 结算与 Claim | 第 17 章 17.27–17.28 | 胜出结果与赎回 |
| 多结果 LMSR | 第 17 章 17.29 | 向量 \(q\) 与归一化价格 |
| SUI 涨跌预测 + Pyth | 第 17 章 17.31 | 10 分钟窗口、双池种子、void 与按比例 claim |

### 攻击与安全

| 示例 | 位置 | 描述 |
|------|------|------|
| 预言机操纵攻击 | 第 18 章 18.1 | 攻击路径演示 + TWAP 防御 |
| 闪电贷攻击 | 第 18 章 18.2 | 三明治攻击 + 防御清单 |
| 逻辑漏洞 | 第 18 章 18.3 | 权限遗漏 + 状态顺序错误 |
| 清算级联 | 第 18 章 18.4 | CircuitBreaker + 保险基金 |
| 治理攻击 | 第 18 章 18.5 | Timelock + Multisig |

### 工程化

| 示例 | 位置 | 描述 |
|------|------|------|
| 角色分离 AdminCap | 第 19 章 19.1 | 位掩码权限系统 |
| 对抗测试 | 第 19 章 19.2 | expected_failure 测试示例 |
| 紧急暂停 | 第 19 章 19.3 | 细粒度 PauseState |
| 权限矩阵 | 第 20 章 20.2 | 完整的权限矩阵模板 |

### Move 安全实践

| 示例 | 位置 | 描述 |
|------|------|------|
| 类型即权限 | 第 21 章 21.1 | Level1/Level2/Level3 类型化权限 |
| 角色 Capability | 第 21 章 21.2 | PauseCap/ParamsCap/OracleCap/EmergencyCap |
| Capability 工厂 | 第 21 章 21.2 | MarketCap/PoolCap 动态创建 |
| 安全算术库 | 第 21 章 21.3 | safe_mul/safe_mul_div/safe_sub 完整实现 |
| 收益分配精度安全 | 第 21 章 21.3 | u256 中间精度的 Pool/UserPosition |
| 资金安全完整示例 | 第 21 章 21.4 | deposit/withdraw 双重检查 + 事件 |
| 时间锁 | 第 21 章 21.5 | ScheduledOp + 延迟执行 |
| 密钥轮换 | 第 21 章 21.5 | Committee 成员轮换 + 版本控制 |
| 细粒度暂停 | 第 21 章 21.7 | PauseState 按操作类型暂停 |
| 安全检查清单 | 第 21 章 21.8 | 28 项上线前检查清单 |
| Move Prover 示例 | 第 21 章 21.8 | 存款金额守恒的形式化验证 |

### 风险控制（系统与经济）

| 示例 | 位置 | 描述 |
|------|------|------|
| 五大风险来源与框架 | 第 22 章 22.1–22.3 | 从代码风险到系统性风险 |
| 价格与预言机风控 | 第 22 章 22.7–22.9 | 生命线、操纵、多源与 TWAP |
| 清算与流动性 | 第 22 章 22.10–22.14 | LTV、挤兑、利率曲线 |
| 治理与死亡螺旋 | 第 22 章 22.16–22.18 | 投票攻击、Timelock、螺旋模型 |
| Launch Checklist | 第 22 章 22.20 | 上线前流程清单 |
