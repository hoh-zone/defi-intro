# 第 11 章 Yield Vault 教学包

本包对应 11.5 节，展示 Yearn 风格收益金库的最小实现：用户存入底层资产获得 `VaultReceipt`，Vault 通过 `harvest` 注入策略收益，并用份额净值表达收益累积。

## 验证

```bash
sui move build
sui move test
```

当前测试覆盖：

- `create_vault`：初始化总资产、总份额和每份额净值。
- `deposit_and_withdraw`：按当前净值铸造份额，并在提款时扣除手续费。

## 教学边界

本实现刻意省略真实策略适配器、Keeper 鉴权、提款队列、策略亏损记账和多资产路由。它用于说明 Vault 份额模型和费用流，不可直接作为生产金库部署。
