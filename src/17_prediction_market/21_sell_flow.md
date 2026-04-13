# 17.21 Sell Shares 流程

卖出是买入的对称操作：降低 \(q\)，从金库取回抵押。但有几个细节不同。

## 用户视角

```
Bob 之前通过 LMSR 买了 YES，现在想卖掉:

  当前: q_yes = 1000, q_no = 200, b = 1000
  Bob 卖 300 YES:

  old_c = cost(1000, 200, 1000)
  new_c = cost(700, 200, 1000)

  refund = old_c - new_c（注意方向：卖出时 old > new）
         ≈ 1380 - 1153
         = 227 USDC

  手续费(2%): 227 × 0.02 = 4 USDC
  Bob 实际获得: 227 - 4 = 223 USDC
```

## sell_internal 逐行分析

```move
fun sell_internal<T>(
    market: &mut Market<T>,
    shares: u64,
    yes_side: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    // ① 状态检查（与 buy 相同）
    assert!(market.resolved == STATUS_TRADING);
    assert!(clock.timestamp_ms() <= market.trading_closes_ms);
    assert!(shares > 0);

    // ② 计算 LMSR 退款
    let old_c = cost_state(market.q_yes, market.q_no, market.b);
    let (qy2, qn2) = if (yes_side) {
        assert!(market.q_yes >= shares);           // ← 下溢保护
        (market.q_yes - shares, market.q_no)
    } else {
        assert!(market.q_no >= shares);            // ← 下溢保护
        (market.q_yes, market.q_no - shares)
    };
    let new_c = cost_state(qy2, qn2, market.b);
    assert!(old_c >= new_c);                       // ← 单调性保护
    let raw = old_c - new_c;

    // ③ 扣手续费
    assert!(raw <= U64_MAX);
    let mut credit = (raw as u64);
    let fee = fee_on(credit, market.fee_bps);
    assert!(credit >= fee);
    credit = credit - fee;

    // ④ 从金库取出
    market.q_yes = qy2;
    market.q_no = qn2;
    let out = balance::split(&mut market.vault, credit);
    coin::from_balance(out, ctx)
}
```

### 与 buy 的关键差异

```
差异 1 — 方向:
  buy:  ΔC = new_c - old_c（用户付给合约）
  sell: ΔC = old_c - new_c（合约付给用户）

差异 2 — q 下溢检查:
  buy:  q 只增不减 → 没有下溢风险
  sell: q 减少 → 必须检查 q >= shares

差异 3 — 不需要 coin_in:
  buy:  用户传入 Coin，合约划走 need，退回多余
  sell: 用户不需要传入任何 Coin → 合约主动付钱

差异 4 — 返回值:
  buy:  没有返回值（Coin 在函数内处理）
  sell: 返回 Coin<T>（用户获得退款）
```

## 数值推演：买入后立刻卖出

```
初始: q_yes = 0, q_no = 0, b = 1000, fee = 0（忽略手续费）

Step 1 — 买 500 YES:
  cost = C(500, 0, 1000) - C(0, 0, 1000)
       ≈ 974 - 693 = 281 USDC
  q_yes = 500

Step 2 — 立刻卖 500 YES:
  refund = C(500, 0, 1000) - C(0, 0, 1000)
         ≈ 974 - 693 = 281 USDC
  q_yes = 0

  净损益 = -281 + 281 = 0 ← 无手续费时零损失 ✅

加上手续费 (2%):
  Step 1: cost = 281, fee = 5, 总付 286
  Step 2: refund = 281, fee = 5, 实收 276
  净损益 = -286 + 276 = -10 USDC（手续费损失）
```

## 数值推演：中间有其他交易

```
初始: q_yes = 0, q_no = 0, b = 1000, fee = 0

Step 1 — Alice 买 500 YES:
  cost = 281 USDC,  q_yes = 500

Step 2 — Bob 买 500 YES:
  cost = C(1000,0) - C(500,0) ≈ 1313 - 974 = 339 USDC
  q_yes = 1000

Step 3 — Alice 卖 500 YES:
  refund = C(1000,0) - C(500,0) ≈ 1313 - 974 = 339 USDC
  q_yes = 500

  Alice 的净损益 = -281 + 339 = +58 USDC
  → Alice 赚了！因为 Bob 的买入推高了价格

这就是 LMSR 的交易利润来源:
  早买入 → 价格被后来者推高 → 卖出时获利
  → 与「信息越早越准确越有价值」一致
```

## 卖出限制

```
限制 1 — 不能卖超过 q:
  q_yes = 300, 想卖 500 YES → assert!(market.q_yes >= shares) 失败
  → 卖出量 <= 当前 q 值

限制 2 — q_yes 和 q_no 不能为负:
  u64 没有负数 → 下溢自动 abort
  → 但我们在 abort 前就 assert 了（更好的错误信息）

限制 3 — 卖出后金库余额:
  credit = old_c - new_c（扣费后）
  如果 vault < credit → balance::split abort
  → 理论上如果 seed 足够，不会发生
  → 实际如果 seed 不足 + 大量单向交易 → 可能出问题
```

## 外部接口

```move
public fun sell_yes<T>(
    market: &mut Market<T>,
    shares: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    sell_internal(market, shares, true, clock, ctx)
}

public fun sell_no<T>(
    market: &mut Market<T>,
    shares: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    sell_internal(market, shares, false, clock, ctx)
}
```

```
为什么 sell 返回 Coin 而 buy 不返回:
  buy → 用户传入 Coin，内部处理退款
  sell → 合约创建新 Coin 返给用户

  另一种设计: sell 也可以 transfer::public_transfer 而不返回
  → 但返回 Coin 更灵活（调用者可以决定做什么）
  → 符合 Move 的 composability 原则
```

## 自检

1. 如果 LMSR 精度不够导致 `old_c < new_c`（买入反而降低了成本状态），`sell_internal` 的 `assert!(old_c >= new_c)` 会怎样？
2. 在什么场景下卖出时金库可能不足？如何预防？
