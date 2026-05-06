# 第 13 章现货杠杆教学包

本包对应第 13 章，展示现货杠杆的最小链上状态：共享的 `LeveragePool` 提供可借流动性，用户持有 `LeveragePosition` 记录抵押品和债务。

## 验证

```bash
sui move build
sui move test
```

当前测试覆盖：

- `open_position_and_borrow`：开仓、借款、健康因子和杠杆倍数。
- `partial_liquidation_after_price_drop`：价格下跌后触发部分清算，债务下降并返回清算抵押品。

## 教学边界

本实现用 SUI 对 SUI 的价格比例模拟现货杠杆，省略真实 DEX swap、预言机、利息累计、跨资产抵押和清算人网络。读者应把它理解为“借贷 + PTB 杠杆路径”的状态机骨架。
