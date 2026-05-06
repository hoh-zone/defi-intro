# 第 14 章套利 TypeScript 示例

本目录保留两个 TypeScript 教学脚本，用于说明套利机器人需要哪些输入和决策步骤。它们不会直接对主网发交易，默认用于阅读、编译和本地模拟。

## 运行

```bash
cd arbitrage_ts
npm install
npm run build
npm run dex-spread
npm run liquidation
```

## 示例边界

- `dex_spread_arbitrage.ts` 展示跨 DEX 价差检测、盈利估算和执行前检查。
- `liquidation_arbitrage.ts` 展示清算候选仓位扫描和粗略利润估算。
- 真实机器人还需要私钥管理、交易模拟、Gas 竞价、失败重试、RPC 限流和风控阈值。
