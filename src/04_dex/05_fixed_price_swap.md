# 4.5 Fixed Price Swap

最简单的 DEX：固定汇率池子。用户向池子存入 SUI 和 USDC，其他人走这个池子按固定汇率兑换。

## 问题：为什么需要 Swap

Alice 有 100 SUI，她想要 USDC。Bob 有 USDC，他想要 SUI。他们如何交换？

最简单的方案：**固定汇率兑换**。比如 1 SUI = 2 USDC，永远不变。

## 固定汇率池子设计

```
┌──────────────────────────────────────┐
│         FixedPricePool               │
│                                      │
│  ┌──────────┐    ┌──────────┐       │
│  │ SUI 余额 │    │USDC 余额 │       │
│  │ 5000 SUI │    │ 10000    │       │
│  └──────────┘    └──────────┘       │
│                                      │
│  rate: 1 SUI = 2 USDC (固定)        │
│  owner: AdminCap (管理员)            │
└──────────────────────────────────────┘

操作:
  add_liquidity  — 存入 SUI + USDC 到池子
  remove_liquidity — 从池子取回 SUI / USDC
  swap_a_to_b    — 用 SUI 换 USDC
  swap_b_to_a    — 用 USDC 换 SUI
  set_rate       — 管理员修改汇率
```

## 完整 Move 实现

