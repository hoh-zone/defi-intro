# 17.19 Move 实现 LMSR Engine

本节逐函数分析 `pm.move` 中的 LMSR 数学实现：定点算术、泰勒级数、log-sum-exp 稳定化。

## 定点算术：WAD = 1e9

```
Move 没有浮点数。链上所有计算用 u128 整数模拟定点小数:

  WAD = 1_000_000_000（10^9）

  真实值 1.0  → 链上表示 1_000_000_000
  真实值 0.5  → 链上表示   500_000_000
  真实值 0.01 → 链上表示    10_000_000

乘法: a_wad × b_wad / WAD（结果仍是 WAD 精度）
除法: a_wad × WAD / b_wad（结果仍是 WAD 精度）

精度: 10^-9 ≈ 纳级别
  对于 USDC（6 位小数），WAD 精度绰绰有余
  对于高精度金融计算，考虑 WAD = 10^18
```

## exp_pos_wad：计算 e^x

```move
fun exp_pos_wad(x: u128): u128 {
    let mut s = WAD;        // 累积和，初始 = 1.0（即 e^0）
    let mut t = WAD;        // 当前项，初始 = 1.0
    let mut i = 1u64;
    while (i <= 30) {
        t = t * x / ((i as u128) * WAD);  // t = t × x / (i × WAD)
        s = s + t;                         // s += t
        i = i + 1;
    };
    s
}
```

```
数学原理:
  泰勒展开: e^x = 1 + x + x²/2! + x³/3! + ...

  递推关系: term_i = term_{i-1} × x / i
  在 WAD 定点中: term_i = term_{i-1} × x_wad / (i × WAD)

迭代过程（x = 1.0 WAD，即 e^1 ≈ 2.718）:
  i=1: t = 1e9 × 1e9 / (1 × 1e9) = 1e9         s = 2e9
  i=2: t = 1e9 × 1e9 / (2 × 1e9) = 5e8          s = 2.5e9
  i=3: t = 5e8 × 1e9 / (3 × 1e9) = 1.667e8      s = 2.667e9
  ...
  i=10: s ≈ 2.718281801e9 ≈ e × 1e9 ✅

30 项足够吗？
  当 x/WAD <= 30 时，第 30 项 ≈ 30^30/30! ≈ 很小
  精度在 WAD 尺度下误差 < 1
  → 对教学和大多数实用场景足够
```

## exp_neg_wad：计算 e^{-x}

```move
fun exp_neg_wad(d: u64): u128 {
    if (d == 0) { return WAD };
    let ex = exp_pos_wad(d as u128);   // e^d
    WAD * WAD / ex                      // 1/e^d = WAD²/e^d（WAD 精度）
}
```

```
为什么不直接用 exp_pos_wad(-x)?
  → u128 没有负数！
  → 所以: e^{-d} = 1 / e^d = WAD / (e^d / WAD) = WAD² / e^d_wad
```

## ln1p_ratio_wad：计算 ln(1 + y/WAD)

```move
fun ln1p_ratio_wad(y: u128): u128 {
    let mut term = y;                    // u = y/WAD 的第一项（WAD 表示）
    let mut acc = term;                  // 累积 = u
    let mut k = 2u64;
    while (k <= 120) {
        term = term * y / WAD;           // term *= u（WAD 乘法）
        if (k % 2 == 0) {
            acc = acc - term / (k as u128);  // 偶数项减
        } else {
            acc = acc + term / (k as u128);  // 奇数项加
        };
        k = k + 1;
    };
    acc
}
```

```
数学原理:
  ln(1 + u) = u - u²/2 + u³/3 - u⁴/4 + ...（|u| ≤ 1）

  交替级数: 偶数项减，奇数项加
  递推: term_k = term_{k-1} × u

为什么 120 项？
  当 u 接近 1 时，ln(1+1) = ln(2) ≈ 0.693
  泰勒级数收敛慢（交替级数）
  需要很多项才能保证精度

  项数对精度的影响:
    30 项:  误差 ≈ 1/30 = 0.033 → 不够
    60 项:  误差 ≈ 1/60 = 0.017 → 勉强
    120 项: 误差 ≈ 1/120 = 0.008 → 足够保证单调性

  单调性至关重要:
    如果精度不够 → cost_state(q+1) 可能 < cost_state(q)
    → 买入时 ΔC < 0 → 下溢 abort
    → 所以用 120 项 + 单调性测试双重保证
```

## lse_wad：log-sum-exp（核心）

