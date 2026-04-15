# 4.6 Liquidity Pool 最小实现

固定汇率的根本问题是价格不能自动调整。流动性池通过**储备量比例**来定价，价格随交易自动变化。

## 核心思想

```
流动性池 = 两种代币的储备池

价格由储备比例决定：
  price_A_in_B = reserve_B / reserve_A

每次交易后，储备量变化 → 价格自动调整
```

## 存入资产

LP 将两种代币按当前价格比例存入池中：

```move
/// LP 存入流动性
public fun add_liquidity<A, B>(
    pool: &mut Pool<A, B>,
    coin_a: Coin<A>,
    coin_b: Coin<B>,
    ctx: &mut TxContext,
) {
    let amount_a = coin::value(&coin_a);
    let amount_b = coin::value(&coin_b);

    // 确保按比例存入
    if (pool.total_shares == 0) {
        // 首次存入：任意比例都可以（设定初始价格）
        let shares = (amount_a as u128) * (amount_b as u128);
        pool.total_shares = (sqrt(shares) as u64);
    } else {
        // 后续存入：必须按当前储备比例
        let shares_a = (amount_a as u128) * (pool.total_shares as u128)
            / (pool.reserve_a as u128);
        let shares_b = (amount_b as u128) * (pool.total_shares as u128)
            / (pool.reserve_b as u128);
        let shares = if (shares_a < shares_b) {
            shares_a
        } else {
            shares_b
        };
        pool.total_shares = pool.total_shares + (shares as u64);
    };

    // 更新储备
    pool.reserve_a = pool.reserve_a + amount_a;
    pool.reserve_b = pool.reserve_b + amount_b;

    // 存入代币
    coin::join(&mut pool.balance_a, coin_a);
    coin::join(&mut pool.balance_b, coin_b);
}
```

### 为什么首次用 sqrt(a × b)

```
首次 LP:
  存入 1000 A + 2000 B
  shares = sqrt(1000 × 2000) = sqrt(2,000,000) = 1414

这个设计确保：
  1. 份额与存入金额的几何平均成正比
  2. 份额不受代币单位影响（如果 A 的精度是 6，B 是 9，不影响）
  3. 后续 LP 的份额计算基于比例，与首次一致
```

## 提取资产

LP 销毁份额，按比例取回代币：

```move
/// LP 移除流动性
public fun remove_liquidity<A, B>(
    pool: &mut Pool<A, B>,
    lp: LP<A, B>,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    let shares = lp.shares;

    // 按比例计算可取回的量
    let amount_a = (shares as u128) * (pool.reserve_a as u128)
        / (pool.total_shares as u128);
    let amount_b = (shares as u128) * (pool.reserve_b as u128)
        / (pool.total_shares as u128);

    // 更新储备
    pool.reserve_a = pool.reserve_a - (amount_a as u64);
    pool.reserve_b = pool.reserve_b - (amount_b as u64);
    pool.total_shares = pool.total_shares - shares;

    // 销毁 LP Token
    let LP { id, pool_id: _, shares: _ } = lp;
    id.delete();

    // 取出代币
    let coin_a = coin::take(&mut pool.balance_a, (amount_a as u64), ctx);
    let coin_b = coin::take(&mut pool.balance_b, (amount_b as u64), ctx);

    (coin_a, coin_b)
}
```

### 提取时的数值验证

```
初始状态:
  reserve_a = 1000, reserve_b = 2000
  total_shares = 1414

LP 持有 1414 份额，全部提取:
  amount_a = 1414 × 1000 / 1414 = 1000 ✅
  amount_b = 1414 × 2000 / 1414 = 2000 ✅
  → LP 取回全部初始投入
```

## LP Share 设计

LP Share 代表池中的所有权份额。在 Sui 中，LP Token 是独立的对象：

```move
public struct LP<phantom A, phantom B> has key, store {
    id: UID,
    pool_id: ID,   // 属于哪个池
    shares: u64,   // 份额数量
}
```

`key + store` 的能力意味着 LP Token：

- 可以被转移（`transfer::transfer`）
- 可以被存储在其他对象中
- 可以在 Kiosk 中出售
- 可以作为其他协议的抵押品

### LP Share 的价值

```
LP 份额的价值 = (shares / total_shares) × 池的总价值

例：
  池中有 1000 SUI ($2000) + 2000 USDC ($2000) = $4000 总价值
  total_shares = 1414
  LP 持有 707 份额

  LP 价值 = (707 / 1414) × $4000 = $2000
  即 50% 的池份额 = $2000
```

## 简单 Swap 实现

有了池和储备量，Swap 就是修改储备量的操作：

```move
/// 简单 Swap（不含手续费）
public fun swap<A, B>(
    pool: &mut Pool<A, B>,
    coin_in: Coin<A>,
    min_output: u64,
    ctx: &mut TxContext,
): Coin<B> {
    let amount_in = coin::value(&coin_in);

    // 简单固定输出计算（不考虑手续费和价格冲击）
    // 这个实现有严重问题——下一节会改进
    let output = (amount_in as u128) * (pool.reserve_b as u128)
        / (pool.reserve_a as u128);

    assert!((output as u64) >= min_output, EInsufficientOutput);
    assert!((output as u64) <= pool.reserve_b, EInsufficientLiquidity);

    pool.reserve_a = pool.reserve_a + amount_in;
    pool.reserve_b = pool.reserve_b - (output as u64);

    coin::join(&mut pool.balance_a, coin_in);
    let coin_out = coin::take(&mut pool.balance_b, (output as u64), ctx);

    coin_out
}
```

### 这个实现的问题

```
问题：reserve_a × reserve_b 不守恒

初始: reserve_a=1000, reserve_b=2000, k=2,000,000
Swap 100 A:
  output = 100 × 2000 / 1000 = 200
  新状态: reserve_a=1100, reserve_b=1800
  新 k = 1100 × 1800 = 1,980,000 ≠ 2,000,000

k 变小了！池的价值在流失！
```

这个问题的解决方案是**恒定乘积公式**（x·y=k），我们将在 4.8 节详细推导。