```move
/// module: fixed_swap::fixed_swap
/// 固定汇率兑换池
/// 1 SUI = rate USDC，汇率由管理员设定
module fixed_swap::fixed_swap;
use sui::coin::{Self, Coin};
use sui::balance::{Self, Balance};
use sui::object::{Self, UID, ID};

// ===== 错误码 =====
const EInvalidAmount: u64 = 0;
const EInsufficientLiquidity: u64 = 1;
const ERateNotSet: u64 = 2;
const EInvalidRate: u64 = 3;
const EWrongPool: u64 = 4;

// ===== 常量 =====
const RATE_PRECISION: u64 = 1_000_000_000; // 汇率精度（1e9）

// ===== 事件 =====
public struct SwapEvent has copy, drop {
    a_to_b: bool,
    amount_in: u64,
    amount_out: u64,
}

public struct LiquidityEvent has copy, drop {
    is_add: bool,
    amount_a: u64,
    amount_b: u64,
}

// ===== 结构体 =====

/// 固定汇率兑换池（Shared Object）
/// A = 支付代币（如 SUI），B = 接收代币（如 USDC）
/// rate_a_to_b: 1 个 A 兑换多少个 B（精度 RATE_PRECISION）
/// 例: rate_a_to_b = 2_000_000_000 表示 1 A = 2 B
public struct Pool<phantom A, phantom B> has key {
    id: UID,
    balance_a: Balance<A>,  // 池中的 A 代币
    balance_b: Balance<B>,  // 池中的 B 代币
    rate_a_to_b: u64,       // 固定汇率: 1 A = rate B
}

/// 管理员能力
public struct AdminCap<phantom A, phantom B> has key, store {
    id: UID,
    pool_id: ID,
}

// ===== 创建池子 =====

/// 创建新的固定汇率池
/// rate_a_to_b: 1 A = rate B（单位：1e9 精度）
/// 例: rate = 2_000_000_000 → 1 A = 2 B
public fun create_pool<A, B>(
    rate_a_to_b: u64,
    ctx: &mut TxContext,
) {
    assert!(rate_a_to_b > 0, EInvalidRate);

    let pool = Pool<A, B> {
        id: object::new(ctx),
        balance_a: balance::zero(),
        balance_b: balance::zero(),
        rate_a_to_b,
    };
    let pool_id = object::id(&pool);

    let cap = AdminCap<A, B> {
        id: object::new(ctx),
        pool_id,
    };

    transfer::share_object(pool);
    transfer::transfer(cap, ctx.sender());
}

// ===== 存入流动性 =====

/// 向池子存入 A 代币
/// 任何人都可以调用，为池子提供流动性
public fun add_liquidity_a<A, B>(
    pool: &mut Pool<A, B>,
    coin: Coin<A>,
) {
    let amount = coin::value(&coin);
    assert!(amount > 0, EInvalidAmount);
    balance::join(&mut pool.balance_a, coin::into_balance(coin));
    sui::event::emit(LiquidityEvent { is_add: true, amount_a: amount, amount_b: 0 });
}

/// 向池子存入 B 代币
public fun add_liquidity_b<A, B>(
    pool: &mut Pool<A, B>,
    coin: Coin<B>,
) {
    let amount = coin::value(&coin);
    assert!(amount > 0, EInvalidAmount);
    balance::join(&mut pool.balance_b, coin::into_balance(coin));
    sui::event::emit(LiquidityEvent { is_add: true, amount_a: 0, amount_b: amount });
}

/// 同时存入 A 和 B（可选）
public fun add_liquidity<A, B>(
    pool: &mut Pool<A, B>,
    coin_a: Coin<A>,
    coin_b: Coin<B>,
) {
    let amount_a = coin::value(&coin_a);
    let amount_b = coin::value(&coin_b);
    assert!(amount_a > 0 || amount_b > 0, EInvalidAmount);

    if (amount_a > 0) {
        balance::join(&mut pool.balance_a, coin::into_balance(coin_a));
    } else {
        coin::destroy_zero(coin_a);
    };
    if (amount_b > 0) {
        balance::join(&mut pool.balance_b, coin::into_balance(coin_b));
    } else {
        coin::destroy_zero(coin_b);
    };

    sui::event::emit(LiquidityEvent { is_add: true, amount_a, amount_b });
}

// ===== 取出流动性（管理员） =====

/// 管理员从池子取出 A 代币
public fun withdraw_a<A, B>(
    _cap: &AdminCap<A, B>,
    pool: &mut Pool<A, B>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<A> {
    assert!(amount > 0, EInvalidAmount);
    assert!(balance::value(&pool.balance_a) >= amount, EInsufficientLiquidity);
    sui::event::emit(LiquidityEvent { is_add: false, amount_a: amount, amount_b: 0 });
    coin::take(&mut pool.balance_a, amount, ctx)
}

/// 管理员从池子取出 B 代币
public fun withdraw_b<A, B>(
    _cap: &AdminCap<A, B>,
    pool: &mut Pool<A, B>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<B> {
    assert!(amount > 0, EInvalidAmount);
    assert!(balance::value(&pool.balance_b) >= amount, EInsufficientLiquidity);
    sui::event::emit(LiquidityEvent { is_add: false, amount_a: 0, amount_b: amount });
    coin::take(&mut pool.balance_b, amount, ctx)
}

// ===== Swap =====

/// 用 A 换 B（固定汇率）
/// amount_out = amount_in × rate / RATE_PRECISION
public fun swap_a_to_b<A, B>(
    pool: &mut Pool<A, B>,
    coin_in: Coin<A>,
    ctx: &mut TxContext,
): Coin<B> {
    let amount_in = coin::value(&coin_in);
    assert!(amount_in > 0, EInvalidAmount);

    // 计算输出: amount_out = amount_in × rate / precision
    let amount_out = amount_in * pool.rate_a_to_b / RATE_PRECISION;
    assert!(amount_out > 0, EInvalidAmount);
    assert!(balance::value(&pool.balance_b) >= amount_out, EInsufficientLiquidity);

    // 输入代币进入池子，输出代币从池子取出
    balance::join(&mut pool.balance_a, coin::into_balance(coin_in));
    let coin_out = coin::take(&mut pool.balance_b, amount_out, ctx);

    sui::event::emit(SwapEvent { a_to_b: true, amount_in, amount_out });
    coin_out
}

/// 用 B 换 A（反向固定汇率）
/// amount_out = amount_in × RATE_PRECISION / rate
public fun swap_b_to_a<A, B>(
    pool: &mut Pool<A, B>,
    coin_in: Coin<B>,
    ctx: &mut TxContext,
): Coin<A> {
    let amount_in = coin::value(&coin_in);
    assert!(amount_in > 0, EInvalidAmount);
    assert!(pool.rate_a_to_b > 0, ERateNotSet);

    // 反向: amount_out = amount_in × precision / rate
    let amount_out = amount_in * RATE_PRECISION / pool.rate_a_to_b;
    assert!(amount_out > 0, EInvalidAmount);
    assert!(balance::value(&pool.balance_a) >= amount_out, EInsufficientLiquidity);

    balance::join(&mut pool.balance_b, coin::into_balance(coin_in));
    let coin_out = coin::take(&mut pool.balance_a, amount_out, ctx);

    sui::event::emit(SwapEvent { a_to_b: false, amount_in, amount_out });
    coin_out
}

// ===== 管理员操作 =====

/// 修改汇率
public fun set_rate<A, B>(
    _cap: &AdminCap<A, B>,
    pool: &mut Pool<A, B>,
    new_rate: u64,
) {
    assert!(new_rate > 0, EInvalidRate);
    pool.rate_a_to_b = new_rate;
}

// ===== 查询 =====

public fun balance_a<A, B>(pool: &Pool<A, B>): u64 {
    balance::value(&pool.balance_a)
}

public fun balance_b<A, B>(pool: &Pool<A, B>): u64 {
    balance::value(&pool.balance_b)
}

public fun rate<A, B>(pool: &Pool<A, B>): u64 {
    pool.rate_a_to_b
}

/// 预计算: 用 amount_a 个 A 可以换多少 B
public fun quote_a_to_b<A, B>(pool: &Pool<A, B>, amount_a: u64): u64 {
    amount_a * pool.rate_a_to_b / RATE_PRECISION
}

/// 预计算: 用 amount_b 个 B 可以换多少 A
public fun quote_b_to_a<A, B>(pool: &Pool<A, B>, amount_b: u64): u64 {
    amount_b * RATE_PRECISION / pool.rate_a_to_b
}

// ===== 测试辅助 =====

#[test_only]
public fun destroy_pool<A, B>(pool: Pool<A, B>) {
    let Pool { id, balance_a, balance_b, rate_a_to_b: _ } = pool;
    balance::destroy_zero(balance_a);
    balance::destroy_zero(balance_b);
    id.delete();
}

#[test_only]
public fun destroy_admin_cap<A, B>(cap: AdminCap<A, B>) {
    let AdminCap { id, pool_id: _ } = cap;
    id.delete();
}
```

