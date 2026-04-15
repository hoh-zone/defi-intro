# 重写计划：《Sui DeFi：从入门到警惕》

## 总体目标
将现有教材升级为**程序员友好型**技术书籍，每个核心协议章节提供：
1. 完整的 Move 代码实现（教学原型 + 生产级参考）
2. 关键算法与数据结构解释
3. 安全性考量与攻击演示代码
4. 单元测试示例

## 章节代码示例规划

### 第 6 章 借贷：从储蓄池到信用市场
#### 6.1 Sui Savings 储蓄协议（教学原型）
- 文件：`src/06_lending/sui_savings.move`
- 功能：deposit(), withdraw(), claim_interest()
- 对象：SavingsPool<T>, SavingsPosition<T>, AdminCap
- 包含：利息计算伪代码 + 实际实现

#### 6.2 常规借贷市场
- 文件：`src/06_lending/lending_market.move`
- 功能：supply(), borrow(), repay(), withdraw_collateral(), liquidate()
- 对象：Market, DebtPosition, CollateralPosition, Reserve
- 利率模型：kinked utilization-based model
- 包含：健康因子计算、部分清算逻辑

#### 6.3 闪电贷实现
- 文件：`src/06_lending/flash_loan.move`
- 核心函数：flash_loan(amount: u64, receiver: address, callback: entry function)
- 工作流：借出 → 执行用户逻辑 → 检查偿还 + 费用
- 安全性：重入保护（Move天然），回调地址白名单
- 示例：套利机器人代码片段

#### 测试示例
- 文件：`tests/lending_move_test.rs` 或 `Move.toml` 中的测试
- 覆盖：正常流程、边界条件（利率极端值）、清算触发、闪电贷成功/失败

### 第 9 章 稳定币（法币 / CDP / 算法）
#### CDP 完整实现
- 文件：`src/09_stablecoin/code/cdp_stablecoin/sources/cdp.move`
- 核心对象：`StableTreasury`, `CDPSystem<Collateral>`, `CDPPosition<Collateral>`
- 功能：open_position, add_collateral, repay, liquidate 等
- 另见：`src/09_stablecoin/code/fiat_stablecoin_sketch/`、`algorithmic_stablecoin_sketch/` 教学包

#### 攻击演示代码（注释掉的危险示例）
- 文件：（规划中）或见第 18 章攻击篇（仅作说明，不编译）
- 举例：不当的清算奖励计算导致的恶意清算
- 举例：预言机更新前的闪电贷攻击路径

### 第 9 章 永续合约
#### 9.2 永续合约完整实现
- 文件：`src/09_derivatives/perp_implementation.move`
- 核心对象：PerpMarket, Position, InsuranceFund
- 功能：open_position(), add_margin(), remove_margin(), update_funding(), liquidate()
- 机制：标记价格计算、资金费率分摊、部分平仓
- 对象设计：如何避免共享对象竞争

#### 资金费率攻击演示
- 时间加权平均价格（TWAP）操纵示例
- 资金费率套利机器人逻辑

### 第 10 章 Launchpad
#### 10.4 完整案例
- 文件：`src/10_launchpad/launchpad_impl.move`
- 状态机：五个明确状态 + 过渡函数
- 对象：LaunchpadRound, Whitelist, SubscriptionTicket, ClaimRecord
- 功能：start_whitelist(), start_sale(), claim_tokens()
- 防御机制：防重入、幂等性检查、时间戳验证

### 第 11-13 章 警惕篇（攻击代码与防御）
#### 11.2 闪电贷攻击演示
- 文件：`src/11_attacks/flash_loan_attack.move`
- 目标：利用不完善的预言机进行价格操纵
- 步骤：闪电贷 → 扭曲DEX价格 → 触发清算 → 偿还贷款
- 防御展示：在借贷协议中加入TWAP价格

#### 11.3 重入攻击尝试（Move中的表现）
- 文件：`src/11_attacks/reentrancy_attempt.move`
- 说明：Move的资源语义如何防止经典重入
- 展示：逻辑漏洞示例（如错误的状态更新顺序）

## 实现建议

### 代码组织结构
```
src/
├── 06_lending/
│   ├── sui_savings.move        # 教学原型
│   ├── lending_market.move     # 生产级参考
│   ├── flash_loan.move         # 闪电贷模块
│   └── attack_examples.move    # 仅作说明
├── 09_stablecoin/
│   └── code/                   # fiat_sketch / cdp_stablecoin / algorithmic_sketch
├── 09_derivatives/
│   └── perp_implementation.move# 永续合约实现
├── 10_launchpad/
│   └── launchpad_impl.move     # Launchpad完整实现
└── 11_attacks/
    ├── flash_loan_attack.move  # 攻击演示
    └── reentrancy_attempt.move # 逻辑漏洞演示
```

### 测试策略
- 每个核心模块配套Move单元测试
- 使用Sui框架的测试工具
- 重点测试：边界条件、失败路径、攻击场景
- 测试文件放在对应章节的tests/目录

### 代码质量标准
1. 完整注释说明设计决策
2. 错误处理与边界条件检查
3. 遵循Sui Move最佳实践
4. 模块化设计，便于理解
5. 安全性考量贯穿始终

## 下一步行动

1.  为每个规划的代码文件创建占位符
2.  从现有章节中提取并改进代码示例
3.  添加攻击演示与防御代码
4.  编写对应的单元测试
5.  更新章节说明以配合代码示例

这个计划确保每个章节不仅讲解机制，还提供可运行、可修改的代码示例，真正面向程序员读者。