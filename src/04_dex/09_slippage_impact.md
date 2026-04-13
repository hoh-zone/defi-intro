# 4.9 滑点与价格冲击

交易者在 DEX 上交易时面临两种成本：手续费和滑点。理解滑点对于正确使用 DEX 至关重要。

## 价格冲击（Price Impact）vs 滑点（Slippage）

这两个概念经常被混淆，但它们是不同的：

| 概念 | 定义 | 原因 |
|------|------|------|
| 价格冲击 | 交易导致的实际价格偏离 spot price | 池中储备量变化 |
| 滑点 | 交易者实际获得的价格与预期价格的差异 | 价格冲击 + 价格变动 + MEV |

```
Spot Price = 2.0 USDC/SUI（交易前的池中价格）
Price Impact = 3%（因为你的交易量推动价格变化）
实际执行价格 = 2.0 × (1 - 0.03) = 1.94 USDC/SUI

如果你在提交交易时，价格已经从 2.0 变到 1.98:
  Slippage = (2.0 - 1.94) / 2.0 = 3%
  其中：Price Impact 贡献了 3%，市场变动贡献了 0%
```

## 价格冲击的数学

### Price Impact 公式

```
Price Impact = 1 - (实际汇率 / Spot Price)

其中：
  Spot Price = y / x
  实际汇率 = Δy / Δx = y / (x + Δx)

所以：
  PI = 1 - x / (x + Δx) = Δx / (x + Δx)
```

### 价格冲击表

```
Δx / x (交易量/储备量) | Price Impact
0.1%                   | 0.10%
1%                     | 0.99%
5%                     | 4.76%
10%                    | 9.09%
20%                    | 16.67%
50%                    | 33.33%
100%                   | 50.00%
```

关键洞察：**价格冲击与交易量占储备量的比例直接相关**。

### 不同池大小的冲击对比

```
交易 $10,000 USDC → SUI:

小池（TVL $100K）:
  reserve_a(SUI) ≈ $50K, reserve_b(USDC) ≈ $50K
  Δx/x = 10,000/50,000 = 20%
  Price Impact = 16.67%
  实际获得 = $10,000 × (1-16.67%) = $8,333
  损失 = $1,667

大池（TVL $10M）:
  reserve_a(SUI) ≈ $5M, reserve_b(USDC) ≈ $5M
  Δx/x = 10,000/5,000,000 = 0.2%
  Price Impact = 0.20%
  实际获得 = $10,000 × (1-0.20%) = $9,980
  损失 = $20

差异：$1,647 → 大池对小交易者更友好
```

## 滑点保护

### Min Output 机制

交易者指定最小输出量，如果实际输出低于此值，交易回滚：

```move
public fun swap_a_to_b<A, B>(
    pool: &mut Pool<A, B>,
    input: Coin<A>,
    min_output: u64,  // ← 滑点保护参数
    ctx: &mut TxContext,
): Coin<B> {
    let output_amount = amount_out(
        coin::value(&input),
        pool.reserve_a,
        pool.reserve_b,
        pool.fee_bps,
    );
    assert!(output_amount >= min_output, EInsufficientOutput);
    // ... 执行 swap
}
```

### 滑点容忍度设置

```
预期输出: 1,000 USDC
滑点容忍度: 0.5%
min_output = 1000 × (1 - 0.005) = 995 USDC

如果实际输出 >= 995 → 交易成功
如果实际输出 < 995 → 交易回滚

建议的滑点设置:
  稳定币对: 0.1-0.5%
  主流币对: 0.5-1%
  波动大的代币: 1-3%
  低流动性代币: 3-5%
```

## 价格冲击与流动性深度的关系

```
Price Impact = Δx / (x + Δx)

改写为：
  PI = 1 / (1 + x/Δx)

当 x >> Δx（池很大、交易很小）:
  PI ≈ Δx/x → 非常小

当 x ≈ Δx（池和交易差不多大）:
  PI ≈ 50% → 极大

结论：池的深度（x + y 的总量）决定了可以承载多大的交易
```

### 不同交易规模的推荐 DEX 类型

| 交易规模 | Pool TVL | Price Impact | 建议 |
|---------|---------|-------------|------|
| < $1K | > $1M | < 0.1% | 任何 DEX |
| $1K-$10K | > $5M | 0.1-0.5% | CLMM 或大 CPMM |
| $10K-$100K | > $50M | 0.5-2% | CLMM 或 Orderbook |
| > $100K | > $100M | > 2% | Orderbook 或 TWAP 分批 |

## Sui 上的滑点优化

Sui 的 PTB 允许在一个原子交易中完成多跳路由，有效降低滑点：

```
直接 Swap 100K SUI → USDC:
  单池 Price Impact: 3%
  损失: $3,000

PTB 路由 Swap:
  1. 50K SUI → USDC (Pool A): PI 1.5%
  2. 50K SUI → USDC (Pool B): PI 1.5%
  总 PI: ~1.5%
  节省: $1,500
```

这种拆单路由在第 6 章（聚合器）和 4.29 节（多池路由）中详细讨论。
