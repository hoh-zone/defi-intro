# 17.30 Scalar 市场与本章总结

## 什么是 Scalar 市场

```
二元市场: "BTC >= $150K?" → YES / NO
多结果市场: "BTC 在哪个区间？" → A / B / C / D

Scalar 市场: "BTC 年底价格是多少？"
  → 赔付 = f(实际价格)
  → 不是「赢/输」，而是连续赔付

例:
  price_range = [$100K, $200K]
  赔付 = (实际价格 - $100K) / ($200K - $100K)

  如果 BTC = $120K → 赔付 = 0.20 USDC/份
  如果 BTC = $150K → 赔付 = 0.50 USDC/份
  如果 BTC = $180K → 赔付 = 0.80 USDC/份
  如果 BTC < $100K → 赔付 = 0（全亏）
  如果 BTC > $200K → 赔付 = 1.00（全赢）
```

## Scalar 市场的实现方式

### 方式 1：分桶（最常见）

```
把连续范围分成 n 个桶 → 变成多结果市场

$100K-$200K 分成 10 个桶:
  [$100K, $110K) → 结果 1
  [$110K, $120K) → 结果 2
  ...
  [$190K, $200K] → 结果 10

优点: 直接复用多结果 LMSR
缺点: 桶越多越精确但成本越高

粒度选择:
  10 个桶: 最坏损失 ≈ b × ln(10) ≈ 2.3b
  100 个桶: 最坏损失 ≈ b × ln(100) ≈ 4.6b
  → 精度 vs 成本的 tradeoff
```

### 方式 2：LONG/SHORT 对（简化版）

```
定义两种代币:
  LONG token: 赔付 = (actual - low) / (high - low)
  SHORT token: 赔付 = 1 - LONG

全集合不变量:
  LONG + SHORT = 1（无论结果如何）

实现:
  与二元市场几乎相同
  区别在 claim 时不是 0/1 而是连续值

claim 逻辑:
  如果持有 100 LONG, 实际价格落在 60% 位置:
    claim = 100 × 0.60 = 60 USDC
  如果持有 100 SHORT:
    claim = 100 × 0.40 = 40 USDC
  → 总计 100 USDC = 原始抵押 ✅
```

### 方式 3：链下计算 + 链上承诺

```
链下:
  根据 Oracle 结果计算每个头寸的精确赔付

链上:
  Merkle root 承诺赔付表
  用户提交 Merkle proof 来 claim

优点: 链上计算最少
缺点: 中心化风险（谁计算赔付表？）
```

## Scalar 市场的裁决难题

```
二元裁决: "YES 还是 NO？" → 简单
Scalar 裁决: "精确数值是多少？" → 复杂

问题 1 — 数据源:
  "BTC 价格" → 哪个交易所？Coinbase？Binance？加权平均？
  不同数据源可能差几百美元
  → 命题文本必须精确定义数据源

问题 2 — 时间精度:
  "年底价格" → UTC 23:59:59 还是 00:00:00？
  价格在秒级别可能变化
  → 需要 TWAP 或快照规则

问题 3 — 桶边界:
  BTC = $149,999.99 → 属于 [$140K, $150K) 还是 [$150K, $160K)?
  开闭区间必须明确定义

问题 4 — Oracle 操纵:
  如果赔付连续依赖价格 → 操纵 Oracle 的激励更大
  差 $1 可能影响数万美元的赔付
  → 需要更强的 Oracle 安全（第 5 章 TWAP + 多源）
```

## 教学代码不实现 Scalar 的理由

```
1. 核心数学相同（LMSR + CTF），二元足以演示
2. Scalar 的 claim 逻辑复杂（连续赔付 vs 0/1）
3. 裁决需要精确 Oracle 集成（超出本章范围）
4. 分桶等价于多结果（17.29 已覆盖思路）

如果读者想实现 Scalar:
  方案 A（分桶）: 直接用多结果 LMSR → 17.29 的扩展
  方案 B（LONG/SHORT）:
    修改 claim:
      let payout_ratio = (oracle_value - low) / (high - low);
      let amt = if (is_long) { pos.yes * payout_ratio } else { pos.no * (1 - payout_ratio) };
    → 需要 Oracle 提供精确数值（第 5 章）
```

## 本章总结

```
回顾本章 30 节的知识图谱:

  基础 (1-4):
    什么是预测市场 → 不是算命工具
    核心角色 → Trader, LP, Oracle, Creator
    模块架构 → LMSR + CTF + Resolution + Claim

  资产层 (5-14):
    二元模型 → YES/NO, P_YES + P_NO = 1
    条件代币 → Split(1 USDC → 1Y + 1N), Merge(1Y + 1N → 1 USDC)
    完整抵押 → vault >= 所有头寸的最坏赎回
    Position → Owned Object, market_id 绑定

  定价层 (15-22):
    LMSR → C(q) = b × ln(Σ exp(qi/b))
    softmax → 价格 = exp(qi/b) / Σ exp(qj/b)
    log-sum-exp → 数值稳定化
    b → 滑点 × 最坏损失 × 灵敏度
    buy/sell → ΔC = C(q') - C(q) ± fee

  裁决层 (26-28):
    submit → challenge → finalize → claim
    争议窗口 → 防止错误结算
    claim → 胜出侧 1:1 赎回

  扩展 (29-30):
    多结果 → n 维 softmax
    Scalar → 分桶 或 LONG/SHORT

核心教训:
  1. 预测市场是「机制 + 裁决 + 激励」的耦合系统
  2. LMSR 数学只解决定价问题，不解决裁决问题
  3. 完整抵押不变量是安全的基石
  4. 链上实现的核心挑战是定点算术和精度
  5. 教学代码与商业产品有明确的距离，本章不假装否则
```

## 下一步

```
读完本章后:
  → 第 18 章（攻击）: 用攻击者视角审视 Oracle 和治理
  → 第 19 章（工程）: 如何把教学代码提升到生产级
  → 第 22 章（风控）: 参数设计和极端场景

构建预测市场产品:
  → 需要: 外部审计 + 参数仿真 + 合规评估 + 运维预案
  → 本章代码是起点，不是终点
```

## 最终自检

1. 用一句话概括 LMSR 的核心性质。
2. 写出完整抵押不变量的数学表达式。
3. 列出预测市场中最危险的三个攻击面。
4. 解释为什么本章代码不能直接上主网。
