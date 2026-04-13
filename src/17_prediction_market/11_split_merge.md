# 17.11 Move 实现 Split / Merge

Split 和 Merge 是条件代币的两个基础操作。如果你理解了它们，就理解了「用户的钱为什么不会凭空消失」。

## Split：存抵押 → 铸造全集合

```
操作: 用户存入 X 抵押，获得 X YES + X NO
不变量: vault 增量 = YES 增量 = NO 增量

数值示例:
  用户存入 100 USDC
  vault: +100
  position.yes: +100
  position.no: +100

  净效果: 用户持有的全集合（100 YES + 100 NO）
         总是值 100 USDC（无论哪边赢）
         → 用户没有方向性敞口
```

### Move 代码逐行分析

```move
public fun split<T>(
    market: &mut Market<T>,
    pos: &mut Position,
    coin_in: Coin<T>,
    _ctx: &mut TxContext,
) {
    assert!(object::id(market) == pos.market_id);  // ①
    let amt = coin::value(&coin_in);                // ②
    assert!(amt > 0);                               // ③
    balance::join(                                   // ④
        &mut market.vault,
        coin::into_balance(coin_in)
    );
    pos.yes = pos.yes + amt;                        // ⑤
    pos.no = pos.no + amt;                          // ⑥
    event::emit(SplitEvent {                        // ⑦
        market_id: object::id(market),
        amount: amt,
    });
}
```

```
① 验证 Position 属于当前 Market（防跨市场攻击）
② 读取存入的抵押数量
③ 禁止零值操作
④ 抵押品进入金库:
   coin::into_balance 消费 Coin 对象，返回 Balance
   balance::join 将 Balance 合入金库
   → Coin 被消费后不可再用，没有双花可能
⑤ YES 余额增加 amt
⑥ NO 余额增加 amt
⑦ 发出事件用于链下索引

关键点:
  ④⑤⑥ 三步保证了 vault_增量 == yes_增量 == no_增量
  这是完整抵押不变量的「存入侧」保证
```

## Merge：销毁全集合 → 取回抵押

```
操作: 用户销毁 X YES + X NO，取回 X 抵押
不变量: vault 减量 = YES 减量 = NO 减量

数值示例:
  用户有 position { yes: 300, no: 300 }
  用户 Merge 200

  position: { yes: 100, no: 100 }
  vault: -200
  用户获得 200 USDC
```

### Move 代码逐行分析

```move
public fun merge<T>(
    market: &mut Market<T>,
    pos: &mut Position,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(object::id(market) == pos.market_id);        // ①
    assert!(amount > 0);                                  // ②
    assert!(pos.yes >= amount && pos.no >= amount);       // ③
    pos.yes = pos.yes - amount;                           // ④
    pos.no = pos.no - amount;                             // ⑤
    let out = balance::split(&mut market.vault, amount);  // ⑥
    let c = coin::from_balance(out, ctx);                 // ⑦
    transfer::public_transfer(c, ctx.sender());           // ⑧
    event::emit(MergeEvent {                              // ⑨
        market_id: object::id(market),
        amount,
    });
}
```

```
① 验证市场匹配
② 禁止零值
③ 关键安全检查: YES 和 NO 都必须 >= amount
   缺一不可——如果只检查一侧，攻击者可以用一侧「凭空」取钱
④ YES 扣减
⑤ NO 扣减
⑥ 从金库分出等量 Balance
⑦ Balance → Coin 对象
⑧ 转给发送者

注意:
  ③ 的 && 条件确保 Merge 是「全集合」操作
  不允许只销毁 YES 或只销毁 NO
  → 这是不变量的「取出侧」保证
```

## 完整数值验证

```
场景: 两个用户交替操作

初始: vault = 1000 (seed)

Alice Split 500:
  vault: 1500   Alice: { yes: 500, no: 500 }

Bob Split 300:
  vault: 1800   Bob: { yes: 300, no: 300 }

Alice Merge 200:
  vault: 1600   Alice: { yes: 300, no: 300 }

Bob Merge 300:
  vault: 1300   Bob: { yes: 0, no: 0 }

Alice Merge 300:
  vault: 1000   Alice: { yes: 0, no: 0 }

最终: vault = 1000 = seed ← 完全恢复 ✅

验证:
  Σ(split) = 500 + 300 = 800
  Σ(merge) = 200 + 300 + 300 = 800
  净变化 = 0 ✅
```

## 边界情况

| 操作 | 预期结果 | 保护机制 |
|------|---------|---------|
| Split 0 USDC | 失败 | `assert!(amt > 0)` |
| Merge 超过持有 | 失败 | `assert!(pos.yes >= amount)` |
| 用 A 市场 Position 操作 B 市场 | 失败 | `market_id` 检查 |
| vault 不足以支付 Merge | 失败 | `balance::split` 会 abort |
| 已结算后 Split/Merge | 未限制（教学版） | 生产应加状态检查 |

### 生产改进建议

```move
// 生产版应在 Split/Merge 中检查市场状态
public fun split<T>(market: &mut Market<T>, ...) {
    assert!(market.resolved == STATUS_TRADING);  // ← 新增
    // ...
}
```

## 与 DEX add/remove_liquidity 的对比

```
DEX add_liquidity:
  存入两种代币 → 获得 LP Token
  LP Token 代表「池中份额」
  取出时按比例获得两种代币

Prediction Market Split:
  存入一种抵押 → 获得 YES + NO
  YES/NO 代表「对赌的两侧」
  取出必须两侧同时消耗

本质区别:
  DEX LP: 可以单独赎回（remove_liquidity 按比例）
  PM Split: 必须 1:1 配对赎回（Merge 需双侧相等）
  → 这确保了预测市场的零和属性
```

## 自检

1. 如果有人 Split 100 后把 YES 转让给别人，他还能 Merge 吗？（答：不能，因为他只有 NO，不满足 `yes >= amount`）
2. 为什么 Merge 用 `transfer::public_transfer` 而不是返回 `Coin`？（答：教学版设计选择；返回 `Coin` 也可以，调用者需自行处理。）
