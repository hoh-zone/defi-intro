# 附录 A 术语表

## A

**Ability** — Move 语言的类型能力系统，包括 `key`（可作为全局对象）、`store`（可被存储）、`drop`（可被丢弃）、`copy`（可被复制）。组合决定了对象的生命周期约束。

**AdminCap** — 管理员能力对象。Sui 上的权限管理模式：持有 AdminCap 的人可以调用管理函数。

**AMM（Automated Market Maker）** — 自动做市商。用算法（如恒定乘积 $x \cdot y = k$）自动确定交易价格的 DEX 机制。

**APR（Annual Percentage Rate）** — 年化收益率，不计复利。

**APY（Annual Percentage Yield）** — 年化收益率，计入复利。APY ≥ APR。

## B

**Base Rate** — 利率模型中的基础利率。即使利用率为 0，借款人也要支付的最低利率。

**Basis Point（bps）** — 基点。1 bps = 0.01%。500 bps = 5%。

**Block** — 区块。区块链上的基本数据单元，包含一批交易。

## C

**Capability** — Sui Move 中的权限凭证模式。通过持有特定对象来证明操作权限。

**CDP（Collateralized Debt Position）** — 抵押债仓。用户抵押资产、借出稳定币的机制。

**CLMM（Concentrated Liquidity Market Maker）** — 集中流动性做市商。LP 可以选择价格区间提供流动性，提升资金效率。

**CLOB（Central Limit Order Book）** — 中心化限价订单簿。买卖双方各自报价，系统按价格优先撮合。

**Collateral** — 抵押品。借款时锁定的资产，用于保障贷款安全。

**Confidence Interval（conf）** — 置信区间。Pyth 预言机提供的价格不确定性度量。

**Composability** — 可组合性。DeFi 协议之间可以互相调用和组合的特性。

## D

**DeepBook** — Sui 上的链上订单簿（CLOB）协议。

**DEX（Decentralized Exchange）** — 去中心化交易所。链上运行的交易平台，不依赖中心化中介。

**Drop（ability）** — Move 的 `drop` ability。允许对象在作用域结束时被自动销毁。金融资产对象不应有 `drop`。

## E

**Epoch** — 纪元。Sui 的时间单位，每个 epoch 约 24 小时。验证者集合和质押奖励按 epoch 更新。

## F

**FCFS（First Come First Served）** — 先到先得。Launchpad 的一种配售策略。

**Flash Loan** — 闪电贷。在同一笔交易内借入并偿还的无抵押贷款。如果未偿还，整笔交易回滚。

**Funding Rate** — 资金费率。永续合约中多头和空头之间的定期费用转移，用于让合约价格锚定现货价格。

## G

**Gas** — 交易手续费。在 Sui 上以 SUI 支付。

**Governance** — 治理。协议参数和方向由社区（而非团队）决定的机制。

## H

**Health Factor（HF）** — 健康因子。衡量借贷仓位安全性的指标。HF = 抵押品价值（含折扣）/ 借款价值。HF < 1.0 时可被清算。

## I

**Impermanent Loss（IL）** — 无常损失。LP 因价格变化导致的相对于持币不动的价值损失。价格回到初始值时损失消失。

**Index Price** — 指数价格。多个数据源的聚合价格，用于衍生品合约的参考。

**Interest Rate Model** — 利率模型。根据资金利用率动态调整借贷利率的算法。

## K

**Key（ability）** — Move 的 `key` ability。允许 struct 作为全局存储的对象（有 `id: UID` 字段）。

**Kink** — 拐点。利率模型中利用率的分界点。拐点前利率平缓，拐点后利率急速上升。

## L

**Liquidation** — 清算。当借款人的抵押率低于阈值时，协议强制出售抵押品以偿还债务。

**Liquidation Penalty** — 清算罚金。清算时从借款人抵押品中额外扣除的比例，作为清算者的激励。

**Liquidity** — 流动性。资产可以快速买卖而不显著影响价格的程度。

**LP（Liquidity Provider）** — 流动性提供者。向 DEX 池中存入资产的用户。

**LP Token** — LP 凭证。证明 LP 在池中份额的代币。

**LSD（Liquid Staking Derivative）** — 流动性质押衍生品。将质押资产转化为可流通代币的机制。

**LST（Liquid Staking Token）** — 流动性质押代币。代表质押资产 + 累积收益的可流通代币。

**LTV（Loan-to-Value）** — 贷款价值比。借款金额与抵押品价值的比率。LTV = 1/HF。

## M

**Maintenance Margin** — 维持保证金。仓位不被清算所需的最低保证金比例。

**Mark Price** — 标记价格。衍生品协议中用于计算未实现盈亏和触发清算的价格。

**MCR（Minimum Collateral Ratio）** — 最低抵押率。开仓时必须满足的最低抵押品与债务的比例。

**Move** — Sui 的智能合约语言。具有资源语义，天然防止重入和双重支付。

## O

**Object** — 对象。Sui 的基本状态单元。每个对象有唯一 ID、所有者和版本号。

**Oracle** — 预言机。将链下数据（如价格）传递到链上的基础设施。

**Owned Object** — 拥有对象。只属于某个地址的对象，只有所有者能操作。

## P

**Perpetual（Perp）** — 永续合约。没有到期日的衍生品合约，通过资金费率锚定现货价格。

**Phantom Type Parameter** — Move 中的幻影类型参数。用 `phantom` 标记的类型参数，不消耗 ability。

**Pool** — 池。DeFi 中资金聚集的容器。通常是共享对象。

**Position** — 仓位。用户在协议中的权益凭证。通常是拥有对象。

**PTB（Programmable Transaction Block）** — 可编程交易块。Sui 允许在单笔交易中执行多个操作。

**Pro-rata** — 按比例分配。Launchpad 的一种配售策略，按认购总额等比例分配。

**Push / Pull（Oracle）** — 推送/拉取。预言机价格更新的两种模式。Push 由节点定期推送，Pull 由用户按需拉取。

## R

**Rebasing** — LST 的一种模式。LST 的数量不变，但每个 LST 对应的底层资产数量随时间增长。

**Reserve Factor** — 储备金比例。协议从借款利息中抽取的比例，用于覆盖坏账。

**Resource Semantics** — 资源语义。Move 的核心特性：资源不能被复制或丢弃，只能被转移或使用。

## S

**Shared Object** — 共享对象。任何人都可以访问的对象。在 Sui 上需要共识机制处理并发。

**Slippage** — 滑点。交易的实际成交价与期望价的偏差。

**Stablecoin** — 稳定币。价值锚定法币（通常是美元）的加密货币。

**Staking** — 质押。锁定代币以参与网络验证并获得奖励。

**Store（ability）** — Move 的 `store` ability。允许对象被存储在其他对象中或作为字段。

**Sui** — Layer 1 区块链，使用对象模型和 Move 语言。

## T

**Timelock** — 时间锁。操作被提出后必须等待一段时间才能执行的安全机制。

**TVL（Total Value Locked）** — 总锁仓价值。协议中锁定的资产总值。

**TWAP（Time-Weighted Average Price）** — 时间加权平均价格。一段时间内价格的时间加权平均值，用于抵抗短期价格操纵。

## U

**Utilization Rate** — 资金利用率。借贷协议中借款总额与存款总额的比率。

## V

**Vesting** — 归属/解锁。代币按时间表逐步释放的机制。

## W

**Withdraw** — 取款。用户从协议中取出资产的操作。

**Whitelist** — 白名单。Launchpad 中符合条件的用户列表。
