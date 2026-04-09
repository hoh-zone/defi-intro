# 附录 E 本书案例索引与代码仓库

## 代码示例索引

### AMM / DEX

| 示例 | 位置 | 描述 |
|------|------|------|
| AMM Pool 完整实现 | 第 4 章 4.2 | 恒定乘积做市商，含 swap/provide/remove |
| Swap 数值示例 | 第 4 章 4.2 | SUI/USDC 池的完整交易周期 |
| 集中流动性 Position struct | 第 4 章 4.3 | CLPosition 对象设计 |
| 订单簿 Order struct | 第 4 章 4.4 | Order + OrderBook 对象设计 |

### 预言机

| 示例 | 位置 | 描述 |
|------|------|------|
| safe_read_price | 第 5 章 5.2 | 四层防御的价格读取函数 |
| PriceGuard | 第 5 章 5.3 | 价格偏差验证 |
| TWAP 实现 | 第 11 章 11.1 | 时间加权平均价格 |

### 借贷

| 示例 | 位置 | 描述 |
|------|------|------|
| Sui Savings 完整实现 | 第 6 章 6.1 | 储蓄池原型，含 deposit/withdraw/claim |
| Lending Market | 第 6 章 6.2 | 常规借贷，含 supply/borrow/repay/liquidate |
| 闪电贷 | 第 6 章 6.3 | FlashLoanPool 完整实现 + 套利示例 + 清算机器人 |
| 利率模型 | 第 6 章 6.4 | Kinked Rate Model 的 Move 实现 |
| 健康因子 | 第 6 章 6.5 | Health Factor 计算与清算函数 |

### CDP / 稳定币

| 示例 | 位置 | 描述 |
|------|------|------|
| CDP 完整实现 | 第 7 章 7.2 | open_position/add_collateral/repay/liquidate |
| 治理参数更新 | 第 7 章 7.2 | update_parameters with AdminCap |

### LSD

| 示例 | 位置 | 描述 |
|------|------|------|
| StakedSUI | 第 8 章 8.2 | 升值型 LST 实现 |
| LiquidStakingPool | 第 8 章 8.2 | 数量增长型 LST 实现 |
| 杠杆收益计算 | 第 8 章 8.3 | leveraged_stake_cost 函数 |

### 衍生品

| 示例 | 位置 | 描述 |
|------|------|------|
| 永续合约完整实现 | 第 9 章 9.2 | PerpMarket + Position + 开仓/减仓/强平 |
| PnL 计算 | 第 9 章 9.1 | perp_math 模块 |
| 清算价格计算 | 第 9 章 9.1 | calculate_liquidation_price |

### Launchpad

| 示例 | 位置 | 描述 |
|------|------|------|
| 状态机完整实现 | 第 10 章 10.1 | 5 状态 + 6 状态转换 |
| 白名单管理 | 第 10 章 10.1 | Whitelist + Subscription |
| AntiBot | 第 10 章 10.2 | Bot 防御机制 |
| Vesting 计算 | 第 10 章 10.3 | calculate_vested 函数 |

### 攻击与安全

| 示例 | 位置 | 描述 |
|------|------|------|
| 预言机操纵攻击 | 第 11 章 11.1 | 攻击路径演示 + TWAP 防御 |
| 闪电贷攻击 | 第 11 章 11.2 | 三明治攻击 + 防御清单 |
| 逻辑漏洞 | 第 11 章 11.3 | 权限遗漏 + 状态顺序错误 |
| 清算级联 | 第 11 章 11.4 | CircuitBreaker + 保险基金 |
| 治理攻击 | 第 11 章 11.5 | Timelock + Multisig |

### 工程化

| 示例 | 位置 | 描述 |
|------|------|------|
| 角色分离 AdminCap | 第 12 章 12.1 | 位掩码权限系统 |
| 对抗测试 | 第 12 章 12.2 | expected_failure 测试示例 |
| 紧急暂停 | 第 12 章 12.3 | 细粒度 PauseState |
| 权限矩阵 | 第 13 章 13.2 | 完整的权限矩阵模板 |
