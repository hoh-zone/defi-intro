# 6.5 Sui 聚合器实例分析

## Sui 上的聚合器生态

| 聚合器 | 路由的 DEX | 特点 |
|--------|-----------|------|
| Aftermath | Cetus, DeepBook, Kriya, Turbos, 自有池 | Sui 生态最全面的聚合器 |
| Cetus 闪电聚合 | Cetus 自有池 | Cetus 内部的跨池路由 |
| 其他 | 按需路由 | 专注特定交易对 |

## Cetus 闪电聚合的实现

Cetus 不仅是一个 DEX，它还内置了跨池路由功能。当用户在 Cetus 上交易时，系统会自动在 Cetus 的多个 CLMM 池之间拆单：

```move
module cetus_router {
    use sui::coin::{Self, Coin};

    public struct SwapRoute has store {
        pools: vector<ID>,
        input_types: vector<u8>,
        output_types: vector<u8>,
        amounts: vector<u64>,
    }

    public fun flash_swap<A, B>(
        pools: &mut vector<Pool>,
        route: &SwapRoute,
        input: Coin<A>,
        ctx: &mut TxContext,
    ): Coin<B> {
        let mut current_coin: Coin<Any> = input;
        let mut i = 0;
        while (i < vector::length(&route.pools)) {
            let pool = vector::borrow_mut(pools, i);
            current_coin = swap_in_pool(pool, current_coin, route.amounts[i], ctx);
            i = i + 1;
        };
        current_coin
    }
}
```

### Cetus 路由的特点

1. **仅限 Cetus 内部池**：只在 Cetus 的 CLMM 池之间路由，不涉及其他 DEX
2. **利用不同费率档位**：同一交易对可能有 0.01%、0.05%、0.25%、1% 四种费率的池子
3. **闪电互换（Flash Swap）**：先获得输出代币，再在交易内支付输入代币

## Aftermath 聚合器

Aftermath 是 Sui 上最全面的 DEX 聚合器，路由覆盖几乎所有主要 DEX。

### 架构

```
用户请求 → Aftermath 报价服务（链下）
               ↓
         收集所有 DEX 状态
               ↓
         计算最优拆单方案
               ↓
         返回 RoutePlan
               ↓
用户提交 PTB → Aftermath 路由合约（链上）
               ↓
         执行拆单到多个 DEX
               ↓
         汇总输出返回用户
```

### 集成 DeepBook 的意义

Aftermath 将 DeepBook 作为大额交易的首选路由目标：
- 小额交易（< $1,000）：Cetus CLMM 通常更优（深度足够、手续费低）
- 中额交易（$1,000 - $100,000）：拆单到 Cetus + DeepBook
- 大额交易（> $100,000）：优先 DeepBook（限价单无滑点）

## 聚合器的风险

| 风险 | 描述 | 缓解措施 |
|------|------|----------|
| 报价过期 | 链下报价在执行时已失效 | deadline + min_output |
| 三明治攻击 | 聚合器交易被 MEV 捕获 | 私有交易池、批量拍卖 |
| 合约风险 | 聚合器合约本身可能有漏洞 | 审计 + 白名单 DEX |
| 路由失败 | 部分路径流动性不足 | 部分执行 + 回退机制 |
| Gas 成本 | 多跳路径消耗更多 Gas | 链下预计算 Gas |

## 聚合器对 DeFi 生态的意义

聚合器不是"另一个 DEX"。它是**流动性层的封装**——让用户不需要关心底层有哪些 DEX、每个 DEX 的价格是多少。它降低了用户的决策成本，同时增加了各 DEX 之间的竞争，推动整体流动性质量提升。
