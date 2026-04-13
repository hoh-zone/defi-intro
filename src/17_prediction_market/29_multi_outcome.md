# 17.29 多结果市场（Multi-Outcome）

前面所有讨论都是二元市场（YES/NO）。本节把 LMSR 推广到 \(n\) 个互斥结果。

## 从二元到多结果

```
二元: "BTC 年底 >= $150K?"
  结果空间: { YES, NO }
  LMSR 状态: (q_yes, q_no)
  代币: 2 种

多结果: "2025 年底 BTC 价格在哪个区间？"
  结果空间: { <$50K, $50K-$100K, $100K-$150K, >$150K }
  LMSR 状态: (q_1, q_2, q_3, q_4)
  代币: 4 种

一般情况:
  n 个互斥完备结果
  LMSR 状态: (q_1, q_2, ..., q_n)
```

## 多结果 LMSR 公式

```
成本函数:
  C(q) = b × ln(Σᵢ exp(qᵢ/b))

边际价格（softmax）:
  pᵢ = exp(qᵢ/b) / Σⱼ exp(qⱼ/b)

性质:
  Σpᵢ = 1 ✅
  pᵢ > 0 ∀i ✅（指数函数永远正）

交易成本:
  买入 Δqᵢ 份结果 i:
  cost = C(q + Δqᵢ eᵢ) - C(q)
  = b × ln(Σⱼ exp(qⱼ'/b)) - b × ln(Σⱼ exp(qⱼ/b))
```

### 数值示例

```
4 结果市场: b = 1000
初始: q = (0, 0, 0, 0) → 价格 = (0.25, 0.25, 0.25, 0.25)

买 200 份结果 1:
  q' = (200, 0, 0, 0)
  C(q') = 1000 × ln(e^0.2 + e^0 + e^0 + e^0)
        = 1000 × ln(1.221 + 1 + 1 + 1)
        = 1000 × ln(4.221)
        = 1000 × 1.440
        = 1440

  C(q) = 1000 × ln(4) = 1000 × 1.386 = 1386

  cost = 1440 - 1386 = 54 USDC

  新价格:
    p1 = e^0.2 / (e^0.2 + 3) = 1.221 / 4.221 = 0.289
    p2 = p3 = p4 = 1 / 4.221 = 0.237

  验证: 0.289 + 3 × 0.237 = 1.000 ✅
```

## 多结果的条件代币

```
二元 Split: 1 USDC → 1 YES + 1 NO
多结果 Split: 1 USDC → 1 T₁ + 1 T₂ + ... + 1 Tₙ

全集合不变量:
  T₁ + T₂ + ... + Tₙ 的全集合总是值 1 USDC
  → 因为恰有一个 Tᵢ 赢，赎回 1 USDC

Merge: 1 T₁ + 1 T₂ + ... + 1 Tₙ → 1 USDC
  → 必须每种各一份

Position 扩展:
  二元: Position { yes: u64, no: u64 }
  多结果: Position { balances: vector<u64> }（或 Table<u8, u64>）
```

## 最坏损失的扩展

```
二元: 最坏损失 ≈ b × ln(2) ≈ 0.693b
多结果: 最坏损失 ≈ b × ln(n)

  n = 2:  0.693b
  n = 3:  1.099b
  n = 4:  1.386b
  n = 10: 2.303b
  n = 100: 4.605b

→ 结果越多，需要的 seed 越大
→ 这限制了多结果市场的实际可用性
→ 100 个结果的市场需要 4.6 × b 的 seed

实际约束:
  如果 b = 10,000 且 n = 10:
    最坏损失 ≈ 23,030 USDC
    seed 至少需要 ≈ 25,000 USDC
    → 对小型市场来说门槛很高
```

## log-sum-exp 的 n 维扩展

```
二元 log-sum-exp:
  lse = max(a, b) + ln(1 + e^{-|a-b|})

n 维 log-sum-exp:
  aᵢ = qᵢ / b
  max_a = max(a₁, ..., aₙ)
  lse = max_a + ln(Σᵢ e^{aᵢ - max_a})

实现:
  1. 找到 max_a
  2. 对每个 i 计算 e^{aᵢ - max_a}（差值 ≤ 0，不溢出）
  3. 求和
  4. 取 ln（结果在 (0, ln(n)] 范围内）
  5. 加上 max_a

Move 伪代码:
  fun lse_n_wad(q: &vector<u64>, b: u64): u128 {
      let max_a = find_max_q_div_b(q, b);
      let mut sum = 0u128;
      let mut i = 0;
      while (i < q.length()) {
          let ai = q[i] * WAD / b;
          let diff = max_a - ai;
          sum += exp_neg_wad(diff);    // e^{-(max - ai)}
          i += 1;
      };
      max_a + ln_wad(sum)              // max + ln(Σ e^{ai-max})
  }
```

## 工程挑战

```
1. Gas 成本:
   n 个结果 → n 次 exp 计算
   每次 exp ≈ 30 次 u128 运算
   n = 10 → ~300 次运算 → Gas 是二元的 5 倍

2. 存储:
   Position 从 2 个 u64 → n 个 u64
   Market 从 2 个 q → n 个 q
   → vector / Table 操作更复杂

3. 离散化:
   连续结果（如价格）需要「分桶」
   桶越多 → 精度越高但成本越高
   桶越少 → 成本低但精度差

4. 裁决:
   n 个结果 → 裁决复杂度增加
   「哪个桶赢？」可能有争议
   边界情况: 如果结果恰好在桶边界上
```

## 本章为什么只实现二元

```
教学理由:
  1. 二元 → 代码最简洁，概念最清晰
  2. LMSR 数学在二元和多结果中结构相同
  3. Position { yes, no } 比 vector<u64> 更直观
  4. 测试更简单（只需验证两侧）

扩展路径:
  如果读者想实现多结果:
  → 把 q_yes/q_no 改为 vector<u64>
  → 把 Position.yes/no 改为 vector<u64>
  → 把 lse_wad 改为 n 维版本
  → 把 claim 改为检查 winning_outcome 对应的 index
  → 核心数学不变，只是维度增加
```

## 自检

1. 在 4 结果市场中，如果价格是 (0.1, 0.2, 0.3, 0.4)，套利者能做什么？（答：价格和 = 1，没有套利机会）
2. 如果价格是 (0.1, 0.2, 0.3, 0.3)，和 = 0.9 < 1，套利者怎么做？（答：买入全集合，花 0.9 获得价值 1 的全集合）
