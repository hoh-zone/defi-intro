# 7.29 借贷协议参数设计方法

借贷协议的安全性和效率取决于参数设计。本节总结参数选择的方法论。

## 参数总览

```
风险参数:
  collateral_factor (LTV上限)
  liquidation_threshold (清算线)
  liquidation_bonus (清算奖励)

利率参数:
  base_rate (基础利率)
  kink (拐点利用率)
  multiplier (拐点下斜率)
  jump_multiplier (拐点上跳跃)
  reserve_factor (储备因子)

限额参数:
  borrow_cap (借款上限)
  supply_cap (存款上限)
  close_factor (单次清算比例)
```

## 按资产类型选参数

### 稳定币（USDC/USDT）

```
collateral_factor: 75-80%
liquidation_threshold: 80-85%
liquidation_bonus: 4-6%
base_rate: 0-2%
kink: 80%
multiplier: 4-8%
jump: 3-5x
reserve_factor: 10-15%

原因:
  → 稳定币价格稳定，风险低
  → 可以给较高的 LTV
  → 清算奖励不需要太高
  → 利率曲线温和
```

### 蓝筹资产（SUI/ETH）

```
collateral_factor: 65-75%
liquidation_threshold: 70-80%
liquidation_bonus: 5-8%
base_rate: 2-3%
kink: 70-80%
multiplier: 8-12%
jump: 5-7x
reserve_factor: 15-20%

原因:
  → 价格波动中等
  → 需要较大的安全缓冲
  → 清算奖励要足够吸引人
  → 利率曲线要反应灵敏
```

### 高波动资产（新项目代币）

```
collateral_factor: 40-60%
liquidation_threshold: 50-65%
liquidation_bonus: 8-15%
base_rate: 5-10%
kink: 60-70%
multiplier: 15-25%
jump: 7-10x
reserve_factor: 20-30%

原因:
  → 价格波动大
  → LTV 要低（防止快速跌破）
  → 清算奖励要高（需要快速清算）
  → 利率要高（补偿风险）
```

## 参数关联性

```
collateral_factor < liquidation_threshold:
  缓冲 = threshold - factor ≥ 5%
  → factor=75%, threshold=80%, 缓冲=5%

liquidation_bonus:
  太低 → 没人清算 → 坏账
  太高 → 过度惩罚借款人
  → 通常 5-10%

kink 与 multiplier 的关系:
  kink 高（80%）+ multiplier 低 → 温和利率
  kink 低（60%）+ multiplier 高 → 激进利率

  kink 处的利率 = base + kink × multiplier
  例: 2% + 80% × 10% = 10%（拐点处利率）
```

## 参数敏感性分析

```
场景: 调整 collateral_factor 从 75% 到 80%

影响:
  + 借款人可借更多 → 使用体验好 → 资本效率高
  - 更小的安全缓冲 → 更容易被清算
  - 极端行情下坏账风险增加

场景: 调整 kink 从 80% 到 70%

影响:
  + 更早进入高利率区间 → 更好保护流动性
  - 正常使用时利率更高 → 借款成本增加
  - 可能降低借款需求

参数调整原则:
  → 保守开始，逐步放宽
  → 监控利用率、清算率、坏账率
  → 每次只调一个参数，观察效果
```

## Navi 和 Scallop 的参数对比

```
参数           │ Navi (SUI)   │ Scallop (SUI)
──────────────┼──────────────┼──────────────
LTV           │ ~75%         │ ~70%
清算阈值       │ ~80%         │ ~75%
清算奖励       │ ~5%          │ ~5%
基础利率       │ 2%           │ 0%
拐点          │ 80%          │ 90%
储备因子       │ 15%          │ 10%

差异原因:
  Navi: Cross Collateral → 更激进
  Scallop: Isolated → 更保守
```

## 总结

```
参数设计方法:
  1. 根据资产类型选择基准参数
  2. 确保 factor < threshold（安全缓冲）
  3. 保守开始，逐步调整
  4. 监控关键指标（利用率、清算率、坏账率）
  5. 每次只调一个参数

核心原则:
  资产越稳定 → 参数越宽松
  资产越波动 → 参数越保守
```
