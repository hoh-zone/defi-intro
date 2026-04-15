# 4.24 实现 Sui StableSwap

本节讨论如何在 Sui 上实现一个 StableSwap 池，重点解决 Newton 迭代求解和精度问题。

## 数据结构

```move
public struct StablePool has key {
    id: UID,
    // 两种代币储备
    balance_a: Balance<USDC>,
    balance_b: Balance<USDT>,
    reserve_a: u64,
    reserve_b: u64,
    // 放大系数（放大 100 倍存储，如 A=100 存为 10000）
    amp_coefficient: u64,
    // 总 LP 份额
    total_supply: u64,
    // 手续费（通常 1-4 bps）
    fee_bps: u64,
}
```

## Newton 迭代求解 D

StableSwap 的核心计算是求解不变量 D。对于两币池：

```
f(D) = A × 4 × (x + y) + 4 × x × y - A × 4 × D - D²

需要找到 D 使得 f(D) = 0

Newton 迭代:
  D_{k+1} = D_k - f(D_k) / f'(D_k)

f'(D) = -4 × A - 2 × D
```

### Move 实现

```move
const MAX_ITERATIONS: u64 = 32;
const PRECISION: u128 = 1_000_000_000_000;

fun compute_d(
    reserve_a: u64,
    reserve_b: u64,
    amp: u64,  // amp_coefficient × n_coins^n
): u128 {
    let sum = (reserve_a as u128) + (reserve_b as u128);
    if (sum == 0) { return 0 };

    let mut d = sum;
    let mut i = 0;

    while (i < MAX_ITERATIONS) {
        let d_prev = d;

        // f(D) 计算
        let prod = (reserve_a as u128) * (reserve_b as u128) * 4;
        // d_new = (amp * sum + prod / d * n) / (amp - 1)
        // 简化迭代公式
        let d_prod = d * d;
        // 更新 d...

        // 检查收敛
        let diff = if (d > d_prev) { d - d_prev } else { d_prev - d };
        if (diff <= 1) { break };
        i = i + 1;
    };

    d
}
```

### 精度考量

```
问题：u64 最大值 ≈ 1.8 × 10^19
      如果 reserve = 10^9（10 亿代币，9 位精度）
      reserve^2 = 10^18，还在范围内
      但 reserve^3 = 10^27，溢出！

解决方案：
  1. 使用 u128 进行中间计算
  2. 分步计算，避免同时累乘
  3. 在每一步除以适当的值保持精度

关键原则：先乘后除，但要注意溢出
```

## Swap 实现

```move
public fun swap_a_to_b(
    pool: &mut StablePool,
    coin_in: Coin<USDC>,
    min_output: u64,
    ctx: &mut TxContext,
): Coin<USDT> {
    let amount_in = coin::value(&coin_in);

    // 1. 计算当前 D
    let d = compute_d(pool.reserve_a, pool.reserve_b, pool.amp_coefficient);

    // 2. 计算 y_new（输入后的新 B 储备量）
    let x_new = (pool.reserve_a as u128) + (amount_in as u128);
    let y_new = compute_y(x_new, d, pool.amp_coefficient);

    // 3. 输出量 = y_old - y_new
    let dy = (pool.reserve_b as u128) - y_new;
    let fee = dy * (pool.fee_bps as u128) / 10000;
    let output = (dy - fee) as u64;

    // 4. 滑点保护
    assert!(output >= min_output, EInsufficientOutput);

    // 5. 更新储备
    pool.reserve_a = pool.reserve_a + amount_in;
    pool.reserve_b = pool.reserve_b - output;

    // 6. 转移代币
    coin::join(&mut pool.balance_a, coin_in);
    coin::take(&mut pool.balance_b, output, ctx)
}
```

## compute_y 函数

给定 x_new 和 D，求 y_new：

```move
fun compute_y(x_new: u128, d: u128, amp: u128): u128 {
    // 从 StableSwap 方程中解出 y
    // 需要另一次 Newton 迭代
    let mut y = d * d / (x_new * 2);  // 初始猜测

    let mut i = 0;
    while (i < MAX_ITERATIONS) {
        let y_prev = y;
        // 迭代更新 y
        // y_{k+1} = (y_k^2 + c) / (2*y_k + b)
        // 其中 c, b 是关于 d, x_new, amp 的函数

        let diff = if (y > y_prev) { y - y_prev } else { y_prev - y };
        if (diff <= 1) { break };
        i = i + 1;
    };

    y
}
```

## 添加/移除流动性

### 添加流动性

```move
public fun add_liquidity(
    pool: &mut StablePool,
    coin_a: Coin<USDC>,
    coin_b: Coin<USDT>,
    ctx: &mut TxContext,
) {
    let amount_a = coin::value(&coin_a);
    let amount_b = coin::value(&coin_b);

    // 计算添加前后的 D
    let d_before = compute_d(pool.reserve_a, pool.reserve_b, pool.amp);
    pool.reserve_a += amount_a;
    pool.reserve_b += amount_b;
    let d_after = compute_d(pool.reserve_a, pool.reserve_b, pool.amp);

    // LP 份额按 D 的增长比例分配
    let shares = (d_after - d_before) * (pool.total_supply as u128) / (d_before);

    pool.total_supply += (shares as u64);
    // ... 铸造 LP Token
}
```

### 单币添加

StableSwap 的独特功能：可以用单一代币添加流动性（不需要同时提供两种）：

```
用户只有 USDC，想提供流动性:
  1. 存入 USDC
  2. 池内部自动将部分 USDC "虚拟交换" 为 USDT
  3. 等价于添加了两种代币

注意：虚拟交换会产生手续费（保护现有 LP）
```

## 边界情况处理

### 脱锚

```
当一种稳定币严重脱锚（如价格跌至 $0.80）:
  → 大量用户将脱锚币换为正常币
  → 池中脱锚币积累
  → LP 承受损失

StableSwap 的自我保护:
  → 随着比例偏离，曲线自动弯曲
  → 脱锚币换正常币的滑点急剧增加
  → 限制损失扩散
```

### 精度极限

```
当储备量极端不均匀时（如 99:1）:
  → Newton 迭代可能不收敛
  → 需要设置最大迭代次数和回退策略
  → 回退到 CPMM 公式作为安全网
```

## 与 CPMM 的实现复杂度对比

| 方面       | CPMM      | StableSwap         |
| ---------- | --------- | ------------------ |
| 核心公式   | 1 行      | Newton 迭代 20+ 行 |
| 精度要求   | u128 足够 | 需要仔细处理       |
| Gas 成本   | 低        | 中高（迭代计算）   |
| 测试复杂度 | 简单      | 需要边界情况测试   |
| 适用范围   | 通用      | 仅限稳定币         |
