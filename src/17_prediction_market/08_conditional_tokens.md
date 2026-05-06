# 17.8 条件资产（Conditional Tokens）

条件代币是预测市场最核心的资产设计——理解它，等于理解了「为什么用户的钱不会凭空消失」。

## 核心思想：1 抵押 = 1 YES + 1 NO

```
Alice 存入 1 USDC 到预测市场合约
合约做了什么:
  1. 把 1 USDC 锁进金库（vault）
  2. 给 Alice 铸造 1 YES 和 1 NO

结算时（假设 YES 赢）:
  1 YES → 可以赎回 1 USDC
  1 NO  → 价值归零

结算时（假设 NO 赢）:
  1 YES → 价值归零
  1 NO  → 可以赎回 1 USDC

无论结果如何:
  Alice 持有的全集合（1 YES + 1 NO）总是值 1 USDC
  → 这就是「完整抵押不变量」的来源
```

## Gnosis CTF（Conditional Token Framework）的思路

Gnosis 在 2019 年提出 CTF，是 Polymarket 等产品的思想来源：

```
CTF 的关键操作:

Split（拆分）:
  输入: 1 USDC
  输出: 1 YES + 1 NO
  金库变化: +1 USDC

Merge（合并）:
  输入: 1 YES + 1 NO
  输出: 1 USDC
  金库变化: -1 USDC

Redeem（赎回）:
  前提: 市场已结算，YES 赢
  输入: 1 YES
  输出: 1 USDC
  金库变化: -1 USDC
```

## 为什么不直接用 `Coin<YES>` 和 `Coin<NO>`

在 Sui Move 中，动态创建新的 Coin 类型需要 OTW（One-Time Witness）。如果每个市场都要独立的 `Coin<YES_MARKET_42>` 类型，工程复杂度很高。

```
方案 A — 每市场独立 Coin 类型:
  优点: YES/NO 是真正的 Coin，可在 DEX 交易
  缺点: 需要 OTW 工厂，每个市场一次发布，部署成本高

方案 B — Position 记账（本章选择）:
  Position { market_id, yes: u64, no: u64 }
  优点: 一个模块支持无限市场，实现简单
  缺点: Position 不能直接在 DEX 上交易（但可以转让）

方案 C — Table 记账:
  Market 内用 Table<address, Balances> 追踪
  优点: 不需要单独的 Position 对象
  缺点: 不可转让，违背 Sui 对象模型精神

生产建议: 如果需要 YES/NO 在 DEX 上交易，用方案 A
          如果只需要结算赎回，方案 B 足够
```

## 数值示例：Split → 交易 → Merge

```
初始状态:
  金库: 0 USDC
  Alice Position: { yes: 0, no: 0 }

Step 1 — Alice Split 100 USDC:
  Alice 存入 100 USDC
  金库: 100 USDC
  Alice Position: { yes: 100, no: 100 }

Step 2 — Alice 把 50 NO 卖给 Bob:
  (通过场外转让或市场操作)
  Alice Position: { yes: 100, no: 50 }
  Bob Position: { yes: 0, no: 50 }

Step 3 — Alice Merge 50 对:
  Alice 消耗 50 YES + 50 NO
  金库退回 50 USDC 给 Alice
  金库: 50 USDC
  Alice Position: { yes: 50, no: 0 }
  Bob Position: { yes: 0, no: 50 }

结算 — 假设 YES 赢:
  Alice claim: 50 YES → 50 USDC
  Bob claim: 50 NO → 0 USDC
  金库: 0 USDC ← 完全清空，没有多余也没有不足
```

### 验证金库平衡

```
全过程中金库余额变化:
  +100 (Split) → -50 (Merge) → -50 (Alice Claim)
  净余额: 0 ✅

如果 NO 赢:
  +100 (Split) → -50 (Merge) → -50 (Bob Claim)
  净余额: 0 ✅

不变量: 只要 Split/Merge 正确实现，金库永远不会出现赤字
```

## Move 中的实现

```move
/// Split: 1 collateral → 1 YES + 1 NO
public fun split<T>(
    market: &mut Market<T>,
    pos: &mut Position,
    coin_in: Coin<T>,
    _ctx: &mut TxContext,
) {
    assert!(object::id(market) == pos.market_id);
    let amt = coin::value(&coin_in);
    assert!(amt > 0);
    balance::join(&mut market.vault, coin::into_balance(coin_in));
    pos.yes = pos.yes + amt;    // ← 1:1 铸造
    pos.no = pos.no + amt;      // ← 1:1 铸造
}
```

```
逐行分析:
  1. 验证 Position 属于这个 Market（防止跨市场操作）
  2. 读取存入金额
  3. 验证非零
  4. 抵押品进入金库（Balance::join）
  5. YES 和 NO 各增加相同数量
  → 金库增量 = YES 增量 = NO 增量 ← 不变量
```

```move
/// Merge: 1 YES + 1 NO → 1 collateral
public fun merge<T>(
    market: &mut Market<T>,
    pos: &mut Position,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(object::id(market) == pos.market_id);
    assert!(amount > 0);
    assert!(pos.yes >= amount && pos.no >= amount);
    pos.yes = pos.yes - amount;
    pos.no = pos.no - amount;
    let out = balance::split(&mut market.vault, amount);
    let c = coin::from_balance(out, ctx);
    transfer::public_transfer(c, ctx.sender());
}
```

```
逐行分析:
  1. 验证市场匹配
  2. 验证非零
  3. 验证用户有足够的 YES 和 NO（缺一不可）
  4. 同时扣减 YES 和 NO
  5. 从金库取出等量抵押
  6. 转给用户
  → 金库减量 = YES 减量 = NO 减量 ← 不变量
```

## 安全检查清单

| 检查项                          | 原因                           | 代码位置                  |
| ------------------------------- | ------------------------------ | ------------------------- |
| `market_id` 匹配                | 防止跨市场篡改余额             | `split`, `merge`, `claim` |
| `amount > 0`                    | 防止零值操作浪费 gas           | `split`, `merge`          |
| `yes >= amount && no >= amount` | Merge 必须两侧都够             | `merge`                   |
| 金库余额 >= 赎回量              | 防止金库不足（理论上不会发生） | `merge`, `claim`          |

## 自检

1. 如果有人只做 Split 不做 Merge，金库会怎样？（答：金库余额只增不减，安全）
2. 如果有 bug 导致 Split 时只铸造了 YES 没铸造 NO，会发生什么？（答：结算时金库不平衡，这就是为什么不变量测试至关重要）