```move
fun lse_wad(qy: u64, qn: u64, b: u64): u128 {
    assert!(b > 0);
    let ay = (qy as u128) * WAD / (b as u128);   // a_yes = q_yes/b（WAD 精度）
    let an = (qn as u128) * WAD / (b as u128);   // a_no  = q_no/b（WAD 精度）
    let max_ac = if (ay >= an) { ay } else { an }; // max(a_yes, a_no)
    let diff = if (ay >= an) { ay - an } else { an - ay }; // |a_yes - a_no|
    let d = if (diff > U64_MAX) { 18446744073709551615u64 } else { (diff as u64) };
    max_ac + log1p_exp_neg(d)              // max + ln(1 + e^{-|diff|})
}
```

```
这就是 log-sum-exp trick 的实现:

  ln(e^a + e^b) = max(a,b) + ln(1 + e^{-|a-b|})

为什么需要这个 trick:
  直接算 e^a:  当 a = 50 × WAD 时, e^50 ≈ 5e21 → u128 溢出
  trick 后:    只需算 e^{-|a-b|} → 永远在 (0, 1] → 不溢出

  例: q_yes = 50000, q_no = 0, b = 1000
    a = 50 WAD, b = 0 WAD
    直接: ln(e^50 + e^0) → e^50 溢出！
    trick: max(50, 0) + ln(1 + e^{-50}) ≈ 50 + 0 = 50 ✅
```

## cost_state：成本函数

```move
fun cost_state(qy: u64, qn: u64, b: u64): u128 {
    let l = lse_wad(qy, qn, b);      // LSE in WAD
    (b as u128) * l / WAD             // C(q) = b × LSE → 原始单位
}
```

```
公式: C(q_yes, q_no) = b × ln(e^{q_yes/b} + e^{q_no/b})

返回值单位: 与 q 相同（不是 WAD）
  lse_wad 返回 WAD 精度的 ln(...)
  乘以 b 再除以 WAD → 回到原始精度

数值验证:
  q_yes = 0, q_no = 0, b = 1000:
    lse = ln(1 + 1) = ln(2) ≈ 0.693 WAD = 693_147_180
    cost = 1000 × 693_147_180 / 1e9 = 693
    → C(0, 0, 1000) ≈ 693 ✅（理论值 = 1000 × ln2 ≈ 693.15）
```

## fee_on：手续费

```move
fun fee_on(amount: u64, fee_bps: u64): u64 {
    ((amount as u128) * (fee_bps as u128) / (BPS_DENOM as u128)) as u64
}
```

```
BPS_DENOM = 10000（基点分母）

例: amount = 100, fee_bps = 200（2%）
  fee = 100 × 200 / 10000 = 2

这个函数纯粹、无状态、可复用。
手续费在 buy_internal / sell_internal 中调用。
```

## 精度与 Gas 的工程权衡

```
当前方案:
  exp: 30 项泰勒展开
  ln:  120 项泰勒展开
  WAD: 1e9 精度

  Gas 消耗:
    lse_wad: ~150 次 u128 乘除
    cost_state: ~150 次 + 1 次 u128 乘除
    buy_internal 两次 cost_state: ~300 次

可以优化的方向:
  1. 查找表（LUT）: 预计算 exp 值存储在链上
     → 减少计算但增加存储读取
  2. 更高精度 WAD: 10^18 → 减少项数但增加溢出风险
  3. Range reduction: 把大的 x 分解为整数部分 + 小数部分
     → e^(n+f) = e^n × e^f → 减少级数项数
  4. Chebyshev 近似: 用更少项数达到相同精度

教学版选择简单泰勒展开:
  → 代码可读
  → 数学透明
  → 足以通过单调性测试
```

## 单调性测试

```move
#[test]
fun cost_state_is_monotone_in_q_yes() {
    let b = 1000u64;
    let mut q = 0u64;
    let mut prev = cost_for_test(0, 0, b);
    while (q <= 5000) {
        q = q + 1;
        let c = cost_for_test(q, 0, b);
        assert!(c >= prev);   // ← 关键: 成本只增不减
        prev = c;
    };
}
```

```
为什么这个测试至关重要:
  如果 cost_state 不单调 → buy_internal 中 new_c - old_c 可能下溢
  → 交易 abort → 市场无法使用

  单调性取决于:
    1. exp_pos_wad 的精度
    2. ln1p_ratio_wad 的精度
    3. 定点截断误差的累积方向

  测试覆盖 q = 0 到 5000（步长 1）:
    如果通过 → 在此范围内单调性成立
    如果失败 → 需要增加泰勒项数或改进算法
```

## 自检

1. 如果把 `WAD` 从 `1e9` 改成 `1e6`，精度会怎样？可能出什么问题？
2. 为什么 `ln1p_ratio_wad` 需要比 `exp_pos_wad` 更多项（120 vs 30）？
