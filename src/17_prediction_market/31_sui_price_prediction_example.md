# 17.31 实例：SUI/USD 十分钟涨跌预测（Pyth + 全栈可跑）

本章前面以 LMSR、条件代币与裁决流程为主；这里给出一个**更小、可端到端跑通**的实例：**只看 SUI/USD 在固定窗口内相对开盘价涨或跌**，用 **Pyth** 喂价，链上用共享对象 `Round` 记录池子与用户押注，结算后胜方按比例分池。

## 1. 业务规则（与合约一致）

| 项目   | 说明                                                                                                             |
| ------ | ---------------------------------------------------------------------------------------------------------------- |
| 窗口   | 默认 **10 分钟**（600_000 ms），创建时写入 `betting_ends_ms`                                                     |
| 种子   | 创建者一次性支付 **20 SUI**：**UP / DOWN 各 10 SUI** 进入对应 `Balance`                                          |
| 投注   | `bet_up` / `bet_down` 在截止时间前增加用户份额与池子                                                             |
| 开盘价 | `create_round` 时从 Pyth **SUI/USD** `PriceInfoObject` 读价（须与链上常量中的 feed id 一致）                     |
| 结算价 | `settle` 在截止后再次读同一 feed；与开盘比较                                                                     |
| 平盘   | 若涨跌幅 **低于 `flat_bps`（万分比）**，视为 **void**：不按涨跌结算，用户走 **`claim_void_refund`** 取回应得份额 |
| 有胜负 | **胜方**按其在胜侧的押注 **占胜侧总押注** 的比例，分配 **两侧池子全部余额**（含种子）；败侧为 0                  |
| 边界   | 若最终判为 UP/DOWN 但**该侧没有任何用户押注**（只有种子），合约强制 **void**，避免除零与不自然分配               |

## 2. 代码位置

| 组件 | 路径                                                      |
| ---- | --------------------------------------------------------- |
| Move | `src/17_prediction_market/code/sui_price_prediction/`     |
| 前端 | `src/17_prediction_market/code/sui_price_prediction_app/` |

详细命令见各目录下 `README.md`。

## 3. 合约要点（`sui_price_prediction::market`）

- **依赖**：`Move.toml` 中自 Pyth / Wormhole 官方仓库拉取 Sui 合约（需联网 `sui move build`）。
- **Feed**：`SUI_USD_PRICE_ID` 为 **Testnet** 常量；换网需改 Move 重发布。
- **对象**：`Round` 为 **shared**，便于任意用户与前端按 ID 传入。
- **时间**：使用 `sui::clock::Clock`；价格「新鲜度」在模块内用 `MAX_PRICE_AGE_SECS` 约束。

## 4. 前端要点

- **钱包与 RPC**：`@mysten/dapp-kit`（`SuiClientProvider` + `WalletProvider` + `ConnectButton`）与 `@tanstack/react-query`；默认 **Testnet** fullnode。
- **SDK**：`@mysten/sui` **2.x** —— 使用 `Transaction`（不再使用旧名 `TransactionBlock`）、`@mysten/sui/transactions`、`@mysten/sui/utils` 等子路径导出。
- **Pyth**：`@pythnetwork/pyth-sui-js` **3.x** 的 `SuiPythClient` + `SuiPriceServiceConnection`（Hermes）；在同一笔交易里先 `updatePriceFeeds` 再调业务 `moveCall`。根目录 `package.json` 用 **npm overrides** 固定子依赖与顶层使用同一 `@mysten/sui`，避免两套 SDK 类型不兼容。
- **Buffer**：Hermes / Pyth 在浏览器打包时需要 `buffer` polyfill（见应用 `README.md` 与 `vite.config.ts`）。

## 5. 推荐操作顺序（Testnet）

1. `sui client publish` 发布 Move 包，记下 Package ID。
2. 前端 `.env` 设置 `VITE_PACKAGE_ID`，`npm run dev`。
3. 连接钱包 → **创建回合**（会拉 Hermes 更新并 `create_round_default`）→ 记下 **Round 对象 ID**。
4. **押 UP 或 DOWN**（在截止时间前）。
5. 截止后 → **结算**（再次 Hermes 更新 + `settle`）。
6. 根据结果 **领取**：`claim_winner` 或 `claim_void_refund`。

## 6. 免责声明

示例用于教学演示，未做生产级审计；主网或真实资金前须完成安全评估、参数审查与运维监控。
