# 17.9 完整抵押不变量

这是预测市场最重要的安全性质——如果这个不变量被打破，用户的钱就会凭空消失。

## 不变量的精确表述

```
在任意时刻:

  vault_balance >= 所有已发行头寸的最坏赎回总额

对于 Split/Merge 路径:
  每次 Split 存入 X 抵押 → 铸造 X YES + X NO
  每次 Merge 销毁 X YES + X NO → 取出 X 抵押

  → vault 变化量 = Σ(split) - Σ(merge)
  → 头寸净增量 = Σ(split) - Σ(merge)（YES 和 NO 各自）
  → vault 永远覆盖所有头寸的赎回需求 ✅
```

### 为什么不变量成立

```
Split 操作:
  vault += X
  total_yes += X
  total_no += X

Merge 操作:
  vault -= X
  total_yes -= X
  total_no -= X

Claim 操作（YES 赢）:
  vault -= winner_yes_balance
  winner.yes = 0
  winner.no = 0（作废，不赎回）

关键: 在结算时，每个用户最多赎回 max(yes, no)
     如果该用户曾做过 Split，yes == no（净持有）
     如果通过 LMSR 买入，则只增加一侧
     → 需要 LMSR 的金库收入 >= LMSR 的金库支出
```

## 数值验证

```
场景: 3 个用户，b = 1000，初始种子 = 1000 USDC

Step 1 — Alice Split 500:
  vault: 1000 + 500 = 1500
  Alice: { yes: 500, no: 500 }
  最坏赎回: max(500, 500) = 500
  vault(1500) >= 500 ✅

Step 2 — Bob 通过 LMSR 买 200 YES:
  cost = C(200, 0, 1000) - C(0, 0, 1000)
       ≈ 1000 × ln(e^0.2 + e^0) - 1000 × ln(2)
       ≈ 1000 × 0.798 - 1000 × 0.693
       = 798 - 693 = 105 USDC
  vault: 1500 + 105 = 1605
  Bob 不持有 Position 中的 YES（LMSR 状态与 Position 分开）
  但如果 Bob 也有 Position 且记入 200 YES:
    Bob: { yes: 200, no: 0 }
    最坏赎回: Alice(500) + Bob(200) = 700
    vault(1605) >= 700 ✅

Step 3 — Carol 通过 LMSR 买 300 NO:
  cost = C(200, 300, 1000) - C(200, 0, 1000)
       ≈ 1000 × ln(e^0.2 + e^0.3) - 1000 × 0.798
       ≈ 1000 × 0.956 - 798
       = 956 - 798 = 158 USDC
  vault: 1605 + 158 = 1763

Step 4 — 结算 YES 赢:
  Alice claim 500 YES → -500
  Bob claim 200 YES → -200
  Carol claim 0（NO 输）→ 0
  vault: 1763 - 500 - 200 = 1063 >= 0 ✅

剩余的 1063 = 初始种子(1000) + Carol的亏损(158) - LMSR净支付(95)
→ 这就是为什么初始种子（bankroll）必须足够大
```

## LMSR 路径下的金库安全

```
LMSR 的最坏损失分析:

初始状态: q_yes = q_no = 0
最坏情况: 所有交易者都正确预测结果

假设只有人买 YES（且 YES 最终赢）:
  买入 N 份 YES 的成本 = C(N, 0, b) - C(0, 0, b)
                       = b × ln(e^(N/b) + 1) - b × ln(2)

  赎回时每份 YES 值 1
  协议净亏损 = N - (买入成本收入)

  当 N → ∞:
    买入成本 → b × (N/b) = N（收敛到 1:1）
    净亏损 → N - N + b × ln(2) = b × ln(2)

  → LMSR 的最坏净损失 ≈ b × ln(2) ≈ 0.693 × b

这就是为什么:
  initial_seed 应 >= b × ln(2)
  b 太大 → 需要更多资金覆盖损失
  b 太小 → 滑点太大，用户体验差
```

## 不变量测试

```move
// tests/pm_tests.move 中的 split_merge_roundtrip

#[test]
fun split_merge_roundtrip() {
    // 1. 创建市场 + Position
    // 2. Split 1000 → yes: 1000, no: 1000, vault += 1000
    // 3. Merge 500 → yes: 500, no: 500, vault -= 500
    // 4. 验证 vault == initial_seed + 500（净 split）
    // 5. 验证 position.yes == 500, position.no == 500
}
```

```
这个测试验证:
  Split(X) + Merge(X) = 恢复原状
  Split(X) + Merge(Y) where Y < X → vault 增加了 (X-Y)
  → 金库永远不会因为 Split/Merge 而赤字
```

## 什么情况下不变量可能被打破

| 场景                                  | 原因         | 防御            |
| ------------------------------------- | ------------ | --------------- |
| Bug 导致 Split 只铸 YES 没铸 NO       | 编码错误     | 测试 + 审计     |
| Merge 不检查 `yes >= amount`          | 下溢         | assert 断言     |
| LMSR 精度不够导致 cost 偏低           | 泰勒级数截断 | 单调性测试      |
| initial_seed 不足以覆盖最坏损失       | 参数设置错误 | 上线前压力测试  |
| Oracle 错误结算导致不应赎回的一方赎回 | 治理失败     | 争议窗口 + 多签 |

## 自检

1. 为什么 `Merge` 必须同时减少 YES 和 NO？如果只减一侧会怎样？
2. 计算：`b = 500` 时，初始种子最少需要多少来覆盖最坏损失？
