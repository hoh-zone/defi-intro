# 4.11 实现 Sui CPMM DEX

前面三节建立了恒定乘积 AMM 的数学基础。本节通过完整代码 walkthrough 展示如何在 Sui 上实现一个生产级的 CPMM DEX。

> 完整代码在 `src/04_dex/code/uniswap_v2/sources/pool.move`，测试在 `tests/pool_test.move`。

## 架构概览

```
数据结构:
  Pool<A, B>  — 流动性池（Shared Object）
  LP<A, B>    — LP Token（Owned Object）
  AdminCap    — 管理员权限（Owned Object）

核心函数:
  create_pool      — 创建池
  add_liquidity    — 添加流动性
  remove_liquidity — 移除流动性
  swap_a_to_b      — A→B 交换
  swap_b_to_a      — B→A 交换
  amount_out       — 纯函数：计算输出量
```

## Pool 结构

```move
public struct Pool<phantom A, phantom B> has key {
    id: UID,
    balance_a: Balance<A>,    // 代币 A 实际余额
    balance_b: Balance<B>,    // 代币 B 实际余额
    reserve_a: u64,           // 追踪的 A 储备量
    reserve_b: u64,           // 追踪的 B 储备量
    total_supply: u64,        // LP 份额总量
    k_last: u128,             // 上次协议费铸造时的 k 值
    fee_bps: u64,             // 交易手续费（基点）
    protocol_fee_bps: u64,    // 协议费比例
    paused: bool,             // 暂停状态
}
```

注意 `balance_a` 和 `reserve_a` 的区别：
- `balance_a` 是实际的 `Balance<A>` 对象，持有真实代币
- `reserve_a` 是 u64 追踪值，用于 AMM 计算
- 两者在正常情况下应该相等，但协议费机制可能导致微小差异

## 创建池

```move
public fun create_pool<A, B>(
    coin_a: Coin<A>,
    coin_b: Coin<B>,
    fee_bps: u64,
    ctx: &mut TxContext,
) {
    let amount_a = coin::value(&coin_a);
    let amount_b = coin::value(&coin_b);
    assert!(amount_a > 0 && amount_b > 0, EInvalidAmount);

    let pool = Pool<A, B> {
        id: object::new(ctx),
        balance_a: coin::into_balance(coin_a),
        balance_b: coin::into_balance(coin_b),
        reserve_a: amount_a,
        reserve_b: amount_b,
        total_supply: 0,
        k_last: (amount_a as u128) * (amount_b as u128),
        fee_bps,
        protocol_fee_bps: 500,
        paused: false,
    };

    transfer::share_object(pool);    // 池为共享对象
    transfer::transfer(admin_cap, ctx.sender());  // 管理员权限转给创建者
}
```

创建池时不发行 LP Token（`total_supply = 0`）。第一个添加流动性的 LP 获得初始份额。

## 添加流动性

```move
public fun add_liquidity<A, B>(
    pool: &mut Pool<A, B>,
    coin_a: Coin<A>,
    coin_b: Coin<B>,
    min_lp: u64,
    ctx: &mut TxContext,
) {
    // 1. 铸造协议费
    mint_protocol_fee(pool);

    // 2. 计算份额
    let shares = if (pool.total_supply == 0) {
        // 首次 LP: 几何平均
        sqrt((amount_a as u128) * (amount_b as u128))
    } else {
        // 后续 LP: 按比例取较小值
        min(shares_a, shares_b)
    };

    // 3. 滑点保护
    assert!(shares >= min_lp, EInsufficientOutput);

    // 4. 更新储备
    pool.reserve_a += amount_a;
    pool.reserve_b += amount_b;
    pool.total_supply += shares;

    // 5. 存入代币
    balance::join(&mut pool.balance_a, coin::into_balance(coin_a));
    balance::join(&mut pool.balance_b, coin::into_balance(coin_b));

    // 6. 铸造 LP Token
    let lp = LP<A, B> { id: object::new(ctx), pool_id: object::id(pool), shares };
    transfer::transfer(lp, ctx.sender());
}
```

## Swap 核心公式

```move
public fun amount_out(
    amount_in: u64,
    reserve_in: u64,
    reserve_out: u64,
    fee_bps: u64,
): u64 {
    let amount_in_with_fee = (amount_in as u128) * (10000 - (fee_bps as u128));
    let numerator = amount_in_with_fee * (reserve_out as u128);
    let denominator = (reserve_in as u128) * 10000 + amount_in_with_fee;
    ((numerator / denominator) as u64)
}
```

### 数值验证

```
输入: amount_in=100, reserve_in=1000, reserve_out=2000, fee_bps=30
amount_in_with_fee = 100 × 9970 = 997,000
numerator = 997,000 × 2000 = 1,994,000,000
denominator = 1000 × 10000 + 997,000 = 10,997,000
output = 1,994,000,000 / 10,997,000 = 181

不含手续费:
output = 100 × 2000 / 1100 = 181.81...
含手续费: 181

手续费效果: 从输出中隐式扣除了 ~0.82 USDC
```

## 移除流动性

```move
public fun remove_liquidity<A, B>(
    pool: &mut Pool<A, B>,
    lp: LP<A, B>,
    min_a: u64,
    min_b: u64,
    ctx: &mut TxContext,
): (Coin<A>, Coin<B>) {
    // 按比例计算取回量
    let amount_a = (shares as u128) * (pool.reserve_a as u128) / (pool.total_supply as u128);
    let amount_b = (shares as u128) * (pool.reserve_b as u128) / (pool.total_supply as u128);

    // 更新储备
    pool.reserve_a -= amount_a;
    pool.reserve_b -= amount_b;
    pool.total_supply -= shares;

    // 取出代币
    let coin_a = coin::take(&mut pool.balance_a, amount_a, ctx);
    let coin_b = coin::take(&mut pool.balance_b, amount_b, ctx);

    // 销毁 LP Token
    let LP { id, pool_id: _, shares: _ } = lp;
    id.delete();

    (coin_a, coin_b)
}
```

## 测试用例

完整测试在 `tests/pool_test.move` 中，覆盖以下场景：

| 测试 | 验证内容 |
|------|---------|
| create_pool | 池创建、管理员权限分配 |
| add_liquidity_first_lp | 首次 LP 份额 = sqrt(a×b) |
| add_liquidity_subsequent | 后续 LP 份额 = min(shares_a, shares_b) |
| swap_a_to_b | Swap 输出量与 amount_out 公式一致 |
| swap_b_to_a | 双向 Swap 正确性 |
| remove_liquidity | 提取量与份额比例一致 |
| slippage_protection | min_output 保护生效 |
| full_lifecycle | 创建→添加→Swap→移除完整流程 |

### 运行测试

```bash
cd src/04_dex/code/uniswap_v2
sui move test
```

## 协议费机制

协议费基于 k 的增长来计算，而不是从每笔交易中直接扣除：

```move
fun mint_protocol_fee<A, B>(pool: &mut Pool<A, B>) {
    let k_current = (pool.reserve_a as u128) * (pool.reserve_b as u128);
    let root_k_current = sqrt(k_current);
    let root_k_last = sqrt(pool.k_last);

    let fee_shares = total_supply * (root_k_current - root_k_last)
        * protocol_fee_bps / (root_k_current * (10000 - protocol_fee_bps));

    pool.total_supply += fee_shares;
    // fee_shares 留在池中，稀释所有 LP
}
```

这种设计的巧妙之处：
- 不需要在每笔 Swap 中计算和分配协议费
- 只在添加/移除流动性时触发
- 协议费份额留在池中，代表协议的所有权
