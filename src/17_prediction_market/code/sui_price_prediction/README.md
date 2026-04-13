# SUI 价格涨跌预测（Move + Pyth）

教学合约：在 **Sui Testnet** 上创建「10 分钟窗口」的 SUI/USD 涨跌预测回合；开盘价与结算价均从 **Pyth** 读取。

## 规则摘要

- 创建回合时从创建者处收取 **20 SUI**，向 **UP / DOWN 两侧各注入 10 SUI** 作为种子流动性。
- 用户在投注期内押 `bet_up` / `bet_down`。
- 投注结束后调用 `settle`：再次读取 Pyth SUI/USD；若相对开盘价变化 **小于 `flat_bps`（万分比）** 则视为平盘（**void**），用户通过 `claim_void_refund` 取回本金（含池子按规则退回）。
- 若有明确涨跌，胜方按押注比例分配 **两侧池子中的全部余额**（含种子与用户资金）；败方份额为 0。

## 构建

```bash
cd src/17_prediction_market/code/sui_price_prediction
sui move build
```

首次构建需联网拉取 `Move.toml` 中的 Pyth / Wormhole 依赖；失败时可重试或配置代理。

## 发布（Testnet）

```bash
sui client switch --env testnet
sui client publish --gas-budget 200000000
```

将发布得到的 **Package ID** 填入前端环境变量 `VITE_PACKAGE_ID`（见 `../sui_price_prediction_app/README.md`）。

## 模块

- `sui_price_prediction::market`：共享对象 `Round`、创建/投注/结算/领取。

链上常量包含 **Testnet** 的 SUI/USD Pyth `price_identifier`；主网部署前须替换为对应网络的 feed id 并重新审计。
