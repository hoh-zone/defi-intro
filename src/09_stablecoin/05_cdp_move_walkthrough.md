# 9.5 CDP 稳定币：Move 实现与代码导读

## 包位置与模块

完整可编译示例位于：

`src/09_stablecoin/code/cdp_stablecoin/`

核心模块：**`cdp_stablecoin::cdp`**

设计要点：

- **`CDP`**：一次性见证与稳定币类型标识，`Coin<CDP>` 即本书中的 USDs 类稳定币。
- **`StableTreasury`**：共享对象，持有全局 `TreasuryCap<CDP>`，供一个或多个抵押品系统铸币。
- **`CDPSystem<Collateral>`**：某一抵押品（如 `SUI`）的 CDP 系统状态：抵押余额、总债务、参数、暂停标志。
- **`CDPPosition<Collateral>`**：用户仓位对象（owned），记录抵押数量与债务。
- **`GovernanceCap<Collateral>`**：治理权限，用于调参与紧急暂停。

与早期教学草稿不同，本实现支持 **泛型抵押品类型** `Collateral`，并通过 `create_system` 为每种抵押品创建独立 `CDPSystem`。

## 初始化与建池

`init` 中创建 `StableTreasury` 并冻结 `CoinMetadata`；之后治理可调用 **`create_system<Collateral>`** 绑定新的抵押品市场并发放 `GovernanceCap`。

## 开仓 `open_position`

函数签名（概念）：

```text
open_position<Collateral>(
    treasury: &mut StableTreasury,
    system: &mut CDPSystem<Collateral>,
    collateral: Coin<Collateral>,
    mint_amount: u64,
    price: u64,
    ctx: &mut TxContext,
): CDPPosition<Collateral>
```

- **`price`**：教学用由调用方传入；生产环境应来自预言机（第 5 章）。
- 检查：`paused`、债务上限、`mint_amount` 不超过按 `collateral_ratio_bps` 与价格算出的上限。
- 抵押进入 `system.collateral_balance`；债务记入 `total_debt`；稳定币从 `treasury_cap` 铸出给用户。

## 增押、偿还、清算

- **`add_collateral`**：追加抵押。
- **`repay`** / **`repay_and_close`**：销毁 `Coin<CDP>`，减少债务；关闭时归还剩余抵押。
- **`liquidate`**：清算人代为偿还债务，按规则取得抵押并可能获得折扣；系统校验抵押率低于清算阈值。

具体算术、事件与错误码见源文件；建议配合 **`tests/cdp_test.move`** 阅读完整生命周期。

## 阅读顺序建议

1. 扫一遍 `CDPSystem` / `CDPPosition` 字段。
2. 跟 `open_position` → `add_collateral` → `repay` 主路径。
3. 最后读 `liquidate` 与 `update_parameters` / `emergency_pause`。

## 与 9.2、9.6 的对照

| 包                              | 回答的问题                                           |
| ------------------------------- | ---------------------------------------------------- |
| `fiat_stablecoin_sketch`        | 法币储备型在链上如何表现为「受控铸销」               |
| **`cdp_stablecoin`**            | 超额抵押与债务如何全链建模                           |
| `algorithmic_stablecoin_sketch` | 算法调节**名义变量**的极简状态机（非完整算法稳定币） |

下一节讨论**算法稳定币**的概念边界与教学代码，请勿与 CDP 的生产级复杂度混为一谈。
