# 17.25 Move 实现 Market Pool（金库与费用）

## 金库设计

```move
public struct Market<phantom T> has key, store {
    // ...
    vault: Balance<T>,    // 抵押品金库
    fee_bps: u64,         // 手续费（基点）
    // ...
}
```

`vault` 是整个预测市场的「银行」——所有的抵押品都在这里。

```
金库的资金来源:
  1. initial_seed（创建时注入）      → create_market
  2. Split 存入                     → split
  3. Buy 支付（LMSR ΔC + 手续费）   → buy_internal

金库的资金流出:
  1. Merge 取回                     → merge
  2. Sell 退款（LMSR ΔC - 手续费）   → sell_internal
  3. Claim 赎回                     → claim

不变量:
  vault_balance = seed + Σ(split) - Σ(merge) + Σ(buy_paid) - Σ(sell_refund) - Σ(claim)
  → 在任意时刻应 >= 0
```

## 手续费流向

```
教学实现: 手续费进入 vault（最简单）

  buy 时: vault += ΔC + fee
  sell 时: vault -= (ΔC - fee)

  效果: 手续费增厚了金库
  → 降低了 seed 不足时的破产风险
  → 但用户无法区分「LMSR 收入」和「手续费收入」

生产实现选项:

  选项 A — 独立 protocol_fees 累积器:
    Market {
        vault: Balance<T>,
        protocol_fees: Balance<T>,  // ← 独立
    }
    → buy 时: vault += ΔC, protocol_fees += fee
    → 好处: 协议收入可独立提取

  选项 B — 分账（vault + treasury）:
    buy 时:
      maker_fee = fee × 20%  → vault（补充流动性）
      taker_fee = fee × 80%  → treasury（协议收入）
    → 参考第 4 章 DEX 的协议费机制

  选项 C — LP 分成:
    如果有外部 LP:
      lp_fee = fee × 50%  → 分给 LP
      protocol_fee = fee × 50% → 协议
    → 参考第 8 章奖励分配器
```

## 金库安全分析

```
场景: b = 1000, seed = 1000, fee = 2%

最坏情况（所有人正确预测 YES）:
  LMSR 净支付:
    收入 = Σ(买 YES 的 ΔC)
    支出 = Σ(claim 的 YES 份额)
    净损 ≈ b × ln(2) = 693

  手续费收入:
    假设总交易量 = 5000
    手续费 = 5000 × 2% = 100

  金库余额:
    = seed - LMSR 净损 + 手续费
    = 1000 - 693 + 100 = 407 USDC

  结论: 足以覆盖 → 安全 ✅

超级最坏情况（seed 不足）:
  seed = 500, b = 1000
  最坏净损 = 693 > 500
  → claim 时 vault 不足 → balance::split abort
  → 最后一批 claimers 无法赎回 → 资金损失

  预防:
    assert!(seed >= b × 693 / 1000) 在 create_market 中
    → 教学版没有这个检查（留给读者作为练习）
```

## 与 DEX Pool 的金库对比

```
DEX Pool (第 4 章):
  balance_a: Balance<A>    // 代币 A
  balance_b: Balance<B>    // 代币 B
  → 两种资产

  swap 时:
    balance_a += amount_in
    balance_b -= amount_out
  → 一进一出，两种资产此消彼长

Prediction Market:
  vault: Balance<T>        // 单一抵押品
  → 只有一种资产

  buy 时:
    vault += ΔC + fee
  → 只有进入

  sell 时:
    vault -= (ΔC - fee)
  → 只有流出

  claim 时:
    vault -= winner_balance
  → 只有流出

区别本质:
  DEX: 资产交换（双向流动）
  PM:  资产注入 → 状态变化 → 最终结算（单向到终态）
```

## Balance 操作安全

```move
// 存入（安全：join 不会失败）
balance::join(&mut market.vault, coin::into_balance(pay));

// 取出（可能失败：vault 余额不足）
let out = balance::split(&mut market.vault, amount);  // 如果 amount > vault → abort

// 查询（安全：只读）
let v = balance::value(&market.vault);
```

```
balance::split 的失败场景:
  1. claim 时 winner 赎回量 > vault 余额
     → 原因: seed 不足以覆盖 LMSR 最坏损失
     → 预防: create_market 时验证 seed >= b × ln(n)

  2. merge 时 amount > vault 余额
     → 理论上不会发生（split 存入多少就只能 merge 多少）
     → 但如果 buy/sell 消耗了 vault...
     → 这是 LMSR 和 CTF 共享金库的风险

  3. sell_internal 时 credit > vault 余额
     → 理论上 LMSR 成本函数保证收入 >= 支出
     → 但精度误差可能导致微小偏差
     → 生产版需要额外检查
```

## 生产改进建议

```
1. 创建时验证 seed:
   assert!(coin::value(&seed) >= (b as u128) * LN2_WAD / WAD);

2. 分离协议费:
   protocol_fees: Balance<T>
   fun collect_protocol_fees(cap: &AdminCap, market, ctx) → Coin<T>

3. 紧急暂停:
   paused: bool
   fun pause(cap: &AdminCap, market)
   → 暂停所有交易和 claim（用于发现 bug 时）

4. 金库审计事件:
   每次金库变化时发出事件 → 链下可重建完整账本

5. 过期退款:
   如果市场超时未结算 → 允许用户按比例取回 vault
   → 防止资金永久锁死
```

## 自检

1. 如果把手续费改为从金库中扣除（而不是从用户额外收取），对金库安全有什么影响？
2. 为什么 LMSR 和 CTF 共享 vault 是一个风险？如何分离？
