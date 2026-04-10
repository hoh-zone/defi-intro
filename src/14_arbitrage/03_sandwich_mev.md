# 14.3 三明治攻击与 MEV

## 什么是三明治攻击

三明治攻击是一种 MEV（Maximal Extractable Value）提取策略。攻击者通过在受害者的交易前后各插入一笔交易来获利：

```
区块 N:
  交易 1 (攻击者): 在 DEX 买入 SUI → 推高价格
  交易 2 (受害者): 在 DEX 买入 SUI → 以更高价格成交
  交易 3 (攻击者): 在 DEX 卖出 SUI → 赚取差价
```

## 攻击逻辑

```move
module sandwich_attack {
    use amm::Pool;
    use sui::coin::{Self, Coin};
    use sui::tx_context::TxContext;

    public fun front_run<A, B>(
        pool: &mut Pool<A, B>,
        amount: u64,
        victim_swap_amount: u64,
        ctx: &mut TxContext,
    ): Coin<B> {
        let price_before = amm::get_price(pool);
        let price_after_victim = amm::simulate_swap(pool, victim_swap_amount);
        let target_price = (price_before + price_after_victim) / 2;
        let optimal_amount = calculate_front_run_amount(pool, target_price);
        let input = if (amount < optimal_amount) { amount } else { optimal_amount };
        amm::swap(pool, input, ctx)
    }

    public fun back_run<A, B>(
        pool: &mut Pool<A, B>,
        coin_b: Coin<B>,
        min_profit: u64,
        ctx: &mut TxContext,
    ): Coin<A> {
        let output = amm::swap_reverse(pool, coin_b, ctx);
        let output_amount = coin::value(&output);
        assert!(output_amount >= min_profit, 0);
        output
    }
}
```

## 数值示例

```
初始状态: SUI/USDC 池 1000 SUI / 2000 USDC, 价格 2.0

受害者要买 200 SUI（约 400 USDC）:
  预期价格: ~2.0
  实际价格（无攻击）: ~2.08（滑点 4%）

攻击者前跑:
  先买入 400 SUI（花 ~888 USDC）
  价格推到 ~2.47

受害者交易:
  买入 200 SUI（花 ~534 USDC）
  价格推到 ~3.02

攻击者后跑:
  卖出 400 SUI（获得 ~960 USDC）
  利润: 960 - 888 = 72 USDC

受害者损失:
  预期花费: ~400 USDC
  实际花费: ~534 USDC
  额外损失: ~134 USDC (33.5%)
```

## MEV 的分类

| MEV 类型 | 描述 | 对用户影响 |
|----------|------|-----------|
| 三明治攻击 | 前后夹击 | 负面（用户损失） |
| 套利 | 消除价差 | 正面（市场效率） |
| 清算 | 执行清算 | 正面（协议安全） |
| JIT 流动性 | 在大额交易前临时提供流动性 | 混合 |
| 尾部交易 | 跟随知情交易者 | 负面 |

## Sui 上的 MEV

Sui 的并行执行和 DAG 共识对 MEV 有独特影响：

| 特性 | 对 MEV 的影响 |
|------|--------------|
| 并行执行 | 非冲突交易可以并行，降低排序竞争 |
| Narwhal-Bullshark | DAG 共识，交易排序更难预测 |
| Gas 优先级 | Sui 目前没有小费市场，MEV 竞争不如 EVM 激烈 |
| 对象模型 | 不同对象的交易并行，同一对象的交易串行 |

Sui 上的 MEV 主要集中在：
- DEX 间的价差套利（非恶意的）
- 清算机器人
- 集中流动性的 JIT 做市

三明治攻击在 Sui 上存在但不如 EVM 上普遍，原因是并行执行让交易排序更难精确控制。

## 防御措施

| 防御 | 描述 |
|------|------|
| 滑点保护 | 设置 `min_output`，价格偏离过大自动回滚 |
| 私有交易池 | 交易不进入公共内存池（如 Flashbots Protect） |
| 批量拍卖 | 所有交易在同一价格结算（如 CoW Protocol） |
| 加密内存池 | 交易内容加密，排序者无法看到内容 |
| 意图架构 | 用户表达意图而非具体交易（如 UniswapX） |
