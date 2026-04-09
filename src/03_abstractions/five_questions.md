# 3.4 协议分析统一框架：五问法

## 五个问题

面对任何一个 DeFi 协议，依次回答以下五个问题：

| 序号 | 问题 | 揭示的内容 |
|------|------|-----------|
| 1 | **资产从哪来？** | 谁在为协议提供资金，他们的动机是什么 |
| 2 | **资产到哪去？** | 资金在协议内部如何流转，最终流到哪里 |
| 3 | **谁在什么条件下可以动资产？** | 权限模型、触发条件、治理边界 |
| 4 | **价格从哪来？** | 价格信号的真实来源和信任假设 |
| 5 | **失败会怎样？** | 极端场景下的损失分配和恢复机制 |

这五个问题不需要你对协议有任何前置知识。只要你能找到答案，你就理解了这个协议的核心机制和风险边界。

## 用五问法分析一个 AMM 池

以一个标准的 SUI/USDC 恒定乘积 AMM 为例：

### Q1：资产从哪来？

LP（流动性提供者）将自己的 SUI 和 USDC 按当前池内比例存入池子。作为交换，LP 获得 LP Token（在 Sui 上是一个 Owned Object）。

```move
public fun provide_liquidity<T1, T2>(
    pool: &mut Pool<T1, T2>,
    coin_a: Coin<T1>,
    coin_b: Coin<T2>,
    ctx: &mut TxContext,
): Position<T1, T2> {
    let amount_a = coin::value(&coin_a);
    let amount_b = coin::value(&coin_b);
    assert!(amount_a * pool.reserve_b == amount_b * pool.reserve_a, EInvalidRatio);
    let shares = calculate_shares(amount_a, pool.reserve_a, pool.total_shares);
    pool.reserve_a = pool.reserve_a + amount_a;
    pool.reserve_b = pool.reserve_b + amount_b;
    pool.total_shares = pool.total_shares + shares;
    merge(&mut pool.coin_a, coin_a);
    merge(&mut pool.coin_b, coin_b);
    Position { id: object::new(ctx), pool_id: object::id(pool), shares }
}
```

LP 的动机：赚取交易手续费。

### Q2：资产到哪去？

两种去向：
- **Swap**：交易者用 USDC 换 SUI（或反过来），资产在池子和交易者之间流转
- **Remove Liquidity**：LP 销毁 LP Token，取回对应的 SUI + USDC

### Q3：谁在什么条件下可以动资产？

| 角色 | 能做什么 | 条件 |
|------|----------|------|
| 交易者 | Swap | 支付的输入代币足够（有余额） |
| LP | 存入/取出流动性 | 存入时保持比例；取出时不超过自己的份额 |
| 管理员 | 调整费率、暂停 | 持有 AdminCap |

```move
public fun swap<T1, T2>(
    pool: &mut Pool<T1, T2>,
    input: Coin<T1>,
    _: &AdminCap,
    ctx: &mut TxContext,
): Coin<T2> {
    assert!(!pool.paused, EPoolPaused);
    let amount_in = coin::value(&input);
    let amount_out = get_amount_out(amount_in, pool.reserve_a, pool.reserve_b, pool.fee_bps);
    assert!(pool.reserve_b >= amount_out, EInsufficientLiquidity);
    pool.reserve_a = pool.reserve_a + amount_in;
    pool.reserve_b = pool.reserve_b - amount_out;
    merge(&mut pool.coin_a, input);
    coin::take(&mut pool.coin_b, amount_out, ctx)
}
```

注意 `assert!(!pool.paused, EPoolPaused)` —— 管理员可以在极端情况下暂停池子，阻止所有交易。

### Q4：价格从哪来？

AMM 不依赖外部价格源。价格由池内两种代币的储备量决定：

$$P = \frac{R_B}{R_A}$$

这是 AMM 的优势（不依赖预言机），也是它的风险（价格可以被大额交易操纵）。

### Q5：失败会怎样？

| 失败场景 | 后果 | 损失承担者 |
|----------|------|-----------|
| 大额交易操纵价格 | 极高滑点 | 交易者 |
| LP 集中撤资 | 池子枯竭，无法 swap | 后续的交易者 |
| 无常损失 | LP 取回的资产价值低于持币不动 | LP |
| 合约漏洞 | 资金被盗 | 所有 LP |

### 五问法分析结果汇总

```
Q1 资产从哪来？    → LP 提供双边流动性，动机是手续费收益
Q2 资产到哪去？    → swap 时给交易者；撤资时还给 LP
Q3 谁可以动资产？  → 交易者 swap，LP 管理仓位，管理员调参
Q4 价格从哪来？    → 池内储备量比例（不依赖预言机）
Q5 失败会怎样？    → 无常损失由 LP 承担；操纵由交易者承担
```

## 如何用五问法快速理解新协议

下次看到一个新协议时，不要先看 UI，不要先看收益率。打开它的合约代码，回答这五个问题。如果任何一个问题找不到明确答案，那就是风险点。
