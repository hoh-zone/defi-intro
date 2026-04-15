# SUI 价格预测前端（Vite + dApp Kit + Pyth）

与 `../sui_price_prediction` 合约配套：连接 Testnet 钱包、从 Hermes 拉取 Pyth 更新、用 `@mysten/sui` **Transaction** 完成创建回合 / 投注 / 结算 / 领取。

## 依赖版本

- **`@mysten/sui` 2.x**（TypeScript SDK）
- **`@mysten/dapp-kit`**（钱包 + `SuiClientProvider` + `useSignAndExecuteTransaction`）
- **`@pythnetwork/pyth-sui-js` 3.x**（依赖 `@mysten/sui`；`package.json` 里用 `overrides` 保证与根目录同一套 `@mysten/sui`，避免重复安装导致类型冲突）

## 环境

- Node 22+（与 `@mysten/sui` engines 一致；略新版本通常也可）
- 钱包内有 **Testnet SUI**（[水龙头](https://docs.sui.io/guides/developer/getting-started/get-coins)）

## 配置

复制并编辑环境变量（或直接在 shell 中导出）：

```bash
cp .env.example .env
```

| 变量              | 说明                                    |
| ----------------- | --------------------------------------- |
| `VITE_PACKAGE_ID` | `sui client publish` 得到的包 ID（0x…） |

默认常量见 `src/constants.ts`（Testnet Pyth state、Wormhole state、SUI/USD feed id、Hermes beta URL）。主网使用前须自行替换为官方文档中的对象 ID 与端点。

## 安装与运行

```bash
npm install
npm run dev
```

浏览器打开提示的本地地址（默认 `http://127.0.0.1:5173`），连接钱包后按界面顺序操作。

生产构建：

```bash
npm run build
npm run preview
```

## 构建说明

- Pyth SDK 在部分文件中 `import { Buffer } from "node:buffer"`；Vite 将 `node:buffer` **alias** 到 npm 包 `buffer`，并在 `main.tsx` 里挂到 `globalThis.Buffer`，供浏览器使用。