## 数值验证

```
设 rate = 2_000_000_000（1 A = 2 B）

A → B:
  输入 100 A
  输出 = 100 × 2_000_000_000 / 1_000_000_000 = 200 B ✅

B → A:
  输入 400 B
  输出 = 400 × 1_000_000_000 / 2_000_000_000 = 200 A ✅

非整数汇率 (1 A = 1.5 B):
  rate = 1_500_000_000
  输入 100 A
  输出 = 100 × 1_500_000_000 / 1_000_000_000 = 150 B ✅
```

## 完整使用流程

```
1. 管理员创建池子
   create_pool<SUI, USDC>(rate: 2_000_000_000)
   → Pool (Shared Object) + AdminCap (Owned)

2. 管理员存入初始流动性
   add_liquidity<SUI, USDC>(pool, 5000 SUI, 10000 USDC)
   → 池中有 5000 SUI + 10000 USDC

3. 用户 Alice: 用 SUI 换 USDC
   swap_a_to_b(pool, 100 SUI)
   → 池中 SUI: 5000 + 100 = 5100
   → 池中 USDC: 10000 - 200 = 9800
   → Alice 获得 200 USDC

4. 用户 Bob: 用 USDC 换 SUI
   swap_b_to_a(pool, 400 USDC)
   → 池中 SUI: 5100 - 200 = 4900
   → 池中 USDC: 9800 + 400 = 10200
   → Bob 获得 200 SUI

5. 管理员取出流动性
   withdraw_a(cap, pool, 1000)
   withdraw_b(cap, pool, 2000)
```

## 对象关系图

```
┌─────────────────────────────────────┐
│        Pool<SUI, USDC>              │
│           (Shared Object)           │
│                                     │
│  balance_a: 4900 SUI               │
│  balance_b: 10200 USDC             │
│  rate: 2_000_000_000               │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│   AdminCap<SUI, USDC>               │
│        (Owned by Admin)             │
│   pool_id: → Pool                   │
└─────────────────────────────────────┘

操作权限:
  add_liquidity:     任何人
  swap_a_to_b:       任何人
  swap_b_to_a:       任何人
  withdraw_a/b:      仅 AdminCap 持有者
  set_rate:          仅 AdminCap 持有者
```

## 查询方法

```
用户在 swap 前可以先查询:

quote_a_to_b(pool, 100)
→ 返回 200（预计算输出）

quote_b_to_a(pool, 200)
→ 返回 100（预计算输出）

balance_a(pool)
→ 查看池中有多少 SUI

rate(pool)
→ 查看当前汇率
```

## 固定汇率的问题

### 1. 与市场脱节

```
池子汇率: 1 SUI = 2 USDC
市场价格: 1 SUI = 3 USDC

→ 套利者用 2000 USDC 在池子买到 1000 SUI
→ 市场上卖出 1000 SUI 获得 3000 USDC
→ 无风险利润 1000 USDC
→ 池中 SUI 被掏空 → 无法继续交易
```

### 2. 无法响应供需变化

```
大量用户想买 SUI:
  固定汇率 → 池中 SUI 被买光 → 无法继续交易
  AMM → SUI 价格上升 → 供需自动平衡
```

### 3. 需要外部定价者

固定汇率需要管理员来设定和维护汇率。这引入了中心化风险——如果管理员犯错或作恶，所有用户都受影响。

## 固定汇率的价值

虽然不适合通用 DEX，但固定汇率在某些场景下仍然有用：

| 场景 | 为什么用固定汇率 |
|------|----------------|
| 稳定币互换 | USDC/USDT 应该接近 1:1 |
| 测试环境 | 简单可预测的定价 |
| 包装代币 | wSUI ↔ SUI 应该 1:1 |
| 场外交易 | 双方约定价格 |

## 总结

```
Fixed Price Swap 的完整实现:
  Pool (Shared) — 存储 A/B 两种代币
  AdminCap (Owned) — 管理员权限

核心方法:
  add_liquidity_a/b — 存入代币到池子
  withdraw_a/b — 管理员取出代币
  swap_a_to_b — 固定汇率兑换 A → B
  swap_b_to_a — 固定汇率兑换 B → A
  quote_a_to_b/b_to_a — 预计算输出

关键公式:
  A → B: amount_out = amount_in × rate / precision
  B → A: amount_out = amount_in × precision / rate

下一步:
  如何让价格自动响应供需？→ Liquidity Pool（4.6）
```
