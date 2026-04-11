# 6.1 聚合器的业务逻辑与架构

## 核心问题

给定：
- 输入代币 A，数量 X
- 输出代币 B
- 可用的流动性源：Cetus、DeepBook、Kriya、...

求：一组交易路径，使得最终获得的代币 B 数量最大。

## 数学表达

$$\max \sum_{i=1}^{n} f_i(x_i)$$

约束条件：

$$\sum_{i=1}^{n} x_i = X, \quad x_i \geq 0$$

其中 $f_i(x_i)$ 是流动性源 $i$ 在输入 $x_i$ 时的输出函数。

### AMM 的输出函数

$$f(x) = \frac{(1 - fee) \cdot x \cdot R_B}{R_A + (1 - fee) \cdot x}$$

### 订单簿的输出函数

离散的：在每个价格档位上匹配挂单。

$$f(x) = \sum_{j=1}^{k} \min(\text{order\_size}_j, \text{remaining}) \text{ at price}_j$$

## 聚合器的三层架构

```
Layer 1: 报价层（Off-chain）
  - 收集所有 DEX 的实时状态
  - 计算最优路径和拆单方案
  - 返回报价给用户

Layer 2: 路由层（On-chain）
  - 在单笔交易中执行拆单
  - 通过 PTB 编排多个 DEX 调用
  - 确保原子性（全部成功或全部回滚）

Layer 3: 结算层（On-chain）
  - 每个 DEX 独立结算
  - 聚合器汇总输出
  - 转移给用户
```

## Move 合约架构

```move
module aggregator {
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const EInsufficientOutput: u64 = 600;
    const EInvalidRoute: u64 = 601;
    const ERouteExpired: u64 = 602;

    public struct RoutePlan has store {
        hops: vector<Hop>,
        deadline: u64,
        min_output: u64,
    }

    public struct Hop has store {
        pool_id: ID,
        dex_type: u8,
        input_token: u8,
        output_token: u8,
        share_bps: u64,
    }

    const DEX_CETUS_CLMM: u8 = 0;
    const DEX_DEEPBOOK: u8 = 1;
    const DEX_AMM: u8 = 2;

    public struct AggregatorCap has key {
        id: UID,
    }

    public fun execute_route<TIn, TOut>(
        plan: &RoutePlan,
        input_coin: Coin<TIn>,
        ctx: &mut TxContext,
    ): Coin<TOut> {
        let now = sui::clock::timestamp_ms(sui::clock::create_for_testing());
        assert!(now <= plan.deadline, ERouteExpired);

        let input_amount = coin::value(&input_coin);
        let mut total_output = 0u64;
        let mut i = 0;
        let coins_out: vector<Coin<TOut>> = vector::empty();

        while (i < vector::length(&plan.hops)) {
            let hop = vector::borrow(&plan.hops, i);
            let hop_input = input_amount * hop.share_bps / 10000;
            let hop_coin = coin::split(&mut input_coin_clone, hop_input, ctx);
            let result = execute_hop(hop, hop_coin, ctx);
            total_output = total_output + coin::value(&result);
            vector::push_back(&mut coins_out, result);
            i = i + 1;
        };

        assert!(total_output >= plan.min_output, EInsufficientOutput);
        merge_all_coins(coins_out)
    }
}
```

## 为什么聚合器需要链下报价

链上搜索最优路径的 Gas 成本太高——每个 DEX 的状态都需要读取，每条路径都需要模拟计算。所以聚合器通常：
1. **链下**：收集所有 DEX 状态，计算最优路径，生成 `RoutePlan`
2. **链上**：用户提交 `RoutePlan`，合约按计划执行

链下报价不是最终承诺——在报价生成到交易执行之间，价格可能已经变化。所以 `RoutePlan` 包含 `deadline` 和 `min_output`（滑点保护）。
