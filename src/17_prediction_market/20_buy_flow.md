# 17.20 Buy Shares 流程

## 用户视角

```
Alice 想买 100 份 YES:

  1. 她不知道确切要付多少钱（价格取决于当前 q 状态和 b）
  2. 她多付一些（比如 200 USDC），合约自动退回多余的
  3. 她得到：q_yes 增加 100（LMSR 状态更新）

  具体过程:
    当前: q_yes = 300, q_no = 100, b = 1000
    cost = C(400, 100, 1000) - C(300, 100, 1000)
         = b × lse(400, 100, 1000) - b × lse(300, 100, 1000)
         ≈ 1000 × 1.056 - 1000 × 0.954
         = 1056 - 954 = 102 USDC

    手续费(2%): 102 × 0.02 = 2.04 → 2 USDC（截断）
    总支付: 102 + 2 = 104 USDC

    Alice 付了 200 USDC:
      104 USDC → vault
      96 USDC → 退回给 Alice
```

## buy_internal 逐行分析

```move
fun buy_internal<T>(
    market: &mut Market<T>,
    mut coin_in: Coin<T>,     // mut: 后面要 split
    shares: u64,              // 要买的份额数
    yes_side: bool,           // true=YES, false=NO
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // ① 状态检查
    assert!(market.resolved == STATUS_TRADING);
    assert!(clock.timestamp_ms() <= market.trading_closes_ms);
    assert!(shares > 0);

    // ② 计算 LMSR 成本
    let old_c = cost_state(market.q_yes, market.q_no, market.b);
    let (qy2, qn2) = if (yes_side) {
        (market.q_yes + shares, market.q_no)
    } else {
        (market.q_yes, market.q_no + shares)
    };
    let new_c = cost_state(qy2, qn2, market.b);
    let raw = new_c - old_c;                     // ΔC

    // ③ 加手续费
    assert!(raw <= U64_MAX);
    let mut need = (raw as u64);
    let fee = fee_on(need, market.fee_bps);
    need = need + fee;

    // ④ 从用户 Coin 划入金库
    assert!(coin::value(&coin_in) >= need);
    let pay = coin::split(&mut coin_in, need, ctx);
    balance::join(&mut market.vault, coin::into_balance(pay));

    // ⑤ 退回多余
    if (coin::value(&coin_in) > 0) {
        transfer::public_transfer(coin_in, ctx.sender());
    } else {
        coin::destroy_zero(coin_in);
    };

    // ⑥ 更新做市状态
    market.q_yes = qy2;
    market.q_no = qn2;

    // ⑦ 发出事件
    event::emit(Traded {
        market_id: object::id(market),
        side_is_yes: yes_side,
        shares,
        collateral_paid: need,
    });
}
```

### 逐步解析

```
① 状态检查:
   - 市场必须在 TRADING 状态（未结算）
   - 当前时间必须 <= 截止时间
   - 份额 > 0（禁止空操作）

② LMSR 成本计算:
   - old_c = C(q_now)
   - new_c = C(q_after)
   - raw = new_c - old_c = 用户为这 N 份需付的净成本
   - 如果 LMSR 不单调（精度 bug），这里会下溢 abort

③ 手续费:
   - fee = raw × fee_bps / 10000
   - need = raw + fee（总支付 = LMSR 成本 + 手续费）
   - 手续费进入 vault（教学版），生产版可分账

④ 支付:
   - coin::split 从用户 Coin 中精确切出 need 金额
   - 剩余 Coin 保留（⑤ 中退回）
   - coin::into_balance 把支付部分存入 vault

⑤ 退款:
   - 如果用户多付了 → 把剩余 Coin 转回
   - 如果刚好 → destroy_zero 销毁空 Coin
   - 这确保了用户不会多付

⑥ 状态更新:
   - 在一切检查和支付完成后才更新 q
   - 这是 CEI 模式（Check-Effect-Interact 的变体）

⑦ 事件:
   - 包含所有交易细节
   - 链下索引器可以重建完整交易历史
```

## 数值示例

```
市场: b = 1000, fee_bps = 200 (2%)
状态: q_yes = 0, q_no = 0

交易 1 — Alice 买 500 YES:
  old_c = cost(0, 0, 1000)     = 1000 × ln(2)       ≈ 693
  new_c = cost(500, 0, 1000)   = 1000 × ln(e^0.5+1) ≈ 974
  raw = 974 - 693 = 281
  fee = 281 × 200 / 10000 = 5
  need = 286 USDC

  p_YES 变化: 0.50 → 0.62

交易 2 — Bob 买 500 YES:
  old_c = cost(500, 0, 1000) ≈ 974
  new_c = cost(1000, 0, 1000) = 1000 × ln(e^1+1) ≈ 1313
  raw = 1313 - 974 = 339
  fee = 339 × 200 / 10000 = 6
  need = 345 USDC

  p_YES 变化: 0.62 → 0.73

注意: Bob 买同样的 500 份，但花了 345 vs Alice 的 286
→ 因为 Alice 已经推高了价格
→ 这就是 LMSR 的「越多人买越贵」
```

## 边界情况处理

| 场景                      | 结果       | 原因                         |
| ------------------------- | ---------- | ---------------------------- |
| `shares = 0`              | 失败       | `assert!(shares > 0)`        |
| 过了截止时间              | 失败       | `clock > trading_closes_ms`  |
| 已结算                    | 失败       | `resolved != STATUS_TRADING` |
| 付款不足                  | 失败       | `coin::value < need`         |
| 付款刚好                  | 成功       | 空 Coin 被 destroy_zero      |
| 多付                      | 成功       | 剩余退回发送者               |
| q + shares 导致 u128 溢出 | 取决于数值 | 极大 q 时 exp 计算可能失败   |

## 自检

1. 为什么先计算 `cost_state` 再 `coin::split`，而不是先收钱再算？（答：需要知道精确金额才能划账）
2. 如果把 `need` 的手续费改为从 LMSR 退款中扣除（而非加在用户支付上），会有什么区别？
