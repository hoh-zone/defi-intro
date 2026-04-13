# 7.19 清算奖励与罚金

清算人为什么要清算？因为有经济激励。本节分析清算奖励的设计。

## 清算奖励的必要性

```
清算人提供的"服务":
  → 监控所有仓位（需要基础设施成本）
  → 准备还款资金（需要资本）
  → 执行链上交易（需要 Gas）
  → 承担价格风险（清算期间价格可能变化）

没有奖励:
  → 没有人愿意做清算人
  → 不健康的仓位不会被清理
  → 系统可能产生坏账

奖励设计原则:
  → 奖励足以覆盖成本 + 利润
  → 不至于过度惩罚借款人
  → 确保清算及时执行
```

## 清算奖励计算

```
seized_amount = debt × (1 + liquidation_bonus)

其中:
  liquidation_bonus: 清算奖励率（如 5-10%）

lending_market 中的实现:
  let seized_amount = debt * (BPS_BASE + market.liquidation_bonus_bps) / BPS_BASE;

  例: debt = 1000, bonus = 500 bps (5%)
  seized = 1000 × (10000 + 500) / 10000 = 1050

  → 清算人还 1000 USDC 的债
  → 获得 1050 SUI 的抵押品
  → 利润 = 50 SUI（5%）
```

## 数值示例

### 示例 1: 正常清算

```
Alice 的仓位:
  抵押品: 1000 SUI
  债务: 800 USDC
  SUI 价格跌到 $1.50

  collateral_value = $1500
  HF = 1500 × 80% / 800 = 1.50... wait
  Actually at HF < 1: need collateral_value × 80% / 800 < 1
  → collateral_value < 1000
  → 1000 SUI at $1.00 → HF = 1000 × 80% / 800 = 1.0

  SUI 跌到 $0.90:
  collateral_value = $900
  HF = 900 × 80% / 800 = 0.90 → 可清算

  清算执行:
  debt = 800 USDC, bonus = 5%
  seized = 800 × 1.05 = 840 SUI

  清算人:
  支出: 800 USDC
  获得: 840 SUI（值 $756）
  利润: $756 - $800 = -$44 ❌

  → 这是因为 SUI 价格太低，清算人亏损
  → 清算人只会在有利润时才清算
  → 这是正常的——清算奖励 = 5% 的额外抵押品
```

### 示例 2: 有利可图的清算

```
Alice 的仓位:
  抵押品: 10000 SUI（价格 $2.00）
  债务: 15000 USDC
  collateral_value = $20000
  HF = 20000 × 80% / 15000 = 1.07 → 安全

  SUI 跌到 $1.85:
  collateral_value = $18500
  HF = 18500 × 80% / 15000 = 0.987 → 可清算

  清算执行:
  debt = 15000 USDC, bonus = 5%
  seized = 15000 × 1.05 = 15750 SUI

  清算人:
  支出: 15000 USDC
  获得: 15750 SUI（值 $29137.5）
  利润: $29137.5 - $15000 = $14137.5

  → 在 DEX 卖出 SUI 后实现利润

  Alice 的剩余:
  10000 - 15750 = 不足！
  → 最多没收全部抵押品
  → Alice 失去所有抵押品
```

## borrower 的损失

```
借款人被清算时的损失:
  1. 债务被清偿（这是应该的）
  2. 额外损失 liquidation_bonus 的抵押品（5-10%）
  3. 如果 seized > collateral，失去所有抵押品

  这是"让仓位不健康"的惩罚
  → 鼓励借款人主动管理仓位
  → 在 HF 接近 1 时主动还款或增加抵押品

避免被清算的方法:
  1. 增加抵押品（supply more collateral）
  2. 部分还款（repay some debt）
  3. 在价格下跌前主动管理
```

## 奖励率的设计考量

```
奖励率太低（如 1%）:
  → 清算人利润少
  → 可能不愿意清算
  → Gas 费可能超过利润
  → 清算延迟 → 坏账风险

奖励率太高（如 20%）:
  → 对借款人惩罚过重
  → 清算人利润过大
  → 可能引发"清算狩猎"（故意让价格下跌触发清算）

行业标准: 5-10%
  → 足以激励清算人
  → 不至于过度惩罚借款人
  → 5% 的缓冲给清算人足够的利润空间
```

## seized_amount 的上限保护

```move
// lending_market 中的保护
let seized_amount = if (seized_amount > deposit_receipt.collateral_amount) {
    deposit_receipt.collateral_amount  // 上限为全部抵押品
} else {
    seized_amount
};
```

```
保护措施:
  → 不能没收超过借款人的全部抵押品
  → 即使 debt × (1+bonus) > collateral
  → 最多只没收全部抵押品

  例:
  debt = 1000, bonus = 5%, collateral = 1000
  seized = 1050 → 但 collateral 只有 1000
  → 实际 seized = 1000

  这意味着:
  → 借款人失去所有抵押品
  → 清算人只获得 1000（不是 1050）
  → 清算人的实际利润可能低于预期
```

## 总结

```
清算奖励设计:
  seized = debt × (1 + bonus)
  上限 = borrower 的全部抵押品

奖励率: 通常 5-10%
  → 覆盖清算人的成本 + 利润
  → 不过度惩罚借款人

借款人的损失:
  偿还债务 + 额外 bonus 的抵押品
  = 不健康仓位的惩罚

design principle: 平衡清算人激励和借款人保护
```
