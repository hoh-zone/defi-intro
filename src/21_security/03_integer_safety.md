# 21.3 整数安全与精度陷阱

## Move 的整数溢出保护

Move 在溢出时会中止（abort），而不是像 EVM（Solidity < 0.8）那样静默回绕：

```move
public fun overflow_example() {
    let max: u64 = 18446744073709551615;
    let result = max + 1;
}
```

这段代码运行时会 abort，不会产生回绕后的 0。这是 Move 的安全基线。

但"不会溢出"不等于"数值正确"。精度问题是 DeFi 中最常见的数学缺陷。

## 常见精度陷阱

### 陷阱 1：先除后乘

```move
public fun bad_calculation(amount: u64, rate: u64, denominator: u64): u64 {
    amount / denominator * rate
}
```

当 `amount < denominator` 时，整除截断使结果为 0，后续乘以 `rate` 仍为 0。

修正：先乘后除。

```move
public fun good_calculation(amount: u64, rate: u64, denominator: u64): u64 {
    amount * rate / denominator
}
```

但这引入了溢出风险。`amount * rate` 可能超过 `u64` 范围。

### 陷阱 2：大数相乘溢出

```move
public fun dangerous_multiply(a: u64, b: u64): u64 {
    a * b
}
```

两个 `u64` 相乘可能超过 `u64` 最大值（~1.8 × 10^19）。在 DeFi 中，金额和精度因子都是大数，这很常见。

解决方案：使用 `u256` 中间精度。

```move
public fun safe_multiply_divide(a: u64, b: u64, denominator: u64): u64 {
    let result = (a as u256) * (b as u256) / (denominator as u256);
    assert!(result <= (18446744073709551615 as u256), EOverflow);
    (result as u64)
}

const EOverflow: u64 = 100;
```

### 陷阱 3：精度因子选择不当

DeFi 协议常用固定精度表示利率、价格等。选择不当会导致微小值被截断：

```move
const PRECISION: u64 = 1000000;

public fun apply_rate(value: u64, rate_bps: u64): u64 {
    value * rate_bps / (10000 * PRECISION)
}
```

如果 `rate_bps` 很小（如 1 bps = 0.01%），且 `value` 也很小，结果可能为 0。

### 陷阱 4：累加器的精度漂移

奖励累加器在长时间运行后会积累精度误差：

```move
public fun accumulate(reward_per_share: u64, reward: u64, total_shares: u64): u64 {
    reward_per_share + reward / total_shares
}
```

如果 `reward < total_shares`，每次累加的结果都是 0。大量小额奖励被吞。

修正：使用更高精度的累加器。

```move
const ACC_PRECISION: u64 = 1_000_000_000_000;

public fun accumulate_precise(
    acc: u64,
    reward: u64,
    total_shares: u64,
): u64 {
    let increment = (reward as u256) * (ACC_PRECISION as u256) / (total_shares as u256);
    acc + (increment as u64)
}
```

## 安全算术库

以下是一个可直接使用的安全算术模块：

```move
module defi::safe_math {
    const EOverflow: u64 = 0;
    const EUnderflow: u64 = 1;
    const EDivisionByZero: u64 = 2;

    public fun safe_mul(a: u64, b: u64): u64 {
        let result = (a as u256) * (b as u256);
        assert!(result <= 0xffffffffffffffff, EOverflow);
        (result as u64)
    }

    public fun safe_mul_div(a: u64, b: u64, c: u64): u64 {
        assert!(c > 0, EDivisionByZero);
        let result = (a as u256) * (b as u256) / (c as u256);
        assert!(result <= 0xffffffffffffffff, EOverflow);
        (result as u64)
    }

    public fun safe_sub(a: u64, b: u64): u64 {
        assert!(a >= b, EUnderflow);
        a - b
    }

    public fun safe_div(a: u64, b: u64): u64 {
        assert!(b > 0, EDivisionByZero);
        a / b
    }

    public fun safe_add(a: u64, b: u64): u64 {
        let result = (a as u256) + (b as u256);
        assert!(result <= 0xffffffffffffffff, EOverflow);
        (result as u64)
    }

    public fun mul_to_u256(a: u64, b: u64): u256 {
        (a as u256) * (b as u256)
    }

    public fun u256_to_u64(v: u256): u64 {
        assert!(v <= 0xffffffffffffffff, EOverflow);
        (v as u64)
    }
}
```

## 实战案例：收益分配的精度安全

以下是一个完整的收益分配函数，展示安全算术的实际使用：

```move
module defi::yield_distribution {
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;

    public struct Pool has key {
        id: UID,
        total_shares: u64,
        acc_reward_per_share: u64,
        reward_balance: Coin<SUI>,
        last_update_epoch: u64,
    }

    public struct UserPosition has key {
        id: UID,
        shares: u64,
        reward_debt: u64,
        pending_reward: u64,
    }

    const PRECISION: u64 = 1_000_000_000;

    public fun update_pool(pool: &mut Pool, current_epoch: u64) {
        if (current_epoch <= pool.last_update_epoch) {
            return
        };

        if (pool.total_shares == 0) {
            pool.last_update_epoch = current_epoch;
            return
        };

        let reward = coin::value(&pool.reward_balance);
        if (reward == 0) {
            pool.last_update_epoch = current_epoch;
            return
        };

        let reward_per_epoch = reward / (current_epoch - pool.last_update_epoch);
        let increment = (reward_per_epoch as u256)
            * (PRECISION as u256)
            / (pool.total_shares as u256);

        pool.acc_reward_per_share = pool.acc_reward_per_share + (increment as u64);
        pool.last_update_epoch = current_epoch;
    }

    public fun harvest(position: &mut UserPosition, pool: &Pool) {
        let accumulated = (position.shares as u256)
            * (pool.acc_reward_per_share as u256)
            / (PRECISION as u256);
        let pending = (accumulated as u64) - position.reward_debt;

        position.pending_reward = position.pending_reward + pending;
        position.reward_debt = (accumulated as u64);
    }
}
```

关键设计决策：
- 使用 `u256` 中间精度避免溢出
- `PRECISION = 10^9`（BPS 级别的精度对 DeFi 不够）
- `reward_debt` 模式避免对每个用户逐一结算
- 所有 `as u64` 转换点都有隐式的溢出保护（Move 会在溢出时 abort）

## 精度审计清单

在审计 DeFi 协议的数学代码时，检查以下每一项：

| 检查项 | 关注点 |
|--------|--------|
| 乘法结果是否溢出？ | `a * b` 中的 a、b 最大值 |
| 除法是否截断关键值？ | `a / b` 中 a < b 的场景 |
| 精度因子是否足够？ | 最小操作单位的精度分辨率 |
| 累加器是否有漂移？ | 长时间运行的误差累积 |
| 类型转换是否安全？ | `u256 → u64` 的截断风险 |
| 奖励分配是否有遗漏？ | `total_shares == 0` 的边界情况 |

## 小结

Move 消除了整数溢出的静默回绕，但精度陷阱依然无处不在。"先除后乘"是 DeFi 代码中最常见的低级错误。使用 `u256` 中间精度、选择足够的精度因子、审计每个算术路径——这是正确处理链上数学的三个原则。
