# 7.18 清算触发机制

当借款人的 Health Factor 低于 1.0 时，清算被触发。本节分析清算的触发条件和过程。

## 清算为什么存在

```
没有清算:
  抵押品价值下跌 → 资不抵债 → 坏账
  → 存款人损失资金
  → 协议破产

有清算:
  抵押品价值下跌 → HF 接近 1 → 清算触发
  → 清算人替借款人还债 + 没收抵押品
  → 系统恢复偿付能力

清算的经济本质:
  去中心化的"追债"机制
  → 任何人都可以当清算人
  → 有利可图 → 有人做
```

## 触发条件

```
Health Factor < 1.0（即 value_bps < 10000）

HF = collateral_value × liquidation_threshold / debt_value

触发原因:
  1. 抵押品价格下跌（最常见）
  2. 借款资产价格上涨
  3. 利息累积导致债务增长
  4. 协议调整清算阈值参数

lending_market 中的检查:
  let hf = health_factor(
      deposit_receipt.collateral_amount,
      debt,
      market.liquidation_threshold_bps,  // ← 注意用 threshold
  );
  assert!(hf.value_bps < BPS_BASE, ENotLiquidatable);
  // 只有 HF < 10000 时才允许清算
```

## 清算阈值 vs 抵押因子

```
两个参数的区别:

collateral_factor (如 75%):
  → 用于 borrow() 时检查
  → 决定最多能借多少
  → borrow 时: HF = collateral × factor / debt > 1

liquidation_threshold (如 80%):
  → 用于 liquidate() 时检查
  → 决定何时被清算
  → liquidate 时: HF = collateral × threshold / debt < 1

为什么 threshold > factor:
  buffer = threshold - factor = 80% - 75% = 5%

  时间线:
  ──────────────────────────────────────→ 价格下跌
  安全区          缓冲区        清算区
  HF > 1.33      HF 1.0-1.33   HF < 1.0
  ← borrow限制    ← 安全缓冲    ← 清算触发

  5% 的缓冲确保:
  → 刚借完款不会立刻被清算
  → 给清算人反应时间
  → 处理价格波动
```

## 清算时间线

```
T0: Alice 存入 1000 SUI（$2.00/SUI），借出 1200 USDC
    collateral_value = $2000, debt = $1200
    HF = 2000 × 80% / 1200 = 1.33 → 安全

T1: SUI 跌到 $1.80
    collateral_value = $1800, debt = $1200
    HF = 1800 × 80% / 1200 = 1.20 → 安全但下降

T2: SUI 跌到 $1.60
    collateral_value = $1600, debt = $1200
    HF = 1600 × 80% / 1200 = 1.07 → 接近危险

T3: SUI 跌到 $1.50
    collateral_value = $1500, debt = $1200
    HF = 1500 × 80% / 1200 = 1.00 → 边缘

T4: SUI 跌到 $1.40
    collateral_value = $1400, debt = $1200
    HF = 1400 × 80% / 1200 = 0.93 → 可清算！

    清算人行动:
    → 还清 Alice 的 1200 USDC 债务
    → 没收 1200 × (1+5%) = 1260 SUI 的抵押品
    → Alice 剩余: 1000 - 1260 = 不足（最多没收全部）
```

## 清算人的工作流程

```
1. 监控链上所有借贷仓位
   → 读取每个 DepositReceipt 和 BorrowReceipt
   → 获取预言机价格
   → 计算 HF

2. 发现可清算仓位
   → HF < 1.0

3. 执行清算交易
   → 准备还款资金
   → 调用 liquidate()
   → 获得抵押品 + 奖金

4. 出售获得的抵押品
   → 在 DEX 上换成稳定币
   → 保留利润
```

## Sui 上的清算优势

```
低延迟:
  → Sui 确认时间 ~300ms
  → 清算人可以更快响应价格变化
  → 减少坏账风险

PTB 组合:
  → 清算 + DEX swap 可以原子化
  → 不需要持有大量资金
  → 闪电贷 + 清算 + swap 一气呵成

并行:
  → 不同用户的清算互不阻塞
  → 暴跌时大量清算可以并行执行
  → 系统恢复更快
```

## 总结

```
清算触发: HF < 1.0
  HF = collateral × liquidation_threshold / debt

触发原因: 价格下跌、利息累积、参数调整

安全缓冲: liquidation_threshold > collateral_factor
  → 确保借款后不会立即被清算

Sui 优势: 低延迟、PTB 组合、并行清算
```
